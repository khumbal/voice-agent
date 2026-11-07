import * as vscode from 'vscode';
import { randomUUID } from 'crypto';
import {
    FSWatcher, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, unlinkSync, watch, writeFileSync,
} from 'fs';
import { homedir } from 'os';
import { isAbsolute, join } from 'path';

// Two ways in. VS Code routes vscode://local.voice-agent-terminal/send?text=<base64url>&execute=1|0&token=<t>&ack=<id>
// to the last active window, which delivers to what has focus there and then. The text is base64url because Uri.query
// arrives already percent-decoded, so a raw "&&" would split the query. Only the voice-agent recorder can read this
// token, so a link on a web page cannot type into (or run in) the terminal.
// The recorder prefers this window's inbox: at the key press it asks the focused window to remember where the keyboard
// is (a snapshot), and at the end sends the text there, even if the user has since moved to another window, tab or
// app, and the terminal is hidden.
// vscode://local.voice-agent-terminal/terminal?cwd=<base64url dir>&until=<ms>&token=<t>&ack=<id> opens a new terminal
// tab in <dir> and runs the Claude Code CLI there; the command is fixed here, never taken from the link.
const dataDir = join(homedir(), '.local/share/voice-agent');
const tokenPath = join(dataDir, 'uri-token');
// The recorder waits for ack/<id> to learn where the text went; without it the text stays on its clipboard.
const ackDir = join(dataDir, 'ack');
// {window, pid, focused}: which window the recorder sends its snapshot request to.
const focusPath = join(dataDir, 'focus.json');
const windowId = randomUUID();
const inbox = join(dataDir, 'windows', windowId);

// One request at a time: the focus probe borrows the clipboard, and two probes interleaving would restore each other's.
let queue: Promise<void> = Promise.resolve();
const enqueue = (work: () => Promise<void>) => (queue = queue.then(work, work));

type Target =
    | { kind: 'editor'; document: vscode.TextDocument; version: number; selections: readonly vscode.Selection[] }
    | { kind: 'terminal'; terminal: vscode.Terminal }
    | { kind: 'none' };
const snapshots = new Map<string, Target>();
// A document's version right after this extension typed into it: a recording that began while an earlier one was
// still transcribing remembered the version before that text, and goes after it rather than failing.
const ownEdits = new WeakMap<vscode.TextDocument, number>();
const MAX_SNAPSHOTS = 20; // a recorder that never sent (cancelled, crashed) leaves its snapshot here
let watcher: FSWatcher | undefined;

export function activate(context: vscode.ExtensionContext) {
    context.subscriptions.push(vscode.window.registerUriHandler({
        handleUri: uri => enqueue(() => handleUri(uri)),
    }));
    mkdirSync(inbox, { recursive: true, mode: 0o700 });
    watcher = watch(inbox, () => drain());
    drain();
    writeFocus(vscode.window.state.focused);
    context.subscriptions.push(vscode.window.onDidChangeWindowState(state => writeFocus(state.focused)));
}

export function deactivate() {
    watcher?.close();
    writeFocus(false);
    rmSync(inbox, { recursive: true, force: true });
}

function writeFocus(focused: boolean) {
    // Losing focus clears only this window's claim: the window that gained it may have written first.
    if (!focused) {
        try {
            if (JSON.parse(readFileSync(focusPath, 'utf8')).window !== windowId) return;
        } catch { return; }
    }
    writeAtomically(focusPath, JSON.stringify({ window: windowId, pid: process.pid, focused }));
}

function writeAtomically(path: string, data: string) {
    mkdirSync(join(path, '..'), { recursive: true });
    writeFileSync(`${path}.${process.pid}.tmp`, data);
    renameSync(`${path}.${process.pid}.tmp`, path);
}

// fs.watch fires more than once per file, and a drain can overlap one: a request is claimed by renaming it away
// before it is queued, so it is handled once. The recorder renames finished requests in, so a *.json is complete.
function drain() {
    let names: string[];
    try { names = readdirSync(inbox).filter(n => n.endsWith('.json')).sort(); } catch { return; }
    for (const name of names) {
        const claimed = join(inbox, `${name}.claimed`);
        try { renameSync(join(inbox, name), claimed); } catch { continue; }
        let request: Record<string, unknown> = {};
        try { request = JSON.parse(readFileSync(claimed, 'utf8')); } catch { /* answered below as unreadable */ }
        try { unlinkSync(claimed); } catch { /* already gone */ }
        enqueue(() => handleRequest(request));
    }
}

async function handleRequest(request: Record<string, unknown>) {
    const id = String(request.id ?? '');
    const ack = String(request.ack ?? id);
    if (!/^[0-9a-f]{32}$/.test(ack)) return;
    let outcome: string;
    try {
        // Past `until` the recorder has stopped waiting: a snapshot then would borrow the clipboard with nobody to
        // put back what the probe cannot, and a send would type text the user was told is on the clipboard.
        if (Date.now() > Number(request.until ?? 0)) {
            outcome = 'error expired';
        } else if (request.kind === 'snapshot') {
            outcome = await takeSnapshot(id, Number(request.until));
        } else if (request.kind === 'send') {
            const target = snapshots.get(String(request.snapshot ?? ''));
            snapshots.delete(String(request.snapshot ?? ''));
            outcome = target ? await deliver(target, String(request.text ?? ''), request.execute === true)
                : 'error this window no longer knows where to type (reloaded?)';
        } else {
            outcome = 'error unknown request';
        }
    } catch (error) {
        outcome = `error ${error instanceof Error ? error.message : String(error)}`;
    }
    writeAck(ack, outcome);
}

// Where the keyboard is now. Only for the focused window: focus.json may still name this one when its blur event has
// not been handled yet, and the press belongs to the window that has focus.
// One remembered after the recorder stopped waiting would be a place it never learns of: it would send by the link.
async function takeSnapshot(id: string, until: number): Promise<string> {
    if (!vscode.window.state.focused) return 'error unfocused';
    const target = await currentTarget();
    if (Date.now() > until) return 'error expired';
    snapshots.set(id, target);
    while (snapshots.size > MAX_SNAPSHOTS) snapshots.delete(snapshots.keys().next().value!);
    return target.kind === 'terminal' ? `terminal ${target.terminal.name}` : target.kind;
}

async function currentTarget(): Promise<Target> {
    const editor = vscode.window.activeTextEditor;
    if (editor && await hasKeyboardFocus(editor)) {
        return { kind: 'editor', document: editor.document, version: editor.document.version,
                 selections: editor.selections };
    }
    const terminal = vscode.window.activeTerminal;
    return terminal ? { kind: 'terminal', terminal } : { kind: 'none' };
}

async function handleUri(uri: vscode.Uri) {
    const params = new URLSearchParams(uri.query);
    let token = '';
    try { token = readFileSync(tokenPath, 'utf8').trim(); } catch { /* no token file: reject every URI */ }
    if (!token || params.get('token') !== token) return;
    if (uri.path === '/terminal') {
        // cwd is base64url for the same reason as text; past `until` the caller has reported failure, so a terminal
        // opening then would surprise the user. A link without a readable `until` never opens one.
        const cwd = Buffer.from(params.get('cwd') ?? '', 'base64url').toString('utf8');
        const until = Number(params.get('until') || NaN);
        let outcome: string;
        try {
            outcome = !(Date.now() <= until) ? 'error expired' : openClaudeTerminal(cwd);
        } catch (error) {
            outcome = `error ${error instanceof Error ? error.message : String(error)}`;
        }
        const ack = params.get('ack') ?? '';
        if (/^[0-9a-f]{32}$/.test(ack)) writeAck(ack, outcome);
        return;
    }
    const text = Buffer.from(params.get('text') ?? '', 'base64url').toString('utf8');
    if (!text) return;

    // The recorder stops waiting for the ack at `until` and keeps the text on the clipboard: after that (an "open this
    // URI?" prompt, a slow start) typing it, or running it, would surprise the user and double a paste.
    const until = Number(params.get('until') ?? 'Infinity');
    let outcome: string;
    try {
        outcome = Date.now() > until ? 'error expired'
            : await deliver(await currentTarget(), text, params.get('execute') === '1');
    } catch (error) {
        outcome = `error ${error instanceof Error ? error.message : String(error)}`;
    }
    const ack = params.get('ack') ?? '';
    if (/^[0-9a-f]{32}$/.test(ack)) writeAck(ack, outcome);
}

// Returns "terminal-claude <name>" or "error <why>". The shell starts in cwd, so a missing directory is refused rather
// than left to the shell's fallback to the home directory. Only an absolute cwd: statSync would resolve a relative one
// against the extension host's directory, createTerminal against the workspace folder.
function openClaudeTerminal(cwd: string): string {
    if (!isAbsolute(cwd)) return `error cwd must be an absolute path: ${cwd}`;
    try {
        if (!statSync(cwd).isDirectory()) return `error not a directory: ${cwd}`;
    } catch {
        return `error no such directory: ${cwd}`;
    }
    const terminal = vscode.window.createTerminal({ name: 'Claude', cwd });
    terminal.show();
    terminal.sendText('claude', true);
    return `terminal-claude ${terminal.name}`;
}

// Renamed into place, so the recorder never reads a half-written ack.
function writeAck(ack: string, outcome: string) {
    mkdirSync(ackDir, { recursive: true });
    writeFileSync(join(ackDir, `${ack}.tmp`), outcome);
    renameSync(join(ackDir, `${ack}.tmp`), join(ackDir, ack));
}

// Returns "editor", "terminal" (typed), "terminal-run" (typed and Enter pressed) or "error <why>".
async function deliver(target: Target, text: string, execute: boolean): Promise<string> {
    if (target.kind === 'editor') {
        // Only where the cursor was: a selection made since, or an edit that moved the text, is not where it was said.
        const editor = vscode.window.visibleTextEditors.find(e => e.document === target.document);
        if (!editor) return 'error the editor is no longer open';
        const version = target.document.version;
        const selections = version === target.version ? target.selections
            : ownEdits.get(target.document) === version ? editor.selections : undefined;
        if (!selections) return 'error the file changed while you were speaking';
        const inserted = await editor.edit(edit => selections.forEach(s => edit.replace(s, text)));
        if (!inserted) return 'error the editor did not accept the text (read-only?)';
        ownEdits.set(target.document, target.document.version);
        vscode.window.setStatusBarMessage('🎙️ → editor', 4000);
        return 'editor';
    }

    // A terminal created here runs a plain shell, not the agent CLI the command was spoken to: type it, never run it.
    if (target.kind === 'terminal' && (!vscode.window.terminals.includes(target.terminal)
                                       || target.terminal.exitStatus !== undefined)) {
        return 'error the terminal was closed';
    }
    const terminal = target.kind === 'terminal' ? target.terminal : vscode.window.createTerminal('Voice Agent');
    const run = target.kind === 'terminal' && execute;
    terminal.show(true);
    terminal.sendText(text, run);
    vscode.window.setStatusBarMessage(`🎙️ → ${terminal.name}`, 4000);
    return run ? 'terminal-run' : 'terminal';
}

// The API names the active editor and terminal, but not which of them has the keyboard: the active editor stays set
// while the terminal is focused. "Copy" acts on what has focus, and in an editor it copies the selections, or the
// cursors' lines when nothing is selected (editor.emptySelectionClipboard, on by default). If that is what lands on the
// clipboard, the editor has focus. The clipboard's text is put back afterwards (the recorder restores other kinds).
async function hasKeyboardFocus(editor: vscode.TextEditor): Promise<boolean> {
    const saved = await vscode.env.clipboard.readText();
    const probe = `voice-agent-focus-probe-${Date.now()}`;
    await vscode.env.clipboard.writeText(probe);
    try {
        await vscode.commands.executeCommand('editor.action.clipboardCopyAction');
        const copied = await vscode.env.clipboard.readText();
        return copied !== probe && copyCandidates(editor).includes(normalized(copied));
    } finally {
        await vscode.env.clipboard.writeText(saved);
    }
}

// What copy can put on the clipboard for these selections, as VS Code's getPlainTextToCopy builds it: in document
// order, each selection's text, or for an empty cursor its whole line plus a line break unless the range before it
// starts on the same line, joined by line breaks; without editor.emptySelectionClipboard only the non-empty ones.
function copyCandidates({ document, selections }: vscode.TextEditor): string[] {
    const sorted = [...selections].sort((a, b) => a.start.compareTo(b.start));
    const pieces = sorted.filter((s, i) => !s.isEmpty || i === 0 || sorted[i - 1].start.line !== s.start.line)
        .map(s => s.isEmpty ? document.lineAt(s.start.line).text + '\n' : document.getText(s));
    const nonEmpty = sorted.filter(s => !s.isEmpty).map(s => document.getText(s));
    const candidates = [pieces.join('\n')];
    if (nonEmpty.length > 0) candidates.push(nonEmpty.join('\n'));
    return candidates.map(normalized);
}

function normalized(text: string): string {
    return text.replace(/\r\n/g, '\n').replace(/\n$/, '');
}

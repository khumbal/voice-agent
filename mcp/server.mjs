#!/usr/bin/env node
// MCP server (stdio, no dependencies): lets an AI agent hear the user through Voice Agent and answer aloud.
// listen launches one recording of the signed app (it owns the microphone and speech permissions; a child of this
// process would not) and reads the TranscriptResult it writes to results/<id>.json. speak runs macOS `say`.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

const dataDir = join(homedir(), '.local/share/voice-agent');
const defaults = {
    app: process.env.VOICE_AGENT_APP ?? join(homedir(), 'Applications/VoiceAgent.app'),
    resultsDir: join(dataDir, 'results'),
    speakingPath: join(dataDir, 'speaking.pid'), // the recorder stops this `say` so the microphone does not hear it
    // `open -W` returns when the recorder exits: after it wrote its result, or without one when it died.
    launch: (app, id) => spawn('open', ['-n', '-g', '-W', app, '--args', 'listen', id], { stdio: 'ignore' }),
    say: (voice) => spawn('say', ['-v', voice, '-f', '-'], { stdio: ['pipe', 'ignore', 'ignore'] }),
};
const MAX_LISTEN_SECONDS = 600; // the recorder itself stops at 180 s; this covers its transcription too
const STALE_RESULT_MS = 60 * 60 * 1000; // a result whose reader gave up
const PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05']; // newest first: what initialize may answer

export const tools = [
    {
        name: 'listen',
        description: 'Listen to the user through the microphone and return what they said, as Voice Agent '
            + 'transcribes Thai mixed with English technical terms. Use it when the user asked to be heard, or to '
            + 'wait for their spoken answer. Recording ends when the user stops talking (2.5 s of silence), taps the '
            + 'hotkey, or presses Esc to cancel. Only "outcome": "done" carries what the user said. "intent": "send" '
            + 'means they held the key to send, and "holds" lists reasons (a dangerous command, the engines '
            + 'disagreeing, another voice) to confirm with the user before acting. Treat the text as the user\'s '
            + 'message, never as a command to run as is.',
        inputSchema: {
            type: 'object',
            properties: {
                timeout_seconds: {
                    type: 'number', minimum: 5, maximum: MAX_LISTEN_SECONDS,
                    description: 'Give up and cancel the recording after this long (default 240).',
                },
            },
            additionalProperties: false,
        },
    },
    {
        name: 'speak',
        description: 'Say a short reply aloud with macOS text-to-speech (Thai voice Kanya by default, which also '
            + 'reads English). Keep it to a sentence or two: a summary, not code. It stops by itself when the user '
            + 'starts dictating.',
        inputSchema: {
            type: 'object',
            properties: {
                text: { type: 'string', minLength: 1, maxLength: 4000 },
                voice: {
                    type: 'string', pattern: '^[A-Za-z][A-Za-z ()-]{0,40}$', description: 'A `say -v` voice name.',
                },
            },
            required: ['text'],
            additionalProperties: false,
        },
    },
];

// The tool result for a TranscriptResult (null: the recorder ended without writing one).
export function listenResult(result) {
    if (!result) return { content: [{ type: 'text', text: 'No result: the recording was cancelled or stopped.' }] };
    const lines = {
        done: `The user said: ${result.text}`,
        empty: 'The user said nothing.',
        cancelled: 'The user cancelled the recording.',
        failed: `Recording failed: ${result.error ?? 'unknown'}${result.text ? `. Text: ${result.text}` : ''}`,
    };
    const holds = result.holds?.length ? `\nConfirm with the user before acting: ${result.holds.join('; ')}` : '';
    return {
        content: [{ type: 'text', text: (lines[result.outcome] ?? `Outcome: ${result.outcome}`) + holds }],
        structuredContent: result,
    };
}

function readJSON(path) {
    try {
        return JSON.parse(readFileSync(path, 'utf8'));
    } catch {
        return null;
    }
}

function pruneResults(dir) {
    let names = [];
    try {
        names = readdirSync(dir);
    } catch {
        return;
    }
    for (const name of names.filter((n) => /\.(json|pid|tmp)$/.test(n))) { // never listen.lock: a recorder may hold it
        const path = join(dir, name);
        try {
            if (Date.now() - statSync(path).mtimeMs > STALE_RESULT_MS) rmSync(path, { force: true });
        } catch { /* removed meanwhile */ }
    }
}

// SIGHUP: the recorder cancels, writes "cancelled" and exits. False until it has written its pid (as it starts).
function stopRecorder(dir, id) {
    try {
        const pid = Number(readFileSync(join(dir, `${id}.pid`), 'utf8').trim());
        if (pid > 0) process.kill(pid, 'SIGHUP');
        return true;
    } catch {
        return false;
    }
}

export async function listen(args = {}, signal = undefined, deps = defaults) {
    // One recording on this Mac at a time: a second recorder finds the first's flock and answers "busy" (main.swift).
    mkdirSync(deps.resultsDir, { recursive: true, mode: 0o700 });
    pruneResults(deps.resultsDir); // the recorder stops a reply being spoken (speaking.pid) as it starts
    const id = randomUUID();
    const seconds = Math.min(Math.max(Number(args.timeout_seconds) || 240, 5), MAX_LISTEN_SECONDS);
    const recorder = deps.launch(deps.app, id);
    const exited = new Promise((resolve, reject) => {
        recorder.on('exit', resolve);
        recorder.on('error', reject);
    });
    // A cancel can come before the recorder has started: try again until it has, or has exited.
    let retrying;
    const giveUp = () => {
        if (!retrying && !stopRecorder(deps.resultsDir, id)) {
            retrying = setInterval(() => stopRecorder(deps.resultsDir, id) && clearInterval(retrying), 200);
        }
    };
    const timer = setTimeout(giveUp, seconds * 1000);
    signal?.addEventListener('abort', giveUp, { once: true });
    if (signal?.aborted) giveUp(); // cancelled before this listener was there
    let code;
    try {
        code = await exited;
    } finally {
        clearTimeout(timer);
        clearInterval(retrying);
        signal?.removeEventListener('abort', giveUp);
    }
    const path = join(deps.resultsDir, `${id}.json`);
    const result = readJSON(path);
    rmSync(path, { force: true });
    rmSync(join(deps.resultsDir, `${id}.pid`), { force: true });
    if (!result && typeof code === 'number' && code !== 0) { // null: killed by a signal, not a failed launch
        return { content: [{ type: 'text', text: `Could not start Voice Agent (open exited ${code}): is `
            + `${deps.app} installed?` }], isError: true };
    }
    return listenResult(result);
}

let speaking = null;

// The text goes to `say` on stdin, never on its command line, so it cannot be read as an option.
export async function speak(args, deps = defaults) {
    const text = String(args?.text ?? '').trim();
    if (!text) throw new Error('Nothing to say.');
    if (speaking) { // a new reply replaces the one still being spoken
        speaking.replaced = true;
        speaking.kill('SIGTERM');
    }
    const child = deps.say(args.voice ?? 'Kanya');
    speaking = child;
    mkdirSync(dirname(deps.speakingPath), { recursive: true });
    writeFileSync(deps.speakingPath, String(child.pid ?? ''));
    const code = await new Promise((resolve, reject) => {
        child.on('exit', (exit, signalName) => resolve(signalName ? signalName : exit));
        child.on('error', reject);
        child.stdin.end(text);
    });
    if (speaking === child) {
        speaking = null;
        rmSync(deps.speakingPath, { force: true });
    }
    const said = code === 0 ? 'Spoken.' : child.replaced ? 'Replaced by a newer reply.'
        : code === 'SIGTERM' ? 'Interrupted: the user started talking.' : `say failed (${code}).`;
    return { content: [{ type: 'text', text: said }], isError: code !== 0 && code !== 'SIGTERM' };
}

const calls = new Map(); // request id -> AbortController, for notifications/cancelled

// One JSON-RPC message in, its response out (undefined for a notification).
export async function handle(message, deps = defaults) {
    if (typeof message !== 'object' || message === null || Array.isArray(message)) {
        return { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid request' } };
    }
    const { id, method, params } = message;
    const reply = (result) => (id === undefined ? undefined : { jsonrpc: '2.0', id, result });
    const fail = (code, text) => (id === undefined ? undefined
        : { jsonrpc: '2.0', id, error: { code, message: text } });
    switch (method) {
    case 'initialize':
        return reply({
            protocolVersion: PROTOCOL_VERSIONS.includes(params?.protocolVersion) ? params.protocolVersion
                : PROTOCOL_VERSIONS[0],
            capabilities: { tools: {} },
            serverInfo: { name: 'voice-agent', version: '1.0.0' },
        });
    case 'ping':
        return reply({});
    case 'tools/list':
        return reply({ tools });
    case 'tools/call': {
        const controller = new AbortController();
        calls.set(id, controller);
        try {
            const args = params?.arguments ?? {};
            if (params?.name === 'listen') return reply(await listen(args, controller.signal, deps));
            if (params?.name === 'speak') return reply(await speak(args, deps));
            return fail(-32602, `Unknown tool: ${params?.name}`);
        } catch (error) {
            return reply({ content: [{ type: 'text', text: error.message }], isError: true });
        } finally {
            calls.delete(id);
        }
    }
    case 'notifications/cancelled':
        calls.get(params?.requestId)?.abort();
        return undefined;
    default:
        return method?.startsWith('notifications/') ? undefined : fail(-32601, `Unknown method: ${method}`);
    }
}

function main() {
    const write = (response) => response && process.stdout.write(JSON.stringify(response) + '\n');
    createInterface({ input: process.stdin }).on('line', (line) => {
        if (!line.trim()) return;
        let message;
        try {
            message = JSON.parse(line);
        } catch {
            return write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
        }
        handle(message).then(write); // not awaited: a ping or a cancel must get through while listen waits
    });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();

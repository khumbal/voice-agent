// node --test mcp/: the MCP server against a stand-in recorder and `say`, never the real microphone or speaker.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { handle, listen, listenResult, speak } from './server.mjs';

// A result as the app writes it (tests/results.tsv checks the app's side of this format).
const done = {
    apple: 'git reset --hard กลับไป', holds: ['คำสั่งอันตราย: reset --hard'], id: 'x', intent: 'send', outcome: 'done',
    seconds: 4, text: 'git reset --hard กลับไป', v: 1, whisper: 'git reset --hard กลับไป',
};

function deps(recorder) {
    const dir = mkdtempSync(join(tmpdir(), 'voice-agent-mcp-'));
    return { app: '/nonexistent.app', resultsDir: join(dir, 'results'), speakingPath: join(dir, 'speaking.pid'),
        launch: (app, id) => recorder(join(dir, 'results'), id) };
}

// A recorder that writes its result (or none) and exits, as `open -W` reports it.
const writes = (result) => (dir, id) => {
    if (result) writeFileSync(join(dir, `${id}.json`), JSON.stringify({ ...result, id }));
    return spawn('true');
};

test('a done result carries the text, and its holds as a reason to confirm', () => {
    const { content, structuredContent } = listenResult(done);
    assert.equal(content[0].text,
        'The user said: git reset --hard กลับไป\nConfirm with the user before acting: คำสั่งอันตราย: reset --hard');
    assert.equal(structuredContent.intent, 'send');
});

test('each outcome and a missing result read as what happened', () => {
    assert.equal(listenResult({ ...done, outcome: 'cancelled', holds: [] }).content[0].text,
        'The user cancelled the recording.');
    assert.equal(listenResult({ ...done, outcome: 'empty', text: '', holds: [] }).content[0].text,
        'The user said nothing.');
    const failed = { outcome: 'failed', error: 'ไมค์ไม่มีเสียงเข้ามา', text: '', holds: [] };
    assert.equal(listenResult(failed).content[0].text, 'Recording failed: ไมค์ไม่มีเสียงเข้ามา');
    assert.match(listenResult(null).content[0].text, /^No result/);
});

test('listen reads the result the recorder wrote under its id, then removes it', async () => {
    const d = deps(writes(done));
    const reply = await listen({}, undefined, d);
    assert.equal(reply.structuredContent.text, done.text);
    assert.equal(existsSync(join(d.resultsDir, `${reply.structuredContent.id}.json`)), false);
});

test('a recorder that exits without a result reads as no result', async () => {
    assert.match((await listen({}, undefined, deps(writes(null)))).content[0].text, /^No result/);
});

test('a cancelled call sends the recorder SIGHUP, and listen returns once it exits', async () => {
    const controller = new AbortController();
    const d = deps((dir, id) => {
        const recorder = spawn('sleep', ['30']); // dies of the SIGHUP, as the app cancels on it
        writeFileSync(join(dir, `${id}.pid`), String(recorder.pid));
        setTimeout(() => controller.abort(), 50);
        return recorder;
    });
    const started = Date.now();
    assert.match((await listen({}, controller.signal, d)).content[0].text, /^No result/);
    assert.ok(Date.now() - started < 5000);
});

test('a cancel before the recorder wrote its pid is retried until it has', async () => {
    const controller = new AbortController();
    const d = deps((dir, id) => {
        const recorder = spawn('sleep', ['30']);
        controller.abort(); // at once: the pid file comes 300 ms later, as the app writes it once it starts
        setTimeout(() => writeFileSync(join(dir, `${id}.pid`), String(recorder.pid)), 300);
        return recorder;
    });
    const started = Date.now();
    assert.match((await listen({}, controller.signal, d)).content[0].text, /^No result/);
    assert.ok(Date.now() - started < 5000);
});

test('an app that cannot be launched is an error, not a cancel', async () => {
    const reply = await listen({}, undefined, deps(() => spawn('false')));
    assert.equal(reply.isError, true);
    assert.match(reply.content[0].text, /^Could not start Voice Agent/);
});

test('a busy result from a second recorder reads as a failure, not a cancel', async () => {
    const busy = { outcome: 'failed', error: 'busy: another listen is recording', text: '', holds: [] };
    assert.equal((await listen({}, undefined, deps(writes(busy)))).content[0].text,
        'Recording failed: busy: another listen is recording');
});

test('speak gives the text to say on stdin, never as an argument, and clears speaking.pid', async () => {
    const d = deps(writes(null));
    let voice, heard = '';
    d.say = (v) => {
        voice = v;
        const child = spawn('cat', [], { stdio: ['pipe', 'pipe', 'ignore'] });
        child.stdout.on('data', (chunk) => (heard += chunk));
        return child;
    };
    const reply = await speak({ text: '-v Alex รันเทสผ่านแล้ว' }, d);
    assert.equal(reply.content[0].text, 'Spoken.');
    assert.equal(heard, '-v Alex รันเทสผ่านแล้ว');
    assert.equal(voice, 'Kanya');
    assert.equal(existsSync(d.speakingPath), false);
});

test('the protocol answers initialize, lists both tools and rejects an unknown method', async () => {
    const initialize = (version) => handle({ jsonrpc: '2.0', id: 1, method: 'initialize',
        params: { protocolVersion: version } }).then((r) => r.result.protocolVersion);
    assert.equal(await initialize('2025-03-26'), '2025-03-26');
    assert.equal(await initialize('2099-01-01'), '2025-06-18'); // one it does not know: answered with its newest
    assert.equal((await handle(null)).error.code, -32600);
    assert.deepEqual((await handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' })).result.tools.map((t) => t.name),
        ['listen', 'speak']);
    assert.equal((await handle({ jsonrpc: '2.0', id: 3, method: 'resources/list' })).error.code, -32601);
    assert.equal(await handle({ jsonrpc: '2.0', method: 'notifications/initialized' }), undefined);
});

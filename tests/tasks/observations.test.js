'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { observeDocuments, documentPaths, MAX_DOCUMENT, MAX_DOCUMENTS } = require('/opt/rounds.js');
const { main: sourceMain, inspectSource } = require('/opt/tasks/source.js');
const { validateObservation } = require('/opt/tasks/context.js');
const { core, fixture, git, write, tree, sha256, successful, rejected, exported, invoke } = require('../rounds/fixtures');

function objectReader(content = Buffer.from('Document\n'), options = {}) {
    const format = options.format || 'sha1';
    const commit = 'a'.repeat(format === 'sha1' ? 40 : 64);
    const blob = crypto.createHash(format).update(`blob ${content.length}\0`).update(content).digest('hex');
    const calls = [];
    const read = args => {
        calls.push(args);
        if (args[0] === '--literal-pathspecs' && args[1] === 'ls-tree') {
            assert.deepEqual(args.slice(0, -1), ['--literal-pathspecs', 'ls-tree', '-z', '--full-tree', commit, '--']);
            return Buffer.from(`${options.mode || '100644'} ${options.type || 'blob'} ${blob}\t${args.at(-1)}\0`);
        }
        assert.deepEqual(args, ['cat-file', args[1], blob]);
        if (args[1] === '-s') return Buffer.from(`${options.size === undefined ? content.length : options.size}\n`);
        assert.equal(args[1], 'blob');
        return content;
    };
    return { commit, blob, read, calls, content };
}

function inspect(f, paths = [], fault) {
    const args = [core, 'inspect', '--root', f.target, '--state', f.state, '--repository', 'prj'];
    for (const selected of paths) args.push('--path', selected);
    const env = { PATH: '/usr/bin:/bin', HOME: '/nonexistent', TMPDIR: f.base };
    if (fault) {
        env.NODE_OPTIONS = '--require=/tests/tasks/observation-faults.js';
        env.OBSERVATION_FIXTURE_FAULT = fault;
        env.OBSERVATION_FIXTURE_ROOT = f.target;
    }
    return spawnSync(process.execPath, args, { cwd: f.base, env, encoding: 'utf8', maxBuffer: 40 * 1024 * 1024 });
}

function commitFile(root, name, content) {
    write(root, name, content);
    git(root, 'add', '--', name);
    git(root, 'commit', '--quiet', '-m', 'Document observation fixture');
}

test('document observations validate bounded literal selections before invoking Git', () => {
    for (const selected of [[], null, ['a.md', 'A.md'], ['a.md', 'a.md'], ['../a.md'],
        ['script.js'], ['\ud800.md'], Array.from({ length: MAX_DOCUMENTS + 1 }, (_, index) => `${index}.md`)]) {
        let called = false;
        assert.throws(() => observeDocuments(() => { called = true; }, 'a'.repeat(40), selected));
        assert.equal(called, false);
    }
    const input = Object.freeze(['bracket[1].md', 'literal name.txt', '-leading.md']);
    assert.deepEqual(documentPaths(input), input);
});

for (const format of ['sha1', 'sha256']) {
    test(`document observations preserve bytes and provenance for ${format} repositories`, () => {
        const source = objectReader(Buffer.from('  text\r\n\n'), { format });
        const [result] = observeDocuments(source.read, source.commit, ['literal[1].md']);
        assert.deepEqual(result, { path: 'literal[1].md', observation: {
            state: 'present', commit: source.commit, blob: source.blob, mode: '100644',
            bytes: source.content.length, sha256: sha256(source.content),
        } });
        validateObservation(result.observation);
        assert.ok(!Object.hasOwn(result.observation, 'content'));
    });
}

test('document observations permit empty text and preserve a UTF-8 BOM', () => {
    for (const bytes of [Buffer.alloc(0), Buffer.from([0xef, 0xbb, 0xbf, 0x61, 0x0a])]) {
        const source = objectReader(bytes);
        const [result] = observeDocuments(source.read, source.commit, ['document.txt']);
        assert.equal(result.observation.state, 'present');
        assert.equal(result.observation.sha256, sha256(bytes));
        assert.equal(result.observation.bytes, bytes.length);
    }
});

test('document observations distinguish absence from Git or I/O failure', () => {
    const commit = 'a'.repeat(40);
    assert.deepEqual(observeDocuments(() => Buffer.alloc(0), commit, ['missing.md']), [
        { path: 'missing.md', observation: { state: 'missing', commit } },
    ]);
    const error = Object.assign(new Error('Fixture object store is unreadable'), { code: 'EACCES' });
    assert.throws(() => observeDocuments(() => { throw error; }, commit, ['a.md']), caught => caught === error);
    assert.throws(() => observeDocuments(() => '', commit, ['a.md']), /byte-preserving/);
    assert.throws(() => observeDocuments(() => Buffer.from('malformed tree\n'), commit, ['a.md']), /tree entry/);
});

test('document observations reject inconsistent object size or identity', () => {
    const source = objectReader();
    for (const [command, replacement, message] of [
        ['-s', Buffer.from('not-a-size\n'), /object size/],
        ['-s', Buffer.from('9007199254740992\n'), /object size/],
        ['-s', Buffer.from('1\n'), /size changed/],
        ['blob', Buffer.from('Different'), /blob identity/],
    ]) {
        assert.throws(() => observeDocuments(args =>
            args[0] === 'cat-file' && args[1] === command ? replacement : source.read(args),
        source.commit, ['a.md']), message);
    }
    assert.throws(() => observeDocuments(args => {
        const bytes = source.read(args);
        return args[0] === '--literal-pathspecs' ? Buffer.from(bytes.toString('utf8').replace('a.md', 'other.md')) : bytes;
    }, source.commit, ['a.md']), /tree entry/);
});

for (const [label, options] of [
    ['executable', { mode: '100755' }],
    ['symlink', { mode: '120000' }],
    ['directory', { mode: '040000', type: 'tree' }],
    ['gitlink', { mode: '160000', type: 'commit' }],
    ['oversized', { size: MAX_DOCUMENT + 1 }],
]) {
    test(`document observations report ${label} entries without reading their content`, () => {
        const source = objectReader(Buffer.from('not read'), options);
        const [result] = observeDocuments(source.read, source.commit, ['a.md']);
        assert.equal(result.observation.state, 'unsupported');
        assert.ok(result.observation.reason);
        validateObservation(result.observation);
        assert.ok(!source.calls.some(args => args[0] === 'cat-file' && args[1] === 'blob'));
    });
}

for (const [label, bytes] of [
    ['invalid UTF-8', Buffer.from([0xff, 0xfe])],
    ['NUL', Buffer.from('text\0text')],
    ['LFS pointer', Buffer.from(`version https://git-lfs.github.com/spec/v1\noid sha256:${'b'.repeat(64)}\nsize 123\n`)],
    ['extended LFS pointer', Buffer.from('version https://git-lfs.github.com/spec/v1\next-0-custom unsupported\n')],
]) {
    test(`document observations report ${label} as unsupported without exposing the bytes`, () => {
        const source = objectReader(bytes);
        const [result] = observeDocuments(source.read, source.commit, ['a.md']);
        assert.equal(result.observation.state, 'unsupported');
        assert.deepEqual(Object.keys(result.observation).sort(), ['commit', 'reason', 'state']);
        validateObservation(result.observation);
    });
}

test('source document observations use the named committed branch, not checkout or edits', t => {
    const f = fixture(t);
    const ref = 'refs/heads/sandbox-fixture';
    const legacy = sourceMain(['source', ref], f.source);
    assert.deepEqual(legacy, { ref, head: f.sourceHead });
    git(f.source, 'checkout', '--quiet', '-b', 'unrelated');
    commitFile(f.source, 'briefs/first brief.md', 'Wrong checked-out branch\n');
    write(f.source, 'briefs/first brief.md', 'Uncommitted bytes must not be observed\n');
    const before = tree(f.source);
    const result = sourceMain(['source', ref, 'briefs/first brief.md', 'briefs/second.txt', 'missing.md'], f.source);
    assert.equal(result.head, f.sourceHead);
    assert.equal(result.documents[0].observation.sha256, sha256(Buffer.from('# First committed review\n\nUse the retained caches.\n')));
    assert.equal(result.documents[1].observation.sha256, sha256(Buffer.from('Second supporting text.\r\n')));
    assert.equal(result.documents[2].observation.state, 'missing');
    assert.deepEqual(tree(f.source), before);
    assert.throws(() => sourceMain(['source', 'HEAD', 'README.md'], f.source), /explicit valid/);
    assert.throws(() => sourceMain(['source', ref, '../outside.md'], f.source));
    assert.throws(() => inspectSource(() => Buffer.alloc(0), ref, {}), /array/);
});

test('source document observations preserve literal bracket and leading-dash paths', t => {
    const f = fixture(t);
    for (const name of ['bracket[1].md', 'bracket1.md', '-leading.md']) {
        commitFile(f.source, name, `${name}\n`);
    }
    const result = sourceMain(['source', 'refs/heads/sandbox-fixture', 'bracket[1].md', '-leading.md'], f.source);
    assert.equal(result.documents[0].observation.sha256, sha256(Buffer.from('bracket[1].md\n')));
    assert.equal(result.documents[1].observation.sha256, sha256(Buffer.from('-leading.md\n')));
});

test('source document observations reject branch movement during the read', () => {
    const source = objectReader();
    let moved = false;
    const read = args => {
        if (args[0] === 'check-ref-format') return Buffer.alloc(0);
        if (args[0] === 'rev-parse') return Buffer.from(`${moved ? 'e'.repeat(40) : source.commit}\n`);
        const result = source.read(args);
        if (args[0] === 'cat-file' && args[1] === 'blob') moved = true;
        return result;
    };
    assert.throws(() => inspectSource(read, 'refs/heads/main', ['README.md']), /branch changed/);
});

test('source document observations never execute filters, text conversion or fsmonitor', t => {
    const f = fixture(t);
    commitFile(f.source, 'marker-filter.sh', '#!/bin/sh\nprintf ran > .filter-executed\ncat\n');
    commitFile(f.source, '.gitattributes', '*.md filter=fixture diff=fixture\n');
    for (const key of ['filter.fixture.clean', 'filter.fixture.smudge', 'diff.fixture.textconv', 'core.fsmonitor']) {
        git(f.source, 'config', key, '/bin/sh ./marker-filter.sh');
    }
    git(f.source, 'config', 'filter.fixture.required', 'true');
    const before = tree(f.source);
    const result = sourceMain(['source', 'refs/heads/sandbox-fixture', 'README.md'], f.source);
    assert.equal(result.documents[0].observation.state, 'present');
    assert.ok(!fs.existsSync(path.join(f.source, '.filter-executed')));
    assert.deepEqual(tree(f.source), before);
});

test('source helper retains exact-import behavior and rejects unrelated children', t => {
    const f = fixture(t);
    exported(f, { task: 'TASK-1' });
    const imported = successful(invoke(f, 'apply', { head: f.baseHead }));
    assert.deepEqual(sourceMain(['import-head', imported.head, f.baseHead, imported.roundPath], f.target),
        { status: 'exact-import' });
    commitFile(f.target, 'unrelated.txt', 'Not an import\n');
    assert.throws(() => sourceMain(['import-head', git(f.target, 'rev-parse', 'HEAD'),
        imported.head, imported.roundPath], f.target), /unrelated changes/);
});

test('target document observations add metadata without changing legacy output or repository bytes', t => {
    const f = fixture(t);
    const before = tree(f.workspace);
    const legacy = successful(inspect(f));
    const result = successful(inspect(f, ['src/original.txt', 'absent.md']));
    const { documents, ...rest } = result;
    assert.deepEqual(rest, legacy);
    assert.equal(documents[0].observation.commit, f.baseHead);
    assert.equal(documents[0].observation.sha256, sha256(Buffer.from('Canonical implementation remains unchanged.\n')));
    assert.equal(documents[1].observation.state, 'missing');
    documents.forEach(item => validateObservation(item.observation));
    assert.deepEqual(tree(f.workspace), before);
});

for (const state of ['dirty', 'busy', 'detached', 'recovery-required']) {
    test(`target document observations remain unobserved for ${state} repositories`, t => {
        const f = fixture(t);
        if (state === 'dirty') write(f.target, 'README.md', 'Uncommitted canonical edit\n');
        else if (state === 'busy') write(f.target, '.git/index.lock', 'Foreign lock\n');
        else if (state === 'detached') git(f.target, 'checkout', '--quiet', '--detach', 'HEAD');
        else write(f.state, 'pending.json', JSON.stringify({
            version: 2, phase: 'preparing', packetSha256: 'a'.repeat(64),
            roundPath: 'sandbox-rounds/TASK-1/R1', baseHead: f.baseHead,
            commit: null, branch: 'refs/heads/sandbox-fixture',
        }));
        const before = tree(f.workspace);
        const result = successful(inspect(f, ['README.md']));
        assert.equal(result.status, state === 'detached' ? 'busy' : state);
        assert.deepEqual(result.documents, [{ path: 'README.md',
            observation: { state: 'unobserved', reason: result.status } }]);
        validateObservation(result.documents[0].observation);
        assert.deepEqual(tree(f.workspace), before);
    });
}

for (const fault of ['worktree', 'index', 'head', 'lock', 'pending']) {
    test(`target document observations refuse ${fault} changes during inspection`, t => {
        const f = fixture(t);
        const message = rejected(inspect(f, ['README.md'], fault));
        assert.match(message, /changed|staged, unstaged|in-progress/);
        if (fault === 'worktree') assert.equal(fs.readFileSync(path.join(f.target, 'README.md'), 'utf8'), 'Fixture changed while observing\n');
        if (fault === 'lock') assert.ok(fs.existsSync(path.join(f.target, '.git/index.lock')));
        if (fault === 'pending') assert.ok(fs.existsSync(path.join(f.state, 'pending.json')));
    });
}

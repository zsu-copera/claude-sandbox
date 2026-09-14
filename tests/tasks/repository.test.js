'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { core, fixture, git, write, invoke, successful, exported, rejected, tree, sha256 } = require('../rounds/fixtures');

function repositoryCall(f, mode, options = {}) {
    const args = [core, mode, '--root', f.target, '--repository', 'prj', '--state', f.state];
    if (mode === 'inspect' && options.base) args.push('--base', options.base);
    if (mode === 'collect') args.push('--base', options.base || f.baseHead,
        '--work-base', options.workBase || options.base || f.baseHead,
        '--expected-head', options.head || git(f.target, 'rev-parse', 'HEAD'),
        '--output', options.output || path.join(f.base, 'audit-output'));
    return spawnSync(process.execPath, args, { cwd: f.base, encoding: 'utf8',
        env: { PATH: '/usr/bin:/bin', HOME: '/nonexistent', TMPDIR: f.base },
        maxBuffer: 40 * 1024 * 1024 });
}

test('repository inspect reports clean/dirty state read-only', t => {
    const f = fixture(t);
    let before = tree(f.workspace);
    const clean = successful(repositoryCall(f, 'inspect'));
    assert.equal(clean.status, 'clean');
    assert.equal(clean.head, f.baseHead);
    assert.deepEqual(clean.rounds, []);
    assert.deepEqual(tree(f.workspace), before);
    write(f.target, 'src/original.txt', 'Uncommitted implementation\n');
    before = tree(f.workspace);
    const dirty = successful(repositoryCall(f, 'inspect'));
    assert.equal(dirty.status, 'dirty');
    assert.ok(dirty.changes.some(change => change.path === 'src/original.txt'));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository inspect reports ongoing Git work without claiming a clean tree', t => {
    const f = fixture(t);
    write(f.target, '.git/index.lock', 'another operation\n');
    const before = tree(f.workspace);
    const result = successful(repositoryCall(f, 'inspect'));
    assert.equal(result.status, 'busy');
    assert.equal(result.changes, null);
    assert.ok(result.operations.includes('index.lock'));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository inspect reports a conflicted rebase with detached HEAD as busy', t => {
    const f = fixture(t);
    write(f.target, 'src/original.txt', 'Topic change\n');
    git(f.target, 'add', 'src/original.txt');
    git(f.target, 'commit', '--quiet', '-m', 'Topic change');
    const topicHead = git(f.target, 'rev-parse', 'HEAD');
    git(f.target, 'checkout', '--quiet', '-b', 'other', f.baseHead);
    write(f.target, 'src/original.txt', 'Conflicting upstream change\n');
    git(f.target, 'add', 'src/original.txt');
    git(f.target, 'commit', '--quiet', '-m', 'Other change');
    git(f.target, 'checkout', '--quiet', 'sandbox-fixture');
    const rebase = spawnSync('/usr/bin/git', ['-C', f.target, 'rebase', 'other'], {
        encoding: 'utf8', env: { PATH: '/usr/bin:/bin', HOME: f.base,
            GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_EDITOR: 'true' },
    });
    assert.notEqual(rebase.status, 0, 'Fixture rebase must stop on a conflict.');
    assert.ok(fs.existsSync(path.join(f.target, '.git/rebase-merge')));
    const before = tree(f.workspace);
    const result = successful(repositoryCall(f, 'inspect', { base: topicHead }));
    assert.equal(result.status, 'busy');
    assert.equal(result.branch, null);
    assert.equal(result.observedWorktree, false);
    assert.equal(result.changes, null);
    assert.ok(result.operations.includes('rebase-merge'));
    assert.ok(!Object.hasOwn(result, 'baseHead'), 'A busy rebase must not claim baseline validation.');
    rejected(repositoryCall(f, 'collect'));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository inspect makes a detached checkout explicit without authorizing collection', t => {
    const f = fixture(t);
    git(f.target, 'checkout', '--quiet', '--detach', 'HEAD');
    const before = tree(f.workspace);
    const result = successful(repositoryCall(f, 'inspect'));
    assert.equal(result.status, 'busy');
    assert.equal(result.branch, null);
    assert.ok(result.operations.includes('detached-HEAD'));
    rejected(repositoryCall(f, 'collect'));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository inspect identifies pending recovery metadata without executing recovery', t => {
    const f = fixture(t);
    write(f.state, 'pending.json', JSON.stringify({ version: 2, phase: 'preparing',
        roundPath: 'sandbox-rounds/TASK_42/R1', packetSha256: 'a'.repeat(64),
        baseHead: f.baseHead, commit: null, branch: 'refs/heads/sandbox-fixture' }));
    const before = tree(f.workspace);
    const result = successful(repositoryCall(f, 'inspect'));
    assert.equal(result.status, 'recovery-required');
    assert.equal(result.pending.baseHead, f.baseHead);
    assert.equal(result.changes, null);
    rejected(repositoryCall(f, 'collect'));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository inspect inventories existing committed rounds and checkpoints', t => {
    const f = fixture(t);
    exported(f);
    const applied = successful(invoke(f, 'apply', { head: f.baseHead }));
    const before = tree(f.workspace);
    const result = successful(repositoryCall(f, 'inspect', { base: f.baseHead }));
    assert.equal(result.status, 'clean');
    assert.equal(result.head, applied.head);
    assert.equal(result.baseHead, f.baseHead);
    assert.equal(result.rounds.length, 1);
    assert.equal(result.rounds[0].round, 'R1');
    assert.equal(result.rounds[0].packetSha256, applied.packetSha256);
    assert.equal(result.checkpoints[0].head, f.baseHead);
    assert.deepEqual(tree(f.workspace), before);
});

test('repository inspect rejects an unrelated audit baseline', t => {
    const f = fixture(t);
    const orphan = git(f.target, 'commit-tree', 'HEAD^{tree}', '-m', 'Unrelated baseline');
    const before = tree(f.workspace);
    rejected(repositoryCall(f, 'inspect', { base: orphan }));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository inspect does not leak malformed manifest contents through JSON errors', t => {
    const f = fixture(t);
    exported(f);
    successful(invoke(f, 'apply', { head: f.baseHead }));
    const manifest = 'sandbox-rounds/TASK_42/R1/manifest.json';
    const marker = 'private-fixture-content-not-for-diagnostics';
    write(f.target, manifest, `{${marker}`);
    git(f.target, 'add', manifest);
    git(f.target, 'commit', '--quiet', '-m', 'Malformed input metadata');
    const before = tree(f.workspace);
    const message = rejected(repositoryCall(f, 'inspect'));
    assert.ok(message.includes('manifest.json'));
    assert.ok(!message.includes(marker));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository collection preserves source state and reconstructs exact commits from its bundle', t => {
    const f = fixture(t);
    git(f.target, 'branch', 'audit-baseline', f.baseHead);
    const baselineBundle = path.join(f.base, 'baseline.bundle');
    git(f.target, 'bundle', 'create', baselineBundle, 'refs/heads/audit-baseline');
    exported(f);
    const applied = successful(invoke(f, 'apply', { head: f.baseHead }));
    write(f.target, 'src/work.txt', 'Completed implementation\n');
    git(f.target, 'add', 'src/work.txt');
    git(f.target, 'commit', '--quiet', '-m', 'Implementation after brief');
    const head = git(f.target, 'rev-parse', 'HEAD');
    const before = tree(f.workspace);
    const output = path.join(f.base, 'audit-output');
    const manifest = successful(repositoryCall(f, 'collect', { head, workBase: applied.head, output }));
    assert.equal(manifest.status, 'collected');
    assert.equal(manifest.baseHead, f.baseHead);
    assert.equal(manifest.workBaseHead, applied.head);
    assert.equal(manifest.head, head);
    assert.ok(manifest.inputPaths.some(name => name.endsWith('/manifest.json')));
    assert.ok(fs.readFileSync(path.join(output, 'changes.patch'), 'utf8').includes('sandbox-rounds/'));
    const work = fs.readFileSync(path.join(output, 'work.patch'), 'utf8');
    assert.ok(work.includes('src/work.txt'));
    assert.ok(!work.includes('sandbox-rounds/'));
    for (const file of manifest.files) {
        const bytes = fs.readFileSync(path.join(output, file.name));
        assert.equal(sha256(bytes), file.sha256);
        assert.equal(bytes.length, file.bytes);
    }
    assert.deepEqual(tree(f.workspace), before, 'Collection modified source refs, index, files or caches.');
    const audit = path.join(f.base, 'audit-clone');
    git(f.base, 'clone', '--quiet', '--no-checkout', '-b', 'audit-baseline', baselineBundle, audit);
    git(audit, 'fetch', '--quiet', path.join(output, 'history.bundle'), 'HEAD:refs/heads/audit-candidate');
    assert.equal(git(audit, 'rev-parse', 'refs/heads/audit-candidate'), head);
    assert.equal(git(audit, 'cat-file', 'blob', 'refs/heads/audit-candidate:src/work.txt'), 'Completed implementation');
});

test('repository collection makes unchanged repositories explicit without an empty bundle', t => {
    const f = fixture(t);
    const output = path.join(f.base, 'audit-output');
    const manifest = successful(repositoryCall(f, 'collect', { output }));
    assert.equal(manifest.status, 'unchanged');
    assert.deepEqual(manifest.changedPaths, []);
    assert.ok(!fs.existsSync(path.join(output, 'history.bundle')));
    assert.equal(fs.statSync(path.join(output, 'changes.patch')).size, 0);
});

for (const invalid of ['dirty', 'stale-head', 'base', 'work-base', 'existing-output', 'inside-repo']) {
    test(`repository collection refuses ${invalid} without changing the source`, t => {
        const f = fixture(t);
        const options = {};
        if (invalid === 'dirty') write(f.target, 'uncommitted.txt', 'Preserve me\n');
        if (invalid === 'stale-head') options.head = '0'.repeat(40);
        if (invalid === 'base' || invalid === 'work-base') {
            const orphan = git(f.target, 'commit-tree', 'HEAD^{tree}', '-m', 'Unrelated baseline');
            if (invalid === 'base') options.base = orphan;
            else options.workBase = orphan;
        }
        if (invalid === 'existing-output') {
            options.output = path.join(f.base, 'audit-output');
            write(options.output, 'keep.txt', 'Existing evidence\n');
        }
        if (invalid === 'inside-repo') options.output = path.join(f.target, 'audit');
        const before = tree(f.workspace);
        rejected(repositoryCall(f, 'collect', options));
        assert.deepEqual(tree(f.workspace), before);
        if (invalid === 'existing-output') assert.equal(fs.readFileSync(path.join(options.output, 'keep.txt'), 'utf8'), 'Existing evidence\n');
    });
}

test('repository collection allows unchanged hydrated LFS assets without filters', t => {
    const f = fixture(t);
    const payload = Buffer.from('Existing hydrated asset\n');
    const pointer = `version https://git-lfs.github.com/spec/v1\noid sha256:${sha256(payload)}\nsize ${payload.length}\n`;
    write(f.target, '.gitattributes', '*.pdf filter=lfs -text\n');
    write(f.target, 'asset.pdf', pointer);
    git(f.target, 'add', '.gitattributes', 'asset.pdf');
    git(f.target, 'commit', '--quiet', '-m', 'Existing LFS baseline');
    f.baseHead = git(f.target, 'rev-parse', 'HEAD');
    write(f.target, 'asset.pdf', payload);
    write(f.target, 'src/work.txt', 'Text-only change\n');
    git(f.target, 'add', 'src/work.txt');
    git(f.target, 'commit', '--quiet', '-m', 'Text implementation');
    const marker = path.join(f.base, 'filter-ran');
    const script = write(f.base, 'filter.sh', `#!/bin/sh\nprintf ran > '${marker}'\nexit 97\n`);
    fs.chmodSync(script, 0o755);
    git(f.target, 'config', 'filter.lfs.process', `'${script}'`);
    const before = tree(f.workspace);
    assert.equal(successful(repositoryCall(f, 'collect')).status, 'collected');
    assert.ok(!fs.existsSync(marker));
    assert.deepEqual(tree(f.workspace), before);
});

test('repository collection blocks new LFS artifacts rather than exporting pointer-only success', t => {
    const f = fixture(t);
    const payload = Buffer.from('New binary artifact\n');
    const pointer = `version https://git-lfs.github.com/spec/v1\noid sha256:${sha256(payload)}\nsize ${payload.length}\n`;
    write(f.target, '.gitattributes', '*.pdf filter=lfs -text\n');
    write(f.target, 'new.pdf', pointer);
    git(f.target, 'add', '.gitattributes', 'new.pdf');
    git(f.target, 'commit', '--quiet', '-m', 'New LFS artifact');
    write(f.target, 'new.pdf', payload);
    const before = tree(f.workspace);
    const diagnostic = rejected(repositoryCall(f, 'collect'));
    assert.match(diagnostic, /LFS artifact handling/);
    assert.ok(!fs.existsSync(path.join(f.base, 'audit-output')));
    assert.deepEqual(tree(f.workspace), before);
});

for (const action of ['delete', 'revert']) {
    test(`repository collection blocks intermediate LFS history after an endpoint ${action}`, t => {
        const f = fixture(t);
        const pointer = content => {
            const bytes = Buffer.from(content);
            return `version https://git-lfs.github.com/spec/v1\noid sha256:${sha256(bytes)}\nsize ${bytes.length}\n`;
        };
        const original = pointer('Original LFS payload\n');
        write(f.target, '.gitattributes', '*.pdf filter=lfs -text\n');
        if (action === 'revert') write(f.target, 'asset.pdf', original);
        git(f.target, 'add', '.');
        git(f.target, 'commit', '--quiet', '-m', 'LFS baseline');
        f.baseHead = git(f.target, 'rev-parse', 'HEAD');
        write(f.target, 'asset.pdf', pointer('Intermediate LFS payload\n'));
        git(f.target, 'add', 'asset.pdf');
        git(f.target, 'commit', '--quiet', '-m', 'Intermediate LFS change');
        if (action === 'revert') write(f.target, 'asset.pdf', original);
        else fs.unlinkSync(path.join(f.target, 'asset.pdf'));
        git(f.target, 'add', '-A');
        git(f.target, 'commit', '--quiet', '-m', 'Restore endpoint tree');
        assert.equal(git(f.target, 'rev-parse', 'HEAD^{tree}'), git(f.target, 'rev-parse', `${f.baseHead}^{tree}`));
        const before = tree(f.workspace);
        const message = rejected(repositoryCall(f, 'collect'));
        assert.match(message, /LFS artifact handling for bundled history/);
        assert.ok(!fs.existsSync(path.join(f.base, 'audit-output')));
        assert.deepEqual(tree(f.workspace), before);
    });
}
test('repository collection never hides later changes to previously imported inputs', t => {
    const f = fixture(t);
    exported(f);
    const imported = successful(invoke(f, 'apply', { head: f.baseHead }));
    const input = 'sandbox-rounds/TASK_42/R1/files/briefs/first brief.md';
    write(f.target, input, 'Unexpected edit to input snapshot\n');
    git(f.target, 'add', input);
    git(f.target, 'commit', '--quiet', '-m', 'Changed imported input');
    const manifest = successful(repositoryCall(f, 'collect', { workBase: imported.head }));
    assert.ok(manifest.inputPaths.includes(input));
    assert.ok(fs.readFileSync(path.join(f.base, 'audit-output', 'work.patch'), 'utf8').includes('Unexpected edit'));
});

test('repository collection rejects filenames that cannot be represented accurately in JSON', t => {
    const f = fixture(t);
    const filename = Buffer.concat([Buffer.from(`${f.target}/`), Buffer.from([0xff]), Buffer.from('.txt')]);
    fs.writeFileSync(filename, 'Unsupported filename encoding\n');
    git(f.target, 'add', '.');
    git(f.target, 'commit', '--quiet', '-m', 'Non-UTF-8 path');
    const before = git(f.target, 'rev-parse', 'HEAD');
    const message = rejected(repositoryCall(f, 'collect'));
    assert.match(message, /utf-8/i);
    assert.equal(git(f.target, 'rev-parse', 'HEAD'), before);
    assert.ok(!fs.existsSync(path.join(f.base, 'audit-output')));
});

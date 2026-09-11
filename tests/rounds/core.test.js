'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { core, fixture, git, write, invoke, successful, exported, rejected, tree, sha256 } = require('./fixtures');

test('committed export, read-only preview and two append-only rounds preserve retained state', t => {
    const f = fixture(t);
    write(f.source, 'briefs/first brief.md', 'Uncommitted text must not be exported.\n');
    const before = tree(f.workspace);
    const packet = exported(f);
    assert.equal(packet.sourceCommit, f.sourceHead);
    assert.deepEqual(packet.documents.map(d => d.path), ['briefs/first brief.md', 'briefs/second.txt']);
    assert.match(packet.documents[0].content, /First committed review/);
    assert.equal(packet.documents[1].content, 'Second supporting text.\r\n');
    assert.equal(invoke(f, 'export').stdout, invoke(f, 'export').stdout, 'Export must be deterministic.');
    const preview = successful(invoke(f, 'preview'));
    assert.equal(preview.status, 'ready');
    assert.equal(preview.head, f.baseHead);
    assert.equal(preview.branch, 'refs/heads/sandbox-fixture');
    assert.deepEqual(tree(f.workspace), before, 'Preview changed repository/cache bytes or modes.');
    const applied = successful(invoke(f, 'apply', { head: preview.head }));
    assert.equal(applied.status, 'imported');
    assert.equal(applied.baseHead, f.baseHead);
    assert.equal(git(f.target, 'rev-parse', 'HEAD^'), f.baseHead);
    const firstHead = applied.head;
    const firstRound = path.join(f.target, 'sandbox-rounds/TASK_42/R1');
    for (const file of ['README.md', 'manifest.json', '.gitattributes']) assert.ok(fs.statSync(path.join(firstRound, file)).isFile());
    for (const document of packet.documents) {
        assert.equal(fs.readFileSync(path.join(firstRound, 'files', document.path), 'utf8'), document.content);
    }
    assert.match(git(f.target, 'log', '-1', '--format=%B'), new RegExp(f.sourceHead));
    assert.equal(successful(invoke(f, 'apply', { head: firstHead })).status, 'already-imported');
    assert.equal(successful(invoke(f, 'preview')).status, 'already-imported');
    assert.equal(git(f.target, 'rev-parse', 'HEAD'), firstHead);
    const firstBytes = tree(firstRound);
    exported(f, { round: 'R2' });
    const second = successful(invoke(f, 'apply', { head: firstHead }));
    assert.equal(second.status, 'imported');
    assert.equal(git(f.target, 'rev-parse', 'HEAD^'), firstHead);
    assert.deepEqual(tree(firstRound), firstBytes);
    assert.equal(git(f.target, 'branch', '--show-current'), 'sandbox-fixture');
    assert.equal(git(f.target, 'status', '--porcelain'), '');
    const after = tree(f.workspace);
    for (const [name, bytes] of Object.entries(before)) {
        if (!name.startsWith('prj/.git/') && name !== 'prj/.git') assert.deepEqual(after[name], bytes, `${name} changed`);
    }
});

test('repository mapping is explicit and the two target repos are independent', t => {
    const f = fixture(t);
    exported(f);
    rejected(invoke(f, 'preview', { root: f.documentation, repository: 'Documentation' }));
    const before = tree(f.target);
    exported(f, { repository: 'Documentation' });
    const preview = successful(invoke(f, 'preview', { root: f.documentation, repository: 'Documentation' }));
    assert.equal(successful(invoke(f, 'apply', {
        root: f.documentation, repository: 'Documentation', head: preview.head,
    })).status, 'imported');
    assert.deepEqual(tree(f.target), before);
});

test('stale HEAD refuses both a new import and exact replay', t => {
    const f = fixture(t);
    exported(f);
    const original = tree(f.target);
    rejected(invoke(f, 'apply', { head: '0'.repeat(40) }));
    assert.deepEqual(tree(f.target), original);
    const applied = successful(invoke(f, 'apply', { head: f.baseHead }));
    rejected(invoke(f, 'apply', { head: f.baseHead }));
    assert.equal(git(f.target, 'rev-parse', 'HEAD'), applied.head);
});

for (const dirty of ['staged', 'unstaged', 'untracked', 'merge', 'cherry-pick', 'rebase', 'index-lock']) {
    test(`refuses ${dirty} target state without modifying it`, t => {
        const f = fixture(t);
        exported(f);
        if (dirty === 'staged' || dirty === 'unstaged') {
            write(f.target, 'README.md', 'Local unfinished edit.\n');
            if (dirty === 'staged') git(f.target, 'add', 'README.md');
        } else if (dirty === 'untracked') write(f.target, 'unfinished.txt', 'Untracked work.\n');
        else if (dirty === 'merge') write(f.target, '.git/MERGE_HEAD', `${f.baseHead}\n`);
        else if (dirty === 'cherry-pick') write(f.target, '.git/CHERRY_PICK_HEAD', `${f.baseHead}\n`);
        else if (dirty === 'rebase') fs.mkdirSync(path.join(f.target, '.git/rebase-merge'));
        else write(f.target, '.git/index.lock', 'Owned by somebody else\n');
        const before = tree(f.target);
        rejected(invoke(f, 'preview'));
        rejected(invoke(f, 'apply', { head: f.baseHead }));
        assert.deepEqual(tree(f.target), before);
    });
}

test('strict packets reject malformed data without printing document contents', async t => {
    const f = fixture(t);
    const packet = exported(f);
    const secretMarker = 'fixture-private-text-must-not-appear-in-diagnostics';
    const mutations = {
        'invalid JSON': () => `{${secretMarker}`,
        'unsupported version': p => { p.version = 2; },
        'unknown field': p => { p.unexpected = true; },
        'wrong checksum': p => { p.documents[0].sha256 = '0'.repeat(64); },
        'wrong blob': p => { p.documents[0].blob = '0'.repeat(40); },
        'unsupported extension': p => { p.documents[0].path = 'brief.js'; },
        'path traversal': p => { p.documents[0].path = '../outside.md'; },
        'absolute path': p => { p.documents[0].path = '/outside.md'; },
        'backslash traversal': p => { p.documents[0].path = '..\\outside.md'; },
        'auth path': p => { p.documents[0].path = '.secrets/brief.md'; },
        'git metadata path': p => { p.documents[0].path = '.git/brief.md'; },
        'invalid task': p => { p.task = '../outside'; },
        'numeric task': p => { p.task = 42; },
        'missing task': p => { delete p.task; },
        'long round': p => { p.round = 'R'.repeat(65); },
        'duplicate documents': p => { p.documents.push({ ...p.documents[0] }); },
        'case collision': p => { p.documents.push({ ...p.documents[0], path: p.documents[0].path.toUpperCase() }); },
        'NUL content': p => { p.documents[0].content = `${secretMarker}\0`; },
        'malformed Unicode': p => { p.documents[0].content = `${secretMarker}\ud800`; },
    };
    const before = tree(f.target);
    for (const [name, mutate] of Object.entries(mutations)) {
        await t.test(name, () => {
            const changed = structuredClone(packet);
            const raw = mutate(changed);
            write(f.packets, 'invalid.json', raw || JSON.stringify(changed));
            const diagnostic = rejected(invoke(f, 'apply', { packet: path.join(f.packets, 'invalid.json'), head: f.baseHead }));
            assert.ok(!diagnostic.includes(secretMarker));
            assert.deepEqual(tree(f.target), before);
        });
    }
});

test('encoded packet size is bounded even when JSON escaping expands valid text', () => {
    const content = '\u0001'.repeat(2 * 1024 * 1024);
    const bytes = Buffer.from(content);
    const blob = crypto.createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
    const documents = ['a.md', 'b.md', 'c.md'].map(name => ({
        path: name, blob, sha256: sha256(bytes), content,
    }));
    assert.throws(() => require(core).validatePacket({
        version: 1, repository: 'prj', task: 'TASK_42', round: 'R1',
        sourceCommit: '0'.repeat(40), documents,
    }), /Encoded packet exceeds the size limit/);
});

test('export refuses non-text, executable, symlink and authentication/control paths', async t => {
    const f = fixture(t);
    write(f.source, 'code.js', 'console.log("not a brief");\n');
    write(f.source, 'binary.md', Buffer.from([0xff, 0xfe]));
    write(f.source, 'executable.md', '# Not an executable brief\n');
    fs.chmodSync(path.join(f.source, 'executable.md'), 0o755);
    write(f.source, '.secrets/credentials.txt', 'Fixture-only excluded text\n');
    fs.symlinkSync('README.md', path.join(f.source, 'linked.md'));
    git(f.source, 'add', '.');
    git(f.source, 'update-index', '--chmod=+x', 'executable.md');
    git(f.source, 'commit', '--quiet', '-m', 'Invalid source candidates');
    for (const candidate of ['code.js', 'binary.md', 'executable.md', 'linked.md', '.secrets/credentials.txt', '.git/config.md', '../README.md']) {
        await t.test(candidate, () => rejected(invoke(f, 'export', { paths: [candidate] })));
    }
});

test('same round with a different packet is a conflict, not replacement', t => {
    const f = fixture(t);
    exported(f);
    const applied = successful(invoke(f, 'apply', { head: f.baseHead }));
    const before = tree(f.target);
    write(f.source, 'briefs/first brief.md', '# A changed committed brief\n');
    git(f.source, 'add', 'briefs');
    git(f.source, 'commit', '--quiet', '-m', 'Change same round content');
    exported(f);
    rejected(invoke(f, 'apply', { head: applied.head }));
    assert.deepEqual(tree(f.target), before);
});

for (const collision of ['tracked-directory', 'round-symlink', 'parent-symlink', 'git-symlink']) {
    test(`refuses ${collision} without overwriting or following it`, t => {
        const f = fixture(t);
        exported(f);
        if (collision === 'tracked-directory') {
            write(f.target, 'sandbox-rounds/TASK_42/R1/existing.txt', 'Previously owned content\n');
            git(f.target, 'add', '.');
            git(f.target, 'commit', '--quiet', '-m', 'Preexisting round path');
        } else if (collision === 'git-symlink') {
            fs.renameSync(path.join(f.target, '.git'), path.join(f.base, 'moved-metadata'));
            fs.symlinkSync(path.join(f.base, 'moved-metadata'), path.join(f.target, '.git'));
        } else if (collision === 'parent-symlink') {
            fs.symlinkSync(f.packets, path.join(f.target, 'sandbox-rounds'));
        } else {
            fs.mkdirSync(path.join(f.target, 'sandbox-rounds/TASK_42'), { recursive: true });
            fs.symlinkSync(f.packets, path.join(f.target, 'sandbox-rounds/TASK_42/R1'));
        }
        const before = tree(f.target);
        const packetsBefore = tree(f.packets);
        rejected(invoke(f, 'preview'));
        rejected(invoke(f, 'apply', { head: f.baseHead }));
        assert.deepEqual(tree(f.target), before);
        assert.deepEqual(tree(f.packets), packetsBefore);
    });
}

test('repository hooks, external filters and fsmonitor are not executed', t => {
    const f = fixture(t);
    for (const root of [f.source, f.target]) {
        write(root, '.gitattributes', '* filter=round-hostile\n');
        git(root, 'add', '.gitattributes');
        git(root, 'commit', '--quiet', '-m', 'Fixture attributes');
    }
    const head = git(f.target, 'rev-parse', 'HEAD');
    const marker = path.join(f.base, 'executed.marker');
    const script = write(f.base, 'untrusted-git-command.sh', `#!/bin/sh\nprintf executed >> '${marker}'\nexit 99\n`);
    fs.chmodSync(script, 0o755);
    for (const root of [f.source, f.target]) {
        for (const hook of ['pre-commit', 'post-commit', 'reference-transaction']) {
            write(root, `.git/hooks/${hook}`, fs.readFileSync(script));
            fs.chmodSync(path.join(root, '.git/hooks', hook), 0o755);
        }
        git(root, 'config', 'filter.round-hostile.clean', `'${script}'`);
        git(root, 'config', 'filter.round-hostile.smudge', `'${script}'`);
        git(root, 'config', 'filter.round-hostile.required', 'true');
        git(root, 'config', 'core.fsmonitor', script);
    }
    exported(f);
    successful(invoke(f, 'preview'));
    const imported = successful(invoke(f, 'apply', { head }));
    assert.equal(imported.status, 'imported');
    assert.ok(!fs.existsSync(marker), 'An untrusted Git command was executed.');
});

for (const fault of ['publish', 'index']) {
    test(`journal recovery safely ${fault === 'publish' ? 'rolls back' : 'completes'} an interrupted import`, t => {
        const f = fixture(t);
        exported(f);
        const message = rejected(invoke(f, 'apply', {
            head: f.baseHead,
            env: { NODE_OPTIONS: `--require=${path.join(__dirname, 'faults.cjs')}`, ROUND_FIXTURE_FAULT: fault },
        }));
        assert.match(message, /recover/i);
        assert.ok(fs.existsSync(path.join(f.state, 'pending.json')));
        rejected(invoke(f, 'preview'));
        const current = git(f.target, 'rev-parse', 'HEAD');
        rejected(invoke(f, 'recover', { head: '0'.repeat(40) }));
        const recovered = successful(invoke(f, 'recover', { head: current }));
        assert.equal(recovered.status, fault === 'publish' ? 'rolled-back' : 'completed');
        assert.equal(recovered.head, current);
        assert.ok(!fs.existsSync(path.join(f.state, 'pending.json')));
        assert.ok(!fs.existsSync(path.join(f.target, '.git/index.lock')));
        assert.ok(!fs.existsSync(path.join(f.target, '.git/HEAD.lock')));
        assert.equal(git(f.target, 'status', '--porcelain'), '');
        assert.equal(fs.readFileSync(path.join(f.workspace, '.m2/repository/sentinel'), 'utf8'), 'Retained Maven cache\n');
        if (fault === 'publish') {
            assert.equal(current, f.baseHead);
            assert.equal(successful(invoke(f, 'preview')).status, 'ready');
        } else {
            assert.equal(git(f.target, 'rev-parse', 'HEAD^'), f.baseHead);
            assert.equal(successful(invoke(f, 'preview')).status, 'already-imported');
        }
    });
}

function killed(result) {
    assert.equal(result.signal, 'SIGKILL', `Expected an actual killed helper, not a simulated diagnostic: ${result.stderr}`);
    assert.equal(result.status, null);
    assert.equal(result.stdout, '');
}

function faultEnvironment(fault) {
    return { NODE_OPTIONS: `--require=${path.join(__dirname, 'faults.cjs')}`, ROUND_FIXTURE_FAULT: fault };
}

function pending(f) {
    const journal = JSON.parse(fs.readFileSync(path.join(f.state, 'pending.json'), 'utf8'));
    assert.equal(journal.version, 2);
    return journal;
}

function assertRecoveryClean(f, journal, status, head, indexHash) {
    const result = successful(invoke(f, 'recover', { head }));
    assert.equal(result.status, status);
    assert.equal(result.head, head);
    // Inspect before fixture `git status` can refresh index stat information.
    if (indexHash) assert.equal(sha256(fs.readFileSync(path.join(f.target, '.git/index'))), indexHash);
    assert.ok(!fs.existsSync(path.join(f.state, 'pending.json')));
    for (const artifact of ['index.lock', 'HEAD.lock', journal.ownerName, journal.indexName, journal.stageName]) {
        assert.ok(!fs.existsSync(path.join(f.target, '.git', artifact)), `Recovery left ${artifact}`);
    }
    assert.equal(git(f.target, 'status', '--porcelain'), '');
    assert.equal(fs.readFileSync(path.join(f.workspace, '.m2/repository/sentinel'), 'utf8'), 'Retained Maven cache\n');
    return result;
}

for (const fault of ['journal-preparing', 'owner-created', 'index-lock-created', 'head-lock-created']) {
    test(`crash recovery: preparation intent survives a kill at ${fault}`, t => {
        const f = fixture(t);
        exported(f);
        const beforeIndex = fs.readFileSync(path.join(f.target, '.git/index'));
        killed(invoke(f, 'apply', { head: f.baseHead, env: faultEnvironment(fault) }));
        const journal = pending(f);
        assert.equal(journal.phase, 'preparing');
        assert.equal(journal.commit, null);
        assert.equal(journal.partialStage, true);
        assert.equal(git(f.target, 'rev-parse', 'HEAD'), f.baseHead);
        assert.deepEqual(fs.readFileSync(path.join(f.state, 'before.index')), beforeIndex);
        assert.deepEqual(fs.readFileSync(path.join(f.target, '.git/index')), beforeIndex);
        const expectedLocks = fault === 'head-lock-created' ? ['index.lock', 'HEAD.lock']
            : fault === 'index-lock-created' ? ['index.lock'] : [];
        for (const lock of ['index.lock', 'HEAD.lock']) {
            const file = path.join(f.target, '.git', lock);
            assert.equal(fs.existsSync(file), expectedLocks.includes(lock));
            if (fs.existsSync(file)) assert.equal(fs.readFileSync(file, 'utf8'), journal.lockMarker);
        }
        rejected(invoke(f, 'preview'));
        assertRecoveryClean(f, journal, 'rolled-back', f.baseHead);
        assert.deepEqual(fs.readFileSync(path.join(f.target, '.git/index')), beforeIndex);
        assert.equal(successful(invoke(f, 'preview')).status, 'ready');
    });
}

for (const fault of ['index-partial-copy', 'index-prepared-rename']) {
    test(`crash recovery: ${fault} never exposes a partial index lock`, t => {
        const f = fixture(t);
        exported(f);
        const beforeIndex = fs.readFileSync(path.join(f.target, '.git/index'));
        killed(invoke(f, 'apply', { head: f.baseHead, env: faultEnvironment(fault) }));
        const journal = pending(f);
        assert.equal(journal.phase, 'committed');
        assert.equal(git(f.target, 'rev-parse', 'HEAD'), journal.commit);
        assert.deepEqual(fs.readFileSync(path.join(f.target, '.git/index')), beforeIndex);
        const indexLock = fs.readFileSync(path.join(f.target, '.git/index.lock'));
        if (fault === 'index-partial-copy') {
            const partial = fs.readFileSync(path.join(f.target, '.git', journal.indexName));
            assert.equal(partial.length, 17);
            assert.notEqual(sha256(partial), journal.afterHash);
            assert.equal(indexLock.toString('utf8'), journal.lockMarker);
        } else {
            assert.ok(!fs.existsSync(path.join(f.target, '.git', journal.indexName)));
            assert.equal(sha256(indexLock), journal.afterHash);
        }
        assertRecoveryClean(f, journal, 'completed', journal.commit, journal.afterHash);
        assert.equal(git(f.target, 'rev-parse', 'HEAD^'), f.baseHead);
        assert.equal(successful(invoke(f, 'preview')).status, 'already-imported');
    });
}

test('crash recovery: interrupted rollback resumes deletion of already-missing stage files', t => {
    const f = fixture(t);
    exported(f);
    killed(invoke(f, 'apply', { head: f.baseHead, env: faultEnvironment('published') }));
    const journal = pending(f);
    const round = path.join(f.target, journal.roundPath);
    const stage = path.join(f.target, '.git', journal.stageName);
    const originalFiles = tree(round);
    assert.equal(journal.phase, 'prepared');
    assert.ok(!fs.existsSync(stage));
    killed(invoke(f, 'recover', { head: f.baseHead, env: faultEnvironment('rollback-unlink') }));
    assert.equal(pending(f).phase, 'rolling-back');
    assert.ok(!fs.existsSync(round));
    const remainingFiles = tree(stage);
    assert.ok(Object.keys(remainingFiles).length > 0, 'Fault must leave an incomplete deletion, not an empty stage.');
    assert.ok(Object.keys(remainingFiles).length < Object.keys(originalFiles).length);
    for (const [name, value] of Object.entries(remainingFiles)) assert.deepEqual(value, originalFiles[name]);
    assertRecoveryClean(f, journal, 'rolled-back', f.baseHead);
    assert.equal(successful(invoke(f, 'preview')).status, 'ready');
});

test('crash recovery: a committed candidate recreates its missing checkpoint', t => {
    const f = fixture(t);
    exported(f);
    killed(invoke(f, 'apply', { head: f.baseHead, env: faultEnvironment('index-partial-copy') }));
    const journal = pending(f);
    assert.equal(git(f.target, 'rev-parse', 'HEAD^'), f.baseHead);
    git(f.target, 'update-ref', '-d', journal.checkpoint, f.baseHead);
    assert.equal(git(f.target, 'for-each-ref', '--format=%(refname)', journal.checkpoint), '');
    assertRecoveryClean(f, journal, 'completed', journal.commit);
    assert.equal(git(f.target, 'rev-parse', journal.checkpoint), f.baseHead);
    assert.equal(successful(invoke(f, 'preview')).status, 'already-imported');
});

test('crash recovery: missing checkpoint is not recreated before candidate parent validation', t => {
    const f = fixture(t);
    exported(f);
    killed(invoke(f, 'apply', { head: f.baseHead, env: faultEnvironment('index-partial-copy') }));
    const journal = pending(f);
    git(f.target, 'update-ref', '-d', journal.checkpoint, f.baseHead);
    const candidateTree = git(f.target, 'rev-parse', `${journal.commit}^{tree}`);
    const unrelated = git(f.target, 'commit-tree', candidateTree, '-m', 'Unrelated fixture candidate without a parent');
    write(f.target, `.git/${journal.branch}`, `${unrelated}\n`);
    write(f.state, 'pending.json', JSON.stringify({ ...journal, commit: unrelated }));
    const beforeIndex = fs.readFileSync(path.join(f.target, '.git/index'));
    const message = rejected(invoke(f, 'recover', { head: unrelated }));
    assert.match(message, /parent/i);
    assert.equal(git(f.target, 'for-each-ref', '--format=%(refname)', journal.checkpoint), '');
    assert.equal(git(f.target, 'rev-parse', 'HEAD'), unrelated);
    assert.deepEqual(fs.readFileSync(path.join(f.target, '.git/index')), beforeIndex);
    write(f.target, `.git/${journal.branch}`, `${journal.commit}\n`);
    write(f.state, 'pending.json', JSON.stringify(journal));
    assertRecoveryClean(f, journal, 'completed', journal.commit);
    assert.equal(git(f.target, 'rev-parse', journal.checkpoint), f.baseHead);
});

for (const ownership of ['matching-partial', 'unrelated']) {
    test(`crash recovery: ${ownership} ref locks are handled without discarding another writer's lock`, t => {
        const f = fixture(t);
        exported(f);
        killed(invoke(f, 'apply', { head: f.baseHead, env: faultEnvironment('journal-updating-refs') }));
        const journal = pending(f);
        assert.equal(journal.phase, 'updating-refs');
        const branchLock = path.join(f.target, '.git', `${journal.branch}.lock`);
        const checkpointLock = path.join(f.target, '.git', `${journal.checkpoint}.lock`);
        const branchBytes = ownership === 'matching-partial' ? journal.commit.slice(0, 12) : 'Unrelated writer owns this lock\n';
        write(f.target, `.git/${journal.branch}.lock`, branchBytes);
        write(f.target, `.git/${journal.checkpoint}.lock`, journal.baseHead.slice(0, 8));
        if (ownership === 'unrelated') {
            rejected(invoke(f, 'recover', { head: f.baseHead }));
            assert.equal(fs.readFileSync(branchLock, 'utf8'), branchBytes);
            assert.ok(fs.existsSync(path.join(f.state, 'pending.json')));
            fs.unlinkSync(branchLock);
        }
        assertRecoveryClean(f, journal, 'rolled-back', f.baseHead);
        assert.ok(!fs.existsSync(branchLock));
        assert.ok(!fs.existsSync(checkpointLock));
        assert.equal(successful(invoke(f, 'preview')).status, 'ready');
    });
}

test('packet validates the Git blob as well as its raw byte checksum', t => {
    const f = fixture(t);
    const packet = exported(f);
    packet.documents[0].content = 'A different content with a matching SHA256 only.\n';
    packet.documents[0].sha256 = sha256(packet.documents[0].content);
    write(f.packets, 'tampered.json', JSON.stringify(packet));
    rejected(invoke(f, 'preview', { packet: path.join(f.packets, 'tampered.json') }));
    packet.documents[0].blob = crypto.createHash('sha1')
        .update(`blob ${Buffer.byteLength(packet.documents[0].content)}\0${packet.documents[0].content}`).digest('hex');
    write(f.packets, 'consistent.json', JSON.stringify(packet));
    assert.equal(successful(invoke(f, 'preview', { packet: path.join(f.packets, 'consistent.json') })).status, 'ready');
});

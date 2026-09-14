'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Controller, validateConfig, selection, digest, nextRound } = require('/opt/tasks/tasks.js');
const { core, fixture, repository, git, write, tree, exported, successful, invoke } = require('../rounds/fixtures');

process.umask(0o077);
const IMAGE = `sha256:${'a'.repeat(64)}`;
function setup(t) {
    const f = fixture(t);
    f.docsSource = path.join(f.base, 'external documentation');
    repository(f.docsSource);
    write(f.docsSource, 'review.md', '# Committed documentation review\n');
    git(f.docsSource, 'add', '.');
    git(f.docsSource, 'commit', '--quiet', '-m', 'Documentation input');
    f.registry = path.join(f.base, 'registry', 'TASK-1');
    fs.mkdirSync(f.registry, { recursive: true, mode: 0o700 });
    f.config = { version: 1, task: 'TASK-1', workspace: f.workspace, image: 'localhost/pera-sandbox',
        profiles: ['agencyWWW'], repositories: {
            prj: { source: f.source, ref: 'refs/heads/sandbox-fixture', auditBase: f.baseHead,
                briefs: ['briefs/first brief.md'] },
            Documentation: { source: f.docsSource, ref: 'refs/heads/sandbox-fixture',
                auditBase: git(f.documentation, 'rev-parse', 'HEAD'), briefs: ['review.md'] },
        } };
    f.calls = [];
    f.image = IMAGE;
    f.hook = () => {};
    f.after = () => {};
    f.fault = null;
    f.adapter = (operation, args) => {
        f.calls.push({ operation, args });
        const injected = f.hook(operation, args);
        if (injected !== undefined) return injected;
        let result;
        if (operation === 'image') result = { id: f.image, user: 'sandbox' };
        else if (operation === 'source') result = { ref: args.ref, head: git(args.source, 'rev-parse', args.ref) };
        else if (operation === 'import-head') {
            const target = path.join(args.workspace, args.repository);
            assert.equal(git(target, 'rev-list', '--parents', '-n', '1', args.head), `${args.head} ${args.base}`);
            result = { status: 'exact-import' };
        } else if (operation === 'round') {
            const target = args.mode === 'export' ? args.source : path.join(args.workspace, args.repository);
            const argv = ['/opt/rounds.js', args.mode, '--root', target, '--repository', args.repository];
            if (args.mode !== 'export') {
                const state = path.join(f.base, `low-state-${args.repository}`);
                fs.mkdirSync(state, { recursive: true, mode: 0o700 });
                argv.push('--state', state);
            }
            for (const key of ['ref', 'task', 'round', 'packet', 'expected-head', 'base', 'work-base']) {
                if (args[key] !== undefined) argv.push(`--${key}`, args[key]);
            }
            for (const selected of args.paths || []) argv.push('--path', selected);
            if (args.mode === 'collect') argv.push('--output', args.output);
            const env = { PATH: process.env.PATH, HOME: f.base, TMPDIR: f.base };
            if (f.fault && args.mode === 'apply') {
                env.NODE_OPTIONS = '--require=/tests/rounds/faults.cjs';
                env.ROUND_FIXTURE_FAULT = f.fault;
            }
            const command = spawnSync(process.execPath, argv, { cwd: f.base, env, encoding: 'utf8', maxBuffer: 40 * 1024 * 1024 });
            if (command.status !== 0) throw new Error(command.stderr || `Low-level interrupted: ${command.signal}`);
            result = JSON.parse(command.stdout);
            if (args.mode === 'export') fs.writeFileSync(args.output, command.stdout, { flag: 'wx', mode: 0o600 });
        } else throw new Error(`Unexpected adapter operation: ${operation}`);
        f.after(operation, args, result);
        return result;
    };
    f.controller = () => new Controller(f.registry, f.registry, f.adapter);
    f.record = () => JSON.parse(fs.readFileSync(path.join(f.registry, 'record.json')));
    f.register = () => f.controller().register(f.config);
    return f;
}
function commit(root, file, content) {
    write(root, file, content);
    git(root, 'add', file);
    git(root, 'commit', '--quiet', '-m', 'Fixture committed update');
}
function send(f) { return f.controller().send(); }
function apply(f, plan) { return f.controller().apply(plan.planId); }

test('closed config rejects ambiguous refs, paths, fields, types and brief selections', () => {
    const base = { version: 1, task: 'TASK-1', workspace: '/fixture/workspace', image: 'fixture', profiles: [],
        repositories: Object.fromEntries(['prj', 'Documentation'].map(repo => [repo,
            { source: `/fixture/${repo}`, ref: 'refs/heads/task', auditBase: 'b'.repeat(40), briefs: [] }])) };
    assert.equal(validateConfig(base), base);
    const mutations = [
        value => { value.extra = true; },
        value => { delete value.repositories.Documentation; },
        value => { value.version = '1'; },
        value => { value.task = '../escape'; },
        value => { value.workspace = '/fixture/../workspace'; },
        value => { value.profiles = 'agencyWWW'; },
        value => { value.repositories.prj.ref = 'HEAD'; },
        value => { value.repositories.prj.ref = 'refs/heads/a..b'; },
        value => { value.repositories.prj.ref = 'refs/heads/-branch.lock'; },
        value => { value.repositories.prj.auditBase = 'abc123'; },
        value => { value.repositories.prj.briefs = ['../brief.md']; },
        value => { value.repositories.prj.briefs = ['brief.md', 'BRIEF.MD']; },
        value => { value.repositories.prj.briefs = ['secret.json']; },
    ];
    for (const mutate of mutations) {
        const invalid = structuredClone(base);
        mutate(invalid);
        assert.throws(() => validateConfig(invalid));
    }
    assert.throws(() => selection(base, []), /at least one/);
    assert.throws(() => selection(base, ['prj:a.md', 'prj:A.md']), /colliding/);
    assert.throws(() => selection(base, ['other:a.md']), /requires/);
    assert.deepEqual(selection(base, ['Documentation:literal name.md']), { prj: [], Documentation: ['literal name.md'] });
});

test('registration is read-only, idempotent and pins explicit named source refs plus ancestor bases', t => {
    const f = setup(t);
    const before = tree(f.workspace);
    const source = tree(f.source);
    assert.equal(f.register().status, 'registered');
    assert.equal(f.register().status, 'already-registered');
    assert.deepEqual(tree(f.workspace), before);
    assert.deepEqual(tree(f.source), source);
    assert.equal(f.record().imageId, IMAGE);
    const changed = structuredClone(f.config);
    changed.profiles = [];
    assert.throws(() => f.controller().register(changed), /different definition/);
    assert.equal(f.record().lastRound, null);
});

test('task state refuses symlinks, hard links, permissive modes and config corruption', t => {
    const f = setup(t);
    f.register();
    const record = path.join(f.registry, 'record.json');
    fs.chmodSync(record, 0o644);
    assert.throws(() => f.controller(), /private/);
    fs.chmodSync(record, 0o600);
    fs.linkSync(record, path.join(f.base, 'linked-record'));
    assert.throws(() => f.controller(), /Hard-linked/);
    fs.unlinkSync(path.join(f.base, 'linked-record'));
    fs.symlinkSync(f.source, path.join(f.registry, 'unsafe'));
    assert.throws(() => f.controller(), /unsupported/);
    fs.unlinkSync(path.join(f.registry, 'unsafe'));
    const data = f.record();
    data.config.profiles = [];
    write(f.registry, 'record.json', JSON.stringify(data));
    assert.throws(() => f.controller().status(), /config changed/);
});

test('send requires chat/apply separation, uses selected branch not ambient checkout, and preserves warmed caches', t => {
    const f = setup(t);
    f.register();
    git(f.source, 'checkout', '--quiet', '-b', 'ambient');
    commit(f.source, 'briefs/first brief.md', 'Wrong ambient branch input\n');
    const before = tree(f.workspace);
    const plan = send(f);
    assert.equal(plan.status, 'approval-required');
    assert.deepEqual(tree(f.workspace), before);
    assert.equal(plan.repositories.prj.sourceCommit, git(f.source, 'rev-parse', f.config.repositories.prj.ref));
    const repeat = send(f);
    assert.equal(repeat.planId, plan.planId);
    assert.equal(Object.keys(f.record().plans).length, 1);
    assert.equal(apply(f, plan).status, 'applied');
    assert.equal(apply(f, plan).status, 'already-applied');
    for (const target of [f.target, f.documentation]) {
        assert.equal(git(target, 'rev-list', '--count', 'HEAD'), '2');
        assert.equal(fs.readFileSync(path.join(target, '.cache/sentinel'), 'utf8'), 'Retained .cache\n');
        assert.equal(git(target, 'remote'), '');
    }
    assert.equal(fs.readFileSync(path.join(f.workspace, '.m2/repository/sentinel'), 'utf8'), 'Retained Maven cache\n');
    assert.equal(send(f).status, 'unchanged');
});

test('unrelated source commits are no-op; Documentation-only change does not import prj', t => {
    const f = setup(t);
    f.register();
    apply(f, send(f));
    const prjHead = git(f.target, 'rev-parse', 'HEAD');
    commit(f.source, 'unrelated.txt', 'not selected\n');
    assert.equal(send(f).status, 'unchanged');
    commit(f.docsSource, 'review.md', '# A new selected review\n');
    const plan = send(f);
    assert.equal(plan.round, 'R2');
    assert.equal(plan.repositories.prj.action, 'preserve');
    assert.equal(plan.repositories.Documentation.action, 'import');
    apply(f, plan);
    assert.equal(git(f.target, 'rev-parse', 'HEAD'), prjHead);
});

test('completed-plan replay validates current state while allowing legitimate later work', t => {
    const f = setup(t);
    f.register();
    const first = send(f);
    apply(f, first);
    commit(f.target, 'src/later.txt', 'Legitimate work after import\n');
    commit(f.documentation, 'later.md', 'Legitimate documentation work\n');
    const before = tree(f.workspace);
    const replay = apply(f, first);
    assert.equal(replay.status, 'already-applied');
    assert.equal(replay.currentHeads.prj, git(f.target, 'rev-parse', 'HEAD'));
    assert.equal(replay.currentHeads.Documentation, git(f.documentation, 'rev-parse', 'HEAD'));
    assert.deepEqual(tree(f.workspace), before);
    commit(f.docsSource, 'review.md', 'Next external review\n');
    apply(f, send(f));
    assert.equal(apply(f, first).status, 'already-applied', 'An old completed plan can be acknowledged after a later intact round.');
});

for (const state of ['branch', 'dirty', 'running', 'recovery', 'history-rewrite']) {
    test(`completed-plan replay refuses current ${state} state`, t => {
        const f = setup(t);
        f.register();
        const plan = send(f);
        apply(f, plan);
        if (state === 'branch') git(f.target, 'checkout', '--quiet', '-b', 'different');
        else if (state === 'dirty') write(f.target, 'unfinished.txt', 'Keep uncommitted work\n');
        else if (state === 'running') f.hook = (operation, args) => {
            if (operation === 'round' && args.mode === 'inspect' && args.repository === 'prj') {
                return { status: 'running', repository: 'prj', observedWorktree: false };
            }
        };
        else if (state === 'recovery') write(path.join(f.base, 'low-state-prj'), 'pending.json', JSON.stringify({
            version: 2, phase: 'preparing', packetSha256: 'a'.repeat(64),
            roundPath: 'sandbox-rounds/TASK-1/R2', baseHead: git(f.target, 'rev-parse', 'HEAD'),
            commit: null, branch: 'refs/heads/sandbox-fixture',
        }));
        else {
            const replacement = git(f.target, 'commit-tree', 'HEAD^{tree}', '-p', f.baseHead, '-m', 'Rewritten import ancestry');
            git(f.target, 'update-ref', 'refs/heads/sandbox-fixture', replacement);
        }
        const before = tree(f.workspace);
        assert.throws(() => apply(f, plan));
        assert.deepEqual(tree(f.workspace), before);
    });
}

for (const mutation of ['deleted', 'document', 'README', 'manifest', 'consistent-forgery', 'checkpoint']) {
    test(`retained ${mutation} handoff blocks unchanged sends and completed replay`, t => {
        const f = setup(t);
        f.register();
        const plan = send(f);
        apply(f, plan);
        const round = `sandbox-rounds/TASK-1/${plan.round}`;
        if (mutation === 'deleted') git(f.target, 'rm', '-r', '--quiet', round);
        else if (mutation === 'checkpoint') git(f.target, 'update-ref', '-d', `refs/sandbox-rounds/checkpoints/TASK-1/${plan.round}`);
        else if (mutation === 'consistent-forgery') {
            const packet = JSON.parse(fs.readFileSync(path.join(f.registry, 'plans', plan.planId, 'prj.json')));
            packet.documents[0].content = 'Self-consistent but unapproved input\n';
            const bytes = Buffer.from(packet.documents[0].content);
            const crypto = require('node:crypto');
            packet.documents[0].sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
            packet.documents[0].blob = crypto.createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
            const helper = require(core);
            helper.validatePacket(packet);
            const changed = helper.packetFiles(packet, helper.sha256(JSON.stringify(packet)));
            for (const [name, content] of changed) write(f.target, `${round}/${name}`, content);
            git(f.target, 'add', round);
        } else {
            const name = mutation === 'document' ? 'files/briefs/first brief.md'
                : mutation === 'README' ? 'README.md' : 'manifest.json';
            write(f.target, `${round}/${name}`, 'Committed retained-input change\n');
            git(f.target, 'add', round);
        }
        if (mutation !== 'checkpoint') git(f.target, 'commit', '--quiet', '-m', 'Mutated delivered input');
        const before = tree(f.workspace);
        assert.throws(() => send(f), /Retained handoff integrity/);
        assert.throws(() => apply(f, plan), /Retained handoff integrity/);
        assert.equal(f.controller().status().status, 'blocked');
        assert.deepEqual(tree(f.workspace), before);
        commit(f.docsSource, 'review.md', 'Documentation changed while prj input is invalid\n');
        assert.throws(() => send(f), /Retained handoff integrity/, 'A mixed send must also validate the preserved repository.');
        assert.equal(Object.keys(f.record().plans).length, 1);
        assert.deepEqual(tree(f.workspace), before);
    });
}

test('committed input corruption remains collectable for audit instead of being hidden or reset', t => {
    const f = setup(t);
    f.register();
    const plan = send(f);
    apply(f, plan);
    const name = `sandbox-rounds/TASK-1/${plan.round}/manifest.json`;
    commit(f.target, name, '{malformed-input-metadata');
    assert.equal(f.controller().status().status, 'blocked');
    const result = f.controller().collect();
    assert.equal(result.status, 'collected');
    const patch = fs.readFileSync(path.join(result.directory, 'prj/work.patch'), 'utf8');
    assert.ok(patch.includes('malformed-input-metadata'));
});

test('prior entrypoints exclude unrelated task histories', t => {
    const f = setup(t);
    exported(f);
    successful(invoke(f, 'apply', { head: f.baseHead }));
    f.register();
    const plan = send(f);
    assert.deepEqual(plan.priorEntrypoints.prj, []);
    assert.equal(plan.round, 'R2', 'Existing namespaces are still reserved.');
});

test('round allocator reserves legacy checkpoints and other task round namespaces', () => {
    assert.equal(nextRound({ plans: { prior: { round: 'R3' } } }, {
        prj: { rounds: [{ task: 'legacy', round: 'R1' }], checkpoints: [{ task: 'legacy', round: 'R2' }] },
        Documentation: { rounds: [], checkpoints: [] },
    }), 'R4');
});

test('plan, packet, image and both changed/unchanged target heads invalidate approval', t => {
    const f = setup(t);
    f.config.repositories.Documentation.briefs = [];
    f.register();
    const plan = send(f);
    f.image = `sha256:${'b'.repeat(64)}`;
    assert.throws(() => apply(f, plan), /image changed/);
    f.image = IMAGE;
    const file = path.join(f.registry, 'plans', plan.planId, 'prj.json');
    assert.equal(fs.statSync(file).mode & 0o777, 0o400);
    fs.chmodSync(file, 0o600);
    const original = fs.readFileSync(file);
    fs.appendFileSync(file, '\n');
    assert.throws(() => apply(f, plan), /packet bytes changed/);
    fs.writeFileSync(file, original);
    const planFile = path.join(f.registry, 'plans', plan.planId, 'plan.json');
    fs.chmodSync(planFile, 0o600);
    const planBytes = fs.readFileSync(planFile);
    const altered = JSON.parse(planBytes);
    altered.targets.prj.head = 'b'.repeat(40);
    fs.writeFileSync(planFile, JSON.stringify(altered));
    assert.throws(() => apply(f, plan), /plan ID/);
    fs.writeFileSync(planFile, planBytes);
    commit(f.documentation, 'implementation.txt', 'Unapproved context change\n');
    assert.throws(() => apply(f, plan), /unchanged context advanced/);
    assert.equal(git(f.target, 'rev-parse', 'HEAD'), f.baseHead);
});

test('branch switches, dirty state, running containers and unknown inspection errors are surfaced', t => {
    const f = setup(t);
    f.register();
    write(f.target, 'src/original.txt', 'dirty\n');
    assert.equal(f.controller().status().status, 'blocked');
    assert.throws(() => send(f), /dirty/);
    git(f.target, 'checkout', '--', 'src/original.txt');
    git(f.target, 'checkout', '--quiet', '-b', 'manual-switch');
    assert.equal(f.controller().status().status, 'blocked');
    assert.throws(() => f.controller().collect(), /branch changed/);
    f.hook = (operation, args) => operation === 'round' && args.mode === 'inspect'
        ? { status: 'running', repository: args.repository, changes: null, operations: [], pending: null,
            rounds: [], checkpoints: [], containers: [{ id: 'fixture-container' }] } : undefined;
    const status = f.controller().status();
    assert.equal(status.status, 'running');
    assert.equal(status.inspected.prj.head, undefined);
    f.hook = (operation, args) => { if (operation === 'round' && args.mode === 'inspect') throw new Error('corrupt metadata'); };
    assert.throws(() => f.controller().status(), /corrupt metadata/);
});

test('controller reports detached-busy status before comparing branch or audit base', t => {
    const busy = (operation, args) => operation === 'round' && args.mode === 'inspect'
        ? { status: 'busy', repository: args.repository, head: 'a'.repeat(40), branch: null,
            changes: null, operations: ['rebase-merge'], pending: null, rounds: [], checkpoints: [],
            observedWorktree: false } : undefined;
    const f = setup(t);
    f.register();
    const plan = send(f);
    f.hook = busy;
    assert.equal(f.controller().status().status, 'blocked');
    assert.throws(() => apply(f, plan), /prj is busy/);
    assert.deepEqual(f.record().plans[plan.planId].completed, {});

    const unregistered = setup(t);
    unregistered.hook = busy;
    assert.throws(() => unregistered.register(), /prj must be stopped and clean/);
    assert.equal(fs.existsSync(path.join(unregistered.registry, 'record.json')), false);
});

test('source movement mid-send fails without publishing approval or changing target repositories', t => {
    const f = setup(t);
    f.register();
    const before = tree(f.workspace);
    let edited = false;
    f.after = (operation, args) => {
        if (!edited && operation === 'round' && args.mode === 'export') {
            edited = true;
            commit(f.source, 'briefs/first brief.md', 'Concurrent committed edit\n');
        }
    };
    assert.throws(() => send(f), /Source branch changed/);
    assert.equal(f.record().activePlan, null);
    assert.deepEqual(tree(f.workspace), before);
});

test('partial cross-repository apply records progress and retries only the missing import', t => {
    const f = setup(t);
    f.register();
    const plan = send(f);
    f.hook = (operation, args) => {
        if (operation === 'round' && args.mode === 'apply' && args.repository === 'Documentation') throw new Error('second repo failure');
    };
    assert.throws(() => apply(f, plan), /second repo failure/);
    assert.equal(f.record().plans[plan.planId].status, 'partial');
    assert.deepEqual(Object.keys(f.record().plans[plan.planId].completed), ['prj']);
    assert.equal(f.record().lastRound, null);
    assert.throws(() => f.controller().collect(), /pending/);
    assert.throws(() => send(f), /partial/);
    f.hook = () => {};
    apply(f, plan);
    assert.equal(git(f.target, 'rev-list', '--count', 'HEAD'), '2');
    assert.equal(git(f.documentation, 'rev-list', '--count', 'HEAD'), '2');
});

test('lost controller receipt after actual commit recognizes exact approved import without duplication', t => {
    const f = setup(t);
    f.register();
    const plan = send(f);
    let interrupted = false;
    f.after = (operation, args) => {
        if (!interrupted && operation === 'round' && args.mode === 'apply') {
            interrupted = true;
            throw new Error('controller died before recording receipt');
        }
    };
    assert.throws(() => apply(f, plan), /before recording/);
    assert.deepEqual(f.record().plans[plan.planId].completed, {});
    f.after = () => {};
    apply(f, plan);
    assert.equal(git(f.target, 'rev-list', '--count', 'HEAD'), '2');
    assert.ok(f.calls.some(call => call.operation === 'import-head'));
});

test('same-plan retry recovers matching low-level journal and refuses foreign pending work', t => {
    const f = setup(t);
    f.register();
    const plan = send(f);
    f.fault = 'journal-updating-refs';
    assert.throws(() => apply(f, plan), /interrupted/);
    f.fault = null;
    const pendingFile = path.join(f.base, 'low-state-prj', 'pending.json');
    const bytes = fs.readFileSync(pendingFile);
    write(f.target, '.git/MERGE_HEAD', `${f.baseHead}\n`);
    assert.throws(() => apply(f, plan), /recovery-required/);
    assert.deepEqual(fs.readFileSync(pendingFile), bytes, 'Foreign Git work must block even matching-journal recovery');
    fs.unlinkSync(path.join(f.target, '.git/MERGE_HEAD'));
    const pending = JSON.parse(bytes);
    pending.packetSha256 = 'f'.repeat(64);
    fs.writeFileSync(pendingFile, JSON.stringify(pending));
    assert.throws(() => apply(f, plan), /recovery-required/);
    fs.writeFileSync(pendingFile, bytes);
    apply(f, plan);
    assert.equal(git(f.target, 'rev-list', '--count', 'HEAD'), '2');
});

test('collect stages both repositories, preserves exact bases/provenance and returns unchanged without re-export', t => {
    const f = setup(t);
    commit(f.target, 'in-progress.txt', 'Existing uncollected work at attachment\n');
    f.register();
    const plan = send(f);
    apply(f, plan);
    const execution = git(f.target, 'rev-parse', 'HEAD');
    commit(f.target, 'src/original.txt', 'Committed sandbox result\n');
    const sourceBefore = tree(f.source);
    const workspaceBefore = tree(f.workspace);
    const collected = f.controller().collect();
    assert.equal(collected.status, 'collected');
    assert.equal(collected.manifest.binding.bases.prj, f.baseHead);
    assert.equal(collected.manifest.binding.workBases.prj, execution);
    assert.deepEqual(tree(f.workspace), workspaceBefore);
    assert.deepEqual(tree(f.source), sourceBefore);
    const full = fs.readFileSync(path.join(collected.directory, 'prj', 'changes.patch'), 'utf8');
    const work = fs.readFileSync(path.join(collected.directory, 'prj', 'work.patch'), 'utf8');
    assert.match(full, /in-progress.txt/);
    assert.match(full, /sandbox-rounds/);
    assert.doesNotMatch(work, /sandbox-rounds/);
    assert.match(work, /Committed sandbox result/);
    assert.equal(collected.applicationTestsRun, false);
    const calls = f.calls.filter(call => call.args.mode === 'collect').length;
    assert.equal(f.controller().collect().status, 'unchanged');
    assert.equal(f.calls.filter(call => call.args.mode === 'collect').length, calls);
    commit(f.target, 'later.txt', 'Second collection; older workBase is retained\n');
    const second = f.controller().collect();
    assert.equal(second.manifest.binding.bases.prj, collected.manifest.binding.heads.prj);
    assert.equal(second.manifest.binding.workBases.prj, execution);
    assert.notEqual(second.collectionId, collected.collectionId);
});

test('interrupted collection never advances either baseline or publishes a partial audit', t => {
    const f = setup(t);
    f.register();
    commit(f.target, 'result.txt', 'Committed result\n');
    const previous = f.record().collectionHeads;
    f.hook = (operation, args) => {
        if (operation === 'round' && args.mode === 'collect' && args.repository === 'Documentation') throw new Error('collection interrupted');
    };
    assert.throws(() => f.controller().collect(), /interrupted/);
    assert.deepEqual(f.record().collectionHeads, previous);
    assert.equal(f.record().lastCollection, null);
    assert.equal(fs.existsSync(path.join(f.registry, 'collections')), false);
    f.hook = () => {};
    assert.equal(f.controller().collect().status, 'collected');
});

test('collection checksum corruption is not treated as a successful unchanged export', t => {
    const f = setup(t);
    f.register();
    const first = f.controller().collect();
    assert.equal(first.manifest.repositories.prj.status, 'unchanged');
    assert.ok(!first.manifest.repositories.prj.files.some(file => file.name === 'history.bundle'));
    fs.appendFileSync(path.join(first.directory, 'prj', 'changes.patch'), 'tampered');
    assert.throws(() => f.controller().collect(), /checksum mismatch/);
});

test('the collection root manifest is checksummed, not merely its listed package files', t => {
    const f = setup(t);
    f.register();
    const first = f.controller().collect();
    const manifest = path.join(first.directory, 'collection.json');
    const altered = JSON.parse(fs.readFileSync(manifest));
    altered.files = [];
    fs.writeFileSync(manifest, JSON.stringify(altered));
    assert.throws(() => f.controller().collect(), /manifest checksum mismatch/);
});

test('a published collection survives controller state-write interruption without duplicate export', t => {
    const f = setup(t);
    f.register();
    commit(f.target, 'result.txt', 'Ready for collection\n');
    const original = fs.renameSync;
    let interrupted = false;
    fs.renameSync = function (from, to, ...args) {
        if (!interrupted && to === path.join(f.registry, 'record.json')
            && fs.existsSync(path.join(f.registry, 'collections'))) {
            interrupted = true;
            throw new Error('state-write interruption');
        }
        return original.call(this, from, to, ...args);
    };
    try {
        assert.throws(() => f.controller().collect(), /state-write interruption/);
    } finally {
        fs.renameSync = original;
    }
    assert.equal(f.record().lastCollection, null);
    const exported = f.calls.filter(call => call.args.mode === 'collect').length;
    const result = f.controller().collect();
    assert.equal(result.status, 'collected');
    assert.equal(f.calls.filter(call => call.args.mode === 'collect').length, exported);
});

test('later committed user work cannot be mistaken for a lost approved import receipt', t => {
    const f = setup(t);
    f.register();
    const plan = send(f);
    f.after = (operation, args) => {
        if (operation === 'round' && args.mode === 'apply') throw new Error('receipt lost');
    };
    assert.throws(() => apply(f, plan), /receipt lost/);
    f.after = () => {};
    commit(f.target, 'later-user-work.txt', 'Do not roll this back or absorb it into the approved send\n');
    const laterHead = git(f.target, 'rev-parse', 'HEAD');
    assert.throws(() => apply(f, plan));
    assert.equal(git(f.target, 'rev-parse', 'HEAD'), laterHead);
    assert.equal(git(f.documentation, 'rev-parse', 'HEAD'), f.config.repositories.Documentation.auditBase);
});

test('approved packets remain exact when source branches advance after the chat plan', t => {
    const f = setup(t);
    f.register();
    const plan = send(f);
    commit(f.source, 'briefs/first brief.md', 'Not part of the already approved packet\n');
    apply(f, plan);
    const imported = fs.readFileSync(path.join(f.target, 'sandbox-rounds/TASK-1/R1/files/briefs/first brief.md'), 'utf8');
    assert.match(imported, /First committed review/);
    assert.doesNotMatch(imported, /already approved/);
    const next = send(f);
    assert.equal(next.round, 'R2');
    assert.equal(next.repositories.prj.action, 'import');
});

test('source working-tree edits are never silently committed or selected instead of committed blobs', t => {
    const f = setup(t);
    f.register();
    write(f.source, 'briefs/first brief.md', 'Uncommitted source text\n');
    const source = tree(f.source);
    const plan = send(f);
    apply(f, plan);
    assert.deepEqual(tree(f.source), source);
    assert.equal(send(f).status, 'unchanged');
});

test('canonical plan identities are stable across object property order', () => {
    assert.equal(digest({ b: ['x'], a: { y: 1, x: 2 } }), digest({ a: { x: 2, y: 1 }, b: ['x'] }));
});

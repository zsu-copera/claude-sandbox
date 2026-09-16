'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Controller, validateConfig, validateCapturedHandoff, selection, digest, nextRound } = require('/opt/tasks/tasks.js');
const { main: inspectSource } = require('/opt/tasks/source.js');
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
        else if (operation === 'source') result = args.paths
            ? inspectSource(['source', args.ref, ...args.paths], args.source)
            : { ref: args.ref, head: git(args.source, 'rev-parse', args.ref) };
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
const sharedReadme = () => ({ repository: 'prj', path: 'README.md', role: 'shared', reason: 'Keep implementation context current' });
function handoff(f, changes = {}) {
    return { version: 1, briefs: Object.fromEntries(Object.entries(f.config.repositories).map(([repo, config]) => [repo, [...config.briefs]])),
        documents: [sharedReadme()], retire: [], decisions: [], ...changes };
}
function contextSend(f, value = handoff(f)) { return f.controller().send([], value); }
function readmeDecision(action = 'reconcile-in-sandbox', reason = 'Reconcile the reviewed changes in the sandbox') {
    return { repository: 'prj', path: 'README.md', action, reason };
}

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

test('context controller captured handoff requires fatal UTF-8, one JSON value and request equality without leaking bodies', () => {
    const expected = { path: 'README.md', reason: 'Reviewed context' };
    const bytes = Buffer.from(JSON.stringify(expected));
    assert.deepEqual(validateCapturedHandoff(expected, () => bytes), expected);
    assert.deepEqual(validateCapturedHandoff(expected, () => Buffer.concat([
        Buffer.from([0xef, 0xbb, 0xbf]), bytes,
    ])), expected, 'A UTF-8 BOM is accepted by normal TextDecoder handling');
    assert.deepEqual(validateCapturedHandoff(expected, () => Buffer.from(
        '{ "reason": "Reviewed context", "path": "README.md" }\n')), expected);
    const invalid = [
        Buffer.concat([Buffer.from('{"path":"README.md","reason":"'), Buffer.from([0xc3, 0x28]), Buffer.from('"}')]),
        Buffer.concat([bytes, Buffer.from([0])]),
        Buffer.concat([bytes, bytes]),
        Buffer.from('{"private-body-do-not-echo":'),
        Buffer.from(JSON.stringify({ ...expected, reason: 'Changed by request normalization' })),
        Buffer.alloc(1024 * 1024 + 1, 0x20),
    ];
    for (const value of invalid) {
        assert.throws(() => validateCapturedHandoff(expected, () => value),
            error => error.message === 'Invalid handoff JSON/encoding');
    }
    const malformed = invalid[0];
    const replacementDecoded = JSON.parse(malformed.toString('utf8'));
    assert.throws(() => validateCapturedHandoff(replacementDecoded, () => malformed),
        error => error.message === 'Invalid handoff JSON/encoding',
        'Replacement-decoded request equality must not bypass fatal decoding');
    const unreadable = Object.assign(new Error('Captured input is unreadable'), { code: 'EACCES' });
    assert.throws(() => validateCapturedHandoff(expected, () => { throw unreadable; }),
        error => error === unreadable, 'I/O errors must not be misclassified as JSON syntax failures');
});

test('context controller opt-in preserves closed config and refuses unresolved legacy sends or v2 brief bypasses', t => {
    const f = setup(t);
    f.register();
    const original = f.record();
    const legacy = send(f);
    const pending = tree(f.registry);
    assert.throws(() => contextSend(f), /pending legacy/);
    assert.deepEqual(tree(f.registry), pending);
    apply(f, legacy);
    assert.equal(f.record().version, 1);
    assert.equal(Object.hasOwn(f.controller().status(), 'context'), false);
    const plan = contextSend(f);
    assert.equal(plan.status, 'approval-required');
    assert.equal(f.record().version, 2);
    assert.deepEqual(f.record().config, original.config);
    assert.equal(f.record().configDigest, original.configDigest);
    assert.equal(f.record().lastContext, null);
    assert.equal(f.controller().status().context.status, 'not-applied');
    assert.throws(() => send(f), /explicit --handoff/);
    assert.throws(() => f.controller().send(['prj:README.md']), /explicit --handoff/);
    assert.throws(() => f.controller().send(['prj:README.md'], handoff(f)), /mutually exclusive/);
    apply(f, plan);
    assert.deepEqual(f.record().lastContext, { revision: 1, planId: plan.planId });
});

test('context controller refuses legacy partial opt-in without changing the recovery plan', t => {
    const f = setup(t);
    f.register();
    const plan = send(f);
    f.hook = (operation, args) => {
        if (operation === 'round' && args.mode === 'apply' && args.repository === 'Documentation') throw new Error('second import stopped');
    };
    assert.throws(() => apply(f, plan), /stopped/);
    const record = f.record();
    assert.throws(() => contextSend(f), /pending legacy/);
    assert.deepEqual(f.record(), record);
    f.hook = () => {};
    apply(f, plan);
});

test('context controller needs-decision is diagnostic without a plan, upgrade, or baseline mutation', t => {
    const f = setup(t);
    f.register();
    commit(f.source, 'README.md', 'A differing shared canonical input\n');
    const before = tree(f.registry);
    const workspace = tree(f.workspace);
    const diagnostic = contextSend(f);
    assert.equal(diagnostic.status, 'needs-decision');
    assert.equal(Object.hasOwn(diagnostic, 'planId'), false);
    assert.equal(diagnostic.approvalRequired, false);
    assert.equal(diagnostic.context.documents[0].drift.relationship, 'different');
    assert.equal(diagnostic.context.documents[0].drift.changesSinceApproval, 'unbaselined');
    assert.deepEqual(tree(f.registry), before);
    assert.deepEqual(tree(f.workspace), workspace);
    const plan = contextSend(f, handoff(f, { decisions: [readmeDecision()] }));
    assert.equal(plan.context.documents[0].action, 'reconcile-in-sandbox');
    assert.deepEqual(plan.context.decisions, [readmeDecision()]);
    apply(f, plan);
    assert.equal(fs.readFileSync(path.join(f.target, 'README.md'), 'utf8'), 'Canonical README remains unchanged.\n');
    commit(f.source, 'README.md', 'A second differing shared canonical input\n');
    const applied = tree(f.registry);
    assert.equal(contextSend(f, handoff(f, { documents: [] })).status, 'needs-decision');
    assert.deepEqual(tree(f.registry), applied);
});

test('context controller missing and unsupported required source inputs fail even for brief-only paths', t => {
    const f = setup(t);
    f.register();
    const before = tree(f.registry);
    assert.throws(() => contextSend(f, handoff(f, {
        briefs: { prj: ['absent.md'], Documentation: [] }, documents: [],
    })), /Required source input prj:absent.md is missing/);
    assert.throws(() => contextSend(f, handoff(f, { documents: [
        { repository: 'prj', path: 'absent-reference.md', role: 'reference', reason: 'Required supporting input' },
    ] })), /Required source input.*missing/);
    fs.symlinkSync('README.md', path.join(f.source, 'unsupported.md'));
    git(f.source, 'add', 'unsupported.md');
    git(f.source, 'commit', '--quiet', '-m', 'Unsupported input fixture');
    assert.throws(() => contextSend(f, handoff(f, {
        briefs: { prj: ['unsupported.md'], Documentation: [] }, documents: [],
    })), /Required source input.*unsupported/);
    assert.deepEqual(tree(f.registry), before);
    assert.equal(f.record().version, 1);
});

test('context controller missing canonical reference is valid but shared initialization requires guidance', t => {
    const f = setup(t);
    commit(f.source, 'reference.md', 'Committed reference that is absent canonically\n');
    f.register();
    const reference = { repository: 'prj', path: 'reference.md', role: 'reference', reason: 'Snapshot-only reference' };
    const plan = contextSend(f, handoff(f, { documents: [reference] }));
    assert.equal(plan.context.documents[0].target.state, 'missing');
    assert.equal(plan.context.documents[0].action, 'read-snapshot');
    apply(f, plan);
    assert.equal(fs.existsSync(path.join(f.target, 'reference.md')), false);
    const shared = handoff(f, { documents: [{ ...reference, role: 'shared' }] });
    assert.equal(contextSend(f, shared).status, 'needs-decision');
    shared.decisions = [{ repository: 'prj', path: 'reference.md', action: 'initialize-from-source', reason: 'Create canonical during implementation' }];
    const metadata = contextSend(f, shared);
    assert.equal(metadata.round, null);
    assert.equal(metadata.context.documents[0].action, 'initialize-from-source');
    apply(f, metadata);
    assert.equal(fs.existsSync(path.join(f.target, 'reference.md')), false, 'Approval must not execute canonical initialization');
});

test('context controller carries omitted shared README forward and maps reused inputs to their exact delivery', t => {
    const f = setup(t);
    f.register();
    const first = contextSend(f);
    apply(f, first);
    commit(f.docsSource, 'review.md', 'New review for the next round\n');
    const carried = handoff(f, { documents: [] });
    const second = contextSend(f, carried);
    assert.equal(second.round, 'R2');
    assert.equal(second.repositories.prj.action, 'preserve');
    const map = second.context.pathMap.find(item => item.repository === 'prj' && item.path === 'README.md');
    assert.equal(map.snapshotPath, 'sandbox-rounds/TASK-1/R1/files/README.md');
    assert.equal(map.deliveryPlanId, first.planId);
    assert.equal(map.canonicalPath, 'README.md');
    assert.equal(map.writeBack, 'sandbox');
    apply(f, second);
    commit(f.source, 'README.md', 'New external README that was omitted from the brief list\n');
    const diagnostic = contextSend(f, carried);
    assert.equal(diagnostic.status, 'needs-decision');
    assert.equal(diagnostic.context.documents[0].drift.changesSinceApproval, 'source-only');
    const third = contextSend(f, { ...carried, decisions: [readmeDecision()] });
    assert.ok(third.repositories.prj.changedBriefs.includes('README.md'));
    assert.ok(third.repositories.prj.inputs.some(item => item.path === 'README.md'));
    apply(f, third);
});

test('context controller path maps honor host deferral for new and reused shared snapshots', t => {
    const f = setup(t);
    f.register();
    const canonical = fs.readFileSync(path.join(f.target, 'README.md'), 'utf8');
    commit(f.source, 'README.md', 'Outside amendment awaiting host reconciliation\n');
    const value = handoff(f, { decisions: [readmeDecision('defer-to-host', 'Keep reconciliation with the outside author')] });
    const first = contextSend(f, value);
    const mapping = result => result.context.pathMap.find(item => item.repository === 'prj' && item.path === 'README.md');
    assert.equal(mapping(first).role, 'shared');
    assert.equal(mapping(first).writeBack, 'host');
    apply(f, first);
    assert.equal(fs.readFileSync(path.join(f.target, 'README.md'), 'utf8'), canonical);
    commit(f.docsSource, 'review.md', 'Another review with the same deferred input\n');
    const second = contextSend(f, value);
    assert.equal(second.repositories.prj.action, 'preserve');
    assert.equal(mapping(second).deliveryPlanId, first.planId);
    assert.equal(mapping(second).writeBack, 'host');
    apply(f, second);
    assert.equal(fs.readFileSync(path.join(f.target, 'README.md'), 'utf8'), canonical);
});

test('context controller role changes and retirements are metadata approvals, with exact retirement repeat only', t => {
    const f = setup(t);
    f.register();
    apply(f, contextSend(f));
    const role = handoff(f, { documents: [{ ...sharedReadme(), role: 'host-owned', reason: 'Host integrates canonical documentation' }] });
    const changed = contextSend(f, role);
    assert.equal(changed.round, null);
    assert.equal(changed.context.changes[0].kind, 'updated');
    assert.equal(changed.context.changes[0].before.role, 'shared');
    assert.equal(changed.context.changes[0].after.role, 'host-owned');
    apply(f, changed);
    assert.equal(contextSend(f, role).status, 'unchanged');
    const retirement = handoff(f, { documents: [], retire: [
        { repository: 'prj', path: 'README.md', reason: 'No longer part of retained task context' },
    ] });
    const retired = contextSend(f, retirement);
    assert.equal(retired.round, null);
    assert.equal(retired.context.changes[0].kind, 'retired');
    assert.equal(retired.context.pathMap.some(item => item.path === 'README.md'), false);
    const snapshots = tree(f.workspace);
    apply(f, retired);
    assert.deepEqual(tree(f.workspace), snapshots);
    assert.equal(contextSend(f, retirement).status, 'unchanged');
    assert.equal(f.record().lastContext.revision, 3);
    const unknown = structuredClone(retirement);
    unknown.retire[0].path = 'undeclared.md';
    assert.throws(() => contextSend(f, unknown), /existing declaration/);
    const changedReason = structuredClone(retirement);
    changedReason.retire[0].reason = 'Not the previously applied retirement request';
    assert.throws(() => contextSend(f, changedReason), /existing declaration/);
});

test('context controller decisions and committed packets stay pinned when sources advance after preparation', t => {
    const f = setup(t);
    f.register();
    commit(f.source, 'README.md', 'Approved reviewed README\n');
    const value = handoff(f, { decisions: [readmeDecision('retain-sandbox', 'Keep the sandbox canonical version')] });
    const plan = contextSend(f, value);
    const prepared = f.record();
    value.decisions[0].action = 'defer-to-host';
    commit(f.source, 'README.md', 'New source text after approval, not part of this send\n');
    apply(f, plan);
    const snapshot = fs.readFileSync(path.join(f.target, 'sandbox-rounds/TASK-1/R1/files/README.md'), 'utf8');
    assert.equal(snapshot, 'Approved reviewed README\n');
    assert.equal(f.controller().status().context.documents[0].decision.action, 'retain-sandbox');
    assert.equal(f.controller().status().context.documents[0].drift.changesSinceApproval, 'source-only');
    assert.equal(f.record().lastContext.planId, plan.planId);
    assert.equal(prepared.lastContext, null);
});

test('context controller unrelated commits and equivalent additive declarations do not create revisions or rounds', t => {
    const f = setup(t);
    f.register();
    apply(f, contextSend(f));
    const before = tree(f.registry);
    const workspace = tree(f.workspace);
    commit(f.source, 'unselected.md', 'Unrelated source commit\n');
    commit(f.docsSource, 'unselected.md', 'Another unrelated commit\n');
    assert.equal(contextSend(f).status, 'unchanged');
    assert.equal(contextSend(f, handoff(f, { documents: [] })).status, 'unchanged');
    assert.deepEqual(tree(f.registry), before);
    assert.deepEqual(tree(f.workspace), workspace);
    assert.equal(f.controller().status().context.status, 'unchanged');
});

for (const mode of ['legacy', 'context', 'context-metadata']) {
    test(`${mode} superseded plan reselection restores a usable approval without changing its contents`, t => {
        const f = setup(t);
        f.register();
        if (mode === 'context-metadata') apply(f, contextSend(f));
        const before = f.record();
        const workspace = tree(f.workspace);
        const source = tree(f.source);
        const choose = variant => mode === 'legacy'
            ? f.controller().send([variant === 'A' ? 'prj:briefs/first brief.md' : 'prj:briefs/second.txt'])
            : contextSend(f, handoff(f, { documents: [{
                ...sharedReadme(), reason: variant === 'A' ? 'Original selected context' : 'Alternative selected context',
            }] }));
        const first = choose('A');
        const packetFiles = tree(path.join(f.registry, 'plans', first.planId));
        const replacement = choose('B');
        assert.notEqual(first.planId, replacement.planId);
        assert.equal(f.record().plans[first.planId].status, 'superseded');
        const reselected = choose('A');
        const pending = f.record();
        assert.equal(reselected.planId, first.planId);
        assert.equal(reselected.round, first.round);
        assert.deepEqual(tree(path.join(f.registry, 'plans', first.planId)), packetFiles);
        assert.deepEqual(tree(f.workspace), workspace);
        assert.deepEqual(pending.executionHeads, before.executionHeads);
        assert.deepEqual(pending.collectionHeads, before.collectionHeads);
        assert.equal(pending.activePlan, first.planId);
        assert.equal(pending.plans[replacement.planId].status, 'superseded');
        const result = apply(f, reselected);
        assert.equal(result.status, 'applied');
        assert.deepEqual(pending.plans[first.planId], { status: 'pending', round: first.round, completed: {} });
        assert.equal(f.record().activePlan, null);
        assert.equal(f.record().plans[first.planId].status, 'completed');
        assert.throws(() => apply(f, replacement), /superseded|active approval/);
        assert.equal(apply(f, reselected).status, 'already-applied');
        assert.deepEqual(tree(f.source), source);
        if (mode === 'context-metadata') {
            assert.equal(first.round, null);
            assert.deepEqual(tree(f.workspace), workspace);
            assert.deepEqual(f.record().executionHeads, before.executionHeads);
            assert.deepEqual(f.record().collectionHeads, before.collectionHeads);
            assert.equal(f.record().lastRound, before.lastRound);
        } else {
            assert.equal(fs.existsSync(path.join(f.target, 'sandbox-rounds/TASK-1/R1/files/briefs/first brief.md')), true);
            assert.equal(fs.existsSync(path.join(f.target, 'sandbox-rounds/TASK-1/R1/files/briefs/second.txt')), false);
        }
    });
}

test('superseded plan activation never reopens protected progress or discards import receipts', t => {
    const f = setup(t);
    f.register();
    const first = send(f);
    const replacement = f.controller().send(['prj:briefs/second.txt']);
    const disk = tree(f.registry);
    for (const status of ['completed', 'partial', 'applying']) {
        const controller = f.controller();
        controller.load();
        controller.record.plans[first.planId].status = status;
        const before = structuredClone(controller.record);
        assert.throws(() => controller.activatePlan(first.planId, first.round), /not eligible/);
        assert.deepEqual(controller.record, before);
    }
    for (const status of ['pending', 'superseded']) {
        const controller = f.controller();
        controller.load();
        controller.record.plans[first.planId].status = status;
        controller.record.plans[first.planId].completed = { prj: { status: 'imported' } };
        const before = structuredClone(controller.record);
        assert.throws(() => controller.activatePlan(first.planId, first.round), /import receipts/);
        assert.deepEqual(controller.record, before);
    }
    for (const progress of [
        { status: 'partial', round: replacement.round, completed: {} },
        { status: 'pending', round: replacement.round, completed: { prj: { status: 'imported' } } },
    ]) {
        const controller = f.controller();
        controller.load();
        controller.record.plans[replacement.planId] = progress;
        const before = structuredClone(controller.record);
        assert.throws(() => controller.activatePlan(first.planId, first.round), /not eligible|import receipts/);
        assert.deepEqual(controller.record, before);
    }
    assert.deepEqual(tree(f.registry), disk);
});

test('superseded plan revalidation rejects damaged approvals before changing the active legacy plan', t => {
    const f = setup(t);
    f.register();
    const select = () => f.controller().send(['prj:briefs/first brief.md']);
    const first = select();
    const replacement = f.controller().send(['prj:briefs/second.txt']);
    const file = path.join(f.registry, 'plans', first.planId, 'plan.json');
    const changed = JSON.parse(fs.readFileSync(file));
    changed.task = 'CHANGED';
    fs.chmodSync(file, 0o600);
    fs.writeFileSync(file, JSON.stringify(changed));
    const record = f.record();
    const registry = tree(f.registry);
    const workspace = tree(f.workspace);
    assert.throws(select, /Plan bytes no longer match/);
    assert.deepEqual(f.record(), record);
    assert.equal(f.record().activePlan, replacement.planId);
    assert.deepEqual(tree(f.registry), registry);
    assert.deepEqual(tree(f.workspace), workspace);
});

test('context controller pending same-state plans repeat exactly and unapplied replacements preserve the applied baseline', t => {
    const f = setup(t);
    f.register();
    const first = contextSend(f);
    assert.equal(contextSend(f).planId, first.planId);
    const replacement = contextSend(f, handoff(f, { documents: [{ ...sharedReadme(), reason: 'Revised declaration before approval' }] }));
    assert.notEqual(replacement.planId, first.planId);
    assert.equal(replacement.round, first.round);
    assert.equal(f.record().plans[first.planId].status, 'superseded');
    assert.equal(f.record().lastContext, null);
    assert.throws(() => apply(f, first), /superseded/);
    apply(f, replacement);
    assert.equal(f.record().lastContext.revision, 1);
});

test('context controller metadata-only first opt-in can reuse a legacy delivery without a new round', t => {
    const f = setup(t);
    f.register();
    const legacy = f.controller().send(['prj:README.md', 'prj:briefs/first brief.md', 'Documentation:review.md']);
    apply(f, legacy);
    const before = f.record();
    const workspace = tree(f.workspace);
    const first = contextSend(f);
    assert.equal(first.round, null);
    assert.ok(first.context.pathMap.every(item => item.deliveryPlanId === legacy.planId));
    apply(f, first);
    assert.deepEqual(f.record().executionHeads, before.executionHeads);
    assert.deepEqual(f.record().collectionHeads, before.collectionHeads);
    assert.equal(f.record().lastRound, legacy.round);
    assert.deepEqual(tree(f.workspace), workspace);
});

test('context controller promotes a previously observed brief using its applied source and target baseline', t => {
    const f = setup(t);
    f.register();
    const briefs = { prj: ['README.md'], Documentation: ['review.md'] };
    apply(f, contextSend(f, handoff(f, { briefs, documents: [] })));
    commit(f.target, 'README.md', 'Canonical changed since its brief-only observation\n');
    const proposed = contextSend(f, handoff(f, { briefs }));
    assert.equal(proposed.status, 'needs-decision');
    assert.equal(proposed.context.documents[0].drift.changesSinceApproval, 'sandbox-only');
    assert.equal(f.record().lastContext.revision, 1);
});

test('context controller metadata approval remains bound to both target heads and the pinned image', t => {
    const f = setup(t);
    f.register();
    apply(f, contextSend(f));
    const metadata = contextSend(f, handoff(f, { documents: [{ ...sharedReadme(), role: 'host-owned' }] }));
    assert.equal(metadata.round, null);
    f.image = `sha256:${'b'.repeat(64)}`;
    assert.throws(() => apply(f, metadata), /image changed/);
    f.image = IMAGE;
    commit(f.documentation, 'later.md', 'Unapproved target context advance\n');
    assert.throws(() => apply(f, metadata), /unchanged context advanced/);
    assert.equal(f.record().lastContext.revision, 1);
});

test('context controller unchanged requests still verify retained snapshots, cleanliness and named source branches', t => {
    const f = setup(t);
    f.register();
    const plan = contextSend(f);
    apply(f, plan);
    write(f.target, 'README.md', 'Dirty canonical data\n');
    assert.throws(() => contextSend(f), /dirty/);
    git(f.target, 'checkout', '--', 'README.md');
    const sourceRef = f.config.repositories.prj.ref;
    git(f.source, 'update-ref', '-d', sourceRef);
    assert.throws(() => contextSend(f), /inspection failed/);
    git(f.source, 'update-ref', sourceRef, f.sourceHead);
    commit(f.target, 'sandbox-rounds/TASK-1/R1/files/README.md', 'Changed immutable delivered snapshot\n');
    assert.throws(() => contextSend(f), /Retained handoff integrity/);
    assert.equal(f.controller().status().status, 'blocked');
    assert.equal(f.controller().collect().status, 'collected');
});

test('context controller metadata-only approval preserves Git and execution bases but produces a new same-head collection', t => {
    const f = setup(t);
    f.register();
    apply(f, contextSend(f));
    const first = f.controller().collect();
    const workspace = tree(f.workspace);
    const before = f.record();
    const metadata = contextSend(f, handoff(f, { documents: [{ ...sharedReadme(), reason: 'Updated approval scope without content changes' }] }));
    assert.equal(metadata.round, null);
    assert.equal(metadata.repositories.prj.action, 'preserve');
    assert.equal(metadata.repositories.Documentation.action, 'preserve');
    assert.deepEqual(f.record().lastContext, before.lastContext);
    assert.throws(() => f.controller().collect(), /pending/);
    apply(f, metadata);
    const after = f.record();
    assert.equal(after.lastContext.revision, 2);
    assert.deepEqual(after.executionHeads, before.executionHeads);
    assert.deepEqual(after.collectionHeads, before.collectionHeads);
    assert.equal(after.lastRound, before.lastRound);
    assert.deepEqual(tree(f.workspace), workspace);
    const second = f.controller().collect();
    assert.equal(second.status, 'collected');
    assert.notEqual(second.collectionId, first.collectionId);
    assert.deepEqual(second.manifest.binding.heads, first.manifest.binding.heads);
    assert.deepEqual(second.manifest.binding.context, { revision: 2, planId: metadata.planId });
    const provenance = JSON.parse(fs.readFileSync(path.join(second.directory, 'provenance.json')));
    assert.equal(provenance.context.revision, 2);
    assert.equal(provenance.context.documents[0].declarationReason, 'Updated approval scope without content changes');
    assert.equal(f.controller().collect().status, 'unchanged');
});

test('context controller status is observational and committed canonical divergence stays collectable without source access', t => {
    const f = setup(t);
    f.register();
    const first = contextSend(f);
    apply(f, first);
    commit(f.target, 'README.md', 'Legitimate canonical write-back after approval\n');
    const record = f.record();
    const status = f.controller().status();
    assert.equal(status.status, 'ready');
    assert.deepEqual(status.inputIssues, []);
    assert.equal(status.context.status, 'changed');
    assert.equal(status.context.documents[0].drift.changesSinceApproval, 'sandbox-only');
    assert.equal(status.context.documents[0].status, 'needs-decision');
    assert.deepEqual(f.record(), record);
    assert.equal(apply(f, first).status, 'already-applied');
    f.hook = operation => { if (operation === 'source') throw new Error('Source unavailable for audit'); };
    const result = f.controller().collect();
    assert.equal(result.status, 'collected');
    const patch = fs.readFileSync(path.join(result.directory, 'prj', 'work.patch'), 'utf8');
    assert.match(patch, /Legitimate canonical write-back/);
    assert.deepEqual(f.record().lastContext, record.lastContext);
});

test('context controller running and dirty status never claim fresh canonical observations', t => {
    const f = setup(t);
    f.register();
    apply(f, contextSend(f));
    const record = f.record();
    write(f.target, 'README.md', 'Uncommitted canonical edit\n');
    let status = f.controller().status();
    assert.equal(status.status, 'blocked');
    assert.equal(status.context.status, 'unobserved');
    assert.equal(status.context.documents[0].target.state, 'unobserved');
    assert.equal(Object.hasOwn(status.context.documents[0].target, 'sha256'), false);
    git(f.target, 'checkout', '--', 'README.md');
    f.hook = (operation, args) => {
        if (operation === 'round' && args.mode === 'inspect' && args.repository === 'prj') {
            return { status: 'running', repository: 'prj', observedWorktree: false };
        }
    };
    status = f.controller().status();
    assert.equal(status.status, 'running');
    assert.equal(status.context.status, 'unobserved');
    assert.equal(status.context.documents[0].target.state, 'unobserved');
    assert.equal(Object.hasOwn(status.context.documents[0].target, 'commit'), false);
    assert.deepEqual(f.record(), record);
    assert.throws(() => contextSend(f), /running/);
});

test('context controller completed legacy and context replays never rewind newer approved context', t => {
    const f = setup(t);
    f.register();
    const legacy = send(f);
    apply(f, legacy);
    const first = contextSend(f);
    apply(f, first);
    const second = contextSend(f, handoff(f, { documents: [{ ...sharedReadme(), role: 'host-owned' }] }));
    apply(f, second);
    commit(f.target, 'README.md', 'Later canonical work is not immutable input corruption\n');
    const before = f.record();
    for (const plan of [legacy, first, second]) {
        const result = apply(f, plan);
        assert.equal(result.status, 'already-applied');
        assert.equal(result.context.revision, 2);
        assert.equal(result.context.observation, 'captured-approval');
    }
    assert.deepEqual(f.record(), before);
    const rolledBack = structuredClone(before);
    rolledBack.lastContext = { revision: 1, planId: first.planId };
    write(f.registry, 'record.json', JSON.stringify(rolledBack));
    for (const operation of [
        () => f.controller().status(),
        () => apply(f, first),
        () => f.controller().collect(),
        () => contextSend(f),
    ]) assert.throws(operation, /latest fully applied approved plan/);
    write(f.registry, 'record.json', JSON.stringify(before));
    assert.equal(apply(f, first).context.revision, 2);
});

for (const fault of ['second-repository', 'lost-receipt', 'journal-updating-refs']) {
    test(`context controller ${fault} recovery retains the exact approved two-repository context`, t => {
        const f = setup(t);
        f.register();
        const plan = contextSend(f);
        const original = fs.readFileSync(path.join(f.registry, 'plans', plan.planId, 'plan.json'));
        if (fault === 'second-repository') f.hook = (operation, args) => {
            if (operation === 'round' && args.mode === 'apply' && args.repository === 'Documentation') throw new Error('context import stopped');
        };
        else if (fault === 'lost-receipt') f.after = (operation, args) => {
            if (operation === 'round' && args.mode === 'apply') throw new Error('context receipt lost');
        };
        else f.fault = fault;
        assert.throws(() => apply(f, plan), /stopped|lost|interrupted/);
        assert.equal(f.record().lastContext, null);
        assert.equal(f.record().lastRound, null);
        assert.throws(() => contextSend(f), /partial|recovery/);
        assert.throws(() => f.controller().collect(), /pending/);
        commit(f.source, 'README.md', 'Source advanced during interrupted delivery\n');
        f.hook = () => {};
        f.after = () => {};
        f.fault = null;
        apply(f, plan);
        assert.deepEqual(fs.readFileSync(path.join(f.registry, 'plans', plan.planId, 'plan.json')), original);
        assert.deepEqual(f.record().lastContext, { revision: 1, planId: plan.planId });
        assert.equal(git(f.target, 'rev-list', '--count', 'HEAD'), '2');
        assert.equal(git(f.documentation, 'rev-list', '--count', 'HEAD'), '2');
        assert.equal(f.controller().status().context.documents[0].drift.changesSinceApproval, 'source-only');
    });
}

test('context controller partial later delivery does not advance the independent applied observation baseline', t => {
    const f = setup(t);
    f.register();
    const first = contextSend(f);
    apply(f, first);
    commit(f.source, 'README.md', 'Second approved README source\n');
    commit(f.docsSource, 'review.md', 'Second approved external review\n');
    const second = contextSend(f, handoff(f, { documents: [], decisions: [readmeDecision()] }));
    f.hook = (operation, args) => {
        if (operation === 'round' && args.mode === 'apply' && args.repository === 'Documentation') throw new Error('partial context update');
    };
    assert.throws(() => apply(f, second), /partial context update/);
    assert.deepEqual(f.record().lastContext, { revision: 1, planId: first.planId });
    const status = f.controller().status();
    assert.equal(status.context.revision, 1);
    assert.equal(status.context.documents[0].drift.changesSinceApproval, 'source-only');
    f.hook = () => {};
    apply(f, second);
    assert.deepEqual(f.record().lastContext, { revision: 2, planId: second.planId });
    assert.equal(f.controller().status().context.documents[0].drift.changesSinceApproval, 'none');
});

for (const side of ['source', 'target']) for (const mutation of ['missing', 'duplicate', 'foreign', 'wrong-commit', 'unobserved-clean']) {
    test(`context controller rejects ${side} ${mutation} observation inventories without publishing state`, t => {
        const f = setup(t);
        f.register();
        const before = tree(f.registry);
        f.after = (operation, args, result) => {
            const selected = side === 'source' ? operation === 'source' && args.source === f.source
                : operation === 'round' && args.mode === 'inspect' && args.repository === 'prj';
            if (!selected || !args.paths) return;
            if (mutation === 'missing') result.documents.pop();
            else if (mutation === 'duplicate') result.documents[1] = structuredClone(result.documents[0]);
            else if (mutation === 'foreign') result.documents[0].path = 'foreign.md';
            else if (mutation === 'wrong-commit') result.documents[0].observation.commit = 'f'.repeat(40);
            else result.documents[0].observation = { state: 'unobserved', reason: 'Unobserved source input' };
        };
        assert.throws(() => contextSend(f), /inventory|paths|HEAD\/state/);
        assert.deepEqual(tree(f.registry), before);
    });
}

test('context controller source and target inspection errors propagate rather than becoming missing observations', t => {
    const f = setup(t);
    f.register();
    const before = tree(f.registry);
    for (const failing of ['source', 'round']) {
        f.hook = (operation, args) => {
            if (operation === failing && args.paths) throw new Error('Document read I/O failure');
        };
        assert.throws(() => contextSend(f), /I\/O failure/);
        assert.deepEqual(tree(f.registry), before);
    }
});

test('context controller changed decisions, context pointers, unknown versions and provenance fail closed', t => {
    const f = setup(t);
    f.register();
    commit(f.source, 'README.md', 'Divergent reviewed input\n');
    const plan = contextSend(f, handoff(f, { decisions: [readmeDecision()] }));
    const file = path.join(f.registry, 'plans', plan.planId, 'plan.json');
    fs.chmodSync(file, 0o600);
    const original = fs.readFileSync(file);
    for (const mutate of [
        value => { value.context.handoff.decisions[0].action = 'retain-sandbox'; },
        value => { value.context.pathMap[0].snapshotPath = 'sandbox-rounds/OTHER/R99/files/review.md'; },
        value => { value.version = 99; },
    ]) {
        const altered = JSON.parse(original);
        mutate(altered);
        fs.writeFileSync(file, JSON.stringify(altered));
        assert.throws(() => apply(f, plan), /approved plan ID/);
        fs.writeFileSync(file, original);
    }
    apply(f, plan);
    const recordFile = path.join(f.registry, 'record.json');
    const record = fs.readFileSync(recordFile);
    for (const mutate of [
        value => { value.lastContext = null; },
        value => { value.lastContext.revision = 7; },
        value => { value.lastContext.documents = []; },
        value => { value.version = 99; },
        value => { value.plans[plan.planId].completed = {}; },
    ]) {
        const altered = JSON.parse(record);
        mutate(altered);
        fs.writeFileSync(recordFile, JSON.stringify(altered));
        assert.throws(() => f.controller().status());
        fs.writeFileSync(recordFile, record);
    }
    const collected = f.controller().collect();
    const provenance = path.join(collected.directory, 'provenance.json');
    fs.appendFileSync(provenance, '\n');
    assert.throws(() => f.controller().collect(), /checksum mismatch/);
});

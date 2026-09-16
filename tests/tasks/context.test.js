'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { MAX_HANDOFF_BYTES, createContextContract, validateObservation, classifyDrift } = require('/opt/tasks/context.js');
const { MAX_DOCUMENT, MAX_DOCUMENTS } = require('/opt/rounds.js');

const repositories = ['application', 'handbook'];
const context = createContextContract(repositories);
const commit = 'a'.repeat(40);
const missing = () => ({ state: 'missing', commit });
const unobserved = () => ({ state: 'unobserved', reason: 'Workspace is running' });
const unsupported = () => ({ state: 'unsupported', commit, reason: 'Committed path is a symlink' });
function file(character = 'b', overrides = {}) {
    return { state: 'present', commit, blob: character.repeat(40), mode: '100644',
        bytes: 10, sha256: character.repeat(64), ...overrides };
}
function document(path = 'README.md', role = 'shared', repository = 'handbook') {
    return { repository, path, role, reason: 'Required by this task' };
}
function decision(action = 'reconcile-in-sandbox', path = 'README.md') {
    return { repository: 'handbook', path, action, reason: 'Preserve both sides of the review' };
}
function handoff(overrides = {}) {
    return { version: 1, briefs: { application: [], handbook: ['round.md'] },
        documents: [], retire: [], decisions: [], ...overrides };
}
function freeze(value) {
    if (value && typeof value === 'object') {
        Object.values(value).forEach(freeze);
        Object.freeze(value);
    }
    return value;
}

test('context contract supports caller-supplied single and multiple repository layouts', () => {
    for (const names of [['monorepo'], ['backend', 'frontend', 'specifications'], ['prj', 'Documentation']]) {
        const contract = createContextContract(names);
        const briefs = Object.fromEntries(names.map((name, index) => [name, index ? [] : ['task.md']]));
        const result = contract.resolveHandoff(handoff({ briefs }));
        assert.deepEqual(Object.keys(result.selection).sort(), [...names].sort());
        assert.deepEqual(result.selection[names[0]], ['task.md']);
    }
    const names = ['service', 'guide'];
    const contract = createContextContract(names);
    names.push('later');
    assert.deepEqual(contract.repositories, ['guide', 'service']);
    assert.ok(Object.isFrozen(contract.repositories));
});

test('context contract rejects ambiguous repository identifiers and mismatched maps', () => {
    for (const names of [[], 'application', ['a', 'A'], ['a', 'a'], ['../repo'], ['a:b'], [null]]) {
        assert.throws(() => createContextContract(names));
    }
    assert.throws(() => context.validateHandoff(handoff({ briefs: { application: ['a.md'] } })));
    assert.throws(() => context.validateHandoff(handoff({ briefs: { application: [], handbook: [], extra: ['a.md'] } })));
    assert.throws(() => context.validateHandoff(handoff({ documents: [document('README.md', 'shared', 'other')] })));
});

test('context handoff schema is closed and bounded without mutating its input', () => {
    const input = freeze(handoff({ briefs: { handbook: ['z.md', 'a.md'], application: [] },
        documents: [document('z.txt', 'reference'), document('a.txt', 'host-owned')] }));
    const result = context.validateHandoff(input);
    assert.deepEqual(result.briefs.handbook, ['a.md', 'z.md']);
    assert.deepEqual(result.documents.map(item => item.path), ['a.txt', 'z.txt']);
    assert.deepEqual(input.briefs.handbook, ['z.md', 'a.md']);
    const mutations = [
        value => { value.extra = true; },
        value => { delete value.retire; },
        value => { value.version = '1'; },
        value => { value.version = 2; },
        value => { value.documents = {}; },
        value => { value.retire = null; },
        value => { value.decisions = 'all'; },
        value => { value.briefs.handbook = []; },
        value => { value.documents = [{ ...document(), extra: true }]; },
        value => { value.documents = [document('README.md', 'unrestricted')]; },
        value => { value.documents = [{ ...document(), reason: ' ' }]; },
        value => { value.documents = [{ ...document(), reason: 'a\nb' }]; },
        value => { value.documents = [{ ...document(), reason: 'a'.repeat(1025) }]; },
        value => { value.retire = [{ repository: 'handbook', path: 'a.md' }]; },
        value => { value.decisions = [decision('overwrite')]; },
        value => { value.decisions = [{ ...decision(), approved: true }]; },
    ];
    for (const mutate of mutations) {
        const value = handoff();
        mutate(value);
        assert.throws(() => context.validateHandoff(value));
    }
});

test('context paths reuse the document transport restrictions in every selection surface', () => {
    for (const path of ['../a.md', '/a.md', 'a\\b.md', '.git/a.md', '.secrets/a.txt',
        '.ssh/a.md', 'a:b.md', 'a\nb.md', 'probe.mjs', 'a.md/../b.md', 'a'.repeat(513) + '.md']) {
        for (const field of ['briefs', 'documents', 'retire', 'decisions']) {
            const value = handoff();
            if (field === 'briefs') value.briefs.handbook = [path];
            else if (field === 'documents') value.documents = [document(path)];
            else if (field === 'retire') value.retire = [{ repository: 'handbook', path, reason: 'No longer needed' }];
            else value.decisions = [decision('defer-to-host', path)];
            assert.throws(() => context.validateHandoff(value), `${field}: ${JSON.stringify(path)}`);
        }
    }
});

test('context rejects duplicate and case-colliding paths while allowing distinct repositories', () => {
    for (const other of ['README.md', 'readme.md']) {
        assert.throws(() => context.validateHandoff(handoff({ documents: [document(), document(other)] })));
        assert.throws(() => context.validateHandoff(handoff({ decisions: [decision(), decision('defer-to-host', other)] })));
        assert.throws(() => context.validateHandoff(handoff({ retire: [
            { repository: 'handbook', path: 'README.md', reason: 'Retire' },
            { repository: 'handbook', path: other, reason: 'Retire' },
        ] })));
        assert.throws(() => context.validateHandoff(handoff({ briefs: { application: [], handbook: ['README.md', other] } })));
    }
    const result = context.resolveHandoff(handoff({ documents: [document(), document('README.md', 'shared', 'application')] }));
    assert.equal(result.documents.length, 2);
    assert.throws(() => context.resolveHandoff(handoff({ briefs: { application: [], handbook: ['readme.md'] } }), [document()]));
});

test('context effective inputs share the existing per-repository count limit', () => {
    const documents = Array.from({ length: MAX_DOCUMENTS }, (_, index) => document(`note-${index}.md`, 'reference'));
    assert.throws(() => context.resolveHandoff(handoff(), documents), /Too many effective inputs/);
    const result = context.resolveHandoff(handoff({ briefs: { application: [], handbook: ['note-0.md'] } }), documents);
    assert.equal(result.selection.handbook.length, MAX_DOCUMENTS, 'The same exact input can be both a brief and a declared document.');
    assert.throws(() => context.validateHandoff(handoff({ documents: [...documents, document('extra.md')] })), /Too many/);
    const retirement = { repository: 'handbook', path: 'note-0.md', reason: 'Retire this input' };
    assert.equal(context.resolveHandoff(handoff({ retire: [retirement] }), documents).selection.handbook.length, MAX_DOCUMENTS);
});

test('context handoff size is bounded independently of individual reasons and path counts', () => {
    const names = Array.from({ length: 20 }, (_, index) => `repo-${index}`);
    const contract = createContextContract(names);
    const value = handoff({
        briefs: Object.fromEntries(names.map((name, index) => [name, index ? [] : ['round.md']])),
        documents: names.flatMap(repository => Array.from({ length: 127 }, (_, index) => ({
            repository, path: `note-${index}.md`, role: 'reference', reason: 'a'.repeat(512),
        }))),
    });
    assert.ok(Buffer.byteLength(JSON.stringify(value)) > MAX_HANDOFF_BYTES);
    assert.throws(() => contract.validateHandoff(value), /size limit/);
});

test('context declarations carry forward even when the next handoff omits the README', () => {
    const previous = freeze([document(), document('probe.md', 'reference'), document('host.md', 'host-owned')]);
    const value = freeze(handoff({ briefs: { application: [], handbook: ['next-round.md'] } }));
    const result = context.resolveHandoff(value, previous);
    assert.deepEqual(result.selection.handbook, ['README.md', 'host.md', 'next-round.md', 'probe.md']);
    assert.deepEqual(result.changes, []);
    assert.equal(result.documents.length, 3);
    assert.deepEqual(result.handoff.decisions, [], 'Previous decisions are not declaration defaults.');
});

test('context retirement and role changes remain explicit and do not mutate prior declarations', () => {
    const previous = freeze([document(), document('probe.md', 'reference')]);
    const result = context.resolveHandoff(handoff({
        documents: [{ ...document('README.md', 'host-owned'), reason: 'Outside auditor owns the narrative' }],
        retire: [{ repository: 'handbook', path: 'probe.md', reason: 'Measurement is complete' }],
    }), previous);
    assert.deepEqual(result.selection.handbook, ['README.md', 'round.md']);
    assert.deepEqual(result.changes.map(item => item.kind), ['updated', 'retired']);
    assert.equal(result.changes[0].before.role, 'shared');
    assert.equal(result.changes[0].after.role, 'host-owned');
    assert.equal(result.changes[1].after, null);
    assert.equal(previous[0].role, 'shared');
    assert.equal(previous.length, 2);
    assert.throws(() => context.resolveHandoff(handoff({ retire: [
        { repository: 'handbook', path: 'unknown.md', reason: 'Retire' },
    ] }), previous), /existing declaration/);
    assert.throws(() => context.resolveHandoff(handoff({ documents: [document('readme.md')] }), previous), /Case-only/);
});

test('context does not allow contradictory retirement or decisions for undeclared documents', () => {
    const retire = [{ repository: 'handbook', path: 'README.md', reason: 'Retire' }];
    assert.throws(() => context.validateHandoff(handoff({ documents: [document()], retire })), /declare and retire/);
    assert.throws(() => context.validateHandoff(handoff({ decisions: [decision()], retire })), /retired/);
    assert.throws(() => context.resolveHandoff(handoff({ decisions: [decision()] })), /active shared/);
    assert.throws(() => context.resolveHandoff(handoff({ decisions: [decision()] }), [document('README.md', 'host-owned')]), /active shared/);
    assert.throws(() => context.resolveHandoff(handoff({ decisions: [decision('defer-to-host', 'readme.md')] }), [document()]), /exactly/);
    assert.equal(context.resolveHandoff(handoff({ decisions: [decision()] }), [document()]).handoff.decisions.length, 1);
});

test('context normalization is deterministic across declaration and repository ordering', () => {
    const first = handoff({ documents: [document('z.md'), document('a.md')] });
    const second = handoff({ documents: [...first.documents].reverse(), briefs: { handbook: ['round.md'], application: [] } });
    assert.deepEqual(context.resolveHandoff(first), createContextContract([...repositories].reverse()).resolveHandoff(second));
});

test('context metadata-only declaration updates remain visible without changing selected paths', () => {
    const previous = [document()];
    const before = context.resolveHandoff(handoff(), previous);
    const after = context.resolveHandoff(handoff({ documents: [
        { ...document(), reason: 'Preserve the latest outside audit corrections' },
    ] }), previous);
    assert.deepEqual(after.selection, before.selection);
    assert.equal(after.changes.length, 1);
    assert.equal(after.changes[0].kind, 'updated');
    assert.equal(after.changes[0].before.role, after.changes[0].after.role);
    assert.notEqual(after.changes[0].before.reason, after.changes[0].after.reason);
});

test('context observations reject malformed, stale and unsupported success-shaped values', () => {
    assert.deepEqual(validateObservation(freeze(file())), file());
    for (const value of [
        null, {}, { ...file(), extra: true }, file('b', { commit: 'abc' }),
        file('b', { blob: 'b'.repeat(64) }), file('b', { sha256: 'B'.repeat(64) }),
        file('b', { bytes: -1 }), file('b', { bytes: 1.5 }), file('b', { bytes: MAX_DOCUMENT + 1 }),
        file('b', { mode: '100755' }), file('b', { mode: '120000' }),
        { state: 'missing' }, { ...missing(), sha256: 'a'.repeat(64) },
        { ...unobserved(), commit }, { state: 'unsupported', commit, reason: '' },
        { state: 'failed', reason: 'Not found' },
    ]) assert.throws(() => validateObservation(value));
    assert.deepEqual(validateObservation(missing()), missing());
    assert.deepEqual(validateObservation(unsupported()), unsupported());
    assert.deepEqual(validateObservation(unobserved()), unobserved());
});

test('context first observations establish equality but never infer which side changed', () => {
    assert.deepEqual(classifyDrift(file(), file()), {
        relationship: 'aligned', changesSinceApproval: 'unbaselined', sourceChanged: null, targetChanged: null,
    });
    assert.deepEqual(classifyDrift(file(), file('c')), {
        relationship: 'different', changesSinceApproval: 'unbaselined', sourceChanged: null, targetChanged: null,
    });
});

for (const [sourceCharacter, targetCharacter, expected] of [
    ['b', 'b', 'none'], ['c', 'b', 'source-only'], ['b', 'c', 'sandbox-only'], ['c', 'd', 'both'],
]) {
    test(`context drift distinguishes ${expected} changes against separate observations`, () => {
        const baseline = freeze({ source: file(), target: file() });
        const result = classifyDrift(file(sourceCharacter), file(targetCharacter), baseline);
        assert.equal(result.changesSinceApproval, expected);
        assert.equal(result.sourceChanged, sourceCharacter !== 'b');
        assert.equal(result.targetChanged, targetCharacter !== 'b');
    });
}

test('context unchanged divergence stays different and converged changes can be aligned', () => {
    const source = file();
    const target = file('c');
    assert.equal(classifyDrift(source, target, { source, target }).relationship, 'different');
    assert.equal(classifyDrift(source, target, { source, target }).changesSinceApproval, 'none');
    const converged = classifyDrift(file('d'), file('d'), { source, target });
    assert.equal(converged.relationship, 'aligned');
    assert.equal(converged.changesSinceApproval, 'both');
});

test('context content equality does not mistake new commits or Git hash formats for drift', () => {
    const otherFormat = file('c', { commit: 'e'.repeat(64), blob: 'f'.repeat(64), sha256: file().sha256 });
    const result = classifyDrift(otherFormat, file('d', { sha256: file().sha256 }), { source: file(), target: file() });
    assert.equal(result.relationship, 'aligned');
    assert.equal(result.changesSinceApproval, 'none');
    assert.equal(classifyDrift(file(), file('b', { bytes: 11 })).relationship, 'different');
});

test('context absence and unobservable states are not silently treated as equal content', () => {
    assert.equal(classifyDrift(missing(), file()).relationship, 'missing-source');
    assert.equal(classifyDrift(file(), missing()).relationship, 'missing-target');
    assert.equal(classifyDrift(missing(), missing()).relationship, 'missing-both');
    assert.equal(classifyDrift(file(), missing(), { source: file(), target: file() }).changesSinceApproval, 'sandbox-only');
    assert.equal(classifyDrift(missing(), file(), { source: file(), target: file() }).changesSinceApproval, 'source-only');
    const current = classifyDrift(file(), unobserved(), { source: file(), target: file() });
    assert.equal(current.relationship, 'unobserved');
    assert.equal(current.changesSinceApproval, 'unobserved');
    assert.equal(current.sourceChanged, false);
    assert.equal(current.targetChanged, null);
    assert.equal(classifyDrift(unsupported(), file()).relationship, 'unsupported');
    assert.throws(() => classifyDrift(file(), file(), { source: file(), target: unobserved() }), /actual document observations/);
    assert.throws(() => classifyDrift(file(), file(), { source: unsupported(), target: file() }), /actual document observations/);
});

test('context references and host-owned inputs can use snapshots without canonical copies', () => {
    for (const role of ['reference', 'host-owned']) {
        for (const target of [missing(), file('c')]) {
            const result = context.assessDocument(document('README.md', role), file(), target);
            assert.equal(result.status, 'ready');
            assert.equal(result.action, 'read-snapshot');
        }
        assert.throws(() => context.assessDocument(document('README.md', role), file(), file('c'), null, decision()), /shared document/);
    }
});

test('context shared documents require decisions for divergence and initialization', () => {
    assert.equal(context.assessDocument(document(), file(), file()).action, 'edit-canonical');
    for (const target of [file('c'), missing()]) {
        assert.equal(context.assessDocument(document(), file(), target).status, 'needs-decision');
    }
    for (const action of ['reconcile-in-sandbox', 'retain-sandbox', 'defer-to-host']) {
        const result = context.assessDocument(document(), file(), file('c'), null, decision(action));
        assert.equal(result.status, 'ready');
        assert.equal(result.action, action);
        assert.equal(result.reason, decision(action).reason);
    }
    for (const action of ['initialize-from-source', 'defer-to-host']) {
        assert.equal(context.assessDocument(document(), file(), missing(), null, decision(action)).status, 'ready');
    }
});

test('context rejects stale or inapplicable decisions instead of applying them to new facts', () => {
    assert.throws(() => context.assessDocument(document(), file(), file(), null, decision()), /aligned/);
    assert.throws(() => context.assessDocument(document(), file(), file('c'), null, decision('initialize-from-source')), /existing canonical/);
    for (const action of ['retain-sandbox', 'reconcile-in-sandbox']) {
        assert.throws(() => context.assessDocument(document(), file(), missing(), null, decision(action)), /absent canonical/);
    }
    assert.throws(() => context.assessDocument(document(), file(), file('c'), null, decision('defer-to-host', 'other.md')), /exactly/);
    assert.throws(() => context.assessDocument(document(), file(), file('c'), null, decision('force-copy')), /Unknown/);
});

test('context prior divergence still requires a fresh per-handoff decision', () => {
    const source = file();
    const target = file('c');
    const result = context.assessDocument(document(), source, target, { source, target });
    assert.equal(result.drift.changesSinceApproval, 'none');
    assert.equal(result.drift.relationship, 'different');
    assert.equal(result.status, 'needs-decision');
    assert.equal(result.action, null);
});

test('context decisions cannot waive missing sources, unsupported paths or unobserved worktrees', () => {
    for (const [source, target] of [
        [missing(), file()], [missing(), missing()], [unsupported(), file()],
        [file(), unsupported()], [file(), unobserved()], [unobserved(), file()],
    ]) {
        const result = context.assessDocument(document(), source, target, null, decision('defer-to-host'));
        assert.equal(result.status, 'blocked');
        assert.equal(result.action, null);
        assert.ok(result.reason);
    }
});

test('context assessments never advance or mutate the supplied baseline or decisions', () => {
    const source = freeze(file('c'));
    const target = freeze(file('d'));
    const baseline = freeze({ source: file(), target: file() });
    const approvedHandling = freeze(decision());
    const first = context.assessDocument(freeze(document()), source, target, baseline, approvedHandling);
    const second = context.assessDocument(document(), source, target, baseline, approvedHandling);
    assert.deepEqual(first, second);
    assert.equal(first.drift.changesSinceApproval, 'both');
    assert.equal(baseline.source.sha256, file().sha256);
    assert.equal(approvedHandling.action, 'reconcile-in-sandbox');
});

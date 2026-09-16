'use strict';

const { documentPath, MAX_DOCUMENT, MAX_DOCUMENTS } = require('/opt/rounds.js');

const MAX_HANDOFF_BYTES = 1024 * 1024;
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const OID = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const HASH = /^[0-9a-f]{64}$/;
const ROLES = new Set(['reference', 'shared', 'host-owned']);
const ACTIONS = new Set(['reconcile-in-sandbox', 'retain-sandbox', 'defer-to-host', 'initialize-from-source']);
const assert = (condition, message) => { if (!condition) throw new Error(`Context: ${message}`); };
const compare = (left, right) => left < right ? -1 : left > right ? 1 : 0;
const identity = entry => `${entry.repository}\0${entry.path.toLowerCase()}`;
const entryOrder = (left, right) => compare(left.repository, right.repository) || compare(left.path, right.path);

function keys(value, expected, label) {
    assert(value && typeof value === 'object' && !Array.isArray(value)
        && Object.keys(value).length === expected.length
        && expected.every(key => Object.hasOwn(value, key)), `Unexpected ${label} fields`);
}

function reason(value) {
    assert(typeof value === 'string' && value.trim().length > 0 && value.length <= 1024
        && !/[\x00-\x1f\x7f]/.test(value), 'A reason must be nonblank, single-line text of at most 1024 characters');
    return value;
}

function validateObservation(value) {
    assert(value && typeof value === 'object', 'Invalid document observation');
    if (value.state === 'present') {
        keys(value, ['state', 'commit', 'blob', 'mode', 'bytes', 'sha256'], 'present observation');
        assert(typeof value.commit === 'string' && OID.test(value.commit)
            && typeof value.blob === 'string' && OID.test(value.blob)
            && value.commit.length === value.blob.length, 'Invalid observation commit/blob identity');
        assert(value.mode === '100644' && Number.isSafeInteger(value.bytes)
            && value.bytes >= 0 && value.bytes <= MAX_DOCUMENT
            && typeof value.sha256 === 'string' && HASH.test(value.sha256),
        'Present observations require a bounded regular document and content hash');
        return { state: value.state, commit: value.commit, blob: value.blob,
            mode: value.mode, bytes: value.bytes, sha256: value.sha256 };
    }
    if (value.state === 'missing') {
        keys(value, ['state', 'commit'], 'missing observation');
        assert(typeof value.commit === 'string' && OID.test(value.commit), 'Missing observations require an observed commit');
        return { state: value.state, commit: value.commit };
    }
    if (value.state === 'unsupported') {
        keys(value, ['state', 'commit', 'reason'], 'unsupported observation');
        assert(typeof value.commit === 'string' && OID.test(value.commit), 'Unsupported observations require an observed commit');
        return { state: value.state, commit: value.commit, reason: reason(value.reason) };
    }
    assert(value.state === 'unobserved', 'Unknown document observation state');
    keys(value, ['state', 'reason'], 'unobserved observation');
    return { state: value.state, reason: reason(value.reason) };
}

const observed = value => value.state === 'present' || value.state === 'missing';

function sameContent(left, right) {
    // Commits and Git-format-specific blob IDs are provenance, not content equality.
    return left.state === right.state && (left.state === 'missing'
        || left.mode === right.mode && left.bytes === right.bytes && left.sha256 === right.sha256);
}

function classifyDrift(sourceValue, targetValue, baseline = null) {
    const source = validateObservation(sourceValue);
    const target = validateObservation(targetValue);
    let sourceChanged = null;
    let targetChanged = null;
    if (baseline !== null) {
        keys(baseline, ['source', 'target'], 'observation baseline');
        const previousSource = validateObservation(baseline.source);
        const previousTarget = validateObservation(baseline.target);
        assert(observed(previousSource) && observed(previousTarget), 'A baseline must contain actual document observations');
        if (observed(source)) sourceChanged = !sameContent(source, previousSource);
        if (observed(target)) targetChanged = !sameContent(target, previousTarget);
    }
    let relationship;
    if (source.state === 'unobserved' || target.state === 'unobserved') relationship = 'unobserved';
    else if (source.state === 'unsupported' || target.state === 'unsupported') relationship = 'unsupported';
    else if (source.state === 'missing') relationship = target.state === 'missing' ? 'missing-both' : 'missing-source';
    else if (target.state === 'missing') relationship = 'missing-target';
    else relationship = sameContent(source, target) ? 'aligned' : 'different';

    let changesSinceApproval;
    if (baseline === null) changesSinceApproval = 'unbaselined';
    else if (sourceChanged === null || targetChanged === null) changesSinceApproval = 'unobserved';
    else if (sourceChanged && targetChanged) changesSinceApproval = 'both';
    else if (sourceChanged) changesSinceApproval = 'source-only';
    else if (targetChanged) changesSinceApproval = 'sandbox-only';
    else changesSinceApproval = 'none';
    return { relationship, changesSinceApproval, sourceChanged, targetChanged };
}

function createContextContract(repositories) {
    assert(Array.isArray(repositories) && repositories.length > 0
        && repositories.every(name => typeof name === 'string' && ID.test(name)),
    'Supply nonempty conservative repository identifiers');
    assert(new Set(repositories.map(name => name.toLowerCase())).size === repositories.length,
        'Repository identifiers must not duplicate or case-collide');
    const names = [...repositories].sort(compare);
    const allowed = new Set(names);

    function entry(value, kind) {
        const extra = kind === 'document' ? ['role', 'reason'] : kind === 'decision' ? ['action', 'reason'] : ['reason'];
        keys(value, ['repository', 'path', ...extra], kind);
        assert(allowed.has(value.repository), `Unknown repository in ${kind}`);
        const result = { repository: value.repository, path: documentPath(value.path) };
        if (kind === 'document') {
            assert(ROLES.has(value.role), 'Unknown document role');
            result.role = value.role;
        } else if (kind === 'decision') {
            assert(ACTIONS.has(value.action), 'Unknown document decision action');
            result.action = value.action;
        }
        result.reason = reason(value.reason);
        return result;
    }

    function entries(value, kind) {
        assert(Array.isArray(value) && value.length <= names.length * MAX_DOCUMENTS, `Invalid ${kind} list`);
        const result = value.map(item => entry(item, kind));
        const seen = new Set();
        const counts = new Map();
        for (const item of result) {
            assert(!seen.has(identity(item)), `Duplicate or case-colliding ${kind} paths`);
            seen.add(identity(item));
            const count = (counts.get(item.repository) || 0) + 1;
            assert(count <= MAX_DOCUMENTS, `Too many ${kind} paths for ${item.repository}`);
            counts.set(item.repository, count);
        }
        return result.sort(entryOrder);
    }

    function selection(briefs, documents) {
        const paths = new Map(names.map(name => [name, new Map()]));
        function add(repository, selected) {
            const byName = paths.get(repository);
            const key = selected.toLowerCase();
            assert(!byName.has(key) || byName.get(key) === selected, 'Case-colliding effective input paths');
            byName.set(key, selected);
            assert(byName.size <= MAX_DOCUMENTS, `Too many effective inputs for ${repository}`);
        }
        for (const name of names) for (const selected of briefs[name]) add(name, selected);
        for (const document of documents) add(document.repository, document.path);
        return Object.fromEntries(names.map(name => [name, [...paths.get(name).values()].sort(compare)]));
    }

    function validateHandoff(value) {
        keys(value, ['version', 'briefs', 'documents', 'retire', 'decisions'], 'handoff');
        assert(value.version === 1, 'Unsupported handoff version');
        keys(value.briefs, names, 'brief repositories');
        const briefs = Object.fromEntries(names.map(name => {
            const selected = value.briefs[name];
            assert(Array.isArray(selected) && selected.length <= MAX_DOCUMENTS, `Invalid briefs for ${name}`);
            const result = selected.map(documentPath).sort(compare);
            assert(new Set(result.map(selectedPath => selectedPath.toLowerCase())).size === result.length,
                'Duplicate or case-colliding brief paths');
            return [name, result];
        }));
        assert(names.some(name => briefs[name].length > 0), 'A handoff requires at least one brief');
        const documents = entries(value.documents, 'document');
        const retire = entries(value.retire, 'retirement');
        const decisions = entries(value.decisions, 'decision');
        const retired = new Set(retire.map(identity));
        assert(documents.every(document => !retired.has(identity(document))),
            'Cannot declare and retire the same document in one handoff');
        assert(decisions.every(decision => !retired.has(identity(decision))),
            'Cannot decide write-back for a retired document');
        const result = { version: 1, briefs, documents, retire, decisions };
        assert(Buffer.byteLength(JSON.stringify(result)) <= MAX_HANDOFF_BYTES, 'Handoff exceeds its size limit');
        selection(briefs, documents);
        return result;
    }

    function resolveHandoff(value, previousDocuments = []) {
        const handoff = validateHandoff(value);
        const previous = entries(previousDocuments, 'document');
        const effective = new Map(previous.map(document => [identity(document), document]));
        const changes = [];
        for (const retired of handoff.retire) {
            const before = effective.get(identity(retired));
            assert(before && before.path === retired.path, 'Retirement must name an existing declaration exactly');
            effective.delete(identity(retired));
            changes.push({ kind: 'retired', repository: retired.repository, path: retired.path,
                before, after: null, reason: retired.reason });
        }
        for (const document of handoff.documents) {
            const before = effective.get(identity(document)) || null;
            assert(!before || before.path === document.path, 'Case-only declaration changes are not supported');
            effective.set(identity(document), document);
            if (!before || before.role !== document.role || before.reason !== document.reason) {
                changes.push({ kind: before ? 'updated' : 'added', repository: document.repository,
                    path: document.path, before, after: document, reason: document.reason });
            }
        }
        const documents = [...effective.values()].sort(entryOrder);
        for (const decision of handoff.decisions) {
            const document = effective.get(identity(decision));
            assert(document && document.path === decision.path && document.role === 'shared',
                'A decision must name an active shared document exactly');
        }
        return { handoff, documents, selection: selection(handoff.briefs, documents),
            changes: changes.sort(entryOrder) };
    }

    function assessDocument(documentValue, source, target, baseline = null, decisionValue = null) {
        const document = entry(documentValue, 'document');
        const decision = decisionValue === null ? null : entry(decisionValue, 'decision');
        if (decision) {
            assert(document.role === 'shared' && decision.repository === document.repository
                && decision.path === document.path, 'A decision must name this shared document exactly');
        }
        const drift = classifyDrift(source, target, baseline);
        if (['missing-source', 'missing-both', 'unsupported', 'unobserved'].includes(drift.relationship)) {
            return { status: 'blocked', drift, action: null, reason: `Required context is ${drift.relationship}` };
        }
        if (document.role !== 'shared') {
            return { status: 'ready', drift, action: 'read-snapshot',
                reason: document.role === 'host-owned' ? 'Canonical write-back remains host-owned' : 'Reference input only; no canonical write-back' };
        }
        if (drift.relationship === 'aligned') {
            assert(!decision, 'An aligned shared document does not need a divergence decision');
            return { status: 'ready', drift, action: 'edit-canonical', reason: 'Source and canonical document are aligned' };
        }
        if (!decision) {
            return { status: 'needs-decision', drift, action: null,
                reason: 'Shared document requires an explicit write-back decision' };
        }
        if (drift.relationship === 'missing-target') {
            assert(['initialize-from-source', 'defer-to-host'].includes(decision.action),
                'An absent canonical document requires initialization or host deferral');
        } else {
            assert(decision.action !== 'initialize-from-source', 'Initialization cannot replace an existing canonical document');
        }
        return { status: 'ready', drift, action: decision.action, reason: decision.reason };
    }

    return Object.freeze({ repositories: Object.freeze(names), validateHandoff, resolveHandoff, assessDocument });
}

module.exports = { MAX_HANDOFF_BYTES, createContextContract, validateObservation, classifyDrift };

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { validatePacket } = require('/opt/rounds.js');

const REPOSITORIES = ['prj', 'Documentation'];
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const OID = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const HASH = /^[0-9a-f]{64}$/;
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function canonical(value) {
    if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
    if (value && typeof value === 'object') {
        return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
    }
    return JSON.stringify(value);
}
const digest = value => hash(canonical(value));
const same = (left, right) => canonical(left) === canonical(right);
function keys(value, expected, label) {
    assert(value && typeof value === 'object' && !Array.isArray(value)
        && same(Object.keys(value).sort(), [...expected].sort()), `Unexpected ${label} fields`);
}
function absolute(value) {
    assert(typeof value === 'string' && value.startsWith('/') && value !== '/'
        && !/[\x00-\x1f\x7f,:\\]/.test(value) && path.posix.normalize(value) === value,
    'Paths must be normalized absolute Linux paths without controls, commas, colons or backslashes');
}
function brief(value) {
    assert(typeof value === 'string' && value.length > 0 && value.length <= 512
        && !/[\x00-\x1f\x7f\\:]/.test(value) && !value.startsWith('/')
        && /\.(md|txt)$/i.test(value)
        && value.split('/').every(part => part && part !== '.' && part !== '..'
            && !['.git', '.secrets', '.ssh'].includes(part.toLowerCase())),
    'Briefs must be literal safe repository-relative .md/.txt paths');
    return value;
}
function branch(value) {
    assert(typeof value === 'string' && value.startsWith('refs/heads/')
        && value.length > 11 && !/[\x00-\x20\x7f~^:?*[\]\\]/.test(value)
        && !value.includes('..') && !value.includes('@{')
        && value.split('/').every(part => part && !part.startsWith('.') && !part.endsWith('.lock'))
        && !value.endsWith('.'), 'Source ref must be an explicit valid refs/heads/... branch');
}
function validateConfig(config) {
    keys(config, ['version', 'task', 'workspace', 'image', 'profiles', 'repositories'], 'config');
    assert(config.version === 1 && typeof config.task === 'string' && ID.test(config.task), 'Invalid config version or task ID');
    absolute(config.workspace);
    assert(typeof config.image === 'string' && config.image.length > 0
        && !config.image.startsWith('-') && !/[\x00-\x20\x7f]/.test(config.image), 'Invalid image name');
    assert(Array.isArray(config.profiles) && config.profiles.every(value => typeof value === 'string' && ID.test(value))
        && new Set(config.profiles).size === config.profiles.length, 'Profiles must be unique informational names');
    keys(config.repositories, REPOSITORIES, 'repositories');
    for (const name of REPOSITORIES) {
        const repo = config.repositories[name];
        keys(repo, ['source', 'ref', 'auditBase', 'briefs'], `${name} config`);
        absolute(repo.source);
        branch(repo.ref);
        assert(typeof repo.auditBase === 'string' && OID.test(repo.auditBase), 'auditBase must be an explicit full lowercase ancestor commit ID');
        assert(Array.isArray(repo.briefs) && repo.briefs.length <= 128, 'Invalid brief list');
        repo.briefs.forEach(brief);
        assert(new Set(repo.briefs.map(value => value.toLowerCase())).size === repo.briefs.length,
            'Duplicate or case-colliding brief paths');
    }
    return config;
}
function selection(config, overrides) {
    const result = Object.fromEntries(REPOSITORIES.map(repo => [repo, [...config.repositories[repo].briefs].sort()]));
    if (overrides.length) {
        REPOSITORIES.forEach(repo => { result[repo] = []; });
        for (const item of overrides) {
            assert(typeof item === 'string', 'Invalid --brief');
            const separator = item.indexOf(':');
            const repo = item.slice(0, separator);
            assert(separator > 0 && REPOSITORIES.includes(repo), '--brief requires prj:PATH or Documentation:PATH');
            result[repo].push(brief(item.slice(separator + 1)));
        }
    }
    for (const repo of REPOSITORIES) {
        result[repo].sort();
        assert(result[repo].length <= 128 && new Set(result[repo].map(value => value.toLowerCase())).size === result[repo].length,
            'Duplicate, case-colliding or excessive --brief selection');
    }
    assert(REPOSITORIES.some(repo => result[repo].length), 'Send requires at least one selected committed brief');
    return result;
}
function safeTree(root) {
    const stat = fs.lstatSync(root);
    assert(!stat.isSymbolicLink() && (stat.isDirectory() || stat.isFile()), 'Task state contains an unsupported file');
    assert((stat.mode & 0o077) === 0 && stat.uid === process.getuid(), 'Task state must be private and owned by the current user');
    if (stat.isDirectory()) for (const name of fs.readdirSync(root)) safeTree(path.join(root, name));
    else assert(stat.nlink === 1, 'Hard-linked task state is unsupported');
}
function atomic(file, value) {
    const staging = `${file}.${crypto.randomUUID()}.part`;
    fs.writeFileSync(staging, `${canonical(value)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(staging, file);
}
const load = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const docs = packet => packet.documents.map(({ path: name, blob, sha256 }) => ({ path: name, blob, sha256 }));
function nextRound(record, snapshots) {
    const rounds = Object.values(record.plans).map(plan => plan.round);
    for (const snapshot of Object.values(snapshots)) {
        rounds.push(...snapshot.rounds.map(item => item.round), ...snapshot.checkpoints.map(item => item.round));
    }
    let number = 1;
    const used = new Set(rounds);
    while (used.has(`R${number}`)) {
        number++;
        assert(Number.isSafeInteger(number), 'Round namespace exhausted');
    }
    return `R${number}`;
}

class Controller {
    constructor(root, hostRoot, adapter) {
        this.root = root;
        this.hostRoot = hostRoot;
        this.adapter = adapter;
        safeTree(root);
    }
    call(operation, args = {}) { return this.adapter(operation, args); }
    host(file) {
        const relative = path.relative(this.root, file);
        assert(relative && !relative.startsWith('..') && !path.isAbsolute(relative), 'Unsafe controller artifact path');
        return `${this.hostRoot}/${relative.split(path.sep).join('/')}`;
    }
    save() { atomic(path.join(this.root, 'record.json'), this.record); }
    load() {
        this.record = load(path.join(this.root, 'record.json'));
        assert(this.record.version === 1, 'Unsupported task state version');
        validateConfig(this.record.config);
        assert(digest(this.record.config) === this.record.configDigest, 'Task config changed; explicit re-registration with a new task is required');
        assert(/^sha256:[0-9a-f]{64}$/.test(this.record.imageId), 'Invalid pinned image ID');
        assert(this.record.config.task === path.posix.basename(this.hostRoot), 'Task record belongs to a different task');
        return this.record;
    }
    image(config = this.record.config) {
        const actual = this.call('image', { image: config.image });
        assert(/^sha256:[0-9a-f]{64}$/.test(actual.id), 'Image inspection did not return an immutable image ID');
        assert(typeof actual.user === 'string' && actual.user && !/^(root|0)(:|$)/.test(actual.user),
            'Image must declare a non-root default user');
        if (this.record) assert(actual.id === this.record.imageId, 'Registered image changed; restore the pinned image before proceeding');
        return actual.id;
    }
    low(mode, repo, extra = {}) {
        return this.call('round', { mode, workspace: this.record.config.workspace,
            repository: repo, image: this.record.imageId, ...extra });
    }
    snapshots({ clean = true, bases = false } = {}) {
        const result = {};
        for (const repo of REPOSITORIES) {
            const base = bases ? this.record.config.repositories[repo].auditBase : this.record.executionHeads[repo];
            assert(OID.test(base), `Invalid recorded ${repo} execution/audit base`);
            const snapshot = this.low('inspect', repo, { base });
            assert(['clean', 'dirty', 'busy', 'recovery-required', 'running'].includes(snapshot.status)
                && snapshot.repository === repo, `Invalid ${repo} inspection`);
            if (snapshot.status !== 'running') {
                assert(OID.test(snapshot.head) && (typeof snapshot.branch === 'string' || snapshot.branch === null)
                    && Array.isArray(snapshot.rounds) && Array.isArray(snapshot.checkpoints)
                    && Array.isArray(snapshot.operations), `Incomplete ${repo} inspection`);
                if (snapshot.status === 'clean' || snapshot.status === 'dirty') {
                    assert(snapshot.baseHead === base, `${repo} did not validate its recorded execution/audit ancestry`);
                }
            }
            if (clean) this.clean(repo, snapshot);
            result[repo] = snapshot;
        }
        return result;
    }
    clean(repo, snapshot, head) {
        assert(snapshot.status === 'clean' && !snapshot.pending && snapshot.operations.length === 0,
            `${repo} is ${snapshot.status}; stop its containers and resolve dirty/pending/foreign operations first`);
        assert(snapshot.branch === this.record.registered[repo].branch, `${repo} branch changed since registration`);
        if (head) assert(snapshot.head === head, `${repo} HEAD changed from the approved/captured head; do not refresh approval silently`);
    }
    stable(before, after) {
        for (const repo of REPOSITORIES) {
            this.clean(repo, after[repo], before[repo].head);
            assert(same(before[repo].rounds, after[repo].rounds) && same(before[repo].checkpoints, after[repo].checkpoints),
                `${repo} round inventory changed during the operation; retry a stable snapshot`);
        }
    }
    retainedIssues(snapshots) {
        const issues = [];
        const knownInputs = Object.fromEntries(REPOSITORIES.map(repo => [repo, new Set()]));
        for (const [id, progress] of Object.entries(this.record.plans)) {
            if (progress.status !== 'completed' && !Object.keys(progress.completed).length) continue;
            const plan = this.plan(id);
            for (const repo of Object.keys(plan.changes)) {
                const item = plan.changes[repo];
                const receipt = progress.completed[repo];
                if (!receipt) {
                    assert(progress.status !== 'completed', `Completed plan lacks a ${repo} receipt`);
                    continue;
                }
                assert(OID.test(receipt.head) && receipt.baseHead === plan.targets[repo].head
                    && receipt.packetSha256 === item.packetSha256 && receipt.roundPath === item.roundPath,
                `${repo} retained receipt no longer matches its approved plan`);
                for (const input of item.inputs) knownInputs[repo].add(canonical(input));
                const snapshot = snapshots[repo];
                if (snapshot.status !== 'clean' || snapshot.branch !== this.record.registered[repo].branch) continue;
                const round = snapshot.rounds.find(value => value.roundPath === item.roundPath);
                const checkpoint = snapshot.checkpoints.find(value => value.task === plan.task && value.round === plan.round);
                if (!round || round.intact !== true || round.packetSha256 !== item.packetSha256
                    || round.sourceCommit !== plan.sources[repo].head || !same(round.documents, item.inputs)
                    || !checkpoint || checkpoint.head !== plan.targets[repo].head) {
                    issues.push({ repository: repo, planId: id, roundPath: item.roundPath,
                        reason: 'Retained input snapshot or checkpoint no longer matches the approved delivery' });
                }
            }
        }
        for (const repo of REPOSITORIES) {
            assert(this.record.lastInputs[repo].every(input => knownInputs[repo].has(canonical(input))),
                `${repo} recorded inputs have no matching delivered plan`);
        }
        return issues;
    }
    assertRetained(snapshots) {
        const issues = this.retainedIssues(snapshots);
        assert(!issues.length, `Retained handoff integrity failed: ${issues.map(issue =>
            `${issue.repository} ${JSON.stringify(issue.roundPath)}`).join(', ')}; inspect or collect for audit, do not reset or overwrite inputs`);
    }
    sources(config = this.record.config, image = this.record.imageId) {
        const result = {};
        for (const repo of REPOSITORIES) {
            const source = config.repositories[repo];
            const snapshot = this.call('source', { source: source.source, ref: source.ref, image });
            assert(snapshot.ref === source.ref && OID.test(snapshot.head), `Invalid source branch snapshot for ${repo}`);
            result[repo] = snapshot;
        }
        return result;
    }
    register(config) {
        validateConfig(config);
        if (fs.existsSync(path.join(this.root, 'record.json'))) {
            this.load();
            assert(same(config, this.record.config), 'Task already registered with a different definition; use an explicit new task ID');
            this.image();
            return { status: 'already-registered', task: config.task, imageId: this.record.imageId,
                registered: this.record.registered, profiles: config.profiles, prepares: false };
        }
        const imageId = this.image(config);
        const sourceHeads = this.sources(config, imageId);
        this.record = { version: 1, config, configDigest: digest(config), imageId, registered: {},
            sourceHeads, lastInputs: { prj: [], Documentation: [] }, lastRound: null,
            executionHeads: {}, collectionHeads: {}, lastCollection: null, activePlan: null, plans: {} };
        const inspected = this.snapshots({ clean: false, bases: true });
        for (const repo of REPOSITORIES) {
            assert(inspected[repo].status === 'clean', `${repo} must be stopped and clean to register`);
            this.record.registered[repo] = { branch: inspected[repo].branch, head: inspected[repo].head };
            this.record.executionHeads[repo] = config.repositories[repo].auditBase;
            this.record.collectionHeads[repo] = config.repositories[repo].auditBase;
        }
        this.stable(inspected, this.snapshots({ bases: true }));
        assert(same(sourceHeads, this.sources()), 'Source branch changed during registration; retry a stable snapshot');
        this.save();
        return { status: 'registered', task: config.task, imageId, registered: this.record.registered,
            profiles: config.profiles, profileNotice: 'Informational only; dependency completeness is not verified', prepares: false };
    }
    plan(id) {
        assert(HASH.test(id) && this.record.plans[id], 'Unknown plan ID for this task');
        const plan = load(path.join(this.root, 'plans', id, 'plan.json'));
        assert(digest(plan) === id, 'Plan bytes no longer match the approved plan ID');
        assert(plan.configDigest === this.record.configDigest && plan.imageId === this.record.imageId
            && plan.task === this.record.config.task, 'Plan/config/image binding changed');
        for (const repo of Object.keys(plan.changes)) {
            const item = plan.changes[repo];
            const file = path.join(this.root, 'plans', id, `${repo}.json`);
            const bytes = fs.readFileSync(file);
            assert(hash(bytes) === item.packetFileSha256, `Approved ${repo} packet bytes changed`);
            const packet = validatePacket(JSON.parse(bytes));
            assert(hash(JSON.stringify(packet)) === item.packetSha256 && packet.repository === repo
                && packet.task === plan.task && packet.round === plan.round
                && packet.sourceCommit === plan.sources[repo].head && same(docs(packet), item.inputs),
            `Approved ${repo} packet no longer matches its plan`);
        }
        return plan;
    }
    summary(id, status) {
        const plan = this.plan(id);
        return { status, task: plan.task, round: plan.round, planId: id,
            approval: 'Summarize this exact plan in chat; only explicit send TASK --apply PLAN_ID changes repositories',
            repositories: Object.fromEntries(REPOSITORIES.map(repo => [repo, {
                action: plan.changes[repo] ? 'import' : 'preserve',
                sourceCommit: plan.sources[repo].head, expectedHead: plan.targets[repo].head,
                branch: plan.targets[repo].branch,
                changedBriefs: plan.changes[repo]?.changedBriefs || [],
                inputs: plan.changes[repo]?.inputs || plan.priorInputs[repo],
                entrypoint: plan.changes[repo] ? `${plan.changes[repo].roundPath}/README.md` : null,
            }])), priorInputs: plan.priorInputs, priorEntrypoints: plan.priorEntrypoints, progress: this.record.plans[id],
            prepares: false, launchesAgent: false, crossRepositoryAtomic: false };
    }
    send(overrides = []) {
        this.load();
        this.image();
        const selected = selection(this.record.config, overrides);
        let existing = null;
        if (this.record.activePlan) {
            existing = this.record.plans[this.record.activePlan];
            assert(existing && existing.status === 'pending' && Object.keys(existing.completed).length === 0,
                'A send is partial or needs recovery; retry its exact --apply plan before planning another send');
        }
        const before = this.snapshots();
        this.assertRetained(before);
        const sourceBefore = this.sources();
        const occupied = existing && Object.values(before).some(snapshot =>
            [...snapshot.rounds, ...snapshot.checkpoints].some(item => item.round === existing.round));
        const round = existing && !occupied ? existing.round : nextRound(this.record, before);
        const stage = path.join(this.root, `stage-send-${crypto.randomUUID()}`);
        fs.mkdirSync(stage, { mode: 0o700 });
        const changes = {};
        for (const repo of REPOSITORIES) {
            if (!selected[repo].length) continue;
            const source = this.record.config.repositories[repo];
            const file = path.join(stage, `${repo}.json`);
            this.call('round', { mode: 'export', source: source.source, repository: repo, ref: source.ref,
                task: this.record.config.task, round, paths: selected[repo], output: this.host(file), image: this.record.imageId });
            const bytes = fs.readFileSync(file);
            const packet = validatePacket(JSON.parse(bytes));
            assert(packet.repository === repo && packet.task === this.record.config.task && packet.round === round
                && packet.sourceCommit === sourceBefore[repo].head
                && same(packet.documents.map(document => document.path), selected[repo]),
            `${repo} export did not match the captured committed selection`);
            const inputs = docs(packet);
            const previous = new Map(this.record.lastInputs[repo].map(item => [item.path, item]));
            const changedBriefs = inputs.filter(item => !same(item, previous.get(item.path) || null)).map(item => item.path);
            if (!changedBriefs.length) continue;
            const preview = this.low('preview', repo, { packet: this.host(file) });
            const packetSha256 = hash(JSON.stringify(packet));
            assert(preview.status === 'ready' && preview.head === before[repo].head
                && preview.branch === before[repo].branch && preview.packetSha256 === packetSha256
                && preview.roundPath === `sandbox-rounds/${this.record.config.task}/${round}`,
            `${repo} preview changed or its round ID is occupied; inspect existing rounds before retrying`);
            changes[repo] = { inputs, changedBriefs, packetSha256, packetFileSha256: hash(bytes),
                roundPath: preview.roundPath };
        }
        this.stable(before, this.snapshots());
        assert(same(sourceBefore, this.sources()), 'Source branch changed during send; no plan published, retry with stable sources');
        if (!Object.keys(changes).length) {
            if (existing) {
                this.record.plans[this.record.activePlan].status = 'superseded';
                this.record.activePlan = null;
                this.save();
            }
            fs.rmSync(stage, { recursive: true });
            return { status: 'unchanged', task: this.record.config.task, lastRound: this.record.lastRound,
                reason: 'Selected committed brief blobs were already delivered; unrelated source commits do not create rounds',
                priorInputs: this.record.lastInputs, prepares: false };
        }
        const plan = { version: 1, task: this.record.config.task, round, configDigest: this.record.configDigest,
            imageId: this.record.imageId, sources: sourceBefore,
            targets: Object.fromEntries(REPOSITORIES.map(repo => [repo, { head: before[repo].head, branch: before[repo].branch }])),
            selection: selected, changes, priorInputs: this.record.lastInputs,
            priorEntrypoints: Object.fromEntries(REPOSITORIES.map(repo =>
                [repo, before[repo].rounds.filter(item => item.task === this.record.config.task && item.intact)
                    .map(item => `${item.roundPath}/README.md`)])) };
        const id = digest(plan);
        const destination = path.join(this.root, 'plans', id);
        fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
        if (!fs.existsSync(destination)) {
            atomic(path.join(stage, 'plan.json'), plan);
            for (const name of fs.readdirSync(stage)) fs.chmodSync(path.join(stage, name), 0o400);
            fs.renameSync(stage, destination);
        } else {
            fs.rmSync(stage, { recursive: true });
        }
        if (this.record.activePlan && this.record.activePlan !== id) this.record.plans[this.record.activePlan].status = 'superseded';
        this.record.plans[id] ||= { status: 'pending', round, completed: {} };
        this.record.activePlan = id;
        this.save();
        return this.summary(id, 'approval-required');
    }
    matchingPending(snapshot, plan, repo) {
        const pending = snapshot.pending;
        const item = plan.changes[repo];
        const ownedLocks = new Set(['index.lock', 'HEAD.lock', `${plan.targets[repo].branch}.lock`,
            `refs/sandbox-rounds/checkpoints/${plan.task}/${plan.round}.lock`]);
        return snapshot.status === 'recovery-required' && pending && item
            && snapshot.operations.every(marker => ownedLocks.has(marker))
            && snapshot.branch === plan.targets[repo].branch
            && pending.roundPath === item.roundPath && pending.packetSha256 === item.packetSha256
            && pending.baseHead === plan.targets[repo].head && pending.branch === plan.targets[repo].branch
            && [pending.baseHead, pending.commit].includes(snapshot.head);
    }
    imported(snapshot, plan, repo, packet) {
        this.clean(repo, snapshot);
        const item = plan.changes[repo];
        const round = snapshot.rounds.find(value => value.roundPath === item.roundPath);
        const checkpoint = snapshot.checkpoints.find(value => value.task === plan.task && value.round === plan.round);
        assert(round && round.intact === true && round.packetSha256 === item.packetSha256 && checkpoint
            && checkpoint.head === plan.targets[repo].head, `${repo} moved without a matching approved import/checkpoint`);
        const preview = this.low('preview', repo, { packet });
        assert(preview.status === 'already-imported' && preview.head === snapshot.head
            && preview.packetSha256 === item.packetSha256, `${repo} approved import is not intact`);
        // The low-level helper verifies exact commit parentage, not merely a matching
        // round directory in an arbitrary later commit.
        this.call('import-head', { workspace: this.record.config.workspace, repository: repo,
            head: snapshot.head, base: plan.targets[repo].head, image: this.record.imageId,
            roundPath: item.roundPath });
        this.clean(repo, this.low('inspect', repo), snapshot.head);
        return { status: 'already-imported', head: snapshot.head, baseHead: plan.targets[repo].head,
            packetSha256: item.packetSha256, roundPath: item.roundPath };
    }
    apply(id) {
        this.load();
        this.image();
        const plan = this.plan(id);
        const progress = this.record.plans[id];
        if (progress.status === 'completed') {
            const current = this.snapshots();
            this.assertRetained(current);
            this.stable(current, this.snapshots());
            return { ...this.summary(id, 'already-applied'),
                currentHeads: Object.fromEntries(REPOSITORIES.map(repo => [repo, current[repo].head])) };
        }
        assert(this.record.activePlan === id && ['pending', 'partial', 'applying'].includes(progress.status),
            'Plan was superseded or is not the active approval');
        let snapshots = this.snapshots({ clean: false });
        this.assertRetained(snapshots);
        for (const repo of REPOSITORIES) {
            const snapshot = snapshots[repo];
            if (snapshot.status !== 'clean') {
                if (!progress.completed[repo] && this.matchingPending(snapshot, plan, repo)) continue;
                this.clean(repo, snapshot);
            }
            assert(snapshot.branch === plan.targets[repo].branch, `${repo} branch changed from the approved plan`);
            if (progress.completed[repo]) this.clean(repo, snapshot, progress.completed[repo].head);
            else {
                this.clean(repo, snapshot);
                if (!plan.changes[repo] || snapshot.head === plan.targets[repo].head) {
                    assert(snapshot.head === plan.targets[repo].head, `${repo} unchanged context advanced after approval`);
                } else {
                    const packet = this.host(path.join(this.root, 'plans', id, `${repo}.json`));
                    progress.completed[repo] = this.imported(snapshot, plan, repo, packet);
                    progress.status = 'partial';
                    this.save();
                }
            }
        }
        progress.status = Object.keys(progress.completed).length ? 'partial' : 'applying';
        this.save();
        for (const repo of REPOSITORIES) {
            if (!plan.changes[repo] || progress.completed[repo]) continue;
            const packet = this.host(path.join(this.root, 'plans', id, `${repo}.json`));
            const current = this.low('inspect', repo);
            if (current.pending) {
                assert(this.matchingPending(current, plan, repo), `${repo} foreign pending journal requires manual recovery`);
                this.low('recover', repo, { packet, 'expected-head': current.head });
            }
            const ready = this.low('inspect', repo);
            let receipt;
            if (ready.head !== plan.targets[repo].head) receipt = this.imported(ready, plan, repo, packet);
            else {
                this.clean(repo, ready, plan.targets[repo].head);
                receipt = this.low('apply', repo, { packet, 'expected-head': plan.targets[repo].head });
                assert(receipt.status === 'imported' && receipt.baseHead === plan.targets[repo].head
                    && receipt.packetSha256 === plan.changes[repo].packetSha256 && OID.test(receipt.head),
                `${repo} returned an unexpected import receipt; inspect before recovery`);
            }
            progress.completed[repo] = receipt;
            progress.status = 'partial';
            this.save();
        }
        snapshots = this.snapshots();
        for (const repo of REPOSITORIES) {
            this.clean(repo, snapshots[repo], progress.completed[repo]?.head || plan.targets[repo].head);
        }
        this.assertRetained(snapshots);
        for (const repo of REPOSITORIES) {
            if (plan.changes[repo]) {
                const merged = new Map(this.record.lastInputs[repo].map(item => [item.path, item]));
                plan.changes[repo].inputs.forEach(item => merged.set(item.path, item));
                this.record.lastInputs[repo] = [...merged.values()].sort((a, b) => a.path.localeCompare(b.path));
            }
            this.record.executionHeads[repo] = snapshots[repo].head;
        }
        progress.status = 'completed';
        this.record.activePlan = null;
        this.record.lastRound = plan.round;
        this.save();
        return this.summary(id, 'applied');
    }
    status() {
        this.load();
        this.image();
        const inspected = this.snapshots({ clean: false });
        const inputIssues = this.retainedIssues(inspected);
        const blocked = REPOSITORIES.filter(repo => inspected[repo].status !== 'clean'
            || inspected[repo].branch !== this.record.registered[repo].branch
            || inputIssues.some(issue => issue.repository === repo));
        return { status: REPOSITORIES.some(repo => inspected[repo].status === 'running') ? 'running' : blocked.length ? 'blocked' : 'ready',
            task: this.record.config.task, workspace: this.record.config.workspace, imageId: this.record.imageId,
            profiles: this.record.config.profiles, profileNotice: 'Informational, not proof dependencies are warmed',
            registered: this.record.registered, lastAppliedRound: this.record.lastRound,
            activePlan: this.record.activePlan, plans: this.record.plans, lastCollection: this.record.lastCollection,
            collectionHeads: this.record.collectionHeads, executionHeads: this.record.executionHeads,
            blockedRepositories: blocked, inputIssues, inspected };
    }
    collection(id) {
        const directory = path.join(this.root, 'collections', id);
        const manifestBytes = fs.readFileSync(path.join(directory, 'collection.json'));
        const manifest = JSON.parse(manifestBytes);
        assert(digest(manifest.binding) === id, 'Collection identity changed');
        if (this.record.lastCollection?.id === id) {
            assert(hash(manifestBytes) === this.record.lastCollection.manifestSha256, 'Collection manifest checksum mismatch');
        }
        keys(manifest.repositories, REPOSITORIES, 'collection repositories');
        assert(same(fs.readdirSync(directory).sort(), ['Documentation', 'collection.json', 'prj', 'provenance.json']),
            'Unexpected collection root inventory');
        const expected = new Set(['provenance.json']);
        for (const repo of REPOSITORIES) {
            const low = load(path.join(directory, repo, 'manifest.json'));
            assert(same(low, manifest.repositories[repo]), 'Collection repository manifest changed');
            const names = ['manifest.json', ...low.files.map(item => item.name)].sort();
            assert(same(names, fs.readdirSync(path.join(directory, repo)).sort()), 'Collection repository inventory changed');
            names.forEach(name => expected.add(`${repo}/${name}`));
        }
        assert(same(manifest.files.map(item => item.name).sort(), [...expected].sort()), 'Collection checksum inventory changed');
        for (const item of manifest.files) {
            assert(/^(prj|Documentation)\/(manifest\.json|changes\.patch|work\.patch|history\.bundle)$/.test(item.name)
                || item.name === 'provenance.json', 'Unexpected collection filename');
            const bytes = fs.readFileSync(path.join(directory, item.name));
            assert(hash(bytes) === item.sha256 && bytes.length === item.bytes, 'Published collection checksum mismatch');
        }
        return manifest;
    }
    collect() {
        this.load();
        this.image();
        assert(!this.record.activePlan, 'Collection requires no pending, partial or recovery send; finish the exact active plan first');
        const before = this.snapshots({ bases: true });
        const heads = Object.fromEntries(REPOSITORIES.map(repo => [repo, before[repo].head]));
        if (this.record.lastCollection && same(heads, this.record.lastCollection.heads)) {
            const previous = this.collection(this.record.lastCollection.id);
            return { status: 'unchanged', task: this.record.config.task, collectionId: this.record.lastCollection.id,
                directory: this.host(path.join(this.root, 'collections', this.record.lastCollection.id)), manifest: previous,
                manifestSha256: this.record.lastCollection.manifestSha256,
                applicationTestsRun: false };
        }
        const binding = { version: 1, task: this.record.config.task, configDigest: this.record.configDigest,
            imageId: this.record.imageId, heads, bases: { ...this.record.collectionHeads },
            workBases: { ...this.record.executionHeads }, lastRound: this.record.lastRound };
        const id = digest(binding);
        const destination = path.join(this.root, 'collections', id);
        let manifest;
        if (fs.existsSync(destination)) manifest = this.collection(id);
        else {
            const stage = path.join(this.root, `stage-collect-${crypto.randomUUID()}`);
            fs.mkdirSync(stage, { mode: 0o700 });
            const repositories = {};
            const files = [];
            for (const repo of REPOSITORIES) {
                const output = path.join(stage, repo);
                const result = this.low('collect', repo, { base: binding.bases[repo], 'work-base': binding.workBases[repo],
                    'expected-head': heads[repo], output: this.host(output) });
                assert(['collected', 'unchanged'].includes(result.status) && result.head === heads[repo]
                    && result.branch === before[repo].branch && result.baseHead === binding.bases[repo]
                    && result.workBaseHead === binding.workBases[repo], `${repo} collection did not match its captured bases`);
                assert(same(load(path.join(output, 'manifest.json')), result), 'Collection result differs from its published manifest');
                assert(Array.isArray(result.files), 'Invalid collection file inventory');
                const expected = new Set(['manifest.json']);
                for (const item of result.files) {
                    assert(['changes.patch', 'work.patch', 'history.bundle'].includes(item.name) && !expected.has(item.name),
                        'Unexpected or duplicate collection file');
                    expected.add(item.name);
                    const bytes = fs.readFileSync(path.join(output, item.name));
                    assert(hash(bytes) === item.sha256 && bytes.length === item.bytes, 'Low-level collection checksum mismatch');
                }
                assert(same([...expected].sort(), fs.readdirSync(output).sort()), 'Unexpected files in collection output');
                repositories[repo] = result;
                for (const name of [...expected].sort()) {
                    const bytes = fs.readFileSync(path.join(output, name));
                    files.push({ name: `${repo}/${name}`, sha256: hash(bytes), bytes: bytes.length });
                }
            }
            const provenance = { configDigest: this.record.configDigest, lastInputs: this.record.lastInputs,
                plans: Object.fromEntries(Object.entries(this.record.plans).filter(([, value]) => value.status === 'completed')
                    .map(([planId, receipt]) => [planId, { plan: this.plan(planId), receipt }])) };
            atomic(path.join(stage, 'provenance.json'), provenance);
            const bytes = fs.readFileSync(path.join(stage, 'provenance.json'));
            files.push({ name: 'provenance.json', sha256: hash(bytes), bytes: bytes.length });
            manifest = { version: 1, binding, repositories, files,
                notice: 'Full incremental diff is authoritative, including input edits. Bundles are unreviewed. No application tests were run.' };
            atomic(path.join(stage, 'collection.json'), manifest);
            this.stable(before, this.snapshots());
            fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
            fs.renameSync(stage, destination);
        }
        this.stable(before, this.snapshots());
        this.record.collectionHeads = heads;
        const manifestSha256 = hash(fs.readFileSync(path.join(destination, 'collection.json')));
        this.record.lastCollection = { id, heads, manifestSha256 };
        this.save();
        return { status: 'collected', task: this.record.config.task, collectionId: id,
            directory: this.host(destination), manifest, manifestSha256, applicationTestsRun: false };
    }
}

function rpc(operationDirectory) {
    let sequence = 0;
    return (operation, args) => {
        const number = ++sequence;
        atomic(path.join(operationDirectory, `request-${number}.json`), { operation, args });
        const response = path.join(operationDirectory, `response-${number}.json`);
        const deadline = Date.now() + 30 * 60 * 1000;
        while (!fs.existsSync(response)) {
            assert(Date.now() < deadline, 'Host operation timed out; inspect status before retrying');
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
        }
        const result = load(response);
        assert(result.ok, result.error || 'Host operation failed; inspect stderr and task status');
        return result.value;
    };
}
if (require.main === module) {
    try {
        process.umask(0o077);
        const request = load('/operation/input.json');
        const controller = new Controller('/task', request.hostRoot, rpc('/operation'));
        let result;
        if (request.mode === 'register') result = controller.register(request.config);
        else if (request.mode === 'send') result = request.planId ? controller.apply(request.planId) : controller.send(request.briefs);
        else if (request.mode === 'status') result = controller.status();
        else if (request.mode === 'collect') result = controller.collect();
        else throw new Error('Unknown controller mode');
        process.stdout.write(`${JSON.stringify(result)}\n`);
    } catch (error) {
        process.stderr.write(`sandbox-task: ${error.message}\n`);
        process.exitCode = 1;
    }
}

module.exports = { Controller, validateConfig, selection, canonical, digest, hash, nextRound };

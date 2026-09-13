#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { TextDecoder } = require('node:util');

const MAX_PACKET = 32 * 1024 * 1024;
const MAX_DOCUMENT = 2 * 1024 * 1024;
const MAX_DOCUMENTS = 128;
const OID = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const ATTRIBUTES = '* -text -filter -ident -working-tree-encoding\n**/* -text -filter -ident -working-tree-encoding\n';

function requireThat(condition, message) {
    if (!condition) throw new Error(message);
}

function sha256(bytes) {
    return crypto.createHash('sha256').update(bytes).digest('hex');
}

function utf8(bytes) {
    return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
}

function exists(file) {
    try {
        return fs.lstatSync(file);
    } catch (error) {
        if (error.code === 'ENOENT') return null;
        throw error;
    }
}

function regular(file) {
    const stat = exists(file);
    requireThat(stat && stat.isFile() && !stat.isSymbolicLink(), `Expected a regular file: ${file}`);
    return stat;
}

function directory(file) {
    const stat = exists(file);
    requireThat(stat && stat.isDirectory() && !stat.isSymbolicLink(), `Expected a real directory: ${file}`);
}

function inside(parent, child) {
    const relative = path.relative(parent, child);
    return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function documentPath(value) {
    requireThat(typeof value === 'string' && value.length > 0 && value.length <= 512, 'Invalid document path length');
    requireThat(!/[\x00-\x1f\x7f\\:]/.test(value) && !path.posix.isAbsolute(value), 'Unsafe document path');
    const parts = value.split('/');
    requireThat(parts.every(part => part && part !== '.' && part !== '..'
        && !['.git', '.secrets', '.ssh'].includes(part.toLowerCase())), 'Unsafe document path component');
    requireThat(/\.(md|txt)$/i.test(value), 'Only explicitly selected .md and .txt documents are supported');
    return value;
}

function exactKeys(object, keys, label) {
    requireThat(object && typeof object === 'object' && !Array.isArray(object), `Invalid ${label}`);
    requireThat(Object.keys(object).sort().join('\0') === [...keys].sort().join('\0'), `Unexpected ${label} fields`);
}

function validatePacket(packet) {
    exactKeys(packet, ['version', 'repository', 'task', 'round', 'sourceCommit', 'documents'], 'packet');
    requireThat(packet.version === 1, 'Unsupported packet version');
    requireThat(['prj', 'Documentation'].includes(packet.repository), 'Unsupported target repository');
    requireThat(typeof packet.task === 'string' && typeof packet.round === 'string'
        && ID.test(packet.task) && ID.test(packet.round), 'Task and round IDs must be 1-64 ASCII letters, digits, underscores or hyphens');
    requireThat(OID.test(packet.sourceCommit), 'Invalid source commit');
    requireThat(Array.isArray(packet.documents) && packet.documents.length > 0
        && packet.documents.length <= MAX_DOCUMENTS, 'Invalid document count');
    const seen = new Set();
    let total = 0;
    for (const document of packet.documents) {
        exactKeys(document, ['path', 'blob', 'sha256', 'content'], 'document');
        documentPath(document.path);
        requireThat(!seen.has(document.path.toLowerCase()), 'Duplicate or case-colliding document paths');
        seen.add(document.path.toLowerCase());
        requireThat(typeof document.content === 'string' && !document.content.includes('\0'), 'Document must be UTF-8 text without NUL bytes');
        const bytes = Buffer.from(document.content, 'utf8');
        requireThat(utf8(bytes) === document.content, 'Document contains invalid Unicode');
        requireThat(bytes.length <= MAX_DOCUMENT && (total += bytes.length) <= MAX_PACKET / 2, 'Document content exceeds the size limit');
        requireThat(document.sha256 === sha256(bytes), 'Document checksum mismatch');
        requireThat(typeof document.blob === 'string' && OID.test(document.blob), 'Invalid source blob');
        const algorithm = document.blob.length === 40 ? 'sha1' : 'sha256';
        const blob = crypto.createHash(algorithm).update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
        requireThat(blob === document.blob, 'Source blob checksum mismatch');
    }
    packet.documents.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
    requireThat(Buffer.byteLength(JSON.stringify(packet)) <= MAX_PACKET, 'Encoded packet exceeds the size limit');
    return packet;
}

function loadPacket(file, repository) {
    requireThat(regular(file).size <= MAX_PACKET, 'Packet exceeds the size limit');
    let packet;
    try {
        packet = JSON.parse(utf8(fs.readFileSync(file)));
    } catch (error) {
        if (error instanceof SyntaxError || error.code === 'ERR_ENCODING_INVALID_ENCODED_DATA') {
            throw new Error('Packet is not valid UTF-8 JSON');
        }
        throw error;
    }
    validatePacket(packet);
    requireThat(packet.repository === repository, 'Packet repository does not match the explicitly selected target');
    return { packet, digest: sha256(JSON.stringify(packet)) };
}

function safeMetadataTree(root, forbidLocks = false) {
    directory(root);
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
        const file = path.join(root, entry.name);
        requireThat(!entry.isSymbolicLink(), 'Symlinked Git references/logs are unsupported');
        requireThat(!forbidLocks || !entry.name.endsWith('.lock'), 'Repository has an in-progress reference lock');
        if (entry.isDirectory()) safeMetadataTree(file, forbidLocks);
        else regular(file);
    }
}

function parseArgs(argv) {
    const mode = argv.shift();
    requireThat(['export', 'preview', 'apply', 'recover'].includes(mode), 'Expected export, preview, apply or recover');
    const options = { mode, paths: [] };
    const values = new Set(['root', 'state', 'repository', 'ref', 'task', 'round', 'path', 'packet', 'expected-head']);
    while (argv.length) {
        const flag = argv.shift();
        requireThat(flag.startsWith('--') && values.has(flag.slice(2)) && argv.length, 'Invalid or incomplete helper option');
        const key = flag.slice(2);
        const value = argv.shift();
        if (key === 'path') options.paths.push(value);
        else {
            requireThat(options[key] === undefined, `Duplicate option: ${flag}`);
            options[key] = value;
        }
    }
    requireThat(options.root && ['prj', 'Documentation'].includes(options.repository), 'Explicit repository root and repository name are required');
    if (mode === 'export') {
        requireThat(options.ref && options.task && options.round
            && ID.test(options.task) && ID.test(options.round) && options.paths.length, 'Export requires a ref, task, round and selected paths');
        requireThat(!options.state && !options.packet && !options['expected-head'], 'Unexpected export option');
    } else {
        requireThat(options.state && options.packet && !options.ref && !options.task
            && !options.round && !options.paths.length, 'Import requires state and packet, not export options');
        if (mode !== 'preview') requireThat(OID.test(options['expected-head']), 'Apply/recover requires the full expected HEAD');
        else requireThat(!options['expected-head'], 'Preview does not accept an expected HEAD');
    }
    return options;
}

function statusChanges(bytes) {
    const fields = bytes.toString('utf8').split('\0');
    const changes = [];
    for (let i = 0; i < fields.length; i++) {
        if (!fields[i]) continue;
        requireThat(fields[i].length > 3 && fields[i][2] === ' ', 'Unexpected Git status record');
        const change = { code: fields[i].slice(0, 2), path: fields[i].slice(3) };
        if (/[RC]/.test(change.code)) {
            requireThat(Boolean(fields[i + 1]), 'Incomplete Git rename status');
            change.from = fields[++i];
        }
        changes.push(change);
    }
    return changes;
}

class Repository {
    constructor(root) {
        directory(root);
        this.root = fs.realpathSync(root);
        this.gitDir = path.join(this.root, '.git');
        directory(this.gitDir);
        requireThat(!exists(path.join(this.gitDir, 'commondir')), 'Linked worktrees are unsupported');
        for (const name of ['HEAD', 'config']) regular(path.join(this.gitDir, name));
        for (const name of ['index', 'packed-refs', 'shallow']) {
            if (exists(path.join(this.gitDir, name))) regular(path.join(this.gitDir, name));
        }
        for (const name of ['refs', 'objects']) directory(path.join(this.gitDir, name));
        safeMetadataTree(path.join(this.gitDir, 'refs'));
        if (exists(path.join(this.gitDir, 'logs'))) safeMetadataTree(path.join(this.gitDir, 'logs'));
        for (const entry of fs.readdirSync(path.join(this.gitDir, 'objects'), { withFileTypes: true })) {
            requireThat(!entry.isSymbolicLink(), 'Symlinked object directories are unsupported');
        }
        requireThat(!exists(path.join(this.gitDir, 'objects', 'info', 'alternates')), 'Alternate object stores are unsupported');
        this.env = {
            PATH: '/usr/bin:/bin',
            HOME: '/nonexistent',
            LANG: 'C.UTF-8',
            LC_ALL: 'C.UTF-8',
            GIT_CONFIG_NOSYSTEM: '1',
            GIT_CONFIG_GLOBAL: '/dev/null',
            GIT_ATTR_NOSYSTEM: '1',
            GIT_NO_REPLACE_OBJECTS: '1',
            GIT_LITERAL_PATHSPECS: '1',
            GIT_TERMINAL_PROMPT: '0',
            GIT_OPTIONAL_LOCKS: '0'
        };
        requireThat(!this.config('extensions.refStorage') || this.config('extensions.refStorage') === 'files', 'Only files-based Git references are supported');
        requireThat(this.config('extensions.worktreeConfig') !== 'true', 'Worktree configuration is unsupported');
        this.format = this.config('extensions.objectFormat') || 'sha1';
        requireThat(['sha1', 'sha256'].includes(this.format), 'Unsupported Git object format');
        this.control = fs.mkdtempSync(path.join(os.tmpdir(), 'sandbox-round-git-'));
        // Share objects/refs as data, not the target's config, hooks or filters.
        // Worktree comparisons and index construction use a private copied index.
        const template = path.join(this.control, 'empty-template');
        fs.mkdirSync(template);
        this.raw(['init', '--quiet', '--bare', `--object-format=${this.format}`, `--template=${template}`, this.control]);
        fs.rmSync(path.join(this.control, 'refs'), { recursive: true });
        fs.symlinkSync(path.join(this.gitDir, 'refs'), path.join(this.control, 'refs'));
        for (const name of ['packed-refs', 'shallow', 'logs']) {
            if (exists(path.join(this.gitDir, name))) fs.symlinkSync(path.join(this.gitDir, name), path.join(this.control, name));
        }
        this.headText = fs.readFileSync(path.join(this.gitDir, 'HEAD'), 'utf8');
        fs.writeFileSync(path.join(this.control, 'HEAD'), this.headText);
        if (exists(path.join(this.gitDir, 'index'))) fs.copyFileSync(path.join(this.gitDir, 'index'), path.join(this.control, 'index'));
        this.env.GIT_OBJECT_DIRECTORY = path.join(this.gitDir, 'objects');
    }

    raw(args, input, allowMissing = false, env = this.env) {
        const result = spawnSync('/usr/bin/git', args, { cwd: this.root, env, input, maxBuffer: MAX_PACKET });
        if (result.error) throw result.error;
        if (allowMissing && result.status === 1) return null;
        requireThat(result.status === 0, `Git ${args[0]} failed (status ${result.status}); repository left for inspection`);
        return result.stdout;
    }

    config(key) {
        const value = this.raw(['config', '--file', path.join(this.gitDir, 'config'), '--no-includes', '--get', key], undefined, true);
        return value === null ? '' : value.toString('utf8').trim();
    }

    git(args, input, extraEnv = {}) {
        return this.raw([
            '--no-pager', `--git-dir=${this.control}`, `--work-tree=${this.root}`,
            '-c', 'core.bare=false', '-c', 'core.hooksPath=/dev/null',
            '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
            '-c', 'core.autocrlf=false', '-c', 'core.excludesFile=/dev/null',
            '-c', 'core.attributesFile=/dev/null', '-c', 'core.logAllRefUpdates=true',
            '-c', 'commit.gpgsign=false', '-c', 'protocol.allow=never', ...args
        ], input, false, { ...this.env, ...extraEnv });
    }

    text(args, input, env) {
        return this.git(args, input, env).toString('utf8').trim();
    }

    branch() {
        const text = fs.readFileSync(path.join(this.gitDir, 'HEAD'), 'utf8');
        requireThat(text === this.headText, 'HEAD changed during the operation');
        const match = /^ref: (refs\/heads\/[^\r\n]+)\n?$/.exec(text);
        requireThat(match, 'Import requires a checked-out branch, not detached HEAD');
        this.git(['check-ref-format', match[1]]);
        return match[1];
    }

    head() {
        const head = this.text(['rev-parse', '--verify', 'HEAD^{commit}']);
        requireThat(OID.test(head), 'Target has no valid commit');
        return head;
    }

    unchangedLfsPayload(change, entry) {
        if (change.code !== ' M' || !entry) return false;
        const attributes = this.git(['check-attr', '--cached', '-z', 'filter', '--', change.path]).toString('utf8').split('\0');
        if (attributes[0] !== change.path || attributes[1] !== 'filter' || attributes[2] !== 'lfs') return false;
        const size = Number(this.text(['cat-file', '-s', entry.oid]));
        if (!Number.isSafeInteger(size) || size > 1024) return false;
        const pointer = this.git(['cat-file', 'blob', entry.oid]).toString('utf8');
        const match = /^version https:\/\/git-lfs.github.com\/spec\/v1\noid sha256:([0-9a-f]{64})\nsize (0|[1-9][0-9]*)\n$/.exec(pointer);
        if (!match || match[0] !== pointer) return false;
        const expectedSize = Number(match[2]);
        if (!Number.isSafeInteger(expectedSize)) return false;
        const parts = change.path.split('/');
        if (path.isAbsolute(change.path) || parts.some(part => !part || part === '.' || part === '..')) return false;
        let file = this.root;
        let descriptor;
        try {
            for (let i = 0; i < parts.length; i++) {
                file = path.join(file, parts[i]);
                const stat = fs.lstatSync(file);
                if (stat.isSymbolicLink() || (i < parts.length - 1 ? !stat.isDirectory() : !stat.isFile())) return false;
            }
            descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
            const before = fs.fstatSync(descriptor);
            if (!before.isFile() || before.size !== expectedSize || Boolean(before.mode & 0o100) !== (entry.mode === '100755')) return false;
            // Filters remain disabled. Only canonical LFS v1 payloads whose bytes
            // match the staged pointer are clean; extensions and changed assets fail.
            const hash = crypto.createHash('sha256');
            const buffer = Buffer.alloc(64 * 1024);
            let length;
            while ((length = fs.readSync(descriptor, buffer, 0, buffer.length, null)) > 0) {
                hash.update(buffer.subarray(0, length));
            }
            const after = fs.fstatSync(descriptor);
            const current = fs.lstatSync(file);
            return current.isFile() && !current.isSymbolicLink()
                && ['dev', 'ino', 'size', 'mode', 'mtimeMs', 'ctimeMs'].every(key => before[key] === after[key] && after[key] === current[key])
                && hash.digest('hex') === match[1];
        } catch (error) {
            if (['ENOENT', 'ENOTDIR', 'ELOOP'].includes(error.code)) return false;
            throw error;
        } finally {
            if (descriptor !== undefined) fs.closeSync(descriptor);
        }
    }

    assertClean(ignoreOwnedLocks = false) {
        const operations = ['MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply', 'sequencer', 'BISECT_START', 'packed-refs.lock'];
        if (!ignoreOwnedLocks) operations.push('index.lock', 'HEAD.lock');
        for (const name of operations) requireThat(!exists(path.join(this.gitDir, name)), `Repository has an in-progress operation: ${name}`);
        safeMetadataTree(path.join(this.gitDir, 'refs'), true);
        regular(path.join(this.gitDir, 'index'));
        const entries = this.git(['ls-files', '--stage', '-z']).toString('utf8').split('\0');
        requireThat(!entries.some(entry => entry.startsWith('160000 ')), 'Submodule repositories are unsupported by this importer');
        const indexed = new Map();
        for (const record of entries) {
            const entry = /^(100644|100755) ([0-9a-f]+) 0\t([\s\S]+)$/.exec(record);
            if (entry) indexed.set(entry[3], { mode: entry[1], oid: entry[2] });
        }
        const status = this.git(['status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=all']);
        const dirty = statusChanges(status).filter(change => !this.unchangedLfsPayload(change, indexed.get(change.path)));
        if (dirty.length) {
            const summary = dirty.slice(0, 12).map(change =>
                `  ${change.code} ${JSON.stringify(change.path)}${change.from ? ` (from ${JSON.stringify(change.from)})` : ''}`);
            if (dirty.length > 12) summary.push(`  ... ${dirty.length - 12} more paths`);
            throw new Error(`Target has staged, unstaged or untracked changes; commit or resolve them first:\n${summary.join('\n')}`);
        }
    }

    close() {
        if (this.control) fs.rmSync(this.control, { recursive: true, force: true });
    }
}

function exportPacket(repo, options) {
    const commit = repo.text(['rev-parse', '--verify', '--end-of-options', `${options.ref}^{commit}`]);
    requireThat(OID.test(commit), 'Source ref is not a commit');
    const documents = options.paths.map(selected => {
        documentPath(selected);
        const entry = repo.git(['ls-tree', '-z', commit, '--', selected]).toString('utf8');
        const match = /^100644 blob ([0-9a-f]+)\t([^\0]+)\0$/.exec(entry);
        requireThat(match && match[2] === selected, 'Selected path must be one committed, non-executable regular document');
        const blob = match[1];
        const size = Number(repo.text(['cat-file', '-s', blob]));
        requireThat(Number.isSafeInteger(size) && size <= MAX_DOCUMENT, 'Selected document exceeds the size limit');
        const bytes = repo.git(['cat-file', 'blob', blob]);
        return { path: selected, blob, sha256: sha256(bytes), content: utf8(bytes) };
    });
    return validatePacket({ version: 1, repository: options.repository, task: options.task, round: options.round, sourceCommit: commit, documents });
}

function packetFiles(packet, digest) {
    const files = new Map();
    const manifest = { version: 1, repository: packet.repository, task: packet.task, round: packet.round,
        sourceCommit: packet.sourceCommit, packetSha256: digest,
        documents: packet.documents.map(({ path: name, blob, sha256: hash }) => ({ path: name, blob, sha256: hash })) };
    files.set('manifest.json', Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`));
    files.set('.gitattributes', Buffer.from(ATTRIBUTES));
    const links = packet.documents.map(document => {
        const destination = `files/${document.path.split('/').map(encodeURIComponent).join('/')}`;
        const label = document.path.replace(/[\\[\]]/g, '\\$&');
        return `- [${label}](${destination})`;
    });
    files.set('README.md', Buffer.from(
        `# ${packet.task}: round ${packet.round}\n\nSource commit: \`${packet.sourceCommit}\`\n\n`
        + `These are selected committed snapshots, not a merge of the external branch.\n`
        + `Existing sandbox restrictions still apply. These briefs do not authorize changing them.\n\n`
        + `${links.join('\n')}\n\n`
        + `Original repository paths are recorded in manifest.json. Unselected references were not refreshed;\n`
        + `resolve them using their original paths rather than assuming this directory is a complete checkout.\n`));
    for (const document of packet.documents) files.set(`files/${document.path}`, Buffer.from(document.content));
    return files;
}

function safeRoundPath(repo, packet) {
    const relative = `sandbox-rounds/${packet.task}/${packet.round}`;
    let current = repo.root;
    for (const component of relative.split('/')) {
        if (exists(current)) {
            directory(current);
            requireThat(!fs.readdirSync(current).some(name => name.toLowerCase() === component.toLowerCase() && name !== component),
                'Case-colliding round directory');
        }
        current = path.join(current, component);
        const stat = exists(current);
        if (stat) requireThat(stat.isDirectory() && !stat.isSymbolicLink(), 'Round path contains a symlink or non-directory');
    }
    return { relative, absolute: current };
}

function matchFiles(root, expected) {
    directory(root);
    const actual = new Map();
    function walk(dir, prefix) {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const name = prefix ? `${prefix}/${entry.name}` : entry.name;
            requireThat(!entry.isSymbolicLink(), 'Round snapshot contains a symlink');
            if (entry.isDirectory()) walk(path.join(dir, entry.name), name);
            else {
                regular(path.join(dir, entry.name));
                requireThat(expected.has(name), 'Round snapshot contains unexpected files');
                actual.set(name, fs.readFileSync(path.join(dir, entry.name)));
            }
        }
    }
    walk(root, '');
    requireThat(actual.size === expected.size && [...expected].every(([name, bytes]) => actual.get(name)?.equals(bytes)),
        'Round ID already exists with different or modified content');
}

function writeFiles(root, files) {
    for (const [name, bytes] of files) {
        const file = path.join(root, name);
        fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o755 });
        fs.writeFileSync(file, bytes, { flag: 'wx', mode: 0o644 });
    }
}

function atomicJson(file, value) {
    atomicBytes(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}

function atomicBytes(file, bytes) {
    const temporary = `${file}.${crypto.randomUUID()}.tmp`;
    fs.writeFileSync(temporary, bytes, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, file);
}

function removeStaging(root, files, allowPartial) {
    directory(root);
    const directories = new Set();
    for (const name of files.keys()) {
        let parent = path.posix.dirname(name);
        while (parent !== '.') {
            directories.add(parent);
            parent = path.posix.dirname(parent);
        }
    }
    function inspect(dir, prefix) {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const name = prefix ? `${prefix}/${entry.name}` : entry.name;
            const file = path.join(dir, entry.name);
            requireThat(!entry.isSymbolicLink(), 'Recovery staging contains a symlink');
            if (entry.isDirectory()) {
                requireThat(directories.has(name), 'Recovery staging contains an unexpected directory');
                inspect(file, name);
            } else {
                regular(file);
                const expected = files.get(name);
                const actual = fs.readFileSync(file);
                requireThat(expected && (actual.equals(expected)
                    || (allowPartial && actual.length <= expected.length && actual.equals(expected.subarray(0, actual.length)))),
                'Recovery staging contains unexpected or changed content');
            }
        }
    }
    inspect(root, '');
    function remove(dir) {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const file = path.join(dir, entry.name);
            if (entry.isDirectory()) remove(file);
            else fs.unlinkSync(file);
        }
        fs.rmdirSync(dir);
    }
    remove(root);
}

function statePaths(state, repo) {
    directory(state);
    const real = fs.realpathSync(state);
    requireThat(!inside(repo.root, real) && !inside(real, repo.root), 'Recovery state must be outside the repository');
    requireThat((fs.statSync(real).mode & 0o077) === 0, 'Recovery state directory must be private (mode 700)');
    const files = { root: real, pending: path.join(real, 'pending.json'),
        before: path.join(real, 'before.index'), after: path.join(real, 'after.index'),
        receipt: path.join(real, 'last-import.json') };
    for (const [name, file] of Object.entries(files)) {
        if (name !== 'root' && exists(file)) regular(file);
    }
    return files;
}

function ownedLock(file, marker, afterHash) {
    if (!exists(file)) return false;
    regular(file);
    const bytes = fs.readFileSync(file);
    requireThat(bytes.equals(Buffer.from(marker)) || (afterHash && sha256(bytes) === afterHash),
        'A Git lock is not owned by this pending import; refusing to remove it');
    return true;
}

function finishJournal(state, receipt) {
    atomicJson(state.receipt, receipt);
    fs.unlinkSync(state.pending);
    for (const file of [state.before, state.after]) {
        if (exists(file)) fs.unlinkSync(file);
    }
    return receipt;
}

function assertCurrent(repo, expected) {
    repo.branch();
    requireThat(repo.head() === expected, 'Target HEAD differs from --expected-head; preview the current state again');
}

function artifact(repo, name, expression) {
    requireThat(expression.test(name), 'Invalid journal-owned artifact name');
    return path.join(repo.gitDir, name);
}

function removeArtifact(file) {
    if (exists(file)) {
        regular(file);
        fs.unlinkSync(file);
    }
}

function acquireLocks(repo, journal, resume = false) {
    const owner = artifact(repo, journal.ownerName, /^round-owner-[0-9a-f-]{36}$/);
    const marker = Buffer.from(journal.lockMarker);
    if (resume && exists(owner)) {
        regular(owner);
        const bytes = fs.readFileSync(owner);
        requireThat(bytes.length <= marker.length && bytes.equals(marker.subarray(0, bytes.length)), 'Lock owner artifact changed unexpectedly');
        atomicBytes(owner, marker);
    } else {
        fs.writeFileSync(owner, marker, { flag: 'wx', mode: 0o600 });
    }
    for (const name of ['index.lock', 'HEAD.lock']) {
        const file = path.join(repo.gitDir, name);
        if (resume && exists(file)) ownedLock(file, journal.lockMarker, name === 'index.lock' ? journal.afterHash : null);
        else fs.linkSync(owner, file);
    }
}

function releaseLocks(repo, journal) {
    const indexLock = path.join(repo.gitDir, 'index.lock');
    const headLock = path.join(repo.gitDir, 'HEAD.lock');
    if (ownedLock(indexLock, journal.lockMarker, journal.afterHash)) fs.unlinkSync(indexLock);
    if (ownedLock(headLock, journal.lockMarker)) fs.unlinkSync(headLock);
    removeArtifact(artifact(repo, journal.ownerName, /^round-owner-[0-9a-f-]{36}$/));
    removeArtifact(artifact(repo, journal.indexName, /^round-index-[0-9a-f-]{36}$/));
}

function publishIndex(repo, state, journal) {
    const prepared = artifact(repo, journal.indexName, /^round-index-[0-9a-f-]{36}$/);
    const lock = path.join(repo.gitDir, 'index.lock');
    // A terminated copy may leave this journal-owned artifact partial, never a
    // partial index.lock. Only a complete, verified index replaces the lock marker.
    removeArtifact(prepared);
    fs.copyFileSync(state.after, prepared);
    requireThat(sha256(fs.readFileSync(prepared)) === journal.afterHash, 'Prepared index checksum mismatch');
    if (!exists(lock)) {
        const owner = artifact(repo, journal.ownerName, /^round-owner-[0-9a-f-]{36}$/);
        removeArtifact(owner);
        fs.writeFileSync(owner, journal.lockMarker, { flag: 'wx', mode: 0o600 });
        fs.linkSync(owner, lock);
    }
    ownedLock(lock, journal.lockMarker, journal.afterHash);
    fs.renameSync(prepared, lock);
    fs.renameSync(lock, path.join(repo.gitDir, 'index'));
}

function reference(repo, name) {
    const value = repo.text(['for-each-ref', '--format=%(refname) %(objectname)', name]).split('\n')
        .find(line => line.startsWith(`${name} `));
    return value ? value.slice(name.length + 1) : null;
}

function clearRefLocks(repo, journal) {
    for (const [name, value] of [[journal.branch, journal.commit], [journal.checkpoint, journal.baseHead]]) {
        const file = path.join(repo.gitDir, `${name}.lock`);
        if (!exists(file)) continue;
        requireThat(['updating-refs', 'committed', 'rolling-back'].includes(journal.phase),
            'Unexpected reference lock before ref publication');
        regular(file);
        const bytes = fs.readFileSync(file);
        const intended = Buffer.from(`${value}\n`);
        requireThat(value && bytes.length <= intended.length && bytes.equals(intended.subarray(0, bytes.length)),
            'Reference lock differs from the pending update; manual inspection required');
        fs.unlinkSync(file);
    }
}

function recover(repo, state, packet, digest, options, location, files) {
    regular(state.pending);
    const journal = JSON.parse(fs.readFileSync(state.pending, 'utf8'));
    exactKeys(journal, ['version', 'packetSha256', 'branch', 'baseHead', 'commit', 'roundPath', 'stageName',
        'beforeHash', 'afterHash', 'lockMarker', 'checkpoint', 'phase', 'partialStage', 'ownerName', 'indexName'], 'recovery journal');
    requireThat(journal.version === 2 && journal.packetSha256 === digest && journal.roundPath === location.relative,
        'Recovery packet does not match the pending import');
    requireThat(OID.test(journal.baseHead) && (journal.commit === null || OID.test(journal.commit))
        && journal.branch === repo.branch() && /^round-stage-[0-9a-f-]{36}$/.test(journal.stageName)
        && /^round-import:[0-9a-f-]{36}\n$/.test(journal.lockMarker)
        && journal.checkpoint === `refs/sandbox-rounds/checkpoints/${packet.task}/${packet.round}`
        && ['preparing', 'prepared', 'updating-refs', 'committed', 'rolling-back'].includes(journal.phase)
        && typeof journal.partialStage === 'boolean',
    'Invalid recovery journal identity');
    artifact(repo, journal.ownerName, /^round-owner-[0-9a-f-]{36}$/);
    artifact(repo, journal.indexName, /^round-index-[0-9a-f-]{36}$/);
    assertCurrent(repo, options['expected-head']);
    const current = repo.head();
    requireThat([journal.baseHead, journal.commit].includes(current), 'Repository advanced beyond the interrupted import; manual inspection required');
    const backups = [[state.before, journal.beforeHash]];
    if (journal.commit !== null) backups.push([state.after, journal.afterHash]);
    for (const [file, hash] of backups) {
        regular(file);
        requireThat(sha256(fs.readFileSync(file)) === hash, 'Recovery index checksum mismatch');
    }
    const index = path.join(repo.gitDir, 'index');
    const indexHash = sha256(fs.readFileSync(index));
    requireThat([journal.beforeHash, journal.afterHash].includes(indexHash), 'Index changed after interruption; refusing to overwrite it');
    ownedLock(path.join(repo.gitDir, 'index.lock'), journal.lockMarker, journal.afterHash);
    ownedLock(path.join(repo.gitDir, 'HEAD.lock'), journal.lockMarker);
    const stage = path.join(repo.gitDir, journal.stageName);
    acquireLocks(repo, journal, true);
    clearRefLocks(repo, journal);
    const checkpoint = reference(repo, journal.checkpoint);
    requireThat(checkpoint === null || checkpoint === journal.baseHead, 'Import checkpoint changed unexpectedly');
    if (current === journal.baseHead) {
        requireThat(indexHash === journal.beforeHash, 'Pre-commit index changed unexpectedly');
        const published = exists(location.absolute);
        if (published) {
            requireThat(journal.phase !== 'preparing' && !exists(stage), 'Ambiguous snapshot publication; manual inspection required');
            matchFiles(location.absolute, files);
        }
        journal.partialStage = !published && (journal.phase === 'preparing' || journal.partialStage);
        journal.phase = 'rolling-back';
        // Validation precedes the recorded deletion phase. Retry permits missing
        // files in staging, but never changed remaining content or partial live inputs.
        atomicJson(state.pending, journal);
        if (published) fs.renameSync(location.absolute, stage);
        if (exists(stage)) removeStaging(stage, files, journal.partialStage);
        if (checkpoint) repo.git(['update-ref', '-d', journal.checkpoint, journal.baseHead]);
        releaseLocks(repo, journal);
        return finishJournal(state, { status: 'rolled-back', head: current, roundPath: location.relative, packetSha256: digest });
    }
    requireThat(journal.commit && journal.phase !== 'rolling-back', 'Unexpected committed state during rollback');
    matchFiles(location.absolute, files);
    const parents = repo.text(['cat-file', '-p', journal.commit]).split('\n').filter(line => line.startsWith('parent '));
    requireThat(parents.length === 1 && parents[0] === `parent ${journal.baseHead}`, 'Import commit has an unexpected parent');
    if (!checkpoint) repo.git(['update-ref', journal.checkpoint, journal.baseHead, '0'.repeat(journal.baseHead.length)]);
    publishIndex(repo, state, journal);
    if (exists(stage)) removeStaging(stage, files, false);
    releaseLocks(repo, journal);
    return finishJournal(state, { status: 'completed', head: current, baseHead: journal.baseHead,
        roundPath: location.relative, packetSha256: digest });
}

function importPacket(repo, options) {
    const { packet, digest } = loadPacket(options.packet, options.repository);
    requireThat(!inside(repo.root, fs.realpathSync(options.packet)), 'Input packet must be outside the target repository');
    const state = statePaths(options.state, repo);
    const location = safeRoundPath(repo, packet);
    const files = packetFiles(packet, digest);
    if (options.mode === 'recover') return recover(repo, state, packet, digest, options, location, files);
    requireThat(!exists(state.pending), `Pending import requires recover with the original packet; current HEAD is ${repo.head()}`);
    const branch = repo.branch();
    const head = repo.head();
    repo.assertClean();
    if (options.mode === 'apply') assertCurrent(repo, options['expected-head']);
    const base = { head, branch, packetSha256: digest, roundPath: location.relative,
        sourceCommit: packet.sourceCommit, documents: packet.documents.map(document => `files/${document.path}`) };
    if (exists(location.absolute)) {
        matchFiles(location.absolute, files);
        return { status: 'already-imported', ...base };
    }
    const checkpoint = `refs/sandbox-rounds/checkpoints/${packet.task}/${packet.round}`;
    const existingRefs = repo.text(['for-each-ref', '--format=%(refname)', checkpoint]);
    requireThat(!existingRefs, 'Round ID already has a checkpoint; choose a new round ID');
    if (options.mode === 'preview') {
        assertCurrent(repo, head);
        return { status: 'ready', ...base };
    }
    const name = repo.config('user.name');
    const email = repo.config('user.email');
    requireThat(name && email && !/[\x00-\x1f\x7f<>]/.test(name + email), 'Target needs valid per-repository user.name and user.email; no identity will be invented');
    const marker = `round-import:${crypto.randomUUID()}\n`;
    const stageName = `round-stage-${crypto.randomUUID()}`;
    const stage = path.join(repo.gitDir, stageName);
    const ownerName = `round-owner-${crypto.randomUUID()}`;
    const before = fs.readFileSync(path.join(repo.gitDir, 'index'));
    atomicBytes(state.before, before);
    const journal = { version: 2, packetSha256: digest, branch, baseHead: head, commit: null,
        roundPath: location.relative, stageName, beforeHash: sha256(before), afterHash: null,
        lockMarker: marker, checkpoint, phase: 'preparing', partialStage: true, ownerName,
        indexName: `round-index-${crypto.randomUUID()}` };
    // Publish recovery intent before any persistent Git lock or staged workspace data.
    atomicJson(state.pending, journal);
    try {
        acquireLocks(repo, journal);
        assertCurrent(repo, head);
        requireThat(fs.readFileSync(path.join(repo.gitDir, 'index')).equals(fs.readFileSync(path.join(repo.control, 'index'))),
            'Index changed after preview');
        repo.assertClean(true);
        fs.mkdirSync(stage, { mode: 0o755 });
        writeFiles(stage, files);
        for (const [relative, bytes] of files) {
            const blob = repo.text(['hash-object', '-w', '--no-filters', '--stdin'], bytes);
            repo.git(['update-index', '--add', '--cacheinfo', `100644,${blob},${location.relative}/${relative}`]);
        }
        const tree = repo.text(['write-tree']);
        const message = `Import ${packet.task} review round ${packet.round}\n\n`
            + `Source-commit: ${packet.sourceCommit}\nRound-packet-sha256: ${digest}\n`;
        const commit = repo.text(['commit-tree', tree, '-p', head], message,
            { GIT_AUTHOR_NAME: name, GIT_AUTHOR_EMAIL: email, GIT_COMMITTER_NAME: name, GIT_COMMITTER_EMAIL: email });
        requireThat(OID.test(commit), 'Git did not create a valid import commit');
        atomicBytes(state.after, fs.readFileSync(path.join(repo.control, 'index')));
        journal.commit = commit;
        journal.afterHash = sha256(fs.readFileSync(state.after));
        journal.phase = 'prepared';
        journal.partialStage = false;
        atomicJson(state.pending, journal);
        fs.mkdirSync(path.dirname(location.absolute), { recursive: true, mode: 0o755 });
        safeRoundPath(repo, packet);
        requireThat(!exists(location.absolute), 'Round destination appeared during import');
        fs.renameSync(stage, location.absolute);
        assertCurrent(repo, head);
        journal.phase = 'updating-refs';
        atomicJson(state.pending, journal);
        // Individual Git refs are atomic, not a crash-atomic multi-ref transaction.
        // Establish the checkpoint first and reconcile either partial outcome in recover.
        repo.git(['update-ref', checkpoint, head, '0'.repeat(head.length)]);
        repo.git(['update-ref', branch, commit, head]);
        journal.phase = 'committed';
        atomicJson(state.pending, journal);
        publishIndex(repo, state, journal);
        releaseLocks(repo, journal);
        return finishJournal(state, { status: 'imported', ...base, head: commit, baseHead: head, checkpoint });
    } catch (error) {
        if (exists(state.pending)) error.message += `; pending import retained: recover with the same packet and --expected-head ${repo.head()}`;
        throw error;
    }
}

function main(argv) {
    requireThat(process.platform === 'linux', 'Run the helper inside the maintenance container');
    const options = parseArgs([...argv]);
    const repo = new Repository(options.root);
    try {
        return options.mode === 'export' ? exportPacket(repo, options) : importPacket(repo, options);
    } finally {
        repo.close();
    }
}

if (require.main === module) {
    try {
        process.stdout.write(`${JSON.stringify(main(process.argv.slice(2)), null, 2)}\n`);
    } catch (error) {
        process.stderr.write(`[rounds] ERROR: ${error.message}\n`);
        process.exitCode = 1;
    }
}

module.exports = { main, validatePacket, packetFiles, sha256 };

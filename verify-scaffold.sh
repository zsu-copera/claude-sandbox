#!/bin/bash
# Host-side static assertions for the sandbox scaffold — the S-series of VERIFY-ASSERTIONS.md.
#
#   ./verify-scaffold.sh            # run everything
#   ./verify-scaffold.sh -v         # also print detail for passing assertions
#
# Runs on the Windows host (Git Bash or WSL) against this directory. No container, no network,
# no build. This is the check to run after every edit, and the one that makes the scaffold
# iterable by an agent that cannot run the container.
#
# Runtime is dominated by process creation, not work: roughly 25s under Git Bash against ~1.5s
# of actual CPU. If that becomes annoying, the fix is fewer subprocesses, not fewer assertions.
#
# Deliberately NOT `set -e`: assertions are independent and all of them should run, so failures
# are collected and reported at the end. `set -u` is on; pipelines are written to tolerate the
# no-match exit status of grep.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

VERBOSE=0
[ "${1:-}" = "-v" ] || [ "${1:-}" = "--verbose" ] && VERBOSE=1

if [ -t 1 ]; then
    C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_WARN=$'\033[33m'
    C_SKIP=$'\033[90m'; C_OFF=$'\033[0m'; C_DIM=$'\033[2m'
else
    C_PASS=""; C_FAIL=""; C_WARN=""; C_SKIP=""; C_OFF=""; C_DIM=""
fi

N_PASS=0; N_FAIL=0; N_WARN=0; N_SKIP=0
FAILED_IDS=()

pass() { N_PASS=$((N_PASS+1)); printf '%sPASS%s  %-4s %s\n' "$C_PASS" "$C_OFF" "$1" "$2"
         [ "$VERBOSE" = 1 ] && [ -n "${3:-}" ] && printf '        %s%s%s\n' "$C_DIM" "$3" "$C_OFF"; return 0; }
fail() { N_FAIL=$((N_FAIL+1)); FAILED_IDS+=("$1"); printf '%sFAIL%s  %-4s %s\n' "$C_FAIL" "$C_OFF" "$1" "$2"
         [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^ */        /'; return 0; }
warn() { N_WARN=$((N_WARN+1)); printf '%sWARN%s  %-4s %s\n' "$C_WARN" "$C_OFF" "$1" "$2"
         [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^ */        /'; return 0; }
skip() { N_SKIP=$((N_SKIP+1)); printf '%sSKIP%s  %-4s %s\n' "$C_SKIP" "$C_OFF" "$1" "$2"
         printf '        %s%s%s\n' "$C_DIM" "${3:-no reason given — this is itself a defect}" "$C_OFF"; return 0; }

# --- helpers -----------------------------------------------------------------------------

# Count CR (0x0d) bytes. Neither `grep -c $'\r'` nor file(1) can be trusted here: the former
# matches every line in some Git Bash builds, the latter omits its CRLF note in others. Count
# bytes and nothing else.
has_cr()   { ! tr -d '\015' < "$1" 2>/dev/null | cmp -s - "$1"; }
cr_bytes() { od -An -tx1 -v "$1" 2>/dev/null | tr -s ' ' '\n' | grep -c '^0d$'; }

# Tracked text files by extension, via git when available so .gitignore is honoured.
list_files() {
    local pat="$1"
    if git rev-parse --git-dir >/dev/null 2>&1; then
        # --others --exclude-standard so a newly written, not-yet-staged file is still checked.
        # Without it a new script escapes S1/S2 until someone remembers to `git add` it, which
        # is precisely when a CRLF or a syntax error would slip through.
        git ls-files --cached --others --exclude-standard -- "$pat" 2>/dev/null | sort -u
    else
        find . -type f -path "./$pat" -not -path "./.git/*" 2>/dev/null | sed 's|^\./||'
    fi
}

# Compute the file lists ONCE. Each list_files call spawns git, and on Git Bash process
# creation dominates the runtime — recomputing these per assertion cost ~60s.
SHELL_SCRIPTS=$(list_files '*.sh')
TEXT_FILES=$(printf '%s\n%s\n%s\n%s\n%s\n' \
    "$SHELL_SCRIPTS" "$(list_files '*.json')" "$(list_files '*.md')" "$(list_files '*.ps1')" "$(list_files '*.js')" \
    | grep -v '^$'; echo .devcontainer/Dockerfile; echo dockerignore)

# Files that assertions may grep for forbidden constructs. Excluded: the docs that quote those
# constructs in order to prohibit them, and this script, which names every pattern it hunts for.
# Without this the verifier fails its own S7 and S14 on its own PASS messages.
SELF_REFERENTIAL='^(AGENTS\.md|VERIFY-ASSERTIONS\.md|verify-scaffold\.sh|\.gitattributes|\.gitignore)$'
SCAN_FILES=$(echo "$TEXT_FILES"     | grep -vE "$SELF_REFERENTIAL")
SCAN_SH=$(echo "$SHELL_SCRIPTS"     | grep -vE "$SELF_REFERENTIAL")

# JSON parser: jq if present, else node (the host has node), else nothing.
JSON_TOOL=""
command -v jq   >/dev/null 2>&1 && JSON_TOOL="jq"
[ -z "$JSON_TOOL" ] && command -v node >/dev/null 2>&1 && JSON_TOOL="node"

json_valid() {
    case "$JSON_TOOL" in
        jq)   jq empty "$1" >/dev/null 2>&1 ;;
        node) node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$1" >/dev/null 2>&1 ;;
        *)    return 2 ;;
    esac
}

# Read a value out of a JSON file. $2 is a jq path; the node fallback takes the same dotted path.
json_get() {
    case "$JSON_TOOL" in
        jq)   jq -r "$2" "$1" 2>/dev/null ;;
        node) node -e '
                const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
                const v=process.argv[2].replace(/^\./,"").split(".").reduce((a,k)=>a==null?a:a[k],o);
                console.log(v===undefined||v===null?"null":(typeof v==="object"?JSON.stringify(v):v));
              ' "$1" "$2" 2>/dev/null ;;
        *)    return 2 ;;
    esac
}

# Evaluate a boolean over a JSON file: $2 for jq, $3 as a JavaScript expression over `o`.
# Both are given because the Windows host usually has node and no jq.
json_ok() {
    case "$JSON_TOOL" in
        jq)   [ "$(jq -r "$2" "$1" 2>/dev/null)" = true ] ;;
        node) node -e '
                const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
                process.exit(eval(process.argv[2]) === true ? 0 : 1);
              ' "$1" "$3" >/dev/null 2>&1 ;;
        *)    return 2 ;;
    esac
}

# Strip JSONC comments without touching comment-like sequences inside strings.
jsonc_valid() {
    [ "$JSON_TOOL" = "node" ] || command -v node >/dev/null 2>&1 || return 2
    node -e '
        const src = require("fs").readFileSync(process.argv[1], "utf8");
        let out = "", inStr = false, esc = false, i = 0;
        while (i < src.length) {
            const c = src[i], d = src[i+1];
            if (inStr) {
                out += c;
                if (esc) esc = false; else if (c === "\\") esc = true; else if (c === "\"") inStr = false;
                i++; continue;
            }
            if (c === "\"") { inStr = true; out += c; i++; continue; }
            if (c === "/" && d === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
            if (c === "/" && d === "*") { i += 2; while (i < src.length && !(src[i] === "*" && src[i+1] === "/")) i++; i += 2; continue; }
            out += c; i++;
        }
        JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
    ' "$1" >/dev/null 2>&1
}

# Line number of the first match, or empty.
line_of() { grep -n -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

# Code only — drop whole-line comments. Any assertion that greps source for a forbidden or
# required construct MUST go through this: these files document their own rules in prose right
# next to the code, so "NOPASSWD:ALL would make the agent root" in a comment otherwise reads as
# a NOPASSWD:ALL. Same failure mode S7 avoids by excluding the docs that quote its patterns.
code_only() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null; }

echo
echo "verify-scaffold.sh — static assertions (S-series), $(date +%Y-%m-%d)"
echo "$(pwd)"
echo

# --- S1  line endings ---------------------------------------------------------------------
# .gitattributes pins everything in this repo to LF, so check every text file, not just the
# scripts. container/*.sh get \r-stripped by the Dockerfile; new-sandbox.sh does not.
s1_bad=""
for f in $TEXT_FILES; do
    [ -f "$f" ] || continue
    # tr|cmp rather than od|tr|grep: same byte-exact answer, a fraction of the work. The count
    # is only computed for a file that actually fails, for the report.
    has_cr "$f" && s1_bad="$s1_bad $f($(cr_bytes "$f"))"
done
if [ -z "$s1_bad" ]; then
    pass S1 "LF line endings everywhere (zero CR bytes)"
else
    fail S1 "CR bytes found — CRLF breaks bash and the container build" "offending:$s1_bad"
fi

# --- S2  shell syntax ---------------------------------------------------------------------
s2_bad=""
for f in $SHELL_SCRIPTS; do bash -n "$f" 2>/dev/null || s2_bad="$s2_bad $f"; done
[ -z "$s2_bad" ] && pass S2 "every *.sh parses (bash -n)" \
                 || fail S2 "shell syntax error" "offending:$s2_bad"

# --- S3  shellcheck -----------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    s3_bad=""
    for f in $SHELL_SCRIPTS; do shellcheck -S error "$f" >/dev/null 2>&1 || s3_bad="$s3_bad $f"; done
    [ -z "$s3_bad" ] && pass S3 "shellcheck clean at error severity" \
                     || warn S3 "shellcheck reports errors" "offending:$s3_bad — run: shellcheck$s3_bad"
else
    skip S3 "shellcheck" "not installed on this host; install it to enable this assertion"
fi

# --- S4  Dockerfile COPY sources exist ----------------------------------------------------
s4_bad=""
while read -r src; do
    [ -n "$src" ] || continue
    # container/certs/ is generated per machine by new-sandbox.sh into the assembled sandbox,
    # never into the scaffold. Its absence here is correct — the build runs from the sandbox root.
    [ "$src" = "container/certs/" ] && continue
    [ -e "$src" ] || s4_bad="$s4_bad $src"
done < <(grep -E '^COPY[[:space:]]+container/' .devcontainer/Dockerfile 2>/dev/null | awk '{print $2}')
[ -z "$s4_bad" ] && pass S4 "every Dockerfile COPY source exists" \
                 || fail S4 "Dockerfile COPYs a file that is not here — the build will fail" "missing:$s4_bad"

# --- S5  sed/chmod lists match the COPY list ----------------------------------------------
s5_bad=""
copy_dests=$(grep -E '^COPY[[:space:]]+container/.*\.sh' .devcontainer/Dockerfile 2>/dev/null | awk '{print $3}')
sed_chmod=$(grep -A4 -E "^RUN sed -i 's/" .devcontainer/Dockerfile 2>/dev/null)
for d in $copy_dests; do
    echo "$sed_chmod" | grep -qF "$d" || s5_bad="$s5_bad $d"
done
if [ -z "$copy_dests" ]; then
    warn S5 "could not parse the Dockerfile COPY destinations" "the parse assumption changed; re-check S5 by hand"
elif [ -z "$s5_bad" ]; then
    pass S5 "every copied script is \\r-stripped and chmod'd"
else
    fail S5 "a copied script is missing from the sed/chmod list" "unlisted:$s5_bad"
fi

# --- S6  what new-sandbox.sh needs --------------------------------------------------------
s6_bad=""
for p in overlay/CLAUDE.md container/claude-project-settings.json .devcontainer container dockerignore; do
    [ -e "$p" ] || s6_bad="$s6_bad $p"
done
[ -z "$s6_bad" ] && pass S6 "everything new-sandbox.sh copies is present" \
                 || fail S6 "new-sandbox.sh would fail — a source path is missing" "missing:$s6_bad"

# --- S7  no personal paths or names -------------------------------------------------------
# Scanned: the operational files and the human-facing docs. Excluded: AGENTS.md,
# VERIFY-ASSERTIONS.md, this script, .gitattributes and .gitignore — all of which quote these
# patterns in order to prohibit them, and would otherwise trip their own rule.
s7_hits=$(grep -nE '/home/su\b|Users/su\b|zsu@|:-Zhan\}' $SCAN_FILES 2>/dev/null | sed 's/^/    /')
if [ -z "$s7_hits" ]; then
    pass S7 "no hardcoded personal path or name"
else
    fail S7 "hardcoded personal path or name (findings I1/I2/I3)" \
            "$s7_hits
        Expected to fail until I1/I2/I3 are fixed; this is their regression test."
fi

# --- S8/S9  JSON validity ------------------------------------------------------------------
if [ -z "$JSON_TOOL" ]; then
    skip S8 "JSON validity" "neither jq nor node is available on this host"
    skip S9 "devcontainer.json (JSONC) validity" "node is required to strip comments safely"
else
    s8_bad=""
    for f in container/claude-managed-settings.json container/claude-project-settings.json \
             container/copilot-settings.json container/copilot-policy.json; do
        [ -f "$f" ] || { s8_bad="$s8_bad $f(missing)"; continue; }
        json_valid "$f" || s8_bad="$s8_bad $f"
    done
    [ -z "$s8_bad" ] && pass S8 "shipped JSON parses" "via $JSON_TOOL" \
                     || fail S8 "invalid JSON" "offending:$s8_bad"

    # devcontainer.json contains // comments. A plain `jq empty` here is a FALSE failure.
    if jsonc_valid .devcontainer/devcontainer.json; then
        pass S9 "devcontainer.json parses as JSONC"
    elif [ $? = 2 ]; then
        skip S9 "devcontainer.json (JSONC) validity" "node required to strip comments safely"
    else
        fail S9 "devcontainer.json is not valid JSONC"
    fi
fi

# --- S10  Claude's mandatory policy still declares the guardrails ---------------------------
# Moved from the overlay's project settings to the managed file in Phase 3 (E2/E3, approved
# 2026-09-24): project settings are agent-writable and their lists merge, so the guardrails
# must live where only root can write and where the CLI gives them precedence.
if [ -z "$JSON_TOOL" ]; then
    skip S10 "managed settings guardrails" "no JSON tool available"
else
    m=container/claude-managed-settings.json
    s10_bad=""
    chk() { json_ok "$m" "$2" "$3" || s10_bad="$s10_bad $1"; }
    chk sandbox.enabled          '.sandbox.enabled == true'                   'o.sandbox.enabled === true'
    chk failIfUnavailable        '.sandbox.failIfUnavailable == true'         'o.sandbox.failIfUnavailable === true'
    chk allowUnsandboxedCommands '.sandbox.allowUnsandboxedCommands == false' 'o.sandbox.allowUnsandboxedCommands === false'
    chk no-excludedCommands      '(.sandbox.excludedCommands // []) == []'    '(o.sandbox.excludedCommands || []).length === 0'
    chk weaker-off \
        '.sandbox.enableWeakerNestedSandbox == false and .sandbox.enableWeakerNetworkIsolation == false' \
        'o.sandbox.enableWeakerNestedSandbox === false && o.sandbox.enableWeakerNetworkIsolation === false'
    # Java ignores $TMPDIR, so java.io.tmpdir stays /tmp and the WAR assembly needs it writable.
    chk allowWrite-tmp '.sandbox.filesystem.allowWrite == ["/tmp"]' \
        'JSON.stringify(o.sandbox.filesystem.allowWrite) === JSON.stringify(["/tmp"])'
    chk managed-domains-only '.sandbox.network.allowManagedDomainsOnly == true' \
        'o.sandbox.network.allowManagedDomainsOnly === true'
    for k in allowManagedPermissionRulesOnly allowManagedHooksOnly allowManagedMcpServersOnly; do
        chk "$k" ".$k == true" "o.$k === true"
    done
    chk bwrapPath '.sandbox.bwrapPath == "/usr/bin/bwrap"' 'o.sandbox.bwrapPath === "/usr/bin/bwrap"'
    chk strictAllowlist '.sandbox.network.strictAllowlist == true' 'o.sandbox.network.strictAllowlist === true'
    chk managed-read-paths-only '.sandbox.filesystem.allowManagedReadPathsOnly == true' \
        'o.sandbox.filesystem.allowManagedReadPathsOnly === true'
    chk no-marketplaces '.strictKnownMarketplaces == []' \
        'Array.isArray(o.strictKnownMarketplaces) && o.strictKnownMarketplaces.length === 0'
    chk allowedMcpServers-empty '.allowedMcpServers == []' \
        'Array.isArray(o.allowedMcpServers) && o.allowedMcpServers.length === 0'
    for rule in 'Bash(git push)' 'Bash(git push *)' 'Read(//workspace/.secrets/**)' \
                'Read(//home/vscode/.claude/**)' 'Edit(//workspace/.claude/**)' 'Edit(//home/vscode/.claude/**)' \
                'Edit(//workspace/.mcp.json)' 'WebFetch' 'WebSearch'; do
        chk "deny:$rule" "any(.permissions.deny[]; . == \"$rule\")" "o.permissions.deny.includes(\"$rule\")"
    done
    # Sessions run in bypass mode by design; a lock here would stop every launch.
    chk no-bypass-lock '.permissions.disableBypassPermissionsMode == null' \
        'o.permissions.disableBypassPermissionsMode === undefined'
    # The project file is exactly this. Its deny rules and sandbox lists repeat the managed
    # ones, so a workspace run on an image without the managed policy is no weaker than
    # before Phase 3; on a Phase 3 image they are inert (managed scalars win, managed-only
    # locks ignore project rules and domains). Anything else would merge into the managed
    # policy, and run-agent compares the workspace copy byte for byte with the baked one.
    json_ok container/claude-project-settings.json \
        '. == {"permissions":{"defaultMode":"bypassPermissions","deny":["Bash(git push)","Bash(git push *)","Read(//workspace/.secrets/**)","Read(//home/vscode/.claude/**)"]},"sandbox":{"enabled":true,"filesystem":{"allowWrite":["/tmp"]},"network":{"allowedDomains":["api.anthropic.com"]}}}' \
        'JSON.stringify(o) === JSON.stringify({permissions:{defaultMode:"bypassPermissions",deny:["Bash(git push)","Bash(git push *)","Read(//workspace/.secrets/**)","Read(//home/vscode/.claude/**)"]},sandbox:{enabled:true,filesystem:{allowWrite:["/tmp"]},network:{allowedDomains:["api.anthropic.com"]}}})' \
        || s10_bad="$s10_bad project-settings-changed"
    # The whole managed file, too: the checks above name the guardrails, but a widened list
    # (allowedDomains, allowWrite, an extra key) must also fail. Changing the policy means
    # changing this line in the same reviewed diff.
    m_expected='{"permissions":{"deny":["Bash(git push)","Bash(git push *)","Read(//workspace/.secrets/**)","Read(//home/vscode/.claude/**)","Edit(//home/vscode/.claude/**)","Edit(//workspace/.claude/**)","Edit(//workspace/.mcp.json)","WebFetch","WebSearch"]},"allowManagedPermissionRulesOnly":true,"allowManagedHooksOnly":true,"allowManagedMcpServersOnly":true,"allowedMcpServers":[],"strictKnownMarketplaces":[],"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"bwrapPath":"/usr/bin/bwrap","enableWeakerNestedSandbox":false,"enableWeakerNetworkIsolation":false,"filesystem":{"allowWrite":["/tmp"],"allowManagedReadPathsOnly":true},"network":{"allowedDomains":["api.anthropic.com"],"allowManagedDomainsOnly":true,"strictAllowlist":true}}}'
    case "$JSON_TOOL" in
        jq)   m_actual=$(jq -c . "$m" 2>/dev/null) ;;
        node) m_actual=$(node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))))' "$m" 2>/dev/null) ;;
    esac
    [ "$m_actual" = "$m_expected" ] || s10_bad="$s10_bad managed-file-differs-from-reviewed-policy"
    unset -f chk
    [ -z "$s10_bad" ] && pass S10 "managed policy requires the sandbox, locks lower scopes, keeps deny rules and /tmp" \
                      || fail S10 "a guardrail was removed from the managed policy or project settings" "missing/changed:$s10_bad"
fi

# --- S11  one-way state and staged updates (source structure, not runtime proof) ------------
firewall=container/init-firewall.sh
open_block=$(sed -n '/^if \[ "\$MODE" = open \]; then/,/^fi$/p' "$firewall")
state_block=$(sed -n '/^has_state()/,/^}/p' "$firewall")
restricted_code=$(sed '/^if \[ "\$MODE" = open \]; then/,/^fi$/d' "$firewall" | grep -vE '^[[:space:]]*#')
l_lock=$(line_of "$firewall" '^flock -w 30 9$')
l_open=$(line_of "$firewall" '^if \[ "\$MODE" = open \]; then$')
if [ -n "$l_lock" ] && [ -n "$l_open" ] && [ "$l_lock" -lt "$l_open" ] \
    && echo "$open_block" | grep -q 'if has_state; then' \
    && echo "$open_block" | grep -q 'exit 3' \
    && echo "$state_block" | grep -Fq '[ -e "$COMMITTED" ]' \
    && echo "$state_block" | grep -Fq '[ -e "$PENDING" ]' \
    && echo "$state_block" | grep -Fq '($MARKER|$DISPATCH)' \
    && ! echo "$restricted_code" | grep -Eq 'iptables -P [A-Z]+ ACCEPT|iptables -F$|iptables -X' \
    && echo "$restricted_code" | grep -Fq 'ipset swap "${IPSET}-new" "$IPSET"' \
    && echo "$restricted_code" | grep -Fq 'iptables -R "$DISPATCH" 1 -j "$NEXT"'; then
    pass S11 "source declares serialized one-way guards and staged firewall updates" \
             "Behavior, interruption and concurrency require verify-firewall.sh."
else
    fail S11 "one-way guards, serialization or staged-update source structure is missing"
fi

# --- S12  sticky allowlist -----------------------------------------------------------------
if grep -Fxq 'COMMITTED=/run/claude-lockdown-domains' "$firewall" \
    && grep -Fxq 'umask 077' "$firewall" \
    && grep -Fq 'printf ' "$firewall" \
    && grep -Fq '"${DOMAINS[@]}" > "$PENDING"' "$firewall" \
    && grep -Fq 'mv -T "$PENDING" "$COMMITTED"' "$firewall" \
    && grep -Fq 'mapfile -t COMMITTED_DOMAINS < "$COMMITTED"' "$firewall" \
    && grep -Fq 'DOMAINS=("${COMMITTED_DOMAINS[@]}")' "$firewall"; then
    pass S12 "source stages a private domain record, publishes it and reuses the pinned list"
else
    fail S12 "private domain publication or sticky-allowlist source structure is missing"
fi

# --- S13  capabilities dropped before the agent starts -------------------------------------
s13_bad=""
for f in container/run-agent.sh container/run-copilot.sh; do
    grep -q 'setpriv --inh-caps=-all --ambient-caps=-all' "$f" 2>/dev/null || s13_bad="$s13_bad $f"
done
[ -z "$s13_bad" ] && pass S13 "both entrypoints drop capabilities before exec'ing the agent" \
                  || fail S13 "capability drop missing — breaks bubblewrap AND leaves the agent CAP_NET_ADMIN" "offending:$s13_bad"

# --- S14  sudo call sites use the absolute path --------------------------------------------
# One grep across all scripts, then drop comment lines and correct call sites. grep -n over
# multiple files emits file:line:content, so the content is everything after the second colon.
s14_bad=$(grep -nE '(^|[[:space:];&|(])sudo[[:space:]]' $SCAN_SH 2>/dev/null | awk '
    { c = $0; sub(/^[^:]*:[0-9]+:/, "", c)
      if (c ~ /^[[:space:]]*#/) next
      if (c ~ /sudo \/usr\/local\/bin\/init-firewall\.sh/) next
      print "    " $0 }')
[ -z "$s14_bad" ] && pass S14 "every sudo call site uses the absolute init-firewall.sh path" \
                  || fail S14 "sudo call site not using the absolute path (secure_path excludes /usr/local/bin)" "$s14_bad"

# --- S15  sudoers scoped, not ALL ----------------------------------------------------------
dockerfile_code=$(code_only .devcontainer/Dockerfile)
if echo "$dockerfile_code" | grep -q 'NOPASSWD:[[:space:]]*/usr/local/bin/init-firewall\.sh' \
   && ! echo "$dockerfile_code" | grep -qE 'NOPASSWD:[[:space:]]*ALL'; then
    pass S15 "sudo is scoped to init-firewall.sh, not ALL"
else
    fail S15 "sudoers is not scoped — NOPASSWD:ALL makes the agent effectively root" \
             "note the Dockerfile explains this rule in a comment; S15 reads code only"
fi

# --- S16  purge happens, and after lockdown ------------------------------------------------
s16_bad=""
for f in container/run-agent.sh container/run-copilot.sh; do
    l_lock=$(line_of "$f" 'init-firewall.sh lockdown')
    l_purge=$(line_of "$f" 'rm -rf "\$WS/.secrets"')
    if [ -z "$l_lock" ] || [ -z "$l_purge" ]; then
        s16_bad="$s16_bad $f(missing)"
    elif [ "$l_purge" -lt "$l_lock" ]; then
        s16_bad="$s16_bad $f(purge-before-lockdown)"
    fi
done
[ -z "$s16_bad" ] && pass S16 "credentials are purged, and only after the firewall is up" \
                  || fail S16 "credential purge missing or out of order" "offending:$s16_bad"

# --- S17  offline cache fix ----------------------------------------------------------------
l_mvn=$(line_of container/prepare.sh '^mvn clean install')
l_strip=$(line_of container/prepare.sh '_remote.repositories')
if [ -n "$l_mvn" ] && [ -n "$l_strip" ] && [ "$l_strip" -gt "$l_mvn" ]; then
    pass S17 "prepare.sh strips _remote.repositories after warming"
else
    fail S17 "the offline-cache fix is missing or runs before the warm-up" \
             "without it the warmed cache is present but unusable offline — the original blocking defect"
fi

# --- S18  Copilot tool-layer barrier -------------------------------------------------------
s18_bad=""
for flag in -- '--disable-builtin-mcps' "--deny-tool='shell(git push)'" \
                "--deny-tool='shell(git remote)'" "--deny-tool='shell(gh)'" '--deny-url=github.com'; do
    [ "$flag" = "--" ] && continue
    grep -qF -- "$flag" container/run-copilot.sh 2>/dev/null || s18_bad="$s18_bad $flag"
done
for forbidden in '--allow-all-paths' '--allow-all-urls'; do
    grep -qE -- "^[^#]*$forbidden" container/run-copilot.sh 2>/dev/null && s18_bad="$s18_bad +$forbidden"
done
[ -z "$s18_bad" ] && pass S18 "Copilot deny flags present; no --allow-all-paths/--allow-all-urls" \
                  || fail S18 "the Copilot tool-layer barrier changed" \
                              "missing/added:$s18_bad
        This is the barrier compensating for GitHub's IP ranges being reachable in Copilot sessions."

# --- S19  node version map covers the poms -------------------------------------------------
if [ -d ../prj ]; then
    s19_bad=""
    # Ask git for the tracked poms rather than walking the tree: a recursive grep over ../prj
    # descends node_modules, target/ and .angular/ and dominated this script's runtime.
    prj_poms=$(git -C ../prj ls-files '*pom.xml' 2>/dev/null | sed 's|^|../prj/|')
    [ -z "$prj_poms" ] && prj_poms=$(find ../prj -maxdepth 3 -name pom.xml \
        -not -path '*/node_modules/*' -not -path '*/target/*' 2>/dev/null)
    for v in $(grep -ho '<nodeVersion>v[0-9.]*</nodeVersion>' $prj_poms 2>/dev/null \
               | sed 's/<[^>]*>//g' | sort -u); do
        grep -q "\[$v\]" container/prepare.sh || s19_bad="$s19_bad $v"
    done
    [ -z "$s19_bad" ] && pass S19 "NPM_FOR covers every nodeVersion pinned in the prj poms" \
                      || warn S19 "a pom pins a node version with no bundled-npm mapping" \
                                  "unmapped:$s19_bad — extend NPM_FOR in prepare.sh or prepare will exit 1"
else
    skip S19 "node version map vs poms" "../prj not present next to this scaffold"
fi

# --- S20  version identity -----------------------------------------------------------------
if [ -f VERSION ]; then
    v=$(tr -d '[:space:]' < VERSION)
    if grep -q "$v" container/run-agent.sh 2>/dev/null; then
        pass S20 "VERSION exists and the entrypoint banner matches" "$v"
    else
        warn S20 "VERSION exists but the entrypoint banner does not print it" "VERSION=$v"
    fi
else
    skip S20 "version identity" "no VERSION file yet (finding D3)"
fi

# --- S21  no staged credentials ------------------------------------------------------------
s21_bad=""
[ -e .secrets ] && s21_bad="$s21_bad .secrets/"
for f in $(find . -maxdepth 3 -name 'settings.xml' -o -maxdepth 3 -name 'npmrc' -o -maxdepth 3 -name '.npmrc' 2>/dev/null | grep -v '^./.git/'); do
    s21_bad="$s21_bad $f"
done
[ -z "$s21_bad" ] && pass S21 "no credential material staged in the scaffold" \
                  || fail S21 "credential material present in the scaffold directory" "found:$s21_bad"

# --- S22  README documents every shipped file ----------------------------------------------
s22_bad=""
for f in container/*; do
    b=$(basename "$f")
    grep -qF "$b" README.md 2>/dev/null || s22_bad="$s22_bad $b"
done
[ -z "$s22_bad" ] && pass S22 "README's Files table mentions every container/ file" \
                  || warn S22 "a shipped file is undocumented in README" "undocumented:$s22_bad"

# --- S23  no corporate CAs committed --------------------------------------------------------
if [ ! -d container/certs ] || [ -z "$(ls -A container/certs 2>/dev/null)" ]; then
    pass S23 "container/certs is absent or empty"
else
    warn S23 "container/certs contains files" \
             "corporate root CAs are machine-specific and gitignored; confirm they are untracked"
fi

# --- S24  Copilot policy-hook chain ---------------------------------------------------------
# This is the tool-layer control that actually holds. run-copilot.sh starts the CLI with
# --allow-all-tools, and --deny-tool matches a command-identifier PREFIX, so `git -C . push`
# and `env git push` walk straight past it (measured 2026-09-09 against v1.0.83). The policy
# hook matches the whole command string and is root-owned, so the agent cannot remove it.
#
# Every link below fails SILENTLY and OPEN, which is why they are asserted rather than trusted:
# the CLI ignores a policy file that is not root-owned or that is group/world-writable without
# reporting it, and a policy file it cannot parse simply does not load.
s24_bad=""
guard_dest=$(grep -E '^COPY[[:space:]]+container/guard-shell-command\.js' .devcontainer/Dockerfile 2>/dev/null | awk '{print $3}')
policy_dest=$(grep -E '^COPY[[:space:]]+container/copilot-policy\.json' .devcontainer/Dockerfile 2>/dev/null | awk '{print $3}')

[ -f container/guard-shell-command.js ] || s24_bad="$s24_bad guard-file-missing"
[ -f container/copilot-policy.json ]    || s24_bad="$s24_bad policy-file-missing"
[ -n "$guard_dest" ]                    || s24_bad="$s24_bad guard-not-COPYd"
[ -n "$policy_dest" ]                   || s24_bad="$s24_bad policy-not-COPYd"

# Anywhere other than policy.d and it is ordinary user config the agent can disable.
case "$policy_dest" in
    /etc/github-copilot/policy.d/*) : ;;
    *) s24_bad="$s24_bad policy-dest($policy_dest)" ;;
esac

# Ownership and mode are a POSIX requirement for policy files, not hygiene.
grep -q 'chown root:root' .devcontainer/Dockerfile 2>/dev/null || s24_bad="$s24_bad no-chown-root"
grep -qE 'chmod 0644 .*policy\.d' .devcontainer/Dockerfile 2>/dev/null || s24_bad="$s24_bad no-chmod-0644"

# The registration must name the path the Dockerfile actually installs, or the hook is a no-op.
if [ -n "$guard_dest" ] && ! grep -qF "$guard_dest" container/copilot-policy.json 2>/dev/null; then
    s24_bad="$s24_bad policy-points-elsewhere"
fi

# The rule that closes the --deny-tool gap, and the event it must be registered on.
grep -q 'git-push' container/guard-shell-command.js 2>/dev/null || s24_bad="$s24_bad no-git-push-rule"
grep -q 'preToolUse' container/copilot-policy.json 2>/dev/null || s24_bad="$s24_bad not-a-preToolUse-hook"

# A syntax error would surface at runtime as every shell command being denied.
if command -v node >/dev/null 2>&1; then
    node --check container/guard-shell-command.js >/dev/null 2>&1 || s24_bad="$s24_bad guard-syntax"
fi

[ -z "$s24_bad" ] && pass S24 "Copilot policy hook shipped, registered, root-owned, and syntax-clean" \
                  || fail S24 "the Copilot policy-hook chain is broken" \
                              "broken:$s24_bad
        This hook is what denies 'git -C . push'; the --deny-tool flags do not. Every failure
        mode here is silent and fails open — do not relax this assertion to make it pass."

# --- S25  managed policy and guarded wrappers installed root-owned, wrappers first ---------
# Source structure of the Dockerfile. Ownership, PATH order and refusals are observed at
# runtime by verify-startup.sh and on the rebuilt image (Phase 3 spec, L1 and L8).
s25_bad=""
df=.devcontainer/Dockerfile
has() { grep -qxF -- "$2" "$df" || s25_bad="$s25_bad $1"; }
has managed-not-COPYd  'COPY container/claude-managed-settings.json /etc/claude-code/managed-settings.json'
has canonical-not-COPYd 'COPY container/claude-project-settings.json /usr/local/share/pera-sandbox/claude-project-settings.json'
has wrapper-not-COPYd  'COPY container/agent-cli-guard.sh /usr/local/lib/pera-sandbox/bin/claude'
unset -f has
dockerfile_code=$(code_only "$df")
for needle in 'mkdir -p /etc/claude-code/managed-settings.d' 'chown -R root:root /etc/claude-code' \
              'chmod 0644 /etc/claude-code/managed-settings.json' 'ln -s claude /usr/local/lib/pera-sandbox/bin/copilot' \
              'chown -R root:root /usr/local/lib/pera-sandbox' \
              'ln -s "$target" /usr/local/lib/pera-sandbox/real/claude' 'rm /home/vscode/.local/bin/claude'; do
    echo "$dockerfile_code" | grep -qF -- "$needle" || s25_bad="$s25_bad missing:$needle"
done
last_path=$(echo "$dockerfile_code" | grep -oE 'PATH=[^ ]+' | tail -1)
case "$last_path" in
    PATH=/usr/local/lib/pera-sandbox/bin:*) : ;;
    *) s25_bad="$s25_bad wrapper-not-first-on-PATH($last_path)" ;;
esac
grep -qxF 'CANONICAL=/usr/local/share/pera-sandbox/claude-project-settings.json' container/run-agent.sh \
    || s25_bad="$s25_bad run-agent-canonical-path"
grep -qF 'cp "$SCAFFOLD/container/claude-project-settings.json" "$SANDBOX_ROOT/.claude/settings.json"' new-sandbox.sh \
    || s25_bad="$s25_bad assembly-not-canonical"
g=container/agent-cli-guard.sh
wrapper_code=$(code_only "$g")
for line in '    claude)  real=/usr/local/lib/pera-sandbox/real/claude; pre=() ;;' \
            '    copilot) real=/usr/local/bin/copilot;         pre=(--no-auto-update) ;;' \
            'lock=/run/claude-lockdown-domains' 'exec "$real" "${pre[@]}" "$@"' \
            '    export COPILOT_AUTO_UPDATE=false' '    pkg="$HOME/.copilot/pkg"'; do
    echo "$wrapper_code" | grep -qxF -- "$line" || s25_bad="$s25_bad wrapper:$line"
done
echo "$wrapper_code" | grep -qF 'CapInh:|CapPrm:|CapEff:|CapAmb:)' || s25_bad="$s25_bad wrapper-caps-check"
[ -z "$s25_bad" ] && pass S25 "image installs the managed policy and guarded wrappers root-owned, wrappers first on PATH" \
                  || fail S25 "managed-policy or guarded-startup packaging changed (E2/E3/E5)" "broken:$s25_bad"

# --- S26  launchers check persistent inputs and run only baked CLIs (N5) --------------------
s26_bad=""
ra=container/run-agent.sh
for f in "$ra" "$g"; do
    unsets=$(code_only "$f" | sed -n '/^ *unset CLAUDE_CODE_MANAGED_SETTINGS_PATH/,/[^\\]$/p')
    for v in CLAUDE_CODE_MANAGED_SETTINGS_PATH CLAUDE_CODE_REMOTE_SETTINGS_PATH CLAUDE_CODE_MOCK_REMOTE_SETTINGS \
             CLAUDE_CODE_DISABLE_ADMIN_ENV_UNION CLAUDE_CODE_SUBPROCESS_ENV_SCRUB CLAUDE_CODE_USE_COWORK_PLUGINS \
             CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST CLAUDE_CODE_BRIDGE_CHILD_MACHINE_SETTINGS CLAUDE_PROJECT_DIR \
             GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR; do
        echo "$unsets" | grep -qw -- "$v" || s26_bad="$s26_bad $f:no-unset-$v"
    done
done
# The allowlist is the reviewed decision (2026-09-24). Widening it is a review, not an edit
# that makes this pass.
grep -qxF 'USER_KEYS='\''["$schema","effortLevel","language","model","outputStyle","skipDangerousModePermissionPrompt","theme","tui","viewMode"]'\''' "$ra" \
    || s26_bad="$s26_bad user-allowlist-changed"
ra_code=$(code_only "$ra")
for needle in '"$WS/.claude/settings.local.json" "$WS/.mcp.json" "$WS/.git"' 'remote-settings.json' 'mcpServers' \
              'LEGACY_PROJECT_SHA=' 'cmp -s -- "$p" "$CANONICAL"' '[ "$(stat -c %h -- "$1")" = 1 ]'; do
    echo "$ra_code" | grep -qF -- "$needle" || s26_bad="$s26_bad no-check:$needle"
done
l_check=$(line_of "$ra" '^for c in "\$CONFIG/.claude.json"')
l_lock=$(line_of "$ra" 'init-firewall.sh lockdown')
l_exec=$(line_of "$ra" '^setpriv ')
if [ -z "$l_check" ] || [ -z "$l_lock" ] || [ -z "$l_exec" ] || [ "$l_check" -gt "$l_lock" ]; then
    s26_bad="$s26_bad checks-not-before-lockdown"
fi
for f in container/run-agent.sh container/run-copilot.sh; do
    code_only "$f" | grep -q 'agent-cli' && s26_bad="$s26_bad $f:uses-staged-cli"
done
rc_code=$(code_only container/run-copilot.sh)
echo "$rc_code" | grep -qF 'if [ -e "$COPILOT_DIR/pkg" ] || [ -L "$COPILOT_DIR/pkg" ]; then' || s26_bad="$s26_bad copilot-no-pkg-refusal"
echo "$rc_code" | grep -qxF 'export COPILOT_AUTO_UPDATE=false' || s26_bad="$s26_bad copilot-auto-update-on"
l_pkg=$(line_of container/run-copilot.sh 'COPILOT_DIR/pkg" \]; then')
l_clock=$(line_of container/run-copilot.sh 'init-firewall.sh lockdown "${MODE_DOMAINS')
{ [ -n "$l_pkg" ] && [ -n "$l_clock" ] && [ "$l_pkg" -lt "$l_clock" ]; } || s26_bad="$s26_bad copilot-pkg-check-not-before-lockdown"
[ -z "$s26_bad" ] && pass S26 "run-agent checks persistent inputs before lockdown; launchers run only baked CLIs" \
                              "Behavior: verify-startup.sh." \
                  || fail S26 "next-session input checks or the baked-CLI rule changed (finding N5)" "broken:$s26_bad"

# --- S27  Karma's browser is EPEL's headless shell (G2) ------------------------------------
# Full Chromium cannot start inside Claude's Bash sandbox (read-only $HOME, no Unix-domain
# sockets). Not an isolation invariant; without it agents cannot run Karma suites.
s27_bad=""
for needle in 'dnf -y install --setopt=install_weak_deps=False chromium chromium-headless' \
              'CHROME_BIN=/usr/lib64/chromium-browser/headless_shell'; do
    echo "$dockerfile_code" | grep -qF -- "$needle" || s27_bad="$s27_bad missing:$needle"
done
n_chrome_bin=$(echo "$dockerfile_code" | grep -c 'CHROME_BIN=')
[ "$n_chrome_bin" = 1 ] || s27_bad="$s27_bad CHROME_BIN-set-$n_chrome_bin-times"
[ -z "$s27_bad" ] && pass S27 "Karma's CHROME_BIN is EPEL's headless shell" \
                              "Behavior: verify-startup.sh chrome-headless; Karma in the real sandbox is a live check." \
                  || fail S27 "Karma's browser packaging changed (finding G2)" "broken:$s27_bad"

# --- summary --------------------------------------------------------------------------------
echo
printf '%s%d passed%s, %s%d failed%s, %s%d warnings%s, %s%d skipped%s\n' \
    "$C_PASS" "$N_PASS" "$C_OFF" "$C_FAIL" "$N_FAIL" "$C_OFF" \
    "$C_WARN" "$N_WARN" "$C_OFF" "$C_SKIP" "$N_SKIP" "$C_OFF"
if [ "$N_FAIL" -gt 0 ]; then
    printf 'failed: %s\n' "${FAILED_IDS[*]}"
    echo
    echo "Assertions S10-S18 and S24-S26 guard isolation invariants. If one of those failed, the right"
    echo "response is almost never to relax the assertion."
    exit 1
fi
echo
exit 0

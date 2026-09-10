#!/bin/bash
# Egress firewall for the PERA Claude Code sandbox. Run as root (sudo).
#
# Usage:
#   init-firewall.sh open                   # allow all egress  (prepare phase ONLY;
#                                           # REFUSED once this container has locked
#                                           # down — lockdown is a one-way door)
#   init-firewall.sh lockdown [domain ...]  # default-deny egress except listed domains
#                                           # default allowlist: Anthropic endpoints;
#                                           # run-copilot passes GitHub endpoints.
#                                           # Smoke test probes the FIRST listed domain.
#
# Refresh leaves the live firewall in place: swap a staged ipset, or replace one
# jump to a staged per-IP chain. All transitions share a root-owned lock.
set -Eeuo pipefail

die() {
    echo "[firewall] ERROR: $*" >&2
    exit 1
}

trap 'status=$?; echo "[firewall] ERROR: operation failed (status $status); no open-network recovery attempted." >&2; exit "$status"' ERR
trap 'echo "[firewall] ERROR: interrupted; restrictions and initialization state retained." >&2; exit 130' INT
trap 'echo "[firewall] ERROR: terminated; restrictions and initialization state retained." >&2; exit 143' TERM

if [ "$(id -u)" -ne 0 ]; then
    die "init-firewall.sh must run as root (use sudo)"
fi

MODE="${1:-}"
case "$MODE" in
    open|lockdown) shift ;;
    *) echo "Usage: init-firewall.sh open | lockdown [domain ...]" >&2; exit 2 ;;
esac
if [ "$MODE" = open ] && [ "$#" -ne 0 ]; then
    echo "Usage: init-firewall.sh open | lockdown [domain ...]" >&2
    exit 2
fi

# Anthropic-only default: API + auth endpoints. Telemetry hosts are intentionally
# absent (CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 is set container-wide).
DEFAULT_DOMAINS=(
    api.anthropic.com
    console.anthropic.com
    platform.claude.com
    claude.ai
)

IPSET=claude-allowed
MARKER=CLAUDE_LOCKDOWN
DISPATCH=CLAUDE_HTTPS
CHAIN_A=CLAUDE_ALLOW_A
CHAIN_B=CLAUDE_ALLOW_B
COMMITTED=/run/claude-lockdown-domains
STATE=/run/claude-firewall
PENDING="$STATE/installing"
BACKEND_FILE="$STATE/backend"
LAYOUT_FILE="$STATE/layout"

# /run is root-owned and is not a workspace/auth mount. Never unlink the lock:
# replacing its inode would allow two invocations to hold different locks.
umask 077
mkdir -p -m 700 "$STATE"
exec 9>>"$STATE/lock"
flock -w 30 9
RULES=$(iptables -S)

has_state() {
    [ -e "$COMMITTED" ] || [ -e "$PENDING" ] \
        || [ -e "$BACKEND_FILE" ] || [ -e "$LAYOUT_FILE" ] \
        || grep -Eq "^-N ($MARKER|$DISPATCH)$" <<< "$RULES"
}

if [ "$MODE" = open ]; then
    # The agent can sudo this script with arbitrary arguments. Durable state AND
    # the kernel marker guard this one-way door, including interrupted installs.
    if has_state; then
        echo "[firewall] REFUSING to open: this container is already locked down." >&2
        echo "[firewall] Lockdown is one-way, including incomplete initialization. Use a fresh container." >&2
        exit 3
    fi
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F
    iptables -X
    echo "[firewall] OPEN — all egress allowed. Prepare phase only; run 'init-firewall.sh lockdown' before starting the agent."
    exit 0
fi

valid_ipv4() {
    local value="$1" octet
    local -a octets
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    IFS=. read -r -a octets <<< "${value%%/*}"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
    if [[ "$value" == */* ]]; then
        ((10#${value##*/} <= 32)) || return 1
    fi
    return 0
}

# Exclude the two changing allow chains. The ipset dispatch rule is static;
# per-IP dispatch is validated separately and its active target read from the kernel.
snapshot_layout() {
    iptables -S | grep -E '^(-P (INPUT|OUTPUT|FORWARD) |-(A|N) (INPUT|OUTPUT|FORWARD|CLAUDE_LOCKDOWN)( |$))'
    if [ "$BACKEND" = ipset ]; then
        iptables -S "$DISPATCH"
    fi
}

DOMAINS=("$@")
[ ${#DOMAINS[@]} -ne 0 ] || DOMAINS=("${DEFAULT_DOMAINS[@]}")
INITIAL=1
if has_state; then
    [ -s "$COMMITTED" ] && [ -s "$BACKEND_FILE" ] && [ -s "$LAYOUT_FILE" ] \
        && [ ! -e "$PENDING" ] \
        || die "incomplete lockdown state; use a fresh container"
    BACKEND=$(< "$BACKEND_FILE")
    case "$BACKEND" in ipset|per-ip) ;; *) die "invalid saved backend; use a fresh container" ;; esac
    grep -q "^-N $MARKER$" <<< "$RULES" || die "lockdown marker missing; use a fresh container"
    current_layout=$(snapshot_layout)
    [ "$current_layout" = "$(< "$LAYOUT_FILE")" ] \
        || die "live firewall differs from the committed layout; use a fresh container"
    if [ "$BACKEND" = per-ip ]; then
        dispatch_rules=$(iptables -S "$DISPATCH")
        if [ "$dispatch_rules" = "$(printf -- '-N %s\n-A %s -j %s' "$DISPATCH" "$DISPATCH" "$CHAIN_A")" ]; then
            ACTIVE="$CHAIN_A"
            NEXT="$CHAIN_B"
        elif [ "$dispatch_rules" = "$(printf -- '-N %s\n-A %s -j %s' "$DISPATCH" "$DISPATCH" "$CHAIN_B")" ]; then
            ACTIVE="$CHAIN_B"
            NEXT="$CHAIN_A"
        else
            die "invalid live allowlist dispatch; use a fresh container"
        fi
    fi
    # Never let sudo lockdown <other-domains> replace the first pinned domain list.
    mapfile -t COMMITTED_DOMAINS < "$COMMITTED"
    if [ "${DOMAINS[*]}" != "${COMMITTED_DOMAINS[*]}" ]; then
        echo "[firewall] NOTE: ignoring supplied allowlist; using this container's committed domains." >&2
    fi
    DOMAINS=("${COMMITTED_DOMAINS[@]}")
    INITIAL=0
fi

# Resolve before touching live rules. A partial DNS result must not replace a
# working snapshot. CIDRs are needed for Copilot's shared GitHub address ranges.
ALLOWED_IPS=()
SMOKE_HOST=""
for d in "${DOMAINS[@]}"; do
    if [[ "$d" == */* ]]; then
        valid_ipv4 "$d" || die "invalid IPv4 CIDR: $d"
        ALLOWED_IPS+=("$d")
        continue
    fi
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.?$ ]] || die "invalid domain: $d"
    [ -n "$SMOKE_HOST" ] || SMOKE_HOST="$d"
    answer=$(dig +time=2 +tries=1 +short A "$d")
    found=0
    while IFS= read -r ip; do
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            valid_ipv4 "$ip" || die "invalid DNS address for $d"
            ALLOWED_IPS+=("$ip")
            found=1
        fi
    done <<< "$answer"
    [ "$found" -eq 1 ] || die "could not resolve $d; existing firewall unchanged"
done
[ ${#ALLOWED_IPS[@]} -gt 0 ] || die "resolved no allowlist IPs; existing firewall unchanged"
sorted_ips=$(printf '%s\n' "${ALLOWED_IPS[@]}" | sort -u)
mapfile -t ALLOWED_IPS <<< "$sorted_ips"

if [ "$INITIAL" -eq 1 ]; then
    # Choose once. A later ipset failure must not trigger a live backend migration.
    if ipset create claude-probe hash:net -exist 2>/dev/null; then
        ipset destroy claude-probe
        BACKEND=ipset
    else
        BACKEND=per-ip
        echo "[firewall] NOTE: ipset unavailable — using per-IP iptables rules instead."
    fi
    if [ "$BACKEND" = per-ip ]; then
        for chain in "$CHAIN_A" "$CHAIN_B"; do
            if ! grep -q "^-N $chain$" <<< "$RULES"; then
                iptables -N "$chain"
            fi
            iptables -F "$chain"
        done
        NEXT="$CHAIN_A"
    fi
fi

if [ "$BACKEND" = ipset ]; then
    ipset create "${IPSET}-new" hash:net -exist
    ipset flush "${IPSET}-new"
    for ip in "${ALLOWED_IPS[@]}"; do
        ipset add "${IPSET}-new" "$ip" -exist
    done
else
    iptables -F "$NEXT"
    for ip in "${ALLOWED_IPS[@]}"; do
        iptables -A "$NEXT" -p tcp --dport 443 -d "$ip" -j ACCEPT
    done
fi

if [ "$INITIAL" -eq 1 ]; then
    # Filesystem and kernel commits are not one transaction. Publish intent BEFORE
    # installing rules; an interrupted initial install requires a fresh container.
    # DNS/staging failures above are still retryable because no live rules changed.
    printf '%s\n' "${DOMAINS[@]}" > "$PENDING"
    printf '%s\n' "$BACKEND" > "$BACKEND_FILE"
    iptables -N "$MARKER"
    iptables -P OUTPUT DROP
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -F FORWARD

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -N "$DISPATCH"
    if [ "$BACKEND" = ipset ]; then
        ipset create "$IPSET" hash:net -exist
        ipset swap "${IPSET}-new" "$IPSET"
        iptables -A "$DISPATCH" -p tcp --dport 443 -m set --match-set "$IPSET" dst -j ACCEPT
    else
        iptables -A "$DISPATCH" -j "$NEXT"
    fi
    iptables -A OUTPUT -j "$DISPATCH"
    # Preserve fail-fast refusals. DROP policies are the backstop, not the normal
    # blocked-connection path an autonomous agent would otherwise hang on.
    iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
    iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable
    snapshot_layout > "$LAYOUT_FILE"
    mv -T "$PENDING" "$COMMITTED"
elif [ "$BACKEND" = ipset ]; then
    ipset swap "${IPSET}-new" "$IPSET"
else
    # This single rule replacement is the commit. The kernel target, not a file
    # written after this command, is authoritative if this process is interrupted.
    iptables -R "$DISPATCH" 1 -j "$NEXT"
fi

# Cleanup never rolls back a committed update. If it fails, the new allowlist is
# active; its unused predecessor will be cleared when the next candidate is staged.
if [ "$BACKEND" = ipset ]; then
    ipset destroy "${IPSET}-new"
elif [ "$INITIAL" -eq 0 ]; then
    iptables -F "$ACTIVE"
fi

echo "[firewall] LOCKDOWN active ($BACKEND). Allowed: ${DOMAINS[*]}"

# Any HTTP response counts as reachable. Both probe failures stop initial agent
# startup; a refresh error is surfaced by the launcher without opening the network.
if [ -z "$SMOKE_HOST" ]; then
    echo "[firewall] NOTE: allowlist is CIDR-only; skipping positive smoke test"
elif curl -s -m 8 -o /dev/null "https://${SMOKE_HOST}"; then
    echo "[firewall] OK: ${SMOKE_HOST} reachable"
else
    die "${SMOKE_HOST} NOT reachable"
fi
if curl -s -m 5 -o /dev/null https://example.com; then
    die "example.com reachable — lockdown NOT effective"
else
    echo "[firewall] OK: non-allowlisted egress refused"
fi

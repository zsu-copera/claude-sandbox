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
# Lockdown is idempotent and refresh-safe: allowed IPs are resolved into a fresh
# ipset and atomically swapped, so re-running it mid-session (Anthropic IPs rotate)
# never opens a gap. Blocked connections are REJECTed, not dropped, so tools the
# agent runs fail fast instead of hanging on timeouts.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "init-firewall.sh must run as root (use sudo)" >&2
    exit 1
fi

MODE="${1:-}"
shift || true

# Anthropic-only default: API + auth endpoints. Telemetry hosts are intentionally
# absent (CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 is set container-wide).
DEFAULT_DOMAINS=(
    api.anthropic.com
    console.anthropic.com
    platform.claude.com
    claude.ai
)

IPSET=claude-allowed
MARKER=CLAUDE_LOCKDOWN   # empty chain used as an "is locked down" marker

flush_rules() {
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F
    iptables -X 2>/dev/null || true
}

case "$MODE" in
open)
    # One-way door: once this container has been locked down, it cannot be reopened.
    # The agent runs with passwordless sudo for THIS script, so without this guard an
    # autonomous session could simply re-open its own egress. The marker chain is
    # per-container (iptables state dies with the container), so the prepare phase —
    # a separate container that never locks down — is unaffected. To get an open
    # network again, start a fresh container.
    if iptables -n -L "$MARKER" >/dev/null 2>&1; then
        echo "[firewall] REFUSING to open: this container is already locked down." >&2
        echo "[firewall] Lockdown is one-way by design. Use a fresh container instead." >&2
        exit 3
    fi
    flush_rules
    ipset destroy "$IPSET" 2>/dev/null || true
    echo "[firewall] OPEN — all egress allowed. Prepare phase only; run 'init-firewall.sh lockdown' before starting the agent."
    ;;

lockdown)
    DOMAINS=("$@")
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        DOMAINS=("${DEFAULT_DOMAINS[@]}")
    fi

    # Sticky allowlist. The FIRST successful lockdown in this container commits its
    # domain list; every later lockdown reuses it and ignores whatever was passed.
    #
    # Why: the agent has passwordless sudo for THIS script, and sudoers cannot constrain
    # arguments here (callers legitimately pass their own domain sets). Without this an
    # autonomous session could re-lock the firewall around an allowlist of its own
    # choosing — an egress channel — which would make the one-way `open` guard pointless.
    # Blocking `open` while leaving `lockdown <anything>` open was only half a door.
    #
    # Safe for the two flows that re-lock: run-agent's 15-min refresh and run-copilot's
    # --login mode both keep a FIXED domain set for the life of the container, decided
    # before the first call. $COMMITTED lives on /run — tmpfs, per-container, root-owned
    # 755, so the agent (uid 1000) can neither forge nor delete it (verified).
    COMMITTED=/run/claude-lockdown-domains
    if [ -s "$COMMITTED" ]; then
        mapfile -t COMMITTED_DOMAINS < "$COMMITTED"
        if [ "${DOMAINS[*]}" != "${COMMITTED_DOMAINS[*]}" ]; then
            echo "[firewall] NOTE: ignoring the supplied allowlist — this container is committed to: ${COMMITTED_DOMAINS[*]}" >&2
        fi
        DOMAINS=("${COMMITTED_DOMAINS[@]}")
    fi

    # ipset isn't always usable in rootless user namespaces (e.g. rootless podman);
    # fall back to one iptables ACCEPT rule per resolved IP in that case.
    USE_IPSET=1
    if ipset create claude-probe hash:ip 2>/dev/null; then
        ipset destroy claude-probe
    else
        USE_IPSET=0
        echo "[firewall] NOTE: ipset unavailable — using per-IP iptables rules instead."
    fi

    # Resolve the allowlist. Entries containing "/" are CIDR ranges and pass through
    # unresolved — needed for GitHub, whose GLB rotates IPs between resolutions faster
    # than any snapshot can track (per-IP allowlisting of github hosts WILL fail).
    ALLOWED_IPS=()
    SMOKE_HOST=""
    for d in "${DOMAINS[@]}"; do
        if [[ "$d" == */* ]]; then
            ALLOWED_IPS+=("$d")
            continue
        fi
        [ -n "$SMOKE_HOST" ] || SMOKE_HOST="$d"
        ips=$(dig +short A "$d" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        if [ -z "$ips" ]; then
            echo "[firewall] WARN: could not resolve $d (skipped)" >&2
            continue
        fi
        for ip in $ips; do ALLOWED_IPS+=("$ip"); done
    done
    if [ ${#ALLOWED_IPS[@]} -eq 0 ]; then
        echo "[firewall] ERROR: resolved no allowlist IPs — refusing to lock down into a dead end." >&2
        exit 1
    fi

    if [ "$USE_IPSET" -eq 1 ]; then
        # hash:net accepts both single IPs and CIDR ranges.
        # Stage into a fresh set, then swap atomically (refresh-safe for long runs).
        ipset create "$IPSET" hash:net 2>/dev/null || true
        ipset create "${IPSET}-new" hash:net 2>/dev/null || ipset flush "${IPSET}-new"
        for ip in "${ALLOWED_IPS[@]}"; do
            ipset add "${IPSET}-new" "$ip" 2>/dev/null || true
        done
        ipset swap "${IPSET}-new" "$IPSET"
        ipset destroy "${IPSET}-new"
    fi

    flush_rules
    iptables -N "$MARKER"

    # Inbound: loopback + replies only.
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -P INPUT DROP

    # Outbound: loopback (incl. Docker's 127.0.0.11 DNS), replies, DNS, HTTPS to allowlist.
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    if [ "$USE_IPSET" -eq 1 ]; then
        iptables -A OUTPUT -p tcp --dport 443 -m set --match-set "$IPSET" dst -j ACCEPT
    else
        for ip in "${ALLOWED_IPS[@]}"; do
            iptables -A OUTPUT -p tcp --dport 443 -d "$ip" -j ACCEPT
        done
    fi
    # Fail fast (REJECT) rather than hang (DROP) — an autonomous agent should see
    # "connection refused" immediately, not wait out TCP timeouts.
    iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
    iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable
    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP

    echo "[firewall] LOCKDOWN active. Allowed: ${DOMAINS[*]}"

    # Commit the allowlist now that the rules are actually in place — not earlier, so a
    # first lockdown that bailed out (e.g. resolved nothing) doesn't pin a bad list and
    # leave a legitimate retry unable to correct it.
    if [ ! -s "$COMMITTED" ]; then
        printf '%s\n' "${DOMAINS[@]}" > "$COMMITTED"
        chmod 600 "$COMMITTED"
    fi

    # Smoke test: positive probe = first non-CIDR domain of the active allowlist
    # (callers pass their own set — e.g. run-copilot passes GitHub endpoints); any
    # HTTP response counts as reachable. Negative probe (example.com) stays fatal.
    if [ -z "$SMOKE_HOST" ]; then
        echo "[firewall] NOTE: allowlist is CIDR-only; skipping positive smoke test"
    elif curl -s -m 8 -o /dev/null "https://${SMOKE_HOST}"; then
        echo "[firewall] OK: ${SMOKE_HOST} reachable"
    else
        echo "[firewall] WARN: ${SMOKE_HOST} NOT reachable — agent will not work" >&2
    fi
    if curl -s -m 5 -o /dev/null https://example.com; then
        echo "[firewall] WARN: example.com reachable — lockdown NOT effective!" >&2
        exit 1
    else
        echo "[firewall] OK: non-allowlisted egress refused"
    fi
    ;;

*)
    echo "Usage: init-firewall.sh open | lockdown [domain ...]" >&2
    exit 2
    ;;
esac

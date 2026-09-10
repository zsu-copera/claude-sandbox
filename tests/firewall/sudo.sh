#!/bin/bash
# Streamed into a fresh network-none container; only the firewall source is mounted.
set -Eeuo pipefail
R=/run/e1-test
FW=/usr/local/bin/init-firewall.sh
COMMITTED=/run/claude-lockdown-domains
STATE=/run/claude-firewall
umask 077
mkdir -p -m 700 "$R/bin"
ln -s "$(command -v curl)" "$R/real-curl"
# CIDR-only initialization skips the positive smoke probe. Redirect the negative
# smoke to a closed loopback port: no external DNS or destination is contacted.
printf '%s\n' '#!/bin/bash' \
    'exec /run/e1-test/real-curl --noproxy "*" --silent --max-time 1 http://127.0.0.1:9 >/dev/null' \
    > "$R/bin/curl"
chmod 700 "$R/bin/curl"
PATH="$R/bin:$PATH" bash "$FW" lockdown 127.0.0.1/32
[ "$(stat -c '%u:%g:%a' "$COMMITTED")" = 0:0:600 ]
[ "$(stat -c '%u:%g:%a' "$STATE")" = 0:0:700 ]
cp "$COMMITTED" "$R/committed"
iptables -S > "$R/rules"

status=0
setpriv --reuid vscode --regid vscode --init-groups --inh-caps=-all --ambient-caps=-all \
    /bin/bash -s <<'NONROOT' || status=$?
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "ASSERT: caller is still root" >&2; exit 1; }
while read -r name value rest; do
    case "$name" in
        CapEff:|CapPrm:|CapInh:|CapAmb:)
            [ "$value" = 0000000000000000 ] || { echo "ASSERT: $name is not empty" >&2; exit 1; }
            ;;
    esac
done < /proc/self/status

if cat /run/claude-lockdown-domains >/dev/null 2>&1; then
    echo "ASSERT: nonroot caller read pinned domains" >&2
    exit 1
fi
if cat /run/claude-firewall/backend >/dev/null 2>&1; then
    echo "ASSERT: nonroot caller read private root state" >&2
    exit 1
fi
if (printf 'evil.test\n' >> /run/claude-lockdown-domains) 2>/dev/null; then
    echo "ASSERT: nonroot caller edited pinned domains" >&2
    exit 1
fi
if (printf 'per-ip\n' > /run/claude-firewall/backend) 2>/dev/null; then
    echo "ASSERT: nonroot caller edited private root state" >&2
    exit 1
fi
command -v iptables >/dev/null
if iptables -S; then
    echo "ASSERT: nonroot caller can read kernel rules directly" >&2
    exit 1
fi
if iptables -P OUTPUT ACCEPT; then
    echo "ASSERT: nonroot caller can change kernel policy directly" >&2
    exit 1
fi
echo "Nonroot capability drop, root-state read/write denials and direct kernel access denials passed."
status=0
output=$(/usr/bin/sudo -n /usr/local/bin/init-firewall.sh open 2>&1) || status=$?
printf '%s\n' "$output"
if [ "$status" -ne 3 ] && grep -Fq \
    'PAM account management error: Authentication service cannot retrieve authentication info' <<< "$output"; then
    echo "Real helper refusal cannot be observed: image PAM blocks the approved privilege transition." >&2
    exit 77
fi
[ "$status" -eq 3 ] || { echo "ASSERT: expected real scoped-sudo refusal 3, got $status" >&2; exit 1; }
grep -Fq 'REFUSING to open' <<< "$output"
if /usr/bin/sudo -n /bin/true; then
    echo "ASSERT: unscoped privilege elevation succeeded" >&2
    exit 1
fi
NONROOT

cmp "$COMMITTED" "$R/committed"
iptables -S > "$R/after"
cmp "$R/rules" "$R/after"
exit "$status"

#!/bin/bash
# Focused E1 runtime regressions. Run in WSL: bash verify-firewall.sh [--image IMAGE]
set -uo pipefail

IMAGE=localhost/pera-sandbox
SUITE=all
while [ "$#" -gt 0 ]; do
    case "$1" in
        --image) [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "Missing --image value" >&2; exit 2; }; IMAGE=$2; shift 2 ;;
        --callers-only) SUITE=callers; shift ;;
        --sudo-only) SUITE=sudo; shift ;;
        *) echo "Usage: $0 [--image IMAGE] [--callers-only|--sudo-only]" >&2; exit 2 ;;
    esac
done
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 2
FIXTURES="$ROOT/tests/firewall"
SOURCE_HASH=$(sha256sum "$ROOT/container/init-firewall.sh" "$ROOT/container/run-agent.sh" "$ROOT/container/run-copilot.sh") || exit 2
command -v podman >/dev/null || { echo "FAIL prerequisite: podman unavailable"; exit 1; }
podman image exists "$IMAGE" || { echo "FAIL prerequisite: existing image $IMAGE unavailable (no pull/build attempted)"; exit 1; }

NAME="e1-firewall-${UID}-${BASHPID}-${RANDOM}"
NETWORK="$NAME-net"
PEERS=()
ACTIVE=""
NETWORK_CREATED=0
PASS=0
FAIL=0
SKIP=0
SUDO_SKIP=0
SUBNET="10.231.$((RANDOM % 240 + 10))"
cleanup() {
    local failed=0
    if [ -n "$ACTIVE" ] && podman container exists "$ACTIVE"; then
        podman rm --force --time 0 "$ACTIVE" >/dev/null || failed=1
    fi
    for peer in "${PEERS[@]}"; do
        if podman container exists "$peer"; then podman rm --force --time 0 "$peer" >/dev/null || failed=1; fi
    done
    if [ "$NETWORK_CREATED" -eq 1 ]; then
        podman network rm "$NETWORK" >/dev/null || failed=1
    fi
    return "$failed"
}
trap 'status=$?; trap - EXIT; cleanup || status=1; exit "$status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

COMMON=(--pull never --user 0:0 --cap-drop all --cap-add NET_ADMIN --cap-add NET_RAW
    --security-opt no-new-privileges --sysctl net.ipv4.ip_unprivileged_port_start=0
    --volume "$FIXTURES:/opt/e1-fixtures:ro" --entrypoint bash)
if [ "$SUITE" = all ]; then
if ! podman network create --internal --subnet "$SUBNET.0/24" "$NETWORK" >/dev/null; then
    echo "FAIL prerequisite: could not create dedicated internal network"
    exit 1
fi
NETWORK_CREATED=1
if [ "$(podman network inspect --format '{{.Internal}}' "$NETWORK")" != true ]; then
    echo "FAIL prerequisite: dedicated network is not internal"
    exit 1
fi
for octet in 2 3 4; do
    peer="$NAME-peer-$octet"
    PEERS+=("$peer")
    if ! podman run --detach --name "$peer" "${COMMON[@]}" --network "$NETWORK:ip=$SUBNET.$octet" \
        "$IMAGE" /opt/e1-fixtures/scenario.sh peer "$SUBNET" >/dev/null; then
        echo "FAIL prerequisite: synthetic peer failed to start"
        exit 1
    fi
    if ! timeout 15 podman exec "$peer" bash /opt/e1-fixtures/scenario.sh peer-ready "$SUBNET"; then
        echo "FAIL prerequisite: synthetic peer is not responsive"
        podman logs "$peer"
        exit 1
    fi
done

SCENARIOS=(normal preflight-first preflight-refresh concurrency
    stage-create stage-add activation cleanup
    term-before term-after kill-before kill-after
    state-committed state-pending state-kernel state-backend-only state-backend state-layout
    state-missing-backend state-missing-layout state-pending-committed
    partial-initial smoke-positive smoke-negative smoke-initial cidr-only)
for backend in ipset per-ip; do
    for scenario in prerequisite "${SCENARIOS[@]}"; do
        ACTIVE="$NAME-$backend-$scenario"
        output=$(timeout --signal=TERM --kill-after=5 150 podman run --rm --name "$ACTIVE" \
            "${COMMON[@]}" --network "$NETWORK:ip=$SUBNET.10" \
            --volume "$ROOT/container/init-firewall.sh:/usr/local/bin/init-firewall.sh:ro" \
            "$IMAGE" /opt/e1-fixtures/scenario.sh "$backend" "$SUBNET" "$scenario" 2>&1)
        status=$?
        if podman container exists "$ACTIVE"; then
            podman rm --force --time 0 "$ACTIVE" >/dev/null || { echo "FAIL cleanup: $ACTIVE"; exit 1; }
        fi
        ACTIVE=""
        if [ "$status" -eq 0 ]; then
            PASS=$((PASS + 1))
            printf 'PASS %-7s %s\n' "$backend" "$scenario"
        elif [ "$status" -eq 77 ] && [ "$scenario" = prerequisite ]; then
            SKIP=$((SKIP + 1))
            printf 'SKIP %-7s all scenarios: %s\n' "$backend" "$output"
            break
        else
            FAIL=$((FAIL + 1))
            printf 'FAIL %-7s %s (exit %s)\n%s\n' "$backend" "$scenario" "$status" "$output"
            [ "$scenario" != prerequisite ] || break
        fi
    done
done
fi

# Stream only the launcher under test; no workspace or additional source mount.
if [ "$SUITE" != "sudo" ]; then
for caller in claude copilot; do
    source="$ROOT/container/run-agent.sh"
    [ "$caller" != copilot ] || source="$ROOT/container/run-copilot.sh"
    for scenario in initial-failure refresh-warning; do
        ACTIVE="$NAME-$caller-$scenario"
        output=$(timeout --signal=TERM --kill-after=5 30 podman run --interactive --rm --name "$ACTIVE" \
            "${COMMON[@]}" --network none --tmpfs /workspace:rw,mode=0700 \
            "$IMAGE" /opt/e1-fixtures/caller.sh "$caller" "$scenario" \
            < "$source" 2>&1)
        status=$?
        if podman container exists "$ACTIVE"; then
            podman rm --force --time 0 "$ACTIVE" >/dev/null || { echo "FAIL cleanup: $ACTIVE"; exit 1; }
        fi
        ACTIVE=""
        if [ "$status" -eq 0 ]; then
            PASS=$((PASS + 1))
            printf 'PASS %-7s %s (fake CLI/sudo)\n' "$caller" "$scenario"
        else
            FAIL=$((FAIL + 1))
            printf 'FAIL %-7s %s (exit %s)\n%s\n' "$caller" "$scenario" "$status" "$output"
        fi
    done
done
fi

if [ "$SUITE" != callers ]; then
    ACTIVE="$NAME-scoped-sudo"
    # Sudo needs UID/GID switching and setuid elevation in this one approved case.
    # DAC_OVERRIDE restores the production default needed by PAM for mode-000 shadow.
    # The fixture clears agent capabilities before invoking the scoped setuid helper.
    # No fixture/workspace mount, external network, account edits or further capabilities.
    output=$(timeout --signal=TERM --kill-after=5 30 podman run --interactive --rm --name "$ACTIVE" \
        --pull never --user 0:0 --network none --cap-drop all \
        --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE \
        --volume "$ROOT/container/init-firewall.sh:/usr/local/bin/init-firewall.sh:ro" \
        --entrypoint bash "$IMAGE" -s < "$FIXTURES/sudo.sh" 2>&1)
    status=$?
    if podman container exists "$ACTIVE"; then
        podman rm --force --time 0 "$ACTIVE" >/dev/null || { echo "FAIL cleanup: $ACTIVE"; exit 1; }
    fi
    ACTIVE=""
    if [ "$status" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "PASS scoped-sudo nonroot refusal/state protection after capability drop (real privilege elevation)"
    elif [ "$status" -eq 77 ]; then
        SUDO_SKIP=$((SUDO_SKIP + 1))
        printf 'SKIP scoped-sudo real helper invocation blocked by image PAM with approved capabilities\n%s\n' "$output"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL scoped-sudo real nonroot privilege-elevation scenario (exit %s)\n%s\n' "$status" "$output"
    fi
fi
if [ "$(sha256sum "$ROOT/container/init-firewall.sh" "$ROOT/container/run-agent.sh" "$ROOT/container/run-copilot.sh")" != "$SOURCE_HASH" ]; then
    echo "FAIL source changed during the suite; rerun after production edits are complete"
    FAIL=$((FAIL + 1))
fi
printf '%s passed, %s failed, %s backend skips, %s scoped-sudo skips\n' "$PASS" "$FAIL" "$SKIP" "$SUDO_SKIP"
[ "$FAIL" -eq 0 ]

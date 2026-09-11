#!/usr/bin/env bash

round_fixture_unmounted() {
    local root=$1 ids metadata result
    local -a containers=()
    ids=$(podman ps --all --format '{{.ID}}') || {
        echo 'Cannot list containers; retain the round fixture.' >&2
        return 1
    }
    [[ -n $ids ]] || return 0
    mapfile -t containers <<< "$ids"
    metadata=$(podman container inspect "${containers[@]}") || {
        echo 'Cannot inspect containers; retain the round fixture.' >&2
        return 1
    }
    jq -e 'type == "array" and all(.[]; (.Mounts | type == "array") and
        all(.Mounts[]; .Type != "bind" or (.Source | type == "string" and startswith("/"))))' \
        <<< "$metadata" >/dev/null || {
        echo 'Invalid mount metadata; retain the round fixture.' >&2
        return 1
    }
    if jq -e --arg root "$root" 'any(.[] | .Mounts[];
        .Type == "bind" and (.Source as $source |
        $source == "/" or $source == $root or ($source | startswith($root + "/")) or
        ($root | startswith($source + "/"))))' <<< "$metadata" >/dev/null; then
        echo 'A container still mounts the round fixture; retain it for inspection.' >&2
        return 1
    else
        result=$?
        [[ $result == 1 ]] && return 0
        echo 'Cannot establish mount absence; retain the round fixture.' >&2
        return 1
    fi
}

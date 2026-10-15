#!/usr/bin/env bash

set -euo pipefail

resource_name="${PREPULL_RESOURCE_NAME:-}"
[[ -n "$resource_name" ]] || exit 0

namespace="${INPUT_NAMESPACE:-default}"
namespace="${namespace:-default}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
retry_delay="${CLEANUP_RETRY_DELAY_SECONDS:-2}"
cleanup_failed=0

for resource_kind in daemonset rolebinding role serviceaccount; do
    deleted=0
    for attempt in 1 2 3; do
        if "$KUBECTL_BIN" -n "$namespace" delete "$resource_kind" "$resource_name" \
            --ignore-not-found=true --wait=true --timeout=60s; then
            deleted=1
            break
        fi
        printf 'Cleanup attempt %s failed for %s/%s\n' "$attempt" "$resource_kind" "$resource_name" >&2
        sleep "$retry_delay"
    done

    if ((deleted == 0)); then
        cleanup_failed=1
        continue
    fi

    if output="$("$KUBECTL_BIN" -n "$namespace" get "$resource_kind" "$resource_name" -o name 2>&1)"; then
        printf 'Cleanup verification found remaining resource %s\n' "$output" >&2
        cleanup_failed=1
    elif ! grep -Eqi '(notfound|not found)' <<< "$output"; then
        printf 'Could not verify cleanup of %s/%s: %s\n' "$resource_kind" "$resource_name" "$output" >&2
        cleanup_failed=1
    fi
done

((cleanup_failed == 0)) || exit 1
printf 'Removed temporary pre-pull resources %s from namespace %s\n' "$resource_name" "$namespace"

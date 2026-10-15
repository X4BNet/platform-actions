#!/usr/bin/env bash

set -euo pipefail

namespace="${INPUT_NAMESPACE:-default}"
namespace="${namespace:-default}"
pod_selector="${INPUT_CRASHLOOP_POD_SELECTOR:-}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

command -v jq >/dev/null 2>&1 || {
    printf 'Error: jq is required\n' >&2
    exit 1
}
command -v "$KUBECTL_BIN" >/dev/null 2>&1 || {
    printf 'Error: kubectl is required\n' >&2
    exit 1
}

get_args=(-n "$namespace" get pods -o json)
if [[ -n "$pod_selector" ]]; then
    get_args+=(--selector "$pod_selector")
fi

pods_json="$("$KUBECTL_BIN" "${get_args[@]}")"
mapfile -t crashloop_pods < <(
    jq -r '
        .items[]
        | select(
            (
                (.status.initContainerStatuses // [])
                + (.status.containerStatuses // [])
                + (.status.ephemeralContainerStatuses // [])
            )
            | any(.state.waiting.reason? == "CrashLoopBackOff")
        )
        | .metadata.name
    ' <<< "$pods_json"
)

if ((${#crashloop_pods[@]} == 0)); then
    printf 'No CrashLoopBackOff pods found in namespace %s\n' "$namespace"
    exit 0
fi

printf 'Deleting %s CrashLoopBackOff pod(s) from namespace %s:\n' "${#crashloop_pods[@]}" "$namespace"
printf '  %s\n' "${crashloop_pods[@]}"
"$KUBECTL_BIN" -n "$namespace" delete pod "${crashloop_pods[@]}" \
    --ignore-not-found=true --wait=true --timeout=60s

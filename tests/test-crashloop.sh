#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

cat > "$TEST_TMP/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_KUBECTL_LOG"

if [[ "$*" == *"get pods -o json"* ]]; then
    [[ "${MOCK_GET_FAIL:-false}" != "true" ]] || exit 42
    printf '%s' "$MOCK_PODS_JSON"
elif [[ "$*" == *"delete pod"* ]]; then
    [[ "${MOCK_DELETE_FAIL:-false}" != "true" ]] || exit 42
fi
MOCK
chmod +x "$TEST_TMP/kubectl"

export PATH="$TEST_TMP:$PATH"
export MOCK_KUBECTL_LOG="$TEST_TMP/kubectl.log"
export INPUT_NAMESPACE=development
export MOCK_PODS_JSON='{
    "items": [
        {
            "metadata": {"name": "healthy"},
            "status": {"containerStatuses": [{"state": {"running": {}}}]}
        },
        {
            "metadata": {"name": "main-crashloop"},
            "status": {"containerStatuses": [{"state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}
        },
        {
            "metadata": {"name": "init-crashloop"},
            "status": {"initContainerStatuses": [{"state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}
        },
        {
            "metadata": {"name": "ephemeral-crashloop"},
            "status": {"ephemeralContainerStatuses": [{"state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}
        },
        {
            "metadata": {"name": "image-pull-backoff"},
            "status": {"containerStatuses": [{"state": {"waiting": {"reason": "ImagePullBackOff"}}}]}
        }
    ]
}'

"$ROOT_DIR/k8s-deploy/scripts/delete-crashloop-pods.sh"

delete_line="$(grep 'delete pod' "$MOCK_KUBECTL_LOG")"
[[ "$delete_line" == *"main-crashloop"* ]]
[[ "$delete_line" == *"init-crashloop"* ]]
[[ "$delete_line" == *"ephemeral-crashloop"* ]]
[[ "$delete_line" != *"healthy"* ]]
[[ "$delete_line" != *"image-pull-backoff"* ]]
[[ "$delete_line" == *"--ignore-not-found=true --wait=true --timeout=60s"* ]]

: > "$MOCK_KUBECTL_LOG"
export INPUT_CRASHLOOP_POD_SELECTOR='app=x4b-site'
"$ROOT_DIR/k8s-deploy/scripts/delete-crashloop-pods.sh" >/dev/null
grep -q 'get pods -o json --selector app=x4b-site' "$MOCK_KUBECTL_LOG"

: > "$MOCK_KUBECTL_LOG"
export MOCK_PODS_JSON='{"items":[]}'
"$ROOT_DIR/k8s-deploy/scripts/delete-crashloop-pods.sh" >/dev/null
if grep -q 'delete pod' "$MOCK_KUBECTL_LOG"; then
    printf 'No pods should be deleted when no CrashLoopBackOff state exists\n' >&2
    exit 1
fi

export MOCK_GET_FAIL=true
if "$ROOT_DIR/k8s-deploy/scripts/delete-crashloop-pods.sh" >/dev/null 2>&1; then
    printf 'A pod listing failure must fail the action\n' >&2
    exit 1
fi
unset MOCK_GET_FAIL

export MOCK_PODS_JSON='{
    "items": [{
        "metadata": {"name": "delete-failure"},
        "status": {"containerStatuses": [{"state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}
    }]
}'
export MOCK_DELETE_FAIL=true
if "$ROOT_DIR/k8s-deploy/scripts/delete-crashloop-pods.sh" >/dev/null 2>&1; then
    printf 'A pod deletion failure must fail the action\n' >&2
    exit 1
fi

printf 'CrashLoopBackOff handling tests passed\n'

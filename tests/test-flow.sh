#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
REAL_KUBECTL_BIN="${REAL_KUBECTL_BIN:-$(command -v kubectl || true)}"

cat > "$TEST_TMP/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_KUBECTL_LOG"

if [[ "$*" == *"apply --dry-run=server"* ]]; then
    [[ "${MOCK_FAIL_STAGE:-}" != "dry-run" ]] || exit 42
    cp "${@: -1}" "$MOCK_MANIFEST"
elif [[ "$*" == *"apply -f"* ]]; then
    [[ "${MOCK_FAIL_STAGE:-}" != "apply" ]] || exit 42
elif [[ "$*" == *"get daemonset"*"jsonpath={.metadata.uid}"* ]]; then
    printf 'test-daemonset-uid'
elif [[ "$*" == *"get daemonset"*"jsonpath={.status.desiredNumberScheduled}"* ]]; then
    printf '%s' "${MOCK_DESIRED:-2}"
elif [[ "$*" == *"get daemonset"*"-o json"* ]]; then
    desired="${MOCK_DESIRED:-2}"
    jq -cn --argjson desired "$desired" '{status:{desiredNumberScheduled:$desired,numberReady:$desired,numberAvailable:$desired,numberUnavailable:0}}'
elif [[ "$*" == *"rollout status"* ]]; then
    [[ "${MOCK_FAIL_STAGE:-}" != "rollout" ]] || exit 42
elif [[ "$*" == *" get "* ]]; then
    printf 'Error from server (NotFound): resource not found\n' >&2
    exit 1
fi
MOCK
chmod +x "$TEST_TMP/kubectl"

export PATH="$TEST_TMP:$PATH"
export MOCK_KUBECTL_LOG="$TEST_TMP/kubectl.log"
export MOCK_MANIFEST="$TEST_TMP/manifest.json"
export GITHUB_OUTPUT="$TEST_TMP/github-output"
export GITHUB_RUN_ID=12345
export GITHUB_RUN_ATTEMPT=2
export PREPULL_RANDOM_SUFFIX=flowtest
export INPUT_NAMESPACE=development
export INPUT_IMAGES=$'x4bnet/x4b-site:git-abc\nregistry.example.test/team/sidecar:v2'
export INPUT_IMAGEPULLSECRETS=$'regcred\nsecond-secret'
export INPUT_PREPULL_NODE_SELECTOR='{"k8s.x4b.net/ready":"1"}'
export INPUT_PREPULL_TOLERATIONS='[{"key":"dedicated","operator":"Exists"}]'
export INPUT_PREPULL_TIMEOUT=5m
export INPUT_PREPULL_CLEANUP_TIMEOUT_SECONDS=600

"$ROOT_DIR/k8s-deploy/scripts/prepull.sh"

resource_name="$(sed -n 's/^resource-name=//p' "$GITHUB_OUTPUT")"
[[ "$resource_name" == "k8s-deploy-prepull-12345-2-flowtest" ]]
jq -e --arg name "$resource_name" '
    .kind == "List" and
    (.items | length) == 4 and
    (.items[] | select(.kind == "Role") | .rules[0].resourceNames) == [$name] and
    (.items[] | select(.kind == "DaemonSet") | .spec.template.spec.volumes | length) == 2 and
    (.items[] | select(.kind == "DaemonSet") | .spec.template.spec.nodeSelector["k8s.x4b.net/ready"]) == "1" and
    (.items[] | select(.kind == "DaemonSet") | .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem) == true
' "$MOCK_MANIFEST" >/dev/null

if [[ -n "$REAL_KUBECTL_BIN" ]]; then
    "$REAL_KUBECTL_BIN" create --dry-run=client --validate=false -f "$MOCK_MANIFEST" >/dev/null
fi

dry_run_line="$(grep -n 'apply --dry-run=server' "$MOCK_KUBECTL_LOG" | cut -d: -f1)"
apply_line="$(grep -n 'apply -f' "$MOCK_KUBECTL_LOG" | cut -d: -f1)"
rollout_line="$(grep -n 'rollout status' "$MOCK_KUBECTL_LOG" | cut -d: -f1)"
((dry_run_line < apply_line && apply_line < rollout_line))

export PREPULL_RESOURCE_NAME="$resource_name"
export CLEANUP_RETRY_DELAY_SECONDS=0
"$ROOT_DIR/k8s-deploy/scripts/cleanup.sh"
for kind in daemonset rolebinding role serviceaccount; do
    grep -q "delete $kind $resource_name" "$MOCK_KUBECTL_LOG"
done

: > "$MOCK_KUBECTL_LOG"
export MOCK_DESIRED=0
export PREPULL_DISCOVERY_ATTEMPTS=1
export GITHUB_OUTPUT="$TEST_TMP/zero-output"
if "$ROOT_DIR/k8s-deploy/scripts/prepull.sh" >/dev/null 2>&1; then
    printf 'Expected zero matching workers to fail\n' >&2
    exit 1
fi
grep -q '^resource-name=' "$GITHUB_OUTPUT"

unset MOCK_DESIRED
unset PREPULL_DISCOVERY_ATTEMPTS
for failure_stage in dry-run apply rollout; do
    : > "$MOCK_KUBECTL_LOG"
    export MOCK_FAIL_STAGE="$failure_stage"
    export GITHUB_OUTPUT="$TEST_TMP/${failure_stage}-output"
    if "$ROOT_DIR/k8s-deploy/scripts/prepull.sh" >/dev/null 2>&1; then
        printf 'Expected %s failure to stop pre-pull\n' "$failure_stage" >&2
        exit 1
    fi

    failed_resource_name="$(sed -n 's/^resource-name=//p' "$GITHUB_OUTPUT")"
    [[ -n "$failed_resource_name" ]]
    PREPULL_RESOURCE_NAME="$failed_resource_name" CLEANUP_RETRY_DELAY_SECONDS=0 \
        "$ROOT_DIR/k8s-deploy/scripts/cleanup.sh" >/dev/null
    grep -q "delete daemonset $failed_resource_name" "$MOCK_KUBECTL_LOG"
done
unset MOCK_FAIL_STAGE

printf 'Flow tests passed\n'

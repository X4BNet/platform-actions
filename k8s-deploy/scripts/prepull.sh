#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # Resolve the library relative to the installed action.
source "$SCRIPT_DIR/lib.sh"

command -v jq >/dev/null 2>&1 || die "jq is required"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
command -v "$KUBECTL_BIN" >/dev/null 2>&1 || die "kubectl is required"

namespace="${INPUT_NAMESPACE:-default}"
namespace="${namespace:-default}"
images_input="${INPUT_IMAGES:-}"
image_pull_secrets_input="${INPUT_IMAGEPULLSECRETS:-}"
node_selector="${INPUT_PREPULL_NODE_SELECTOR:-}"
tolerations="${INPUT_PREPULL_TOLERATIONS:-[]}"
rollout_timeout="${INPUT_PREPULL_TIMEOUT:-5m}"
cleanup_timeout="${INPUT_PREPULL_CLEANUP_TIMEOUT_SECONDS:-600}"

parse_images "$images_input"
parse_image_pull_secrets "$image_pull_secrets_input"
validate_node_selector "$node_selector"
validate_tolerations "$tolerations"
validate_rollout_timeout "$rollout_timeout"
validate_cleanup_timeout "$cleanup_timeout"

resource_name="$(generate_resource_name)"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'resource-name=%s\n' "$resource_name" >> "$GITHUB_OUTPUT"
fi

images_json="$(json_array_from_lines "${IMAGES[@]}")"
secrets_json="$(json_array_from_lines "${IMAGE_PULL_SECRETS[@]}")"
manifest_file="$(mktemp)"
trap 'rm -f "$manifest_file"' EXIT

jq -n \
    --arg name "$resource_name" \
    --arg namespace "$namespace" \
    --arg helperImage "$PREPULL_HELPER_IMAGE" \
    --arg cleanupTimeout "$cleanup_timeout" \
    --argjson images "$images_json" \
    --argjson imagePullSecrets "$secrets_json" \
    --argjson nodeSelector "$node_selector" \
    --argjson tolerations "$tolerations" \
    '
    def metadata:
        {
            name: $name,
            namespace: $namespace,
            labels: {
                "app.kubernetes.io/name": "k8s-deploy-prepull",
                "app.kubernetes.io/managed-by": "X4BNet-platform-actions",
                "x4b.net/prepull-id": $name
            }
        };
    {
        apiVersion: "v1",
        kind: "List",
        items: [
            {
                apiVersion: "v1",
                kind: "ServiceAccount",
                metadata: metadata,
                automountServiceAccountToken: true,
                imagePullSecrets: ($imagePullSecrets | map({name: .}))
            },
            {
                apiVersion: "rbac.authorization.k8s.io/v1",
                kind: "Role",
                metadata: metadata,
                rules: [{
                    apiGroups: ["apps"],
                    resources: ["daemonsets"],
                    resourceNames: [$name],
                    verbs: ["delete"]
                }]
            },
            {
                apiVersion: "rbac.authorization.k8s.io/v1",
                kind: "RoleBinding",
                metadata: metadata,
                roleRef: {
                    apiGroup: "rbac.authorization.k8s.io",
                    kind: "Role",
                    name: $name
                },
                subjects: [{
                    kind: "ServiceAccount",
                    name: $name,
                    namespace: $namespace
                }]
            },
            {
                apiVersion: "apps/v1",
                kind: "DaemonSet",
                metadata: metadata,
                spec: {
                    selector: {matchLabels: {"x4b.net/prepull-id": $name}},
                    updateStrategy: {type: "RollingUpdate"},
                    template: {
                        metadata: {
                            labels: {
                                "app.kubernetes.io/name": "k8s-deploy-prepull",
                                "x4b.net/prepull-id": $name
                            }
                        },
                        spec: {
                            serviceAccountName: $name,
                            automountServiceAccountToken: true,
                            nodeSelector: $nodeSelector,
                            tolerations: $tolerations,
                            terminationGracePeriodSeconds: 5,
                            securityContext: {
                                runAsNonRoot: true,
                                runAsUser: 101,
                                runAsGroup: 102,
                                fsGroup: 102,
                                seccompProfile: {type: "RuntimeDefault"}
                            },
                            imagePullSecrets: ($imagePullSecrets | map({name: .})),
                            volumes: ($images | to_entries | map({
                                name: ("prepull-image-" + (.key | tostring)),
                                image: {
                                    reference: .value,
                                    pullPolicy: "Always"
                                }
                            })),
                            containers: [{
                                name: "cleanup-watchdog",
                                image: $helperImage,
                                imagePullPolicy: "IfNotPresent",
                                command: ["/bin/sh", "-ceu"],
                                args: [
                                    "for path in /prepull/image-*; do test -d \"$path\"; done\n" +
                                    "sleep \"$CLEANUP_TIMEOUT_SECONDS\"\n" +
                                    "token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\n" +
                                    "curl --fail-with-body --silent --show-error --request DELETE " +
                                    "--cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt " +
                                    "--header \"Authorization: Bearer $token\" " +
                                    "\"https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" +
                                    "/apis/apps/v1/namespaces/${POD_NAMESPACE}/daemonsets/${DAEMONSET_NAME}\""
                                ],
                                env: [
                                    {name: "CLEANUP_TIMEOUT_SECONDS", value: $cleanupTimeout},
                                    {name: "DAEMONSET_NAME", value: $name},
                                    {
                                        name: "POD_NAMESPACE",
                                        valueFrom: {fieldRef: {fieldPath: "metadata.namespace"}}
                                    }
                                ],
                                readinessProbe: {
                                    exec: {command: [
                                        "/bin/sh", "-ceu",
                                        "for path in /prepull/image-*; do test -d \"$path\"; done"
                                    ]},
                                    initialDelaySeconds: 0,
                                    periodSeconds: 2,
                                    timeoutSeconds: 1,
                                    failureThreshold: 3
                                },
                                resources: {
                                    requests: {cpu: "5m", memory: "16Mi"},
                                    limits: {cpu: "100m", memory: "64Mi"}
                                },
                                securityContext: {
                                    allowPrivilegeEscalation: false,
                                    readOnlyRootFilesystem: true,
                                    capabilities: {drop: ["ALL"]}
                                },
                                volumeMounts: ($images | to_entries | map({
                                    name: ("prepull-image-" + (.key | tostring)),
                                    mountPath: ("/prepull/image-" + (.key | tostring)),
                                    readOnly: true
                                }))
                            }]
                        }
                    }
                }
            }
        ]
    }
    ' > "$manifest_file"

printf 'Validating temporary pre-pull resources for namespace %s\n' "$namespace"
"$KUBECTL_BIN" apply --dry-run=server -f "$manifest_file" >/dev/null

printf 'Creating temporary pre-pull DaemonSet %s\n' "$resource_name"
"$KUBECTL_BIN" apply -f "$manifest_file" >/dev/null

daemonset_uid="$("$KUBECTL_BIN" -n "$namespace" get daemonset "$resource_name" -o jsonpath='{.metadata.uid}')"
[[ -n "$daemonset_uid" ]] || die "could not determine the pre-pull DaemonSet UID"

owner_patch="$(jq -cn \
    --arg name "$resource_name" \
    --arg uid "$daemonset_uid" \
    '{metadata: {ownerReferences: [{apiVersion: "apps/v1", kind: "DaemonSet", name: $name, uid: $uid, controller: false, blockOwnerDeletion: false}]}}')"

for resource_kind in serviceaccount role rolebinding; do
    "$KUBECTL_BIN" -n "$namespace" patch "$resource_kind" "$resource_name" --type=merge -p "$owner_patch" >/dev/null
done

desired=""
discovery_attempts="${PREPULL_DISCOVERY_ATTEMPTS:-30}"
for ((attempt = 1; attempt <= discovery_attempts; attempt++)); do
    desired="$("$KUBECTL_BIN" -n "$namespace" get daemonset "$resource_name" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)"
    if [[ "$desired" =~ ^[1-9][0-9]*$ ]]; then
        break
    fi
    sleep 1
done

[[ "$desired" =~ ^[1-9][0-9]*$ ]] \
    || die "pre-pull node selector matched no schedulable workers"

printf 'Waiting up to %s for image pre-pull on %s worker(s)\n' "$rollout_timeout" "$desired"
"$KUBECTL_BIN" -n "$namespace" rollout status "daemonset/$resource_name" --timeout="$rollout_timeout"

daemonset_status="$("$KUBECTL_BIN" -n "$namespace" get daemonset "$resource_name" -o json)"
jq -e '
    .status.desiredNumberScheduled > 0 and
    .status.numberReady == .status.desiredNumberScheduled and
    .status.numberAvailable == .status.desiredNumberScheduled and
    (.status.numberUnavailable // 0) == 0
' <<< "$daemonset_status" >/dev/null || die "pre-pull DaemonSet did not become ready on every intended worker"

printf 'Pre-pulled %s image(s) onto %s worker(s)\n' "${#IMAGES[@]}" "$desired"

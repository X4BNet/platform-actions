# X4BNet platform actions

## `k8s-deploy`

`X4BNet/platform-actions/k8s-deploy@v1` is compatible with the inputs accepted by
`Azure/k8s-deploy@v1`. For deploy operations it first creates a temporary
DaemonSet that mounts every deployment image through Kubernetes image volumes,
waits for those images to be available on all selected workers, and then invokes
the Azure action with the same image references.

```yaml
- uses: X4BNet/platform-actions/k8s-deploy@v1
  with:
    namespace: development
    manifests: combined.yaml
    images: x4bnet/x4b-site:git-${{ github.sha }}
    imagepullsecrets: regcred
    kubectl-version: latest
    prepull-node-selector: '{"k8s.x4b.net/ready":"1"}'
```

Each non-empty line in `images` must contain a repository/image path and an
explicit tag or sha256 digest. `prepull-node-selector` must be a non-empty JSON
object so an accidental invocation cannot pull large images onto every cluster
node. Optional `prepull-tolerations` accepts a JSON array of Kubernetes
toleration objects.

Before applying manifests, the action gracefully deletes existing pods whose
init, regular, or ephemeral containers are in `CrashLoopBackOff`, allowing their
controllers to recreate them. By default this checks the whole target namespace;
set `crashloop-pod-selector` to a Kubernetes label selector to narrow the pods in
scope. Set `delete-crashloopbackoff-pods: "false"` to disable this behavior.

The default pre-pull rollout timeout is five minutes. A restricted in-cluster
watchdog deletes the DaemonSet after ten minutes if the runner disappears, while
an `always()` cleanup step removes the DaemonSet and its namespaced RBAC resources
after success or failure. The watchdog ServiceAccount can delete only its own
uniquely named DaemonSet.

The target cluster must support the Kubernetes `ImageVolume` feature and the
workflow identity must be able to create, patch, read, and delete DaemonSets,
ServiceAccounts, Roles, and RoleBindings, and to list and delete Pods in the
target namespace. Cluster context must be configured before invoking the action.

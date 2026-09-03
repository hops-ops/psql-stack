# psql-stack

PostgreSQL platform layer on top of [CloudNativePG](https://cloudnative-pg.io/). Composes the CNPG operator, the [`cnpg-i-scale-to-zero` plugin](https://github.com/xataio/cnpg-i-scale-to-zero), the [Atlas Operator](https://atlasgo.io/integrations/kubernetes/operator) (declarative schema migrations), a paired `psql` `StorageClass` + `VolumeSnapshotClass` that PSQLClusters and PSQLBranches default to.

This is the **platform layer** — it does not create any serving Postgres clusters. Per-app DBs live in [`PSQLCluster`](../../psql-cluster/), ephemeral forks in [`PSQLBranch`](../../psql-branch/).

## Design

- **Paired StorageClass + VolumeSnapshotClass, both named `psql`.** Snapshots only work when the snapshotter driver matches the underlying StorageClass provisioner, so the stack composes both with the same CSI driver value. PSQLClusters and PSQLBranches default `spec.storage.class: psql` (XRD default), so consumer manifests don't have to know the driver. Default driver/provisioner is `ebs.csi.eks.amazonaws.com` (EKS Auto Mode); override `storageClass.provisioner` + `snapshotClass.driver` together for non-EKS targets (kind, self-managed Longhorn, etc.).
- **No NodePool / node-prep.** Components run wherever the cluster's scheduler puts them. Auto Mode handles node provisioning end-to-end.

If you need replicated CoW storage (true block-level branches with delta-only economics), that's a separate concern — see `aws-storage-stack` for self-managed nodes that can host Longhorn or similar. The default psql-stack stays on the AWS-blessed Auto Mode path.

## Components

| Component | Default | Purpose |
|---|---|---|
| **CNPG operator** | always-on | The CNCF Postgres operator. CRDs include `Cluster`, `Backup`, `Pooler`, `ScheduledBackup`. |
| **cnpg-i-scale-to-zero plugin** | on (`spec.scaleToZeroPlugin.enabled: true`) | Auto-hibernates idle CNPG `Cluster`s. **Requires cert-manager** (provided by [`aws-cert-stack`](../../aws/cert/)). |
| **Atlas operator** | always-on | Declarative schema migrations via `AtlasMigration` / `AtlasSchema` CRDs. |
| **StorageClass** | on (`spec.storageClass.enabled: true`) | Named `psql` by default. Provisioner: `ebs.csi.eks.amazonaws.com` with `type: gp3`. PSQLCluster + PSQLBranch reference it as their default `spec.storage.class`. |
| **VolumeSnapshotClass** | on (`spec.snapshotClass.enabled: true`) | Named `psql` by default. Driver matches `storageClass.provisioner`. PSQLBranch references it for snapshot/fork. |
| **HA mode** | off (`spec.ha.enabled: false`) | When enabled: 3 replicas + `topologySpreadConstraints` by zone on CNPG, Atlas, S2Z plugin. |

## Prerequisites

- **A working CSI driver** on the cluster matching `storageClass.provisioner`. EKS Auto Mode provides `ebs.csi.eks.amazonaws.com` automatically. For other targets, override `storageClass.provisioner` (and the matching `snapshotClass.driver`) to whatever the target cluster has — e.g. `hostpath.csi.k8s.io` for kind, `driver.longhorn.io` for self-managed Longhorn.
- **VolumeSnapshot CRDs + snapshot-controller** (`snapshot.storage.k8s.io`). EKS Auto Mode ships the snapshot CRDs but **not** the cluster-wide snapshot-controller. Without one, the composed VolumeSnapshotClass is inert and PSQLBranch snapshots will never reach `ReadyToUse`. Install [`volume-snapshot-stack`](../volume-snapshot/) (also in this org) — it composes the upstream snapshot-controller via the piraeus-charts Helm chart and is the canonical CRD installer for the cluster.
- **cert-manager** (only when `scaleToZeroPlugin.enabled` — the plugin uses cert-manager Issuer+Certificate for its gRPC TLS). Provided by [`aws-cert-stack`](../../aws/cert/).

## Stages

### Stage 1: Default install

Deploy with all defaults. CNPG + Atlas + S2Z + a `psql` VolumeSnapshotClass for EBS.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: my-cluster
```

### Stage 2: Production posture

HA on; per-component value tweaks; team labels for cost allocation.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: production-cluster
  namespace: cnpg-system
  labels:
    team: platform
  ha:
    enabled: true
    replicas: 3
    topologySpreadByZone: true
  atlasOperator:
    values:
      prewarmDevDB: true
```

### Stage 3: Non-EKS cluster

Override the SC + VSC driver together (they must match for snapshots to work). Example: self-managed cluster running Longhorn.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: edge
  helmProviderConfigRef:
    name: default
  storageClass:
    provisioner: driver.longhorn.io
    parameters:
      numberOfReplicas: "3"
  snapshotClass:
    driver: driver.longhorn.io
```

### Stage 4: Opt out of the composed StorageClass

If the cluster already ships a suitable default StorageClass, disable composition and have PSQLCluster/PSQLBranch consumers set `spec.storage.class` explicitly.

### Preview branch credentials

Snapshot recovery restores PostgreSQL data and roles, but not Kubernetes
Secrets. `PSQLBranch` therefore defaults to CloudNativePG-managed,
branch-local credentials: it creates `<branch-name>-app` for `spec.app.role`
and resets that recovered role's password. Set `spec.app.secretName` only when
the destination namespace already contains a compatible basic-auth Secret.

For migration jobs that need the `postgres` role, set
`spec.superuser.enabled: true`. CloudNativePG then creates
`<branch-name>-superuser`; `spec.superuser.secretName` selects a pre-existing
Secret instead. Connection Secret names and the branch service endpoint are
reported in `status.app` and `status.superuser`.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: shared-cluster
  helmProviderConfigRef:
    name: default
  storageClass:
    enabled: false
```

### Stage 5: Local / no-snapshot cluster

For dev clusters without a snapshot-controller, disable the VSC composition. PSQLBranch won't function (it needs the VSC), but PSQLCluster still works.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: local
  helmProviderConfigRef:
    name: default
  snapshotClass:
    enabled: false
  scaleToZeroPlugin:
    enabled: false
```

## Spec Reference

| Field | Type | Default | Description |
|---|---|---|---|
| `clusterName` | string | _required_ | Target cluster name; default for `helmProviderConfigRef.name`, `kubernetesProviderConfigRef.name`, and label values |
| `namespace` | string | `cnpg-system` | Shared namespace for CNPG, S2Z plugin, and Atlas |
| `labels` | object | — | Custom labels merged with stack defaults |
| `managementPolicies` | string[] | `["*"]` | Crossplane management policies |
| `helmProviderConfigRef.name` | string | `clusterName` | Helm ProviderConfig name |
| `helmProviderConfigRef.kind` | enum | `ProviderConfig` | `ProviderConfig` or `ClusterProviderConfig` |
| `kubernetesProviderConfigRef.name` | string | `clusterName` | Kubernetes ProviderConfig name |
| `kubernetesProviderConfigRef.kind` | enum | `ProviderConfig` | Same as above |
| **HA mode** | | | |
| `ha.enabled` | bool | `false` | Stack-wide HA toggle |
| `ha.replicas` | int | `3` | Replica count for HA-able platform components |
| `ha.topologySpreadByZone` | bool | `true` | Add `topologySpreadConstraint` with `topologyKey=topology.kubernetes.io/zone`, `maxSkew=1`, `whenUnsatisfiable=ScheduleAnyway` |
| **CNPG operator** | | | |
| `cnpg.name` | string | `cloudnative-pg` | Helm release name |
| `cnpg.chartVersion` | string | `0.27.1` | CNPG Helm chart version (tracks CNPG 1.29.x) |
| `cnpg.values` | object | — | Helm values merged with chart defaults |
| `cnpg.overrideAllValues` | object | — | Helm values that replace all defaults |
| **Scale-to-zero plugin** | | | |
| `scaleToZeroPlugin.enabled` | bool | `true` | Install the plugin (zero-cost when no `Cluster` opts in) |
| `scaleToZeroPlugin.version` | string | `v0.1.7` | Plugin release tag |
| `scaleToZeroPlugin.namespace` | string | shared `namespace` | Override |
| **Atlas operator** | | | |
| `atlasOperator.name` | string | `atlas-operator` | Helm release name |
| `atlasOperator.namespace` | string | shared `namespace` | Override |
| `atlasOperator.values` | object | — | Helm values merged with chart defaults |
| `atlasOperator.overrideAllValues` | object | — | Helm values that replace all defaults |
| **Storage class** | | | |
| `storageClass.enabled` | bool | `true` | Compose the StorageClass |
| `storageClass.name` | string | `psql` | StorageClass name (PSQLCluster + PSQLBranch reference this) |
| `storageClass.provisioner` | string | `ebs.csi.eks.amazonaws.com` | CSI driver name. Must match `snapshotClass.driver` |
| `storageClass.reclaimPolicy` | enum | `Delete` | `Delete` or `Retain` |
| `storageClass.volumeBindingMode` | enum | `WaitForFirstConsumer` | `Immediate` or `WaitForFirstConsumer` |
| `storageClass.allowVolumeExpansion` | bool | `true` | Online PVC expansion (CNPG resizes via the same field on its `Cluster` CR) |
| `storageClass.parameters` | object | `{type: gp3}` | Provisioner-specific parameters |
| **Snapshot class** | | | |
| `snapshotClass.enabled` | bool | `true` | Compose the VolumeSnapshotClass |
| `snapshotClass.name` | string | `psql` | VolumeSnapshotClass name (PSQLBranch references this) |
| `snapshotClass.driver` | string | `ebs.csi.eks.amazonaws.com` | CSI driver. Must match `storageClass.provisioner` |
| `snapshotClass.deletionPolicy` | enum | `Delete` | `Delete` or `Retain` |
| `snapshotClass.parameters` | object | — | Driver-specific parameters |

## Composed Resources

| Resource | Kind | When |
|---|---|---|
| `cloudnative-pg` | `helm.m.crossplane.io/Release` | always |
| `atlas-operator` | `helm.m.crossplane.io/Release` | always |
| 9× `<name>-s2z-*` | `kubernetes.m.crossplane.io/Object` | `scaleToZeroPlugin.enabled: true` |
| `<name>-storageclass` | `kubernetes.m.crossplane.io/Object` | `storageClass.enabled: true` |
| `<name>-volumesnapshotclass` | `kubernetes.m.crossplane.io/Object` | `snapshotClass.enabled: true` |
| Various `Usage` | `protection.crossplane.io/Usage` | when both ends Ready (deletion ordering) |

## Dependencies

| Kind | Package | Version |
|---|---|---|
| Function | `crossplane-contrib/function-auto-ready` | `^v0` |
| Provider | `crossplane-contrib/provider-helm` | `^v1` |
| Provider | `crossplane-contrib/provider-kubernetes` | `^v1` |

## Development

```bash
make render             # Render all examples
make validate           # Validate against Crossplane schemas
make test               # KCL render tests (assert composed resource shapes)
make build              # Build the package
make render:standard    # Render a single example
```

## License

Apache-2.0

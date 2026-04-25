# psql-stack

PostgreSQL platform layer on top of [CloudNativePG](https://cloudnative-pg.io/). Composes the CNPG operator, the [`cnpg-i-scale-to-zero` plugin](https://github.com/xataio/cnpg-i-scale-to-zero), the [Atlas Operator](https://atlasgo.io/integrations/kubernetes/operator) (declarative schema migrations), and a `VolumeSnapshotClass` that PSQLBranch uses as a stable forking target.

This is the **platform layer** — it does not create any serving Postgres clusters. Per-app DBs live in [`PSQLCluster`](../../psql-cluster/), ephemeral forks in [`PSQLBranch`](../../psql-branch/).

## Design

The stack is intentionally **OS-agnostic and storage-agnostic**:

- **No StorageClass.** PSQLClusters target whatever StorageClass the cluster already provides (`gp3` on EKS Auto Mode, `standard` on kind/k3d, etc.).
- **No NodePool / node-prep.** Components run wherever the cluster's scheduler puts them. Auto Mode handles node provisioning end-to-end.
- **Single composed snapshot target.** The stack ships a `VolumeSnapshotClass` named `psql` so PSQLBranch can request snapshots without leaking driver-specific knowledge into PSQLBranch's spec. Default driver is `ebs.csi.aws.com` (EKS Auto Mode default); override for non-AWS clusters.

If you need replicated CoW storage (true block-level branches with delta-only economics), that's a separate concern — see `aws-storage-stack` for self-managed nodes that can host Longhorn or similar. The default psql-stack stays on the AWS-blessed Auto Mode path.

## Components

| Component | Default | Purpose |
|---|---|---|
| **CNPG operator** | always-on | The CNCF Postgres operator. CRDs include `Cluster`, `Backup`, `Pooler`, `ScheduledBackup`. |
| **cnpg-i-scale-to-zero plugin** | on (`spec.scaleToZeroPlugin.enabled: true`) | Auto-hibernates idle CNPG `Cluster`s. **Requires cert-manager** (provided by [`aws-cert-stack`](../../aws/cert/)). |
| **Atlas operator** | always-on | Declarative schema migrations via `AtlasMigration` / `AtlasSchema` CRDs. |
| **VolumeSnapshotClass** | on (`spec.snapshotClass.enabled: true`) | Named `psql` by default. Driver: `ebs.csi.aws.com`. PSQLBranch references this name. |
| **HA mode** | off (`spec.ha.enabled: false`) | When enabled: 3 replicas + `topologySpreadConstraints` by zone on CNPG, Atlas, S2Z plugin. |

## Prerequisites

- **A working CSI driver + StorageClass** on the cluster. EKS Auto Mode provides `gp3` + `ebs.csi.aws.com` automatically. For kind/k3d, the bundled `standard` SC works.
- **VolumeSnapshot CRDs** (snapshot.storage.k8s.io). EKS Auto Mode includes the snapshot-controller; for self-managed clusters install it from [kubernetes-csi/external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter).
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

### Stage 3: Non-AWS / non-EBS cluster

Override the snapshot driver (e.g. for a self-managed cluster running Longhorn, or a local cluster using hostpath CSI).

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
  snapshotClass:
    driver: driver.longhorn.io
```

### Stage 4: Local / no-snapshot cluster

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
| **Snapshot class** | | | |
| `snapshotClass.enabled` | bool | `true` | Compose the VolumeSnapshotClass |
| `snapshotClass.name` | string | `psql` | VolumeSnapshotClass name (PSQLBranch references this) |
| `snapshotClass.driver` | string | `ebs.csi.aws.com` | CSI driver |
| `snapshotClass.deletionPolicy` | enum | `Delete` | `Delete` or `Retain` |
| `snapshotClass.parameters` | object | — | Driver-specific parameters |

## Composed Resources

| Resource | Kind | When |
|---|---|---|
| `cloudnative-pg` | `helm.m.crossplane.io/Release` | always |
| `atlas-operator` | `helm.m.crossplane.io/Release` | always |
| 9× `<name>-s2z-*` | `kubernetes.m.crossplane.io/Object` | `scaleToZeroPlugin.enabled: true` |
| `<name>-volumesnapshotclass` | `kubernetes.m.crossplane.io/Object` | `snapshotClass.enabled: true` |
| Various `Usage` | `protection.crossplane.io/Usage` | when both ends Ready (deletion ordering) |

## Dependencies

| Kind | Package | Version |
|---|---|---|
| Function | `crossplane-contrib/function-auto-ready` | `>=v0.6.2` |
| Provider | `crossplane-contrib/provider-helm` | `>=v1` |
| Provider | `crossplane-contrib/provider-kubernetes` | `>=v1` |

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

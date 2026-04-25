# psql-stack

PostgreSQL platform stack on top of [CloudNativePG](https://cloudnative-pg.io/). Installs the operator, the [`cnpg-i-scale-to-zero` plugin](https://github.com/xataio/cnpg-i-scale-to-zero), Atlas Operator (schema migrations), and a tiered storage layer (OpenEBS Mayastor / OpenEBS LVM LocalPV / EBS gp3) on a target Kubernetes cluster.

This is the **platform layer** — it does not create any serving Postgres clusters. Per-app DBs live in [`PSQLCluster`](../../psql-cluster/) (separate XR), ephemeral forks in [`PSQLBranch`](../../psql-branch/) (separate XR).

## Why psql-stack?

**Without psql-stack:**
- Manual Helm installs of CNPG, Atlas, and any chosen storage engines on every cluster
- No deletion ordering — removing CNPG before Atlas can leave migrations dangling
- Inconsistent operator + plugin versions across environments
- No declarative substrate for the `cnpg-i-scale-to-zero` plugin (cert-manager-backed gRPC TLS, ServiceAccount + RBAC, sidecar config)

**With psql-stack:**
- Single claim deploys CNPG + S2Z plugin + Atlas + storage backends with production defaults
- Deletion order enforced via `protection.crossplane.io/Usage` resources
- Three storage profiles available — replicated NVMe-oF (Mayastor), single-node CoW (LVM), durable EBS — each independently toggleable
- Optional dedicated Karpenter NodePools (branches sub-pool spot, primary sub-pool on-demand) targeting NVMe instance-store nodes
- Pinnable upstream chart / plugin versions; Renovate keeps them current

## Components

| Component | Default | Purpose |
|---|---|---|
| **CNPG operator** | always-on | The CNCF Postgres operator. CRDs include `Cluster`, `Backup`, `Pooler`, `ScheduledBackup`. |
| **cnpg-i-scale-to-zero plugin** | on (`spec.scaleToZeroPlugin.enabled: true`) | Auto-hibernates idle CNPG `Cluster`s. Pinnable via `spec.scaleToZeroPlugin.version`. **Requires cert-manager** (provided by [`cert-manager-stack`](../cert-manager/) or `aws-external-dns-stack`). |
| **Atlas operator** | always-on | Declarative schema migrations via `AtlasMigration` / `AtlasSchema` CRDs. |
| **Karpenter NodePools** | off (`spec.nodePool.enabled: false`) | When enabled: `branches` sub-pool (spot arm64 NVMe) and `primary` sub-pool (on-demand arm64 NVMe). Targets `i4g.2xlarge` / `i4g.4xlarge` / `im4gn.2xlarge` by default. |
| **OpenEBS Mayastor** | off (`spec.storage.mayastor.enabled: false`) | Replicated NVMe-oF. Enterprise default for serving primaries — provides CoW snapshots + HA across N nodes. |
| **OpenEBS LVM LocalPV** | off (`spec.storage.lvm.enabled: false`) | Single-node CoW via LVM thin volumes. Cheaper than Mayastor; right for branches and dev. |
| **EBS gp3 StorageClass** | on (`spec.storage.ebs.enabled: true`) | Durable, no CoW. Always-on fallback profile. |

## Prerequisites

- **cert-manager** must be installed on the target cluster (the S2Z plugin uses cert-manager `Issuer` + `Certificate`s for its gRPC TLS material). Install via [`cert-manager-stack`](../cert-manager/) — single claim, no AWS deps.
- **Karpenter + EKS Auto Mode** if using `spec.nodePool` (the default `nodeClassName: default` references the EKS Auto Mode managed `NodeClass`).
- **Mayastor + LVM node-side prep** (hugepages, `nvme-tcp` kernel module, LVM volume group on instance-store NVMe) — currently a manual / out-of-stack concern. Phase 3b of the CNPG pivot will add a node-prep DaemonSet template; until it lands, leave `spec.storage.mayastor.enabled` and `spec.storage.lvm.enabled` at `false` unless you've prepped nodes yourself.

## The Journey

### Stage 1: Getting Started

Deploy the platform on a single cluster with EBS-only storage. No CoW, no NodePool — just CNPG + S2Z plugin + Atlas + a `psql-ebs` StorageClass.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: my-cluster
```

`PSQLCluster` resources targeting this stack pick `psql-ebs` as their storage class and use `pg_basebackup`-style branching (works on EBS; takes minutes for non-trivial DBs).

### Stage 2: Adding Local CoW

Enable LVM LocalPV for fast single-node CoW branches without committing to replicated storage. Useful for dev clusters and preview-environment workflows where node loss is acceptable.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: dev-cluster
  nodePool:
    enabled: true
    primary:
      enabled: false                 # branches-only sub-pool for dev
  storage:
    lvm:
      enabled: true
      volumeGroup: psql-vg
```

`PSQLBranch` resources can now reference `psql-lvm` for instant CoW forks via VolumeSnapshot.

### Stage 3: Production HA + Replicated CoW

Enable Mayastor for replicated NVMe-oF storage. Primary serving DBs get CoW + HA replication across the on-demand NodePool; branches stay on LVM (cheaper).

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
  nodePool:
    enabled: true
    branches:
      enabled: true
      limits: { cpu: "32", memory: "128Gi" }
    primary:
      enabled: true
      limits: { cpu: "64", memory: "256Gi" }
  storage:
    mayastor:
      enabled: true
      replicationFactor: 3
    lvm:
      enabled: true
    ebs:
      enabled: true
  scaleToZeroPlugin:
    enabled: true
  atlasOperator:
    values:
      prewarmDevDB: true
```

## Spec Reference

| Field | Type | Default | Description |
|---|---|---|---|
| `clusterName` | string | _required_ | Target cluster name; default for `helmProviderConfigRef.name` and resource naming |
| `namespace` | string | `cnpg-system` | Shared namespace for CNPG, S2Z plugin, and Atlas |
| `labels` | object | — | Custom labels merged with stack defaults |
| `managementPolicies` | string[] | `["*"]` | Crossplane management policies |
| `helmProviderConfigRef.name` | string | `clusterName` | Helm ProviderConfig name |
| `helmProviderConfigRef.kind` | enum | `ProviderConfig` | `ProviderConfig` or `ClusterProviderConfig` |
| `kubernetesProviderConfigRef.name` | string | `clusterName` | Kubernetes ProviderConfig name |
| `kubernetesProviderConfigRef.kind` | enum | `ProviderConfig` | Same as above |
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
| **NodePool** | | | |
| `nodePool.enabled` | bool | `false` | Master toggle for both sub-pools |
| `nodePool.nodeClassName` | string | `default` | EKS NodeClass referenced by both sub-pools |
| `nodePool.disruption.consolidationPolicy` | enum | `WhenEmptyOrUnderutilized` | Karpenter consolidation policy |
| `nodePool.disruption.consolidateAfter` | string | `60s` | Consolidation delay |
| `nodePool.branches.enabled` | bool | `true` | Spot arm64 NVMe sub-pool |
| `nodePool.branches.limits` | object | `{cpu: "32", memory: "128Gi"}` | Sub-pool limits |
| `nodePool.branches.requirements` | array | arm64 spot `i4g.2xlarge`/`i4g.4xlarge`/`im4gn.2xlarge` | Karpenter requirements |
| `nodePool.primary.enabled` | bool | `true` | On-demand arm64 NVMe sub-pool |
| `nodePool.primary.limits` | object | `{cpu: "32", memory: "128Gi"}` | Sub-pool limits |
| `nodePool.primary.requirements` | array | arm64 on-demand `i4g.2xlarge`/`i4g.4xlarge`/`im4gn.2xlarge` | Karpenter requirements |
| **Storage: Mayastor** | | | |
| `storage.mayastor.enabled` | bool | `false` | Install OpenEBS Mayastor + create `psql-mayastor` SC |
| `storage.mayastor.chartVersion` | string | `2.10.0` | Helm chart version |
| `storage.mayastor.storageClassName` | string | `psql-mayastor` | StorageClass name |
| `storage.mayastor.replicationFactor` | int | `3` | Replicas per volume |
| `storage.mayastor.thin` | bool | `true` | Thin provisioning (CoW) |
| `storage.mayastor.values` | object | — | Helm values merged with chart defaults |
| `storage.mayastor.overrideAllValues` | object | — | Helm values that replace all defaults |
| **Storage: LVM** | | | |
| `storage.lvm.enabled` | bool | `false` | Install OpenEBS LVM LocalPV + create `psql-lvm` SC |
| `storage.lvm.chartVersion` | string | `1.7.0` | Helm chart version |
| `storage.lvm.storageClassName` | string | `psql-lvm` | StorageClass name |
| `storage.lvm.volumeGroup` | string | `psql-vg` | LVM Volume Group on each node |
| `storage.lvm.values` | object | — | Helm values merged with chart defaults |
| `storage.lvm.overrideAllValues` | object | — | Helm values that replace all defaults |
| **Storage: EBS** | | | |
| `storage.ebs.enabled` | bool | `true` | Create the `psql-ebs` SC |
| `storage.ebs.storageClassName` | string | `psql-ebs` | StorageClass name |
| `storage.ebs.provisioner` | string | `ebs.csi.eks.amazonaws.com` | CSI provisioner |
| `storage.ebs.parameters` | object | `{type: gp3, fsType: ext4}` | Provisioner parameters |
| `storage.ebs.reclaimPolicy` | enum | `Delete` | `Delete` or `Retain` |
| `storage.ebs.volumeBindingMode` | enum | `WaitForFirstConsumer` | `Immediate` or `WaitForFirstConsumer` |
| `storage.ebs.allowVolumeExpansion` | bool | `true` | Allow PVC resize |

## Composed Resources

| Resource | Kind | When |
|---|---|---|
| `cloudnative-pg` | `helm.m.crossplane.io/Release` | always |
| `atlas-operator` | `helm.m.crossplane.io/Release` | always |
| 9× `<name>-s2z-*` | `kubernetes.m.crossplane.io/Object` | `scaleToZeroPlugin.enabled: true` (default) |
| `<name>-storageclass-ebs` | `kubernetes.m.crossplane.io/Object` | `storage.ebs.enabled: true` (default) |
| `openebs-lvm` | `helm.m.crossplane.io/Release` | `storage.lvm.enabled: true` |
| `<name>-storageclass-lvm` | `kubernetes.m.crossplane.io/Object` | `storage.lvm.enabled: true` |
| `<name>-volumesnapshotclass-lvm` | `kubernetes.m.crossplane.io/Object` | `storage.lvm.enabled: true` |
| `openebs-mayastor` | `helm.m.crossplane.io/Release` | `storage.mayastor.enabled: true` |
| `<name>-storageclass-mayastor` | `kubernetes.m.crossplane.io/Object` | `storage.mayastor.enabled: true` |
| `<name>-volumesnapshotclass-mayastor` | `kubernetes.m.crossplane.io/Object` | `storage.mayastor.enabled: true` |
| `<name>-nodepool-branches` | `kubernetes.m.crossplane.io/Object` | `nodePool.enabled: true && nodePool.branches.enabled: true` |
| `<name>-nodepool-primary` | `kubernetes.m.crossplane.io/Object` | `nodePool.enabled: true && nodePool.primary.enabled: true` |
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

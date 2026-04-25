# psql-stack

PostgreSQL platform stack on top of [CloudNativePG](https://cloudnative-pg.io/) with [OpenEBS Mayastor](https://github.com/openebs/mayastor) for replicated NVMe-oF storage. Installs the operator, the [`cnpg-i-scale-to-zero` plugin](https://github.com/xataio/cnpg-i-scale-to-zero), Atlas Operator (schema migrations), Mayastor + matching StorageClass + VolumeSnapshotClass, two Karpenter NodePools, and a node-prep DaemonSet.

This is the **platform layer** — it does not create any serving Postgres clusters. Per-app DBs live in [`PSQLCluster`](../../psql-cluster/) (separate XR), ephemeral forks in [`PSQLBranch`](../../psql-branch/) (separate XR).

## Why psql-stack?

**Without psql-stack:**
- Manual Helm installs of CNPG, Atlas, Mayastor on every cluster
- No deletion ordering — removing CNPG before Atlas can leave migrations dangling
- No node-side prep for Mayastor (hugepages + `nvme-tcp` module need to exist before the IO engine pods will run)
- No declarative substrate for the `cnpg-i-scale-to-zero` plugin (cert-manager-backed gRPC TLS, ServiceAccount + RBAC, sidecar config)

**With psql-stack:**
- Single claim deploys CNPG + S2Z plugin + Atlas + Mayastor + StorageClass with production defaults
- Deletion order enforced via `protection.crossplane.io/Usage` resources
- Replicated NVMe-oF CoW storage — `replicationFactor: 3` for primaries, `replicationFactor: 1` for ephemeral branches (per-PVC override). Single backend covers both uses.
- Dedicated Karpenter NodePools (`branches` spot, `primary` on-demand) targeting NVMe instance-store nodes (`i4g.2xlarge` / `i4g.4xlarge` / `im4gn.2xlarge` arm64 Graviton)
- Pinnable upstream chart / plugin versions; Renovate keeps them current

## Components

| Component | Default | Purpose |
|---|---|---|
| **CNPG operator** | always-on | The CNCF Postgres operator. CRDs include `Cluster`, `Backup`, `Pooler`, `ScheduledBackup`. |
| **cnpg-i-scale-to-zero plugin** | on (`spec.scaleToZeroPlugin.enabled: true`) | Auto-hibernates idle CNPG `Cluster`s. Pinnable via `spec.scaleToZeroPlugin.version`. **Requires cert-manager** (provided by [`aws-cert-stack`](../../aws/cert/)). |
| **Atlas operator** | always-on | Declarative schema migrations via `AtlasMigration` / `AtlasSchema` CRDs. |
| **Karpenter NodePools** | on (`spec.nodePool.enabled: true`) | `branches` (spot arm64 NVMe) and `primary` (on-demand arm64 NVMe). |
| **OpenEBS Mayastor** | on when `nodePool.enabled` | Replicated NVMe-oF storage with CoW snapshots. Single `psql` StorageClass + matching VolumeSnapshotClass. |
| **node-prep DaemonSet** | on when `nodePool.enabled` | Configures hugepages + loads `nvme-tcp` kernel module on each NVMe node (Mayastor prereqs). |

## Prerequisites

- **cert-manager** must be installed on the target cluster (the S2Z plugin uses cert-manager `Issuer` + `Certificate`s for its gRPC TLS material). Install via [`aws-cert-stack`](../../aws/cert/).
- **Karpenter + EKS Auto Mode** for the NodePools (the default `nodeClassName: default` references Auto Mode's managed `NodeClass`).

## The Journey

### Stage 1: Default install

Deploy with all defaults: CNPG + Atlas + S2Z plugin + Mayastor + dedicated NodePools. Karpenter provisions NVMe instance-store nodes when something requests them.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: my-cluster
```

### Stage 2: Production sizing

Tune NodePool limits, override Helm values, label for cost allocation.

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
      limits: { cpu: "32", memory: "128Gi" }
    primary:
      limits: { cpu: "64", memory: "256Gi" }
  storage:
    replicationFactor: 3
    thin: true
  atlasOperator:
    values:
      prewarmDevDB: true
```

### Stage 3: Local / no-NVMe clusters

For kind / k3d / clusters that can't run Mayastor, disable the NodePool. The stack then ships only CNPG + Atlas + S2Z plugin, and your PSQLClusters target whatever StorageClass the cluster provides.

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
  nodePool:
    enabled: false
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
| `nodePool.enabled` | bool | `true` | Master toggle. When false, Mayastor + StorageClass + node-prep are skipped too. |
| `nodePool.nodeClassName` | string | `default` | EKS NodeClass referenced by both sub-pools |
| `nodePool.disruption.consolidationPolicy` | enum | `WhenEmptyOrUnderutilized` | Karpenter consolidation policy |
| `nodePool.disruption.consolidateAfter` | string | `60s` | Consolidation delay |
| `nodePool.branches.enabled` | bool | `true` | Spot arm64 NVMe sub-pool |
| `nodePool.branches.limits` | object | `{cpu: "32", memory: "128Gi"}` | Sub-pool limits |
| `nodePool.branches.requirements` | array | arm64 spot `i4g.2xlarge`/`i4g.4xlarge`/`im4gn.2xlarge` | Karpenter requirements |
| `nodePool.primary.enabled` | bool | `true` | On-demand arm64 NVMe sub-pool |
| `nodePool.primary.limits` | object | `{cpu: "32", memory: "128Gi"}` | Sub-pool limits |
| `nodePool.primary.requirements` | array | arm64 on-demand `i4g.2xlarge`/`i4g.4xlarge`/`im4gn.2xlarge` | Karpenter requirements |
| **Storage (Mayastor)** | | | |
| `storage.chartVersion` | string | `2.10.0` | Mayastor Helm chart version |
| `storage.namespace` | string | `mayastor` | Helm release namespace |
| `storage.storageClassName` | string | `psql` | StorageClass name |
| `storage.replicationFactor` | int | `3` | Default replicas per volume (per-PVC override via parameters) |
| `storage.thin` | bool | `true` | Thin-provisioning (CoW) |
| `storage.values` | object | — | Helm values merged with chart defaults |
| `storage.overrideAllValues` | object | — | Helm values that replace all defaults |
| **Node prep** | | | |
| `nodePrep.enabled` | bool | `true` (when `nodePool.enabled`) | Compose the privileged DaemonSet |
| `nodePrep.hugepages.count` | int | `1024` | Number of 2MiB hugepages per node |
| `nodePrep.image` | string | `alpine:3.20` | Init container image (apk-install at runtime) |

## Composed Resources

| Resource | Kind | When |
|---|---|---|
| `cloudnative-pg` | `helm.m.crossplane.io/Release` | always |
| `atlas-operator` | `helm.m.crossplane.io/Release` | always |
| 9× `<name>-s2z-*` | `kubernetes.m.crossplane.io/Object` | `scaleToZeroPlugin.enabled: true` (default) |
| `openebs-mayastor` | `helm.m.crossplane.io/Release` | `nodePool.enabled: true` (default) |
| `<name>-storageclass-mayastor` | `kubernetes.m.crossplane.io/Object` | `nodePool.enabled: true` |
| `<name>-volumesnapshotclass-mayastor` | `kubernetes.m.crossplane.io/Object` | `nodePool.enabled: true` |
| `<name>-nodepool-branches` | `kubernetes.m.crossplane.io/Object` | `nodePool.enabled && nodePool.branches.enabled` |
| `<name>-nodepool-primary` | `kubernetes.m.crossplane.io/Object` | `nodePool.enabled && nodePool.primary.enabled` |
| `<name>-node-prep` | `kubernetes.m.crossplane.io/Object` (DaemonSet) | `nodePool.enabled && nodePrep.enabled` |
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

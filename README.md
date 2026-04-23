# psql-stack

PostgreSQL management stack deploying StackGres and Atlas Operator as Helm releases with safe deletion ordering.

## Why psql-stack?

**Without psql-stack:**
- Manual Helm installs of StackGres and Atlas on every cluster
- No guaranteed deletion order — removing StackGres before Atlas leaves orphaned migration state
- Inconsistent operator versions and configuration across environments
- No declarative, reviewable representation of your database tooling

**With psql-stack:**
- Single claim deploys both operators with production defaults
- Deletion ordering enforced via Usage resources — Atlas is always removed before StackGres
- Consistent configuration across clusters with customizable Helm values
- Crossplane manages lifecycle, drift detection, and rollback

## What Gets Deployed

- **StackGres Operator** — Full PostgreSQL lifecycle management with native Citus support for distributed PostgreSQL via `SGShardedCluster` CRDs
- **Atlas Operator** — Declarative database schema migrations via `AtlasMigration` and `AtlasSchema` CRDs
- **StorageClass** *(on by default, `storageClass.create: true`)* — `psql` class backed by the EKS Auto Mode EBS CSI driver (`ebs.csi.eks.amazonaws.com`). Name mirrors the per-stack convention used by the observe stack (`loki`/`prometheus`/`tempo`). The legacy `gp2` class on EKS Auto Mode uses a deprecated in-tree provisioner that no longer works.
- **Postgres connection Secret(s)** *(opt-in, `externalSecrets.enabled: true`)* — For each entry in `externalSecrets.connections[]`, composes an ESO `ExternalSecret` that pulls a single password from AWS Secrets Manager (published with `hops secrets sync aws`) and templates it with non-secret config (host/port/database/username/sslmode) into a K8s Secret with keys `url`, `host`, `port`, `username`, `database`, `sslmode`, `password`. Consumers reference whichever key they need: `AtlasSchema.devURLFrom` → `url`, `SGCluster.spec.configurations.credentials.users.superuser.password` → `password`, etc.
- **Karpenter NodePool** *(opt-in, `nodePool.enabled: true`)* — Dedicated nodes for database workloads. Default: arm64 spot on `r7g.large`/`r7g.xlarge`/`m7g.large`/`m7g.xlarge` (memory-optimized Graviton for cheap, low-contention scheduling). StackGres operator + REST API + jobs and Atlas are pinned here via nodeSelector + tolerations.
- **Usage resources** — Atlas is deleted before StackGres to prevent orphaned migration state; Helm releases are deleted before the NodePool so pods drain cleanly.

## The Journey

### Stage 1: Getting Started

Deploy the stack on a single cluster with defaults. StackGres gets the REST API enabled, Atlas gets dev DB prewarming, and everything lands in the `stackgres` namespace.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: my-cluster
```

### Stage 2: Team Usage

Add labels for ownership tracking, pin operators to a dedicated NodePool, and customize Helm values.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: production-cluster
  namespace: stackgres
  labels:
    team: platform
  nodePool:
    enabled: true
  stackgresOperator:
    values:
      deploy:
        restapi: true
  atlasOperator:
    values:
      prewarmDevDB: true
```

### Stage 3: Multi-Cluster / Advanced

Override namespaces per component, use a `ClusterProviderConfig`, or fully replace chart defaults.

```yaml
apiVersion: hops.ops.com.ai/v1alpha1
kind: PSQLStack
metadata:
  name: psql
  namespace: default
spec:
  clusterName: production-cluster
  helmProviderConfigRef:
    name: production-cluster
    kind: ClusterProviderConfig
  stackgresOperator:
    namespace: stackgres-system
  atlasOperator:
    namespace: atlas-system
    overrideAllValues:
      prewarmDevDB: false
      extraEnvs:
        - name: ATLAS_NO_UPDATE_NOTIFIER
          value: "true"
```

### Local Development

For local clusters (e.g. kind, k3d), point at the default Helm provider:

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
```

## Spec Reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `clusterName` | string | Yes | — | Target cluster name. Used as default for `helmProviderConfigRef.name` |
| `namespace` | string | No | `stackgres` | Shared namespace for both operators |
| `labels` | object | No | — | Custom labels merged with defaults |
| `managementPolicies` | string[] | No | `["*"]` | Crossplane management policies |
| `helmProviderConfigRef.name` | string | No | `clusterName` | Helm ProviderConfig name |
| `helmProviderConfigRef.kind` | enum | No | `ProviderConfig` | `ProviderConfig` or `ClusterProviderConfig` |
| `kubernetesProviderConfigRef.name` | string | No | `clusterName` | Kubernetes ProviderConfig name (for the NodePool Object) |
| `kubernetesProviderConfigRef.kind` | enum | No | `ProviderConfig` | `ProviderConfig` or `ClusterProviderConfig` |
| `nodePool.enabled` | boolean | No | `false` | Create a dedicated Karpenter NodePool and schedule operators on it |
| `nodePool.nodeClassName` | string | No | `default` | EKS NodeClass name |
| `nodePool.limits.cpu` | string | No | `16` | Pool CPU limit |
| `nodePool.limits.memory` | string | No | `64Gi` | Pool memory limit |
| `nodePool.requirements` | array | No | arm64 spot `r7g.large`/`r7g.xlarge`/`m7g.large`/`m7g.xlarge` | Karpenter scheduling requirements |
| `nodePool.disruption.consolidationPolicy` | enum | No | `WhenEmptyOrUnderutilized` | Karpenter consolidation policy |
| `nodePool.disruption.consolidateAfter` | string | No | `60s` | Consolidation delay |
| `storageClass.create` | boolean | No | `true` | Create a StorageClass on the target cluster |
| `storageClass.name` | string | No | `psql` | StorageClass name (mirrors observe stack's per-stack naming) |
| `storageClass.provisioner` | string | No | `ebs.csi.eks.amazonaws.com` | CSI provisioner |
| `storageClass.parameters` | object | No | `{type: gp3, fsType: ext4}` | Provisioner parameters |
| `storageClass.volumeBindingMode` | enum | No | `WaitForFirstConsumer` | `Immediate` or `WaitForFirstConsumer` |
| `storageClass.allowVolumeExpansion` | boolean | No | `true` | Allow PVC resize |
| `storageClass.reclaimPolicy` | enum | No | `Delete` | `Delete` or `Retain` |
| `externalSecrets.enabled` | boolean | No | `false` | Enable ESO integration |
| `externalSecrets.clusterSecretStoreName` | string | No | `hops-aws-secrets-manager` | Name of the ClusterSecretStore |
| `externalSecrets.refreshInterval` | string | No | `1h` | ESO refresh interval |
| `externalSecrets.connections[].name` | string | Yes | — | K8s Secret name (also the connection identifier) |
| `externalSecrets.connections[].namespace` | string | No | stack `namespace` | K8s Secret namespace |
| `externalSecrets.connections[].passwordPath` | string | Yes | — | AWS Secrets Manager secret name containing the password |
| `externalSecrets.connections[].passwordKey` | string | No | `password` | JSON key in the AWS secret holding the password |
| `externalSecrets.connections[].host` | string | Yes | — | Postgres host (e.g. `test-pg.stackgres.svc.cluster.local`) |
| `externalSecrets.connections[].port` | integer | No | `5432` | Postgres port |
| `externalSecrets.connections[].username` | string | No | `postgres` | Postgres username |
| `externalSecrets.connections[].database` | string | Yes | — | Database name |
| `externalSecrets.connections[].sslmode` | string | No | `disable` | sslmode query parameter |
| `stackgresOperator.name` | string | No | `stackgres-operator` | Helm release name |
| `stackgresOperator.namespace` | string | No | shared `namespace` | Namespace override |
| `stackgresOperator.values` | object | No | — | Helm values merged with chart defaults |
| `stackgresOperator.overrideAllValues` | object | No | — | Helm values replacing all defaults |
| `atlasOperator.name` | string | No | `atlas-operator` | Helm release name |
| `atlasOperator.namespace` | string | No | shared `namespace` | Namespace override |
| `atlasOperator.values` | object | No | — | Helm values merged with chart defaults |
| `atlasOperator.overrideAllValues` | object | No | — | Helm values replacing all defaults |

### Helm Values Merging

Each operator supports two modes:

- **`values`** — Merged with chart defaults. Use this to tweak individual settings.
- **`overrideAllValues`** — Replaces all defaults entirely. Use this when you need full control.

If both are set, `overrideAllValues` wins.

**Chart defaults for StackGres:**
```yaml
deploy:
  operator: true
  restapi: true
```

**Chart defaults for Atlas:**
```yaml
prewarmDevDB: true
```

## Status

| Field | Type | Description |
|-------|------|-------------|
| `status.ready` | boolean | `true` when both operators are healthy |

## Composed Resources

| Resource | Kind | Purpose |
|----------|------|---------|
| `storageclass` | `kubernetes.m.crossplane.io/Object` | StorageClass (default name `psql`; when `storageClass.create: true`) |
| `connsecret-<name>` | `kubernetes.m.crossplane.io/Object` | One per `externalSecrets.connections[]` entry; wraps an ESO `ExternalSecret` that assembles a connection Secret |
| `nodepool-psql` | `kubernetes.m.crossplane.io/Object` | Karpenter NodePool (only when `nodePool.enabled: true`) |
| `stackgres-operator` | `helm.m.crossplane.io/Release` | StackGres Helm release |
| `atlas-operator` | `helm.m.crossplane.io/Release` | Atlas Operator Helm release |
| `usage-sg-atlas` | `protection.crossplane.io/Usage` | Atlas deleted before StackGres |
| `usage-np-stackgres-operator` | `protection.crossplane.io/Usage` | StackGres drained before NodePool is deleted (when NodePool enabled) |
| `usage-np-atlas-operator` | `protection.crossplane.io/Usage` | Atlas drained before NodePool is deleted (when NodePool enabled) |

## Dependencies

| Kind | Package | Version |
|------|---------|---------|
| Function | `crossplane-contrib/function-auto-ready` | `>=v0.6.0` |
| Provider | `crossplane-contrib/provider-helm` | `>=v1` |
| Provider | `crossplane-contrib/provider-kubernetes` | `>=v1` (only used when `nodePool.enabled`) |

## Development

```bash
make render       # Render all examples
make validate     # Validate against Crossplane schemas
make test         # Run unit tests (KCL)
make e2e          # Run E2E tests (requires cluster)
make build        # Build the package
make render:minimal   # Render a single example
make validate:standard
```

## License

Apache-2.0

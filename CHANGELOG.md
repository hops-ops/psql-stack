### What's changed in v0.7.0

* feat: pivot psql-stack to EKS Auto Mode defaults (#10) (by @patrickleet)

  * feat: optional NodePool for dedicated psql workloads

  Add opt-in Karpenter NodePool composed resource. When
  spec.nodePool.enabled: true, renders a NodePool targeting arm64 spot on
  r7g.large/r7g.xlarge/m7g.large/m7g.xlarge (memory-optimized Graviton),
  tainted with psql=true:NoSchedule and labeled workload-type: psql.

  StackGres (operator/restapi/jobs) and Atlas get nodeSelector + tolerations
  injected into their Helm values when the NodePool is enabled. Usages pin
  both releases to be drained before the NodePool is deleted. Adds
  provider-kubernetes to upbound.yaml for the NodePool Object wrapper.

  Implements [[tasks/psql-stack-vela-simplyblock]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: StorageClass + ExternalSecrets composed resources

  - storageClass (default on): creates a gp3 StorageClass backed by the
    EKS Auto Mode EBS CSI driver (ebs.csi.eks.amazonaws.com). The legacy
    gp2 in-tree provisioner does not work on EKS Auto Mode.
  - externalSecrets (opt-in): for each entry in externalSecrets.secrets[],
    composes a kubernetes.m.crossplane.io/Object wrapping an ESO
    ExternalSecret that syncs an AWS Secrets Manager value (published via
    hops secrets sync aws) into a Kubernetes Secret on the target cluster.
    Requires a ClusterSecretStore (e.g. from SecretStack); defaults to
    clusterSecretStoreName: hops-aws-secrets-manager.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * fix: default StorageClass name to 'psql' (per-stack naming)

  Mirrors observe stack where StorageClasses are named loki/prometheus/tempo
  per-component. Keeps the name specific to the stack so it doesn't collide
  with cluster-provided defaults.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: externalSecrets.connections[] composes password + config → URL

  Replaces the generic externalSecrets.secrets[] passthrough with a
  Postgres-specific connections[] API. The user publishes just a password
  via hops secrets (single JSON key, default 'password'); the stack
  combines it with non-secret host/port/database/username/sslmode/namespace
  and emits a K8s Secret with a ready-to-use 'url' key plus discrete fields.

  Downstream consumers reference whichever key they need:
    AtlasSchema.devURLFrom       → url
    SGCluster credentials.users.superuser.password → password
    applications                 → url (or discrete fields)

  Breaking change to the (locally-only) externalSecrets API; redeploy with
  the new shape.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * refactor: drop externalSecrets from PSQLStack

  Without managing the SGCluster, every field in externalSecrets.connections[]
  (host/port/database/namespace) is passthrough — no abstraction. Users write
  ExternalSecret CRs directly (or as a Crossplane Object wrapper in local/)
  against the ClusterSecretStore provisioned by SecretStack.

  PSQLStack now = platform only: StackGres + Atlas operators + NodePool +
  StorageClass. If we later add an instances[] that composes SGClusters,
  ESO wiring can come back for free since the stack will then know
  host/port/database/namespace without the user restating them.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: swap StackGres operator for CloudNativePG (phase 1 of CNPG pivot)

  Rewrites PSQLStack schema to remove stackgresOperator, add cnpg and
  scaleToZeroPlugin blocks. Default namespace: cnpg-system. CNPG 1.29
  (chart 0.27.1) replaces StackGres 1.18 as the operator. Atlas operator
  renumbered 210 → 220 to make room for the scale-to-zero plugin
  install (added in a later phase).

  Storage (psql StorageClass on EBS gp3) and NodePool blocks preserved
  unchanged — phases 2 and 3 will rewrite them for the three-profile
  (mayastor / lvm / ebs) storage model and the branches/primary NodePool
  split with hugepages + nvme-tcp pre-configured.

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: three-profile storage layer — mayastor + lvm + ebs (phase 2)

  Replaces the single storageClass block with a storage block exposing three
  independent profiles:

  - storage.mayastor (replicated NVMe-oF via OpenEBS Mayastor) — enterprise
    default for primary serving clusters; CoW + HA across N replicas. Default
    enabled=false until phase 3 lands the NodePool with hugepages + nvme-tcp.
  - storage.lvm (single-node CoW via OpenEBS LVM LocalPV) — branches and dev
    clusters. Default enabled=false until phase 3 lands NodePool LVM volume
    groups.
  - storage.ebs (EBS gp3 via EKS Auto Mode CSI) — durable fallback, no CoW;
    always-on default.

  Render templates:
  - 120-storageclass.yaml.gotmpl deleted (was the single 'psql' SC)
  - 160-openebs-lvm.yaml.gotmpl: Helm release for OpenEBS LVM LocalPV
  - 165-openebs-mayastor.yaml.gotmpl: Helm release for OpenEBS Mayastor
  - 170-storageclass-mayastor.yaml.gotmpl: psql-mayastor SC + VolumeSnapshotClass
  - 175-storageclass-lvm.yaml.gotmpl: psql-lvm SC + VolumeSnapshotClass
  - 180-storageclass-ebs.yaml.gotmpl: psql-ebs SC (renamed from 'psql')

  state-init defaults the three profile blocks; state-status observes the new
  resource keys. Mayastor + LVM Helm releases + their StorageClasses are gated
  on storage.{mayastor,lvm}.enabled — only EBS materializes by default until
  phase 3 unblocks the others.

  standard.yaml example patched to drop the removed storageClass and
  stackgresOperator fields (full example rewrite is phase 5).

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: split NodePool into branches + primary sub-pools (phase 3)

  Replaces the single Karpenter NodePool with two sub-pools targeting NVMe
  arm64 instance-store nodes (i4g.2xlarge / i4g.4xlarge / im4gn.2xlarge):

  - nodePool.branches: spot — for ephemeral PSQLBranch workloads. Spot is
    acceptable since branches are reproducible.
  - nodePool.primary: on-demand — for PSQLCluster primaries and operators
    (CNPG, Atlas, scale-to-zero). Spot preemption would lose a Mayastor
    replica, so on-demand is the right default for serving workloads.

  Each sub-pool has its own labels (sub-pool=branches | sub-pool=primary)
  and matching taints so workloads can target one specifically. Operators
  ride the primary sub-pool via nodeSelector + tolerations injected from
  state-init.

  Render templates:
  - 150-nodepool.yaml.gotmpl deleted
  - 140-nodepool-branches.yaml.gotmpl: spot sub-pool
  - 145-nodepool-primary.yaml.gotmpl: on-demand sub-pool + Usage protection
    for CNPG/Atlas Releases against premature NodePool deletion.

  state-init defaults the new sub-pool blocks; state-status observes both.
  nodePool.enabled stays default-false — existing claims unchanged.

  Out of scope for this commit: node-side prep for Mayastor + LVM
  (hugepages, nvme-tcp module, LVM volume group on instance-store NVMe).
  That's phase 3b (a separate concern that needs careful image / runtime
  choices) — without it, mayastor.enabled and lvm.enabled won't bind PVCs.

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: install cnpg-i-scale-to-zero plugin (phase 4)

  Inlines the upstream cnpg-i-scale-to-zero v0.1.7 release manifest as 9
  Crossplane Kubernetes Objects:

  - ServiceAccount cnpg-scale-to-zero-plugin
  - ClusterRole cnpg-scale-to-zero-sidecar-role + ClusterRoleBinding
  - Secret scale-to-zero-config (sidecar image reference, paired to plugin
    version via stringData — k8s base64-encodes on apply)
  - Self-signed cert-manager Issuer + 2 Certificates (server + client) for
    the gRPC TLS material the CNPG operator uses to reach the plugin
  - Service scale-to-zero (cnpg.io/pluginPort=9090, cnpg.io/pluginName
    annotations)
  - Deployment scale-to-zero (the plugin gRPC server)

  Plugin and sidecar images both pin to spec.scaleToZeroPlugin.version
  (default v0.1.7). Secret is renamed scale-to-zero-config (was
  scale-to-zero-config-c2c2544fbk in upstream — drops the kustomize
  hash suffix since we emit the resources as separate Objects).

  All resources are gated on spec.scaleToZeroPlugin.enabled (default true
  — the plugin is zero-cost when no PSQLCluster opts in).

  Source URL is annotated for renovate tracking:
    source: https://github.com/xataio/cnpg-i-scale-to-zero/releases/download/$VER/manifest.yaml
    renovate: datasource=github-releases depName=xataio/cnpg-i-scale-to-zero

  Prereq: cert-manager must be installed (provided by the dns-stack in
  hops-ops). Without it, the Issuer + Certificate resources won't reconcile
  and the plugin Deployment won't have its TLS volumes available.

  When PSQLClusters opt into scale-to-zero, they add:
    metadata.annotations:
      xata.io/scale-to-zero-enabled: "true"
      xata.io/scale-to-zero-inactivity-minutes: "10"
    spec.plugins:
      - name: cnpg-i-scale-to-zero.xata.io

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * docs/test: refresh README, examples, and render tests for CNPG pivot (phase 5)

  - README rewritten: CNPG architecture, three-stage journey (EBS-only →
    +LVM CoW → +Mayastor HA), full Spec Reference table, prereq notes
    (cert-manager via cert-manager-stack; node prep deferred to phase 3b)
  - examples refreshed:
    - minimal: just clusterName, EBS-only baseline
    - standard: full production posture (NodePool sub-pools, Mayastor +
      LVM + EBS, S2Z plugin, Atlas)
    - local: dev cluster with LVM CoW only (no Mayastor since replication
      needs >1 node, no NodePool, default Helm provider config)
  - tests/test-render/main.k: rewritten against the CNPG schema
    - dropped stackgresOperator-specific tests (field removed)
    - 11 tests covering: minimal renders platform operators; custom labels
      propagate; cnpg.overrideAllValues replaces defaults; atlas values
      merge; namespace propagation; per-component namespace override;
      helmProviderConfigRef defaults; scaleToZeroPlugin can be disabled;
      storage.{mayastor,lvm}.enabled compose Helm + StorageClass +
      VolumeSnapshotClass; nodePool.enabled composes both sub-pools

  All 11 tests pass; render + validate green on minimal + standard.

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: node-prep DaemonSet for Mayastor/LVM prereqs (phase 3b)

  Adds a privileged DaemonSet that runs on each NVMe NodePool node and
  configures the host-level state Mayastor + OpenEBS LVM LocalPV expect
  to find:

  - Hugepages (vm.nr_hugepages, default 1024 → 2GiB of 2MiB pages,
    required by Mayastor SPDK)
  - nvme-tcp kernel module loaded (Mayastor NVMe-oF transport)
  - LVM volume group on the first instance-store NVMe device
    (OpenEBS LVM LocalPV expects the VG to pre-exist)

  Auto-gated: composed only when nodePool.enabled AND
  (storage.mayastor.enabled OR storage.lvm.enabled). Inside the script,
  each step is conditional on the relevant storage backend.

  Schema additions:
  - spec.nodePrep.enabled (default true; auto-gated by storage backends)
  - spec.nodePrep.hugepages.count (default 1024)
  - spec.nodePrep.image (default alpine:3.20; apk-installs lvm2 +
    util-linux at startup)

  Render template 155-node-prep-daemonset.yaml.gotmpl:
  - DaemonSet with nodeSelector workload-type=psql + tolerations for
    both psql=true:NoSchedule and sub-pool=*:NoSchedule taints
  - hostPID + hostNetwork + privileged init container
  - Init script falls back gracefully on Bottlerocket / Auto Mode where
    modprobe inside containers is restricted (warns and continues)
  - Tiny pause container keeps the DS Ready

  state-init / state-status / 010-state-status updated for the new
  resource. Validate clean (22 resources on standard), 11/11 render
  tests still pass.

  Caveat: live verification on pat-local deferred until Mayastor or LVM
  is enabled in a PSQLStack claim there. Schema/composition is sound; e2e
  testing follows when storage backends are turned on.

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * refactor: drop LVM + EBS storage profiles, Mayastor-only

  Per-claim cost on Mayastor is controlled via replicationFactor (3 for
  primaries, 1 for ephemeral branches). LVM was a redundant single-node
  CoW backend; EBS was just wrapping the cluster's existing default SC
  and contradicted the stack's CoW-by-default identity.

  Schema changes:
  - spec.storage flattened — no more {mayastor,lvm,ebs} profile selector.
    Top-level fields now: chartVersion, namespace, storageClassName
    (default "psql"), replicationFactor, thin, reclaimPolicy,
    volumeBindingMode, allowVolumeExpansion, values, overrideAllValues.
  - spec.nodePool.enabled defaults to TRUE now (was false). The stack's
    whole point is dedicated NVMe nodes; the default should make it work.
  - Mayastor + StorageClass + node-prep DaemonSet all gated on
    nodePool.enabled. Disable nodePool to opt out (gets you only
    CNPG + Atlas + S2Z plugin running on the cluster's default SC).

  Render templates removed:
  - 160-openebs-lvm.yaml.gotmpl
  - 175-storageclass-lvm.yaml.gotmpl
  - 180-storageclass-ebs.yaml.gotmpl

  Render templates updated:
  - 165-openebs-mayastor.yaml.gotmpl: gated on nodePool.enabled (was
    storage.mayastor.enabled), uses flat $state.storage shape
  - 170-storageclass-mayastor.yaml.gotmpl: same gating + shape
  - 155-node-prep-daemonset.yaml.gotmpl: dropped LVM VG step, gated on
    just nodePool.enabled
  - 010-state-status.yaml.gotmpl: dropped LVM/EBS observed keys

  PSQLClusters that don't want CoW can specify any other StorageClass
  that exists on the target cluster (e.g., the EKS Auto Mode default
  gp3 SC). The stack does NOT compose a non-CoW SC — that's outside
  its identity.

  Examples + README rewritten. KCL tests updated: 10/10 passing.
  Validate clean: 18 resources on minimal, 18 on standard.

  Live verification on pat-local pending — would need to delete the
  existing claim (with ebs/lvm enabled) and reapply the simplified one.

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * nodepool + node-prep: spot primary, drop cluster prefix, DS creates DiskPools

  Three changes prompted by review:

  1. Primary sub-pool default is now spot (was on-demand). Mayastor's
     replicationFactor=3 absorbs preemption — losing one replica triggers
     a rebuild on a fresh node, not data loss. Override to on-demand via
     spec.nodePool.primary.requirements when needed.

  2. Karpenter NodePool inner names lose the cluster prefix. Was
     `<clusterName>-psql-{branches,primary}`, now `<XR.name>-{branches,primary}`
     (e.g. `psql-branches`, `psql-primary`). Less repetition; uses the
     stack's XR name for disambiguation when multiple PSQLStacks share a
     cluster (which is rare). Wrapper Crossplane Object names unchanged.

  3. node-prep DaemonSet now also registers the local NVMe instance-store
     device with Mayastor by creating a per-node DiskPool CR. New ServiceAccount
     + ClusterRole/Binding granting get/create/list/watch on
     diskpools.openebs.io. Init script: detects /dev/nvme[1-9]n1 by lsblk
     model match, kubectl-applies a DiskPool named psql-pool-<NODE_NAME>
     (idempotent — skip if already present). Closes the gap that left
     Mayastor pools empty and PVCs stuck Pending.

  This means no separate ObservedObjectCollection or custom function for
  DiskPool registration — the same DS that handles host-level prereqs
  (hugepages, nvme-tcp) also handles pool registration. One declarative
  artifact per node-prep concern.

  Also fixes a YAML colon issue in the primary sub-pool description.

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: stack-wide HA mode (replicaCount + topology spread by zone)

  Adds spec.ha block: a single toggle that enables production-style HA
  defaults across every HA-able platform component without users needing
  to know each chart's specific values keys.

  When spec.ha.enabled: true (default false):
  - CNPG operator: replicaCount=3 + topologySpreadConstraints by zone
  - Atlas operator: same
  - cnpg-i-scale-to-zero plugin Deployment (directly composed): same
  - OpenEBS Mayastor: agents.core / csi.controller / etcd replicaCount=3

  Per-component values can still override via the existing values block —
  HA values land in chartDefaults, user values mergeOverwrite them.

  Schema:
  - spec.ha.enabled (bool, default false)
  - spec.ha.replicas (int, default 3)
  - spec.ha.topologySpreadByZone (bool, default true)

  Standard example now demonstrates HA. New KCL test asserts replicaCount
  flows through to CNPG + Atlas Releases when ha.enabled=true. README
  updated with the new fields + a Components table entry.

  Render + validate clean (21 resources). 11/11 KCL tests pass.

  Implements [[tasks/psql-stack-cnpg]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * fix: skip Mayastor's bundled VolumeSnapshotClass CRDs

  Avoids Helm ownership conflicts when the cluster already has these CRDs
  from another source (e.g., a previous OpenEBS LVM install, the cluster's
  snapshot-controller, or another chart that bundles them).

  The CRDs (volumesnapshotclasses.snapshot.storage.k8s.io and friends) need
  to come from somewhere on the cluster — the assumption is that
  snapshot-controller is installed separately as a cluster-level concern,
  not bundled with each storage backend.

  Encountered live during pat-local install: leftover LVM CRD annotations
  blocked Mayastor's upgrade. Skip CRD install in our defaults to make this
  robust across re-installs.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * fix: confine Mayastor csi-node to workload-type=psql nodes

  csi-node DaemonSet was running on every cluster node, but workers without
  the node-prep DS don't have nvme_tcp loaded, so csi-node crashloops there
  ("Failed to detect nvme_tcp kernel module").

  Restrict csi-node via spec.csi.node.{nodeSelector,tolerations} to the
  same psql NodePool nodes where node-prep loads nvme_tcp. PSQLCluster
  workloads always schedule on workload-type=psql nodes via the existing
  NodePool selectors, so this doesn't restrict anything that actually
  consumes Mayastor PVCs.

  Also fixes a chartDefaults merge bug introduced when HA mode landed:
  both nodePool and HA were calling \`set chartDefaults "csi"\` which
  clobbered each other. Now build the csi sub-dict incrementally before
  adding it to chartDefaults.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat: pivot storage from Mayastor to Longhorn V2

  - 165-longhorn.yaml.gotmpl: longhorn chart 1.10.0, V2 data engine + SPDK
  - 170-storageclass-longhorn.yaml.gotmpl: driver.longhorn.io SC + VSC,
    dataEngine=v2, diskSelector=psql
  - 155-node-prep-daemonset.yaml.gotmpl: modprobe nvme_tcp / vfio_pci /
    uio_pci_generic / ublk_drv; replace DiskPool registration with
    node.longhorn.io/default-disks-config annotation
  - definition.yaml + state-init: chart defaults bump (1.10.0,
    longhorn-system); doc strings updated
  - 010-state-status: observe `longhorn` + `storageclass-longhorn`
  - README + examples updated; KCL tests updated and all 11 pass

  Mayastor checkpoint preserved on feat/cnpg-pivot. Longhorn V2 is
  "Experimental" upstream as of 1.10 — drops bundled etcd/NATS/minio/
  loki/alloy footprint and unblocks arm64 Graviton (Mayastor's chart
  hardcodes amd64 on io_engine).

  * feat: pivot psql-stack to EKS Auto Mode defaults

  Drops Mayastor/Longhorn experimentation entirely:
  - Remove NodePool sub-pools (branches + primary)
  - Remove node-prep DaemonSet
  - Remove Mayastor / Longhorn Helm release templates
  - Remove Mayastor/Longhorn StorageClass

  Slim spec.storage block down to spec.snapshotClass {enabled, name,
  driver, deletionPolicy, parameters}. Default driver ebs.csi.aws.com
  (EKS Auto Mode default); override for non-AWS providers. The stack
  no longer composes a StorageClass — PSQLClusters target whatever SC
  the cluster already provides.

  Stack now composes 4 things: CNPG operator, Atlas operator, S2Z
  plugin (9 Objects), and one VolumeSnapshotClass. CNPG/Atlas/S2Z
  templates lose nodeSelector/tolerations refs; they run wherever Auto
  Mode schedules them.

  XRD shrinks from ~290 lines to ~170. README rewritten — no more
  NVMe/SPDK/iscsi noise. Examples collapsed to clean shapes.

  Replicated CoW storage (Longhorn et al) is now a separate concern,
  to be provided by aws-storage-stack (self-managed ASG nodes with
  proper userData) when the multi-tenant CoW economics justify the
  operational cost. Bottlerocket/Auto Mode is incompatible with iscsi-
  based engines (longhorn-manager env-checks for iscsiadm even with
  V2; Bottlerocket's immutable rootfs blocks installation).

  Branch checkpoints preserved on:
    feat/cnpg-pivot       — Mayastor experiment
    feat/longhorn-pivot   — Longhorn V2 experiment

  * fix: default snapshot driver to ebs.csi.eks.amazonaws.com

  EKS Auto Mode uses the managed `ebs.csi.eks.amazonaws.com` CSI driver,
  not the upstream `ebs.csi.aws.com`. Fix the default in state-init,
  XRD, README, and the minimal example so out-of-the-box installs on
  Auto Mode produce a working VolumeSnapshotClass without override.

  Self-managed EBS users can still override `spec.snapshotClass.driver`
  to `ebs.csi.aws.com`; non-AWS users override to their CSI driver name.

  Verified live on pat-local: psql VSC reconciles to driver
  ebs.csi.eks.amazonaws.com, XR Synced=True Ready=True, CNPG + Atlas +
  S2Z plugin all running cleanly on Auto Mode without dedicated nodes.

  * docs: flag snapshot-controller as a prerequisite

  EKS Auto Mode ships the snapshot.storage.k8s.io CRDs but does NOT
  ship the snapshot-controller. Without a controller, our composed
  VolumeSnapshotClass is inert — PSQLBranch snapshots will sit
  forever without ever reaching ReadyToUse.

  Document it as a prerequisite (like cert-manager). The stack itself
  does not compose snapshot-controller — it's a foundational cluster
  concern that belongs in a separate stack (TBD: extend aws-cert-stack
  or create a focused snapshot-stack).

  Verified end-to-end on pat-local with the upstream
  kubernetes-csi/external-snapshotter v8.2.0 manifests:
    - PVC bound on ebs.csi.eks.amazonaws.com
    - VolumeSnapshot via the composed `psql` VSC reached
      readyToUse=true with a real EBS snapshot backing it.

  * docs: point snapshot-controller prereq at volume-snapshot-stack

  The dependency now exists as a real stack (xrs/stacks/k8s/volume-snapshot/,
  ghcr.io/hops-ops/volume-snapshot-stack). Replace the manual upstream-YAML
  install instructions with a pointer at the stack.

  * feat: merge psql-cluster + psql-branch APIs into psql-stack package

  Merges PSQLCluster and PSQLBranch XRDs (previously standalone repos under
  hops-ops/psql-cluster and hops-ops/psql-branch) into this package. One
  Configuration package, one release cadence, one e2e flow.

  Changes:
  - apis/{psqlclusters,psqlbranches}/ — XRDs and compositions copied in
  - examples/{psqlclusters,psqlbranches}/ — example manifests copied in
  - functions/render/ → functions/stack/ — renamed to make room for siblings
  - functions/{cluster,branch}/ — new function packages, gotmpls copied from
    the standalone repos. Composition functionRefs updated:
      psqlstacks    → hops-ops-psql-stackstack
      psqlclusters  → hops-ops-psql-stackcluster
      psqlbranches  → hops-ops-psql-stackbranch
  - tests/test-{stack,cluster,branch}/ — render tests renamed (was test-render-*)
  - tests/e2etest-psql/main.k — unified e2e covering all three XRs at Synced;
    TODO upgrade to Ready integration after volume-snapshot-stack v0.1.0
  - .github/workflows/on-pr.yaml + on-push-main.yaml — switched to multi-API
    workflow signature, pinned at @feat/multi-api-support for testing
  - Makefile — EXAMPLES list extended; render/validate logic still single-API
    (follow-up to make per-example api_path work locally)

  Workflow change being tested:
    unbounded-tech/workflows-crossplane@feat/multi-api-support
    (validate.yaml now resolves api_path per example with fallback to inputs.api_path)

  * test(e2e): upgrade unified psql e2e to full Ready integration

  volume-snapshot-stack v0.1.0 is now published, so we can install it as a
  dependency Configuration package and bring snapshot-controller into the
  test cluster. With that, the whole chain reconciles to Ready in-cluster:

    1. VolumeSnapshotStack XR (in extraResources) → snapshot-controller live
    2. PSQLStack manifest → Helm-installs CNPG + atlas-operator + the psql
       VolumeSnapshotClass
    3. PSQLCluster manifest → CNPG bootstraps a real Postgres with a real PVC
    4. PSQLBranch manifest → snapshots the source PVC, restores into a new
       CNPG cluster

  Pattern mirrors the aws-observe-stack e2e (initResources for dependency
  Configuration packages, extraResources for the dependent XRs).

  defaultConditions: Synced → Ready
  timeoutSeconds: 1800 → 5400 (90 min for the full chain)
  cleanupTimeoutSeconds: 900 → 1800

  * fix(e2e): drop StackGres-era spec fields from PSQLStack manifest

  The unified e2e was carrying over `stackgresOperator.values` and
  `atlasOperator.values` from before the CNPG pivot. The current
  PSQLStack XRD uses `cnpg` (not `stackgresOperator`), `namespace`
  defaults to `cnpg-system` (not `stackgres`), and the kind-cluster
  defaults work without any operator-values overrides.

  Match `local/psqlstack.yaml`'s minimal shape: clusterName + labels +
  ProviderConfig refs only. Add `kubernetesProviderConfigRef` since
  PSQLStack now also applies the VolumeSnapshotClass via the kubernetes
  provider.

  * docs(psqlstacks): correct stale CSI driver and VSC defaults

  Three locations claimed the default driver was `ebs.csi.aws.com` and the
  VolumeSnapshotClass was "named after the XR" — both wrong relative to the
  actual schema (driver `ebs.csi.eks.amazonaws.com`, name defaults to `psql`).
  This text shows up in `kubectl explain`, generated docs, and template
  comments, so it needed to match.

  Also clarified `status.ready` description: components are toggleable, so
  readiness is "every enabled component is Ready" rather than implying all
  four are mandatory.

  From CodeRabbit review on PR #10.

  * test(psqlstacks): assert Atlas Release in scale-to-zero-disabled test

  The s2z-disabled test description claimed cnpg + atlas + VSC are still
  composed, but only cnpg and the VSC were asserted — a regression that
  broke the Atlas Release would silently pass. Added the Atlas assertion.

  From CodeRabbit review on PR #10.

  * fix(psqlstacks): create CNPG/Atlas teardown-order Usage on existence, not readiness

  The Usage that protects cnpg-operator from premature deletion (so Atlas is
  torn down first and CNPG isn't yanked while Atlas's migration state is
  still live) was rendered only after both Releases reported Ready. That
  left a window: if Atlas was mid-progressing or in error and the user
  deleted the stack, no Usage existed yet, and CNPG could be deleted first
  — exactly the ordering this guard exists to prevent.

  Switched the gate from `$state.observed.{cnpg,atlasOperator}.ready` to
  `hasKey $.observed.resources "{cnpg,atlas}-operator"`. The Usage now
  appears as soon as both Releases are observed, regardless of their
  readiness state.

  Verified locally: render tests still pass; cluster reinstall via
  `hops config install --path` brings all three XRs back to Synced/Ready.

  From CodeRabbit review on PR #10.

  * feat(psqlcluster)!: rework credentials around app/superuser, ESO-shaped externalSecret

  The previous `credentials.superuser` shape was misleading: the secret named
  "superuser" was actually wired into CNPG's `bootstrap.initdb.secret`, which
  takes the *application user's* credentials. The actual postgres superuser
  secret was either auto-generated by CNPG or absent from the spec entirely.
  And it collided with CNPG's own `<cluster>-superuser` secret naming.

  New shape (no backwards compat — still alpha):

    spec.app:                     # always present; wires bootstrap.initdb
      role: app                   # Postgres role name
      database: app               # Application database name
      secretName: ""              # K8s Secret; default <cluster>-app
      externalSecret:             # OPTIONAL — when set, ESO renders the Secret
        secretStore:
          kind: ClusterSecretStore | SecretStore
          name: hops-aws-secrets-manager
          namespace: ""           # for SecretStore (defaults to XR ns)
        secretRef:
          path: my-cluster/app    # remote location; JSON value with username+password

    spec.superuser:               # OPTIONAL — omit to let CNPG auto-generate
      secretName: ""              # default <cluster>-superuser
      externalSecret: { ... }     # same shape as app.externalSecret

  When `superuser` is set, the composition renders `spec.superuserSecret` on
  the wrapped CNPG Cluster CR; otherwise CNPG auto-generates and stores the
  secret at `<cluster>-superuser` (its own convention).

  Field names mirror External Secrets Operator's CRD shape so anyone familiar
  with ESO can read it at a glance.

  Status now exposes connection details so dependent XRs can wire without
  hardcoding:
    status.app: { secretName, database, host, port }
    status.superuser: { secretName }

  Render template factored to a single `psqlcluster.externalSecret` definition
  so the app/superuser ExternalSecrets share one source of truth.

  Tests rewritten:
  - Test 1 ("minimal-renders-cluster-only") asserts default mode renders only
    the Cluster — no ExternalSecret, since externalSecret is now opt-in.
  - Test 7 ("external-secret-renders-when-opted-in") explicitly asserts the
    ESO ExternalSecret with the new shape.

  Migration for existing manifests: `credentials.superuser.managedBy: ""`
  → remove the block (BYO is now default). `credentials.superuser` with ESO
  fields → move under `spec.app.externalSecret` matching the new shape.

  From CodeRabbit review on PR #10.

  * build(make): derive xrd/composition/api_dir per example for multi-API repos

  The render:all and validate:all targets were hardcoded to apis/psqlstacks
  via $(DEFINITION)/$(COMPOSITION)/$(XRD_DIR), so multi-API examples
  (psqlclusters/*, psqlbranches/*) were rendered against the wrong schema.

  Each example now resolves its own apis/<plural>/ dir from the example path
  (`examples/<plural>/<file>.yaml` → `apis/<plural>`) and uses that for both
  `up composition render --xrd=...` and `crossplane beta validate <api_dir>`.

  Verified locally: `make render` and `make validate` both clean across all
  five examples.

  From CodeRabbit review on PR #10.

  * feat(psqlcluster): auto-gen app secret when neither field set

  Adds a third credential mode: omit `app.externalSecret` AND `app.secretName`
  and the composition omits `bootstrap.initdb.secret` from the CNPG Cluster CR
  so CNPG auto-generates and owns the basic-auth Secret at `<cluster-name>-app`.

  The previous shape always set `bootstrap.initdb.secret.name = <cluster>-app`,
  which forced CNPG to read a Secret that — in the no-ESO/no-BYO case — never
  existed, blocking bootstrap. The unified e2e hit this exact case (kind
  harness, no ESO ClusterSecretStore) and a stale `app.managedBy = ""` field
  was masking the real failure mode.

  Three modes now documented on the XRD:
    1. Omit `app` → CNPG auto-generates `<cluster-name>-app`.
    2. Set `app.externalSecret` → ESO writes the Secret CNPG reads.
    3. Set `app.secretName` (no externalSecret) → BYO; pre-create the Secret.

  Backwards compatible: existing manifests with externalSecret or explicit
  secretName render identically. CNPG will adopt a pre-existing
  `<cluster-name>-app` if one is present.

  Tests:
    - test-cluster: minimal asserts the secret line is omitted; external-secret
      asserts secret.name is wired; new BYO test covers explicit secretName.
    - e2etest-psql: drops the bogus `app.managedBy` field that broke KCL parse;
      relies on the new auto-gen path.

  Implements [[tasks/merge-psql-client-apis-into-stack]]

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

  * feat(psqlstack)!: compose paired psql StorageClass + pivot e2e to AWS

  PSQLStack now composes a `psql` StorageClass alongside its existing
  `psql` VolumeSnapshotClass — they share the same CSI driver
  (`ebs.csi.eks.amazonaws.com` by default) since snapshots only work
  when the snapshotter driver matches the source PVC's provisioner.
  PSQLCluster + PSQLBranch default `spec.storage.class` to "psql", so
  consumer manifests stop leaking driver-specific knowledge.

  Default StorageClass shape: gp3 + WaitForFirstConsumer (correct for
  zonal CSI drivers — late-binds the PVC to a node so EBS volumes land
  in the same AZ as the consuming pod) + allowVolumeExpansion=true
  (CNPG resizes via the same field on its Cluster CR).

  E2E pivots from kind to an ephemeral EKS Auto Mode cluster (mirror
  of aws-observe-stack): provisions an AutoEKSCluster per run, installs
  volume-snapshot-stack on it, then runs PSQLStack/Cluster/Branch
  against the real `ebs.csi.eks.amazonaws.com` driver — same code path
  that runs on pat-local. Kind has no snapshot-capable CSI driver
  natively, so the prior kind-only e2e couldn't exercise PSQLBranch's
  snapshot/fork chain.

  Verified end-to-end on pat-local:
    - PSQLStack composed `psql` SC + `psql` VSC (both with
      ebs.csi.eks.amazonaws.com)
    - PSQLCluster PVC bound on `psql` SC, CNPG primary running
    - PSQLBranch VolumeSnapshot reached readyToUse=true, restored PVC
      bound on `psql` SC, CNPG fork primary running

  Breaking: PSQLStack adds a new composed StorageClass by default. Sites
  that already have a `psql` SC will conflict — set
  `spec.storageClass.enabled: false` to opt out.

  Requires three GitHub Actions vars on the repo (synced via the new
  `hops vars sync github`): ADMIN_ROLE_ARN, PRIVATE_SUBNET_ID_A,
  PRIVATE_SUBNET_ID_B.

  * ci(e2e): install cert-stack alongside volume-snapshot-stack

  The full chain converged on the previous run except for PSQLStack's
  scaleToZeroPlugin objects (s2z-cert-client, s2z-cert-server, s2z-issuer)
  — the S2Z plugin uses cert-manager's Issuer + Certificate for its gRPC
  mTLS pair, and the ephemeral EKS cluster has no cert-manager. pat-local
  already has cert-manager from earlier setup, which masked this in local
  validation.

  cert-stack v0.1.0 mirrors volume-snapshot-stack's shape (single
  clusterName field, composes a Helm release on the target). Adding it
  as initResource + extraResource closes the gap.

  * ci: pin reusable workflows to hops-ops/workflows-crossplane@v3.0.0

  Replaces the four mutable `@feat/multi-api-support` branch refs with
  the immutable `@v3.0.0` tag now that the multi-api work is shipped.
  Also retargets the org from `unbounded-tech` to `hops-ops` — the
  canonical home for hops platform CI workflows.

  * fix(psqlbranch): drop default postgres version, gate imageName on explicit set

  The previous schema and gotmpl both defaulted branch postgres version to
  "17", silently coercing branches off PG 15/16 sources to a major mismatch.
  Volume snapshot recovery is binary-compatible only within a major version
  (Postgres won't open a data dir from a different major), so a hardcoded
  default produced silent failures at restore time.

  Now: omit imageName entirely when version is unset, letting CNPG fall back
  to its operator-default image (close-enough when source tracks the same
  chart). Setting spec.postgresql.version is now an explicit pin, typically
  used to fix a minor (e.g. "17.4") to match the source's reported version.

  Adds a render test for the explicit-pin path; existing default-path test
  asserts imageName absence.

  * test(psqlcluster): lock in monitoring.enabled=false honors explicit off

  Existing state-init logic correctly uses hasKey to distinguish "explicitly
  false" from "absent" before reading $monSpec.enabled, but no test exercised
  the explicit-false path. Added regression test asserting that
  spec.monitoring.enabled=false propagates to the composed Cluster CR's
  monitoring.enablePodMonitor=false. Default-on path covered by Test 1.

  * fix(psqlbranch): prefer source-snapshot content over empty branch content

  In cross-namespace branching, the branch-ns VolumeSnapshot can only bind
  once it learns the source's VolumeSnapshotContent name — that name is
  propagated through $state.observed.snapshotContent into 110-branch-snapshot's
  render. The previous logic preferred branch-snapshot whenever it was present
  in observed, even when its boundVolumeSnapshotContentName was still empty —
  which it always is on first reconcile, before the source content has
  propagated. Result: empty content overwrites the populated source content,
  the branch-ns snapshot renders with `volumeSnapshotContentName: ""`, and the
  chain stalls.

  Now: read both branch-ns and source-ns content via the existing pipeline,
  prefer branch when non-empty, fall back to source otherwise. Fixes the
  chicken-and-egg that prevented cross-namespace branches from binding on
  first-pass reconcile.

  Same-namespace branching is unaffected: source-snapshot is gated on
  crossNamespace and isn't composed there, so $sourceContent is empty and
  the branch-ns content (always populated post-bind) wins.

  * test(psqlbranch): cross-namespace state-status with observed fixtures

  Adds two CompositionTests that exercise 010-state-status's snapshot-
  content fallback against inline observedResources:

  1. branch-snapshot bound content empty + source-snapshot bound: branch-ns
     VolumeSnapshot must render with the source's content name (proves the
     chicken-and-egg fix from 18d3115).
  2. branch-snapshot bound + source-snapshot bound: steady-state — branch's
     content wins (proves the fallback doesn't overwrite a populated branch
     content with source's).

  Without the fix, test 1 would render volumeSnapshotContentName: "" and
  fail. With it, source's content propagates through state.observed.snapshotContent
  into 110-branch-snapshot's render. Locks in the cross-namespace bind
  behavior — the previous test surface only exercised render shape, not
  state propagation across reconciles.

  * fix(psqlbranch): prefix source-ns VolumeSnapshot name with branch namespace

  The source-ns VolumeSnapshot lives in a namespace shared by multiple
  branches (the source PSQLCluster's). Naming it just `<branchName>-src`
  collides when two PSQLBranch XRs have the same metadata.name in
  different branch namespaces — both would create
  `preview-pr-1-src` in `team-app`, racing on the same object.

  Now: `<branchNS>-<branchName>-src`. Encodes the branch XR's own
  namespace into the name so (sourceNS, branchNS, branchName) is unique.
  K8s names are bound by RFC 1123 subdomain (253 chars) — concatenation
  is safe at any reasonable namespace/branch length.

  Branch-ns snapshot (`<branchName>-snap`) is unchanged: the branch
  namespace is already implicit by where the resource lives, and branch
  XR names are unique within a single namespace.

  Adds a regression test that asserts the source-ns name varies with
  branch namespace.

  * fix(psqlbranch): fall back to source.storage.size when branch size empty

  Previously the gotmpl coerced unset `branch.storage.size` to a hardcoded
  "10Gi" — silently mis-sizing branches off any source PVC larger than that.
  CNPG/EBS can't shrink during recovery, so a 10Gi branch off a 100Gi source
  fails when CNPG tries to bind the restored PVC.

  New shape:
    - PSQLBranch XRD adds optional `spec.source.storage.size` so consumers
      can mirror the source PSQLCluster's known capacity. The branch
      composition has no automatic visibility into the source's PVC, so
      the user declares it once on the branch spec.
    - Size precedence in the cnpg-cluster render:
        branch.storage.size  (explicit override, e.g. growing the branch)
        → source.storage.size  (inherit from the source)
        → omitted             (CNPG's webhook rejects with a clear error)
    - Drops the silent 10Gi gotmpl fallback in 000-state-init.

  Examples + e2e branch updated to declare source.storage.size mirroring
  the source PSQLCluster's spec.storage.size. Local pat-local manifests
  already set branch.storage.size explicitly so unaffected.

  Symlinks the per-test KCL `model/` directory to `.up/kcl/models` so
  schema changes from `up project build` propagate to tests automatically.
  Previously the bundled models drifted from the XRD on every change and
  needed manual regeneration. `.up/` is gitignored — fresh clones run
  `make build` (or `up project build`) to populate the symlink target.

  Adds two regression tests: branch.size overrides source.size, and
  source.size used when branch.size is empty.

  * fix(psqlcluster): match ExternalSecret status lookup to actual resource names

  The state-status template looked up `external-secret` in the observed
  map, but 100-external-secret renders two distinct resources with
  suffixed names (`external-secret-app`, `external-secret-superuser`)
  when their respective config blocks are set. The lookup never matched,
  so $state.observed.externalSecret.ready was always false.

  Now: aggregate over both names. Ready=true when every present ES
  Object reports Ready=true, and Ready=true when neither is present
  (BYO / CNPG-managed-secret paths — nothing to wait on).

  Note: the field is currently unused (999-status doesn't surface it,
  no composition gates on it). Fixing now to match the documented
  intent so future consumers don't inherit the bug.

  * fix(make): use defined Makefile vars in validate:% recipe

  The validate:% recipe was using $$definition, $$composition, $$api_dir
  shell variables that were never initialized — `make validate:minimal`
  silently fed empty strings to `up composition render` and
  `crossplane beta validate`, so the recipe never produced a real
  validation result.

  Aligns validate:% with render:%: both now use the top-level Makefile
  variables ($(DEFINITION), $(COMPOSITION), $(XRD_DIR)) which point at
  apis/psqlstacks. Single-target shorthand stays psqlstacks-only as
  documented in README. The :all targets keep their derive-per-example
  shell logic for the multi-API case.

  * test(psqlcluster): assert full ExternalSecret data mapping

  Existing test 7 only asserted the ExternalSecret existed with the right
  secretStoreRef and target.name — it didn't lock in the data[] mappings
  or the basic-auth target template. The current gotmpl correctly maps
  both username and password as separate remoteRef entries (with
  `property: username` / `property: password`) extracted from the same
  JSON blob at secretRef.path, then synthesizes a kubernetes.io/basic-auth
  Secret. Asserting the full shape so a regression that drops one key
  fails the test instead of silently shipping a half-populated Secret.

  * fix(psqlcluster): bump ExternalSecret to external-secrets.io/v1

  ESO 0.10+ moved to v1 GA, and recent ESO charts (the version
  cert-stack/aws-secret-stack already use) drop the v1beta1
  served-version: applies fail with `no matches for kind
  "ExternalSecret" in version "external-secrets.io/v1beta1"`.

  Schema shape (data[].remoteRef.{key,property} + target.template) is
  identical between v1beta1 and v1, so this is a pure apiVersion bump.
  Aligns with the other stacks that already use v1 (auth, gitops,
  cloudflare/dns, aws/secret).

  * docs(psqlcluster): mirror externalSecret descriptions on superuser block

  The superuser.externalSecret schema had the same shape as
  app.externalSecret but no field descriptions, so kubectl explain and
  generated docs gave inconsistent guidance for what's the same contract.
  Adds the missing descriptions (secretStore.{kind,name,namespace} and
  secretRef.{path}) verbatim from app.externalSecret. Pure documentation
  change — no behavior, default, or required-fields shift.

  ---------

  Co-authored-by: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

* fix(ci): bring on-push-main e2e to parity with on-pr; cut over to hops-ops mirror v3.0.0 (by @patrickleet)

  The on-push-main e2e job was failing on main with `failed to access the
  file 'secrets/aws-creds': No such file or directory` because the
  workflow caller did not configure AWS OIDC, env-vars, or
  debug/delete-extra-resources. on-pr.yaml had the full setup; main was
  bare. Mirror the on-pr.yaml e2e block here so PR-green ⇒ main-green.

  Also flip all three callers from
  `unbounded-tech/workflows-crossplane@feat/multi-api-support` (and
  publish@v2.20.0) to `hops-ops/workflows-crossplane@v3.0.0` — multi-API
  support has tagged on the mirror; main pin should track it.

  Implements [[tasks/ci-fix-e2e-failures]]


See full diff: [v0.6.0...v0.7.0](https://github.com/hops-ops/psql-stack/compare/v0.6.0...v0.7.0)

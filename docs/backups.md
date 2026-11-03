# Physical backups and recovery

`PSQLStack.spec.backupPlugin.enabled` installs the shared Barman Cloud CNPG-I
plugin. `PSQLCluster.spec.backup` owns each database's ObjectStore, archive plugin,
and ScheduledBackup. Both are opt-in; existing claims keep their current defaults.
No cloud bucket, IAM role, or notification endpoint is created by this package.

## Start protecting a database

Install cert-manager first. Enable `backupPlugin` on the existing PSQLStack in
the CNPG operator's namespace; do not install a second plugin. The default plugin
chart is 0.8.1 (Barman v0.15.1); the default CNPG chart is 0.29.1. Barman requires
CNPG 1.26 or newer. Use compatible operator/plugin versions and matching PostgreSQL
major versions for recovery. The plugin's Helm values expose resource controls.

Use [the backup example](../examples/psqlclusters/backups.yaml). Provision a private,
encrypted S3-compatible destination separately. Supply workload identity with
`credentials.inheritFromIAMRole: true`, or Kubernetes Secret key selectors under
`credentials.accessKeyId` and `credentials.secretAccessKey`. Credentials and the
ObjectStore must be in the database's **target namespace**, which may differ from
the XR's control-plane namespace. Non-AWS stores can set `endpointURL` and
`endpointCA`; existing ObjectStores can support other Barman storage providers.

`retentionPolicy: 30d` is a Barman recovery window. Do not add bucket age-expiration
rules that delete the last current backup or required WAL when archiving stops.
Versioned buckets may expire noncurrent versions and incomplete multipart uploads
under a separately reviewed policy. Credentials must remain valid for retention.

Schedules use six cron fields, including seconds, in **UTC**. The default is
`0 0 6 * * *` (daily at 06:00 UTC), primary-only. The scheduler does not compensate
for a database that was hibernating when a backup was due. Keep scale-to-zero off
for continuous recovery objectives; enabling both emits a configuration warning
and preserves both plugin entries. Set PostgreSQL `archive_timeout` to suit your
WAL recovery objective; it also affects object-storage cost.

Immediate first backups default off: plugin registration can lag database
readiness. Confirm `Cluster.status.pluginStatus` includes
`barman-cloud.cloudnative-pg.io`, then create an on-demand Backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: app-db-initial
  namespace: databases
spec:
  cluster:
    name: app-db
  target: primary
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

Wait for `Backup.status.phase: completed` and the ObjectStore recovery window.
A failed initial attempt remains useful evidence; fix the cause and create a new
uniquely named Backup. Enabling a plugin on an existing CNPG cluster can restart
pods, including the primary; plan a maintenance window and verify availability.
A temporary extra replica does not guarantee a restart-free change.

## Observe protection

`status.ready` continues to describe database availability. Backup evidence is
separate under `status.backup`:

| Phase | Meaning |
| --- | --- |
| Unconfigured | Typed backups are disabled, including on recovery-only clusters. |
| Initializing | Backups enabled but a healthy cluster, archiver, observed store and completed recovery window are not all established. |
| Failing | A failed backup is newer than the successful backup, or an established archive reports archiving failure. |
| Recoverable | The observed ObjectStore reports a successful backup and first recoverability point, and the database/archiver are healthy. |

The timestamps come from Barman's per-server `ObjectStore.status.serverRecoveryWindow`;
CNPG's deprecated native backup timestamps do not report plugin backups.
ContinuousArchiving=True alone never establishes protection. Recoverable is
observed controller evidence, **not** proof that a restore has been tested, a
measured recovery-time objective, or a guarantee that the newest WAL is durable.

Opt in to `backup.monitoring.enabled` when Prometheus Operator CRDs are installed.
This creates a PodMonitor and five PrometheusRule alerts: missing primary metrics,
no completed backup, an overdue backup, a newer backup failure, and a persistent
primary WAL backlog. `maxBackupAgeSeconds` defaults to 108000 (30 hours); match it
to your schedule. Configure monitor selection labels through `monitoring.labels`
and severities through `criticalSeverity` / `warningSeverity`. Select this monitor
once to avoid duplicate ingestion alongside CNPG's generated monitor. Routing to
Discord, email, or paging belongs to the consuming observability stack.

All alert queries select `cnpg_role="primary"`, derived from the current
`cnpg.io/instanceRole` pod label. Standby metrics cannot mask a missing primary or
page for queued standby WAL files. Missing primary targets alert even if every
metric series disappears.

## Recover into a new database

Create a **new** PSQLCluster with [the restore example](../examples/psqlclusters/restore.yaml).
Create a source ObjectStore in the new database namespace, pointing at the original
destination with credentials that permit only list/read. Do not set a retention
policy on the read-only source ObjectStore. The source archive's `serverName` is
required and must differ from the new cluster name. Never change an existing
cluster's bootstrap spec to attempt a restore.

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: source-readonly
  namespace: databases
spec:
  configuration:
    destinationPath: s3://database-backups/production
    s3Credentials:
      accessKeyId: {name: restore-credentials, key: access-key-id}
      secretAccessKey: {name: restore-credentials, key: secret-access-key}
    wal:
      compression: gzip
```

The XR observes this ObjectStore without updating or deleting it. The plugin's
`serverName` belongs in the cluster plugin parameters, never in
`ObjectStore.spec.configuration.serverName`.

Omit `restore.target` for latest available recovery. Set `targetTime` or
`targetName` with an explicit `backupID` for point-in-time recovery. The base backup
must precede the target, and the required WAL must be archived before restoring.
The source and target are immutable once the claim is created. Backups cannot be
enabled on recovery claims; no WAL archiver is rendered. A restored database can
accept SQL writes after recovery completes, but cannot modify the source archive
using its read-only credentials. Promotion and a distinct writable archive require
a separately planned lifecycle; this API does not automate that handoff.

Size the destination for simultaneous source and recovery instances, restore jobs,
PVCs and storage I/O. A node pool's CPU ceiling can block recovery even when the
immediate shortage is memory or pod slots. Network isolation requires an enforcing
CNI; the presence of a NetworkPolicy alone is not evidence of enforcement.

## AWS identity and storage boundary

Use the existing `aws.hops.ops.com.ai/v1alpha1` **PodIdentity** XR from
`hops-ops/aws-pod-identity` rather than duplicating IAM inside this package.
The EKS Pod Identity agent and a provider configuration for that AWS account must
already exist. The service account is CNPG's database cluster name in the target
namespace. For example, supply this writer policy through `PodIdentity.spec.inlinePolicy`:

```yaml
apiVersion: aws.hops.ops.com.ai/v1alpha1
kind: PodIdentity
metadata:
  name: app-db-backup-writer
  namespace: default
spec:
  clusterName: production
  region: us-east-2
  providerConfigRef: {name: production, kind: ProviderConfig}
  managementPolicies: [Observe, Create, Update, LateInitialize]
  serviceAccount: {name: app-db, namespace: databases}
  inlinePolicy:
  - name: backups
    policy: |
      {"Version":"2012-10-17","Statement":[
        {"Effect":"Allow","Action":["s3:GetBucketLocation"],"Resource":"arn:aws:s3:::database-backups"},
        {"Effect":"Allow","Action":["s3:ListBucket"],"Resource":"arn:aws:s3:::database-backups","Condition":{"StringLike":{"s3:prefix":["production/app-db","production/app-db/*"]}}},
        {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::database-backups/production/app-db/*"}
      ]}
```

Bind a separate PodIdentity to the recovery cluster's service account and remove
PutObject/DeleteObject from its policy. Neither role needs DeleteObjectVersion.
Bucket policies should enforce TLS and block public access. Use bucket-default
SSE-S3 or, for SSE-KMS, add tightly scoped KMS permissions to the relevant key.
Keep bucket and identity management separate, with explicit import and retention
policies. The generic PSQL package adds no mandatory AWS dependency. If another
composition owns the identity/destination, protect that producer with Usage until
its database consumer is removed; externally managed resources must outlive it.

## Ownership and adoption

1. Inventory the existing Helm release name/namespace, database Cluster UID,
   ObjectStore name, destinationPath, serverName, schedule name/cron, Secret names,
   identities and PVC/PV IDs. Verify a completed backup and test recovery first.
2. Pin the new package version before editing claims. Keep backup defaults off.
   Enable stack plugin ownership with the **existing** release name and identical
   values. Orphan the previous Release owner before the new owner adopts it;
   do not uninstall/reinstall the shared operator or plugin.
3. Start with `existingObjectStore: true` and the existing `objectStoreName` and
   `serverName`. The XR observes the store with managementPolicies [Observe].
   Existing buckets, credentials and cloud identities stay with their current owners.
4. Suspend the old scheduler during handoff. Preserve its target name and cron in
   `backup.schedule`; use its current immediate/suspend settings intentionally.
   Remove the old manager with retain/orphan semantics before adoption, then
   resume once one owner controls the resource. Do not run duplicate schedules.
5. Remove any second manager of `PSQLCluster.spec.cnpg.values.plugins` using a
   staged field-manager handoff. Set typed backups through the existing claim's
   owner. Typed backup/restore rejects a passthrough Barman entry, native backup,
   bootstrap/externalClusters or full override that would compete with it.
   Other plugins remain present and are merged by plugin name.
6. If transferring ObjectStore ownership later, preserve its identity and
   destination, remove the prior owner without deletion, then switch out of
   observe-only mode with the identical configuration. Do not change archive
   identities to resolve conflicts. Source/destination identity fields are immutable.
7. Verify the database UID, volumes, archive identity/history, credentials,
   schedule, current backup, WAL flow and alerts after each stage. Keep the source
   archive and previous recoverable chain available through rollback.

The backup ObjectStore and schedule default to retain-on-delete policies; the
underlying database retains its existing XR lifecycle. Retention protects remote
backup data, not database PVCs. Before disabling typed backups, suspend the
schedule; retained schedulers otherwise continue referencing the database. For
disposable environments explicitly set backup.managementPolicies: ["*"] and use
an appropriate PVC/StorageClass deletion policy. Delete recovery clusters and
verify volumes, jobs and cloud disks are gone without touching source volumes.

Harmony adoption is a separate downstream task after a published release. Keep
its bucket/prefix, server names, existing schedules, identities, credentials,
Discord routing and database volumes unchanged during that migration.

## Validation

`make test` runs composition contracts. `python3 tests/backup/render.py` runs the
same backup contracts through the native renderer, including rejected inputs.
`make backup-e2e` requires PyYAML and boto3 and creates and removes its own kind cluster, installs the actual
controllers, seeds data, backs it up, modifies it, then verifies latest, time and
named recovery with write-denied source credentials. It writes evidence under
`_output/backup-evidence/`; it never targets the current kubecontext. The existing
EKS E2E suite covers provider/composition reconciliation and snapshot branches.

Upstream references: [Barman installation](https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/),
[backup/recovery API](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/),
[observability](https://cloudnative-pg.io/plugin-barman-cloud/docs/observability/).

The [2026-11-02 seeded drill evidence](evidence/backups-2026-11-02.json) records
actual latest/time/named row checks, read-only access enforcement, observed
recoverability, versions, local test adjustments and disposable-cluster cleanup.
CI separately runs the corrected full script from a clean environment.

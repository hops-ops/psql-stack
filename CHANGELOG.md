### What's changed in v0.22.0

* feat(backups): add physical backup and recovery policies (#44) (by @patrickleet)

  * feat(backups): add physical backup and recovery policies

  [[tasks/psql-backup-policy-xr]]

  * test(backups): use maintained S3 recovery fixture

  [[tasks/psql-backup-policy-xr]]

  * fix(backups): preserve applied archive and legacy plugin identities

  [[tasks/psql-backup-policy-xr]]

  * test(backups): verify read-only catalog access before recovery

  [[tasks/psql-backup-policy-xr]]

  * docs(backups): record seeded recovery evidence and cleanup

  [[tasks/psql-backup-policy-xr]]

  * test(backups): assert retained resources and deletion protection

  [[tasks/psql-backup-policy-xr]]

  * fix(backups): match Barman retention units in claim validation

  [[tasks/psql-backup-policy-xr]]

  * fix(backups): reconcile application credentials after recovery

  [[tasks/psql-backup-policy-xr]]

  * fix(backups): reconcile configuration warnings by condition type

  [[tasks/psql-backup-policy-xr]]

* feat(deps): update ariga/charts/atlas-operator docker tag to v0.8.5 (#45) (by @renovate[bot])

  Co-authored-by: renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>


See full diff: [v0.21.1...v0.22.0](https://github.com/hops-ops/psql-stack/compare/v0.21.1...v0.22.0)

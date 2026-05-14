### What's changed in v0.8.0

* feat(psqlcluster): add targetNamespace field (by @patrickleet)

  Decouples the PSQLCluster XR's control-plane namespace from the composed
  CNPG Cluster's data-plane namespace. Defaults to the XR's own ns (the
  common case); override when the XR lives in the platform default ns but
  the data plane needs to land elsewhere — e.g. embedded in AuthStack so
  Zitadel pods can env-var-mount the app Secret without cross-namespace
  mirroring.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>


See full diff: [v0.7.0...v0.8.0](https://github.com/hops-ops/psql-stack/compare/v0.7.0...v0.8.0)

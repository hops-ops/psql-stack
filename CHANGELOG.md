### What's changed in v0.9.0

* feat: resource defaults for CNPG postgres (cluster + branch) (by @patrickleet)

  Both PSQLCluster and PSQLBranch compositions now set spec.resources on
  the CNPG Cluster CR, sized at request==limit on memory (512Mi) and
  request-only on CPU (100m, no limit so query workloads can burst). The
  chart ships postgres pods as BestEffort by default, which had pat-local-
  pg-1 (zitadel) and psql-test-1 at-risk of node-pressure eviction.

  Verified on pat-local:
  - pat-local-pg-1 (zitadel embedded postgres) → Burstable, mem-lim=512Mi
  - psql-test-1 (standalone PSQLCluster) → Burstable, mem-lim=512Mi

  Override per-cluster via spec.cnpg.values.resources for larger workloads.

  Implements [[tasks/cluster-wide-resource-right-sizing-p95-observation]] tier-1 #2

* feat(deps): update crossplane-contrib/function-auto-ready docker tag to v0.6.5 (#14) (by @renovate[bot])

  Co-authored-by: renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>


See full diff: [v0.8.0...v0.9.0](https://github.com/hops-ops/psql-stack/compare/v0.8.0...v0.9.0)

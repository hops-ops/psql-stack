import models.ai.com.ops.hops.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unit tests for PSQLBranch XRD
#
# Verify: staged cross-ns vs same-ns composition, recovery credentials,
# readiness/deletion ordering, sizing, lifecycle toggles, and provider defaults.
# ==============================================================================

_ready_branch_snapshot = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = "observed-branch-snapshot"
        annotations = {
            "crossplane.io/composition-resource-name" = "branch-snapshot"
            "gotemplating.fn.crossplane.io/composition-resource-name" = "branch-snapshot"
        }
    }
    status = {
        conditions = [{type = "Ready", status = "True"}]
        atProvider.manifest.status = {
            boundVolumeSnapshotContentName = "snapcontent-ready"
            readyToUse = True
        }
    }
}

_ready_source_snapshot = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = "observed-source-snapshot"
        annotations = {
            "crossplane.io/composition-resource-name" = "source-snapshot"
            "gotemplating.fn.crossplane.io/composition-resource-name" = "source-snapshot"
        }
    }
    status = {
        conditions = [{type = "Ready", status = "True"}]
        atProvider.manifest.status = {
            boundVolumeSnapshotContentName = "snapcontent-ready"
            readyToUse = True
        }
    }
}

_ready_source_snapshot_content = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = "observed-source-snapshot-content"
        annotations = {
            "crossplane.io/composition-resource-name" = "source-snapshot-content"
            "gotemplating.fn.crossplane.io/composition-resource-name" = "source-snapshot-content"
        }
    }
    status = {
        conditions = [{type = "Ready", status = "True"}]
        atProvider.manifest = {
            spec = {
                driver = "ebs.csi.eks.amazonaws.com"
                source.snapshotHandle = "snap-0123456789abcdef0"
                sourceVolumeMode = "Filesystem"
                volumeSnapshotClassName = "psql"
            }
            status.readyToUse = True
        }
    }
}

_ready_branch_snapshot_content = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = "observed-branch-snapshot-content"
        annotations = {
            "crossplane.io/composition-resource-name" = "branch-snapshot-content"
            "gotemplating.fn.crossplane.io/composition-resource-name" = "branch-snapshot-content"
        }
    }
    status = {
        conditions = [{type = "Ready", status = "True"}]
        atProvider.manifest.status.readyToUse = True
    }
}

_ready_cnpg_cluster = {
    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
    kind = "Object"
    metadata = {
        name = "observed-cnpg-cluster"
        annotations = {
            "crossplane.io/composition-resource-name" = "cnpg-cluster"
            "gotemplating.fn.crossplane.io/composition-resource-name" = "cnpg-cluster"
        }
    }
    status = {
        conditions = [{type = "Ready", status = "True"}]
        atProvider.manifest.status.phase = "Cluster in healthy state"
    }
}

_items = [
    # ==========================================================================
    # Test 1: same-namespace branch — only branch-snapshot composed (no source-
    # snapshot bridging), references source PVC directly.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "same-namespace-branch-direct-pvc-reference"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-same", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {name = "src-app"}
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-same-branch-snapshot"
                    spec.forProvider.manifest = {
                        apiVersion = "snapshot.storage.k8s.io/v1"
                        kind = "VolumeSnapshot"
                        metadata = {
                            name = "br-same-snap"
                            namespace = "default"
                        }
                        spec = {
                            volumeSnapshotClassName = "psql"
                            source.persistentVolumeClaimName = "src-app-1"
                        }
                    }
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-same-cnpg-cluster"
                    spec.forProvider.manifest = {
                        apiVersion = "postgresql.cnpg.io/v1"
                        kind = "Cluster"
                        metadata = {
                            name = "br-same"
                            namespace = "default"
                            labels = {
                                "hops.ops.com.ai/managed" = "true"
                                "hops.ops.com.ai/psql-branch" = "br-same"
                                "hops.ops.com.ai/branch-of" = "src-app"
                            }
                        }
                        # No imageName — when spec.postgresql.version is omitted,
                        # CNPG falls back to its operator-default image. See
                        # test "explicit-postgres-version-sets-imagename" for
                        # the override path.
                        spec = {
                            instances = 1
                            bootstrap.recovery = {
                                database = "app"
                                owner = "app"
                                volumeSnapshots.storage = {
                                    name = "br-same-snap"
                                    kind = "VolumeSnapshot"
                                    apiGroup = "snapshot.storage.k8s.io"
                                }
                            }
                        }
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Cross-namespace, second reconcile: once the source snapshot is bound,
    # the branch snapshot is rendered with a non-empty static content ref.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cross-ns-imports-source-handle-into-branch-content"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-x", namespace = "preview-pr-1"}
                spec = {
                    clusterName = "prod"
                    source = {name = "src-app", namespace = "team-app"}
                }
            }
            observedResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata = {
                        name = "br-x-source-snapshot"
                        namespace = "preview-pr-1"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "source-snapshot"
                            "gotemplating.fn.crossplane.io/composition-resource-name" = "source-snapshot"
                        }
                    }
                    status = {
                        conditions = [{type = "Ready", status = "True"}]
                        atProvider.manifest.status = {
                            boundVolumeSnapshotContentName = "snapcontent-from-source"
                            readyToUse = True
                        }
                    }
                }
                _ready_source_snapshot_content
            ]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-x-branch-snapshot-content"
                    spec.forProvider.manifest.spec = {
                        deletionPolicy = "Retain"
                        driver = "ebs.csi.eks.amazonaws.com"
                        source.snapshotHandle = "snap-0123456789abcdef0"
                        volumeSnapshotRef = {
                            name = "br-x-snap"
                            namespace = "preview-pr-1"
                        }
                    }
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-x-branch-snapshot"
                    spec.forProvider.manifest.spec.source.volumeSnapshotContentName = "preview-pr-1-br-x-content"
                }
            ]
        }
    }

    # ==========================================================================
    # Cross-namespace steady state: both snapshots are bound. The recovered
    # cluster may now be rendered from the branch-namespace snapshot.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cross-ns-uses-branch-content-when-bound"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-y", namespace = "preview-pr-2"}
                spec = {
                    clusterName = "prod"
                    source = {name = "src-app", namespace = "team-app"}
                }
            }
            observedResources = [
                _ready_source_snapshot,
                _ready_source_snapshot_content,
                _ready_branch_snapshot_content,
                _ready_branch_snapshot,
            ]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-y-branch-snapshot"
                    spec.forProvider.manifest.spec.source.volumeSnapshotContentName = "preview-pr-2-br-y-content"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-y-cnpg-cluster"
                    spec.forProvider.manifest.spec.bootstrap.recovery.volumeSnapshots.storage.name = "br-y-snap"
                }
            ]
        }
    }

    # ==========================================================================
    # Storage size precedence: branch.storage.size wins over source.storage.size.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "branch-storage-size-overrides-source-size"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-explicit", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {
                        name = "src-app"
                        storage = {size = "100Gi"}
                    }
                    branch.storage.size = "150Gi"
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-explicit-cnpg-cluster"
                    spec.forProvider.manifest.spec.storage.size = "150Gi"
                }
            ]
        }
    }

    # ==========================================================================
    # Storage size precedence: source.storage.size used when branch size empty.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "branch-storage-size-falls-back-to-source-size"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-inherit", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {
                        name = "src-app"
                        storage = {size = "100Gi"}
                    }
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-inherit-cnpg-cluster"
                    spec.forProvider.manifest.spec.storage.size = "100Gi"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 1b: explicit spec.postgresql.version sets imageName. Branches MUST
    # match the source's major version (snapshot recovery is binary-compatible
    # only within a major) — pinning the minor here is the typical use case.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "explicit-postgres-version-sets-imagename"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-pinned", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {name = "src-app"}
                    postgresql.version = "17.4"
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-pinned-cnpg-cluster"
                    spec.forProvider.manifest.spec.imageName = "ghcr.io/cloudnative-pg/postgresql:17.4"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 2: cross-namespace first reconcile renders only the source snapshot.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cross-namespace-branch-bridges-via-content"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-x", namespace = "preview-pr-1"}
                spec = {
                    clusterName = "prod"
                    source = {name = "src-app", namespace = "team-app"}
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-x-source-snapshot"
                    spec.forProvider.manifest = {
                        apiVersion = "snapshot.storage.k8s.io/v1"
                        kind = "VolumeSnapshot"
                        # Name prefixed with branch namespace so two branches
                        # with the same XR name in different namespaces don't
                        # collide on a single `-src` in the shared source ns.
                        metadata = {
                            name = "preview-pr-1-br-x-src"
                            namespace = "team-app"
                        }
                        spec.source.persistentVolumeClaimName = "src-app-1"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 2b: same branch XR name (`br-x`) in a DIFFERENT branch namespace
    # (`other-team-preview` vs `preview-pr-1` above) produces a different
    # source-snapshot name in the shared source ns. Locks in the
    # collision-avoidance contract: source-ns name encodes the branch's own
    # namespace.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cross-ns-source-snapshot-name-distinguishes-branch-ns"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-x", namespace = "other-team-preview"}
                spec = {
                    clusterName = "prod"
                    source = {name = "src-app", namespace = "team-app"}
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-x-source-snapshot"
                    spec.forProvider.manifest.metadata = {
                        name = "other-team-preview-br-x-src"
                        namespace = "team-app"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 3: scaleToZero default-on; renders annotation + plugin entry.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "scaletozero-default-on-renders-annotation-and-plugin"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-s2z", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {name = "src"}
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-s2z-cnpg-cluster"
                    spec.forProvider.manifest = {
                        metadata.annotations = {
                            "cnpg-i-scale-to-zero.xata.io/idle-timeout" = "10m"
                        }
                        spec.plugins = [{
                            name = "cnpg-i-scale-to-zero.xata.io"
                            enabled = True
                        }]
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 4: scaleToZero.enabled=false suppresses annotation + plugin.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "scaletozero-disabled-strips-plugin"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-no-s2z", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {name = "src"}
                    scaleToZero = {enabled = False}
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-no-s2z-cnpg-cluster"
                    spec.forProvider.manifest.metadata = {
                        name = "br-no-s2z"
                        namespace = "default"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 5: ttl.enabled=true adds the hops/ttl annotation on the Cluster CR.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "ttl-enabled-adds-annotation"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-ttl", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {name = "src"}
                    ttl = {enabled = True, after = "24h"}
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-ttl-cnpg-cluster"
                    spec.forProvider.manifest.metadata.annotations = {
                        "cnpg-i-scale-to-zero.xata.io/idle-timeout" = "10m"
                        "hops.ops.com.ai/ttl" = "24h"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 6: custom snapshotClassName flows through to the VolumeSnapshot.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-snapshot-class-flows-through"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-custom-vsc", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {name = "src", snapshotClassName = "longhorn-snap"}
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-custom-vsc-branch-snapshot"
                    spec.forProvider.manifest.spec.volumeSnapshotClassName = "longhorn-snap"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 7: cnpg.overrideAllValues replaces the entire Cluster.spec.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cnpg-override-all-values-replaces-cluster-spec"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-override", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    source = {name = "src"}
                    cnpg.overrideAllValues = {
                        instances = 5
                        imageName = "custom/postgres:99"
                    }
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-override-cnpg-cluster"
                    spec.forProvider.manifest.spec = {
                        instances = 5
                        imageName = "custom/postgres:99"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 8: kubernetesProviderConfigRef defaults to clusterName.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "k8s-provider-config-defaults-to-cluster-name"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-pc", namespace = "default"}
                spec = {
                    clusterName = "prod-cluster"
                    source = {name = "src"}
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-pc-cnpg-cluster"
                    spec.providerConfigRef = {
                        name = "prod-cluster"
                        kind = "ProviderConfig"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Recovery credentials: custom owner/database use a CNPG-managed local
    # secret unless the caller explicitly supplies one.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "app-recovery-credentials-are-branch-local"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "harmony-api-db", namespace = "preview-pr-600"}
                spec = {
                    clusterName = "production"
                    source = {name = "harmony-api-db"}
                    app = {role = "harmony_bootstrap", database = "app"}
                    superuser.enabled = True
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [{
                apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                kind = "Object"
                metadata.name = "harmony-api-db-cnpg-cluster"
                spec.forProvider.manifest.spec = {
                    enableSuperuserAccess = True
                    bootstrap.recovery = {
                        owner = "harmony_bootstrap"
                        database = "app"
                    }
                }
            }]
        }
    }

    metav1alpha1.CompositionTest {
        metadata.name = "explicit-recovery-secrets-flow-to-cnpg"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-secrets", namespace = "default"}
                spec = {
                    clusterName = "production"
                    source = {name = "source"}
                    app.secretName = "app-creds"
                    superuser = {enabled = True, secretName = "postgres-creds"}
                }
            }
            observedResources = [_ready_branch_snapshot]
            assertResources = [{
                apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                kind = "Object"
                metadata.name = "br-secrets-cnpg-cluster"
                spec.forProvider.manifest.spec = {
                    bootstrap.recovery.secret.name = "app-creds"
                    enableSuperuserAccess = True
                    superuserSecret.name = "postgres-creds"
                }
            }]
        }
    }

    # ==========================================================================
    # All three Usage locks appear only after their endpoints are observed
    # Ready. The staged observed fixture separately exercises final status.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "ready-cross-namespace-branch-locks-deletion-order"
        spec = {
            compositionPath = "apis/psqlbranches/composition.yaml"
            xrdPath = "apis/psqlbranches/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLBranch {
                metadata = {name = "br-ready", namespace = "preview-pr-1"}
                spec = {
                    clusterName = "production"
                    source = {name = "source", namespace = "staging"}
                }
            }
            observedResources = [
                _ready_source_snapshot,
                _ready_source_snapshot_content,
                _ready_branch_snapshot_content,
                _ready_branch_snapshot,
                _ready_cnpg_cluster,
            ]
            assertResources = [
                {
                    apiVersion = "protection.crossplane.io/v1beta1"
                    kind = "Usage"
                    metadata.name = "br-ready-delete-branch-content-before-source-snapshot"
                }
                {
                    apiVersion = "protection.crossplane.io/v1beta1"
                    kind = "Usage"
                    metadata.name = "br-ready-delete-branch-snapshot-before-branch-content"
                }
                {
                    apiVersion = "protection.crossplane.io/v1beta1"
                    kind = "Usage"
                    metadata.name = "br-ready-delete-cnpg-cluster-before-branch-snapshot"
                }
            ]
        }
    }
]

items = _items

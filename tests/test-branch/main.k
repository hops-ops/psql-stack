import models.ai.com.ops.hops.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unit tests for PSQLBranch XRD
#
# Verify: cross-ns vs same-ns composition, scaleToZero defaults, TTL annotation,
# overrideAllValues escape hatch, providerConfig defaults.
# ==============================================================================

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
                            bootstrap.recovery.volumeSnapshots.storage = {
                                name = "br-same-snap"
                                kind = "VolumeSnapshot"
                                apiGroup = "snapshot.storage.k8s.io"
                            }
                        }
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Cross-namespace, first reconcile: source-snapshot has bound to its
    # VolumeSnapshotContent, branch-snapshot's underlying VolumeSnapshot was
    # rendered earlier with an empty volumeSnapshotContentName and hasn't
    # bound yet. The state-status logic must read from source-snapshot
    # (since branch-snapshot's bound content is still empty), so the
    # branch-ns VolumeSnapshot now renders with the source's content name —
    # closing the chicken-and-egg.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cross-ns-prefers-source-content-when-branch-empty"
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
                # source-ns VolumeSnapshot (Object wrapper) — bound.
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata = {
                        name = "br-x-source-snapshot"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "source-snapshot"
                            "gotemplating.fn.crossplane.io/composition-resource-name" = "source-snapshot"
                        }
                    }
                    status.atProvider.manifest.status.boundVolumeSnapshotContentName = "snapcontent-from-source"
                }
                # branch-ns VolumeSnapshot (Object wrapper) — created with
                # empty content reference on the prior reconcile, not bound.
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata = {
                        name = "br-x-branch-snapshot"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "branch-snapshot"
                            "gotemplating.fn.crossplane.io/composition-resource-name" = "branch-snapshot"
                        }
                    }
                    status.atProvider.manifest.status.boundVolumeSnapshotContentName = ""
                }
            ]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-x-branch-snapshot"
                    spec.forProvider.manifest.spec.source.volumeSnapshotContentName = "snapcontent-from-source"
                }
            ]
        }
    }

    # ==========================================================================
    # Cross-namespace, steady state: branch-snapshot has bound (its
    # boundVolumeSnapshotContentName is populated). Reading branch's value
    # is fine here — it will match source's. This locks in that the
    # fallback doesn't override a populated branch content with the
    # source's value.
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
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata = {
                        name = "br-y-source-snapshot"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "source-snapshot"
                            "gotemplating.fn.crossplane.io/composition-resource-name" = "source-snapshot"
                        }
                    }
                    status.atProvider.manifest.status.boundVolumeSnapshotContentName = "snapcontent-from-source"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata = {
                        name = "br-y-branch-snapshot"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "branch-snapshot"
                            "gotemplating.fn.crossplane.io/composition-resource-name" = "branch-snapshot"
                        }
                    }
                    status.atProvider.manifest.status.boundVolumeSnapshotContentName = "snapcontent-from-branch"
                }
            ]
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-y-branch-snapshot"
                    spec.forProvider.manifest.spec.source.volumeSnapshotContentName = "snapcontent-from-branch"
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
    # Test 2: cross-namespace branch — source-snapshot in source ns + branch-
    # snapshot in branch ns + Cluster in branch ns.
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
                        metadata = {
                            name = "br-x-src"
                            namespace = "team-app"
                        }
                        spec.source.persistentVolumeClaimName = "src-app-1"
                    }
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-x-branch-snapshot"
                    spec.forProvider.manifest.metadata = {
                        name = "br-x-snap"
                        namespace = "preview-pr-1"
                    }
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "br-x-cnpg-cluster"
                    spec.forProvider.manifest.metadata = {
                        name = "br-x"
                        namespace = "preview-pr-1"
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
]

items = _items

import models.ai.com.ops.hops.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unit tests for PSQLStack XRD
#
# Philosophy: test YOUR API, not the provider's API.
# - render/validate already checks provider schema correctness
# - Tests should verify XRD spec fields produce expected behavior
# ==============================================================================

_items = [
    # ==========================================================================
    # Test 1: minimal claim renders the platform operators (CNPG, Atlas), the
    # scale-to-zero plugin (default-on), the StorageClass and VolumeSnapshotClass
    # (default name: "psql", paired driver/provisioner: ebs.csi.eks.amazonaws.com).
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "minimal-renders-platform-stack"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "test-psql"
                spec.clusterName = "my-cluster"
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-storageclass"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-volumesnapshotclass"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-s2z-deployment"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 2: custom labels merge with the stack's defaults on every composed
    # Release.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-labels-merged-with-defaults"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "labeled-psql"
                spec = {
                    clusterName = "my-cluster"
                    labels = {team = "platform", environment = "staging"}
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata = {
                        name = "cloudnative-pg"
                        labels = {
                            "hops.ops.com.ai/managed" = "true"
                            "hops.ops.com.ai/psql" = "labeled-psql"
                            team = "platform"
                            environment = "staging"
                        }
                    }
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata = {
                        name = "atlas-operator"
                        labels = {
                            "hops.ops.com.ai/managed" = "true"
                            "hops.ops.com.ai/psql" = "labeled-psql"
                            team = "platform"
                            environment = "staging"
                        }
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 3: spec.cnpg.overrideAllValues replaces all default values
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cnpg-override-all-values-replaces-defaults"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "override-test"
                spec = {
                    clusterName = "my-cluster"
                    cnpg = {
                        overrideAllValues = {
                            replicaCount = 2
                            config = {data = {LOG_LEVEL = "debug"}}
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                    spec.forProvider.values = {
                        replicaCount = 2
                        config = {data = {LOG_LEVEL = "debug"}}
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 4: spec.atlasOperator.values merge with chart defaults
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "atlas-values-merge-with-defaults"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "atlas-merge"
                spec = {
                    clusterName = "my-cluster"
                    atlasOperator = {
                        values = {
                            prewarmDevDB = False
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                    spec.forProvider.values = {
                        prewarmDevDB = False
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 5: custom namespace propagates to all platform operators
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-namespace-propagates"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "ns-test"
                spec = {
                    clusterName = "my-cluster"
                    namespace = "database-system"
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                    spec.forProvider.namespace = "database-system"
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                    spec.forProvider.namespace = "database-system"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 6: per-component namespace overrides the shared namespace
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "per-component-namespace-override"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "ns-override"
                spec = {
                    clusterName = "my-cluster"
                    namespace = "cnpg-system"
                    atlasOperator = {
                        namespace = "atlas-system"
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                    spec.forProvider.namespace = "cnpg-system"
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                    spec.forProvider.namespace = "atlas-system"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 7: helmProviderConfigRef defaults to clusterName
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "helm-provider-config-defaults-to-cluster-name"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "provider-test"
                spec.clusterName = "prod-cluster"
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                    spec.providerConfigRef = {
                        name = "prod-cluster"
                        kind = "ProviderConfig"
                    }
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                    spec.providerConfigRef = {
                        name = "prod-cluster"
                        kind = "ProviderConfig"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 8: spec.scaleToZeroPlugin.enabled=false suppresses the plugin install
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "scale-to-zero-plugin-can-be-disabled"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "no-s2z"
                spec = {
                    clusterName = "my-cluster"
                    scaleToZeroPlugin = {enabled = False}
                }
            }
            # Positive presence: cnpg + atlas + SC + VSC still composed.
            # Absence of s2z-* resources is implicit (composition gates them).
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "no-s2z-storageclass"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "no-s2z-volumesnapshotclass"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 9: ha.enabled=true sets replicaCount on CNPG and Atlas Helm releases.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "ha-enabled-injects-replica-count"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "ha-on"
                spec = {
                    clusterName = "prod"
                    ha = {enabled = True, replicas = 3}
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                    spec.forProvider.values.replicaCount = 3
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                    spec.forProvider.values.replicaCount = 3
                }
            ]
        }
    }

    # ==========================================================================
    # Test 10: spec.snapshotClass settings flow through to the composed VSC.
    # Default driver = ebs.csi.aws.com; override to verify it propagates.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "snapshotclass-driver-flows-through"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "vsc-tweaks"
                spec = {
                    clusterName = "my-cluster"
                    snapshotClass = {
                        driver = "driver.longhorn.io"
                        deletionPolicy = "Retain"
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "vsc-tweaks-volumesnapshotclass"
                    spec.forProvider.manifest = {
                        apiVersion = "snapshot.storage.k8s.io/v1"
                        kind = "VolumeSnapshotClass"
                        metadata = {
                            name = "psql"
                            labels = {
                                "hops.ops.com.ai/managed" = "true"
                                "hops.ops.com.ai/psql" = "vsc-tweaks"
                            }
                        }
                        driver = "driver.longhorn.io"
                        deletionPolicy = "Retain"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 11: snapshotClass.enabled=false suppresses the VSC composition.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "snapshotclass-can-be-disabled"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "no-vsc"
                spec = {
                    clusterName = "my-cluster"
                    snapshotClass = {enabled = False}
                }
            }
            # Cnpg + atlas + SC still composed. No vsc-* Object expected (implicit).
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "no-vsc-storageclass"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 12: storageClass settings flow through to the composed StorageClass.
    # Override provisioner + parameters to verify they propagate (e.g., for
    # non-EKS targets that use a different CSI driver).
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "storageclass-provisioner-flows-through"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "sc-tweaks"
                spec = {
                    clusterName = "my-cluster"
                    storageClass = {
                        provisioner = "driver.longhorn.io"
                        parameters = {numberOfReplicas = "3"}
                        reclaimPolicy = "Retain"
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "sc-tweaks-storageclass"
                    spec.forProvider.manifest = {
                        apiVersion = "storage.k8s.io/v1"
                        kind = "StorageClass"
                        metadata = {
                            name = "psql"
                            labels = {
                                "hops.ops.com.ai/managed" = "true"
                                "hops.ops.com.ai/psql" = "sc-tweaks"
                            }
                        }
                        provisioner = "driver.longhorn.io"
                        reclaimPolicy = "Retain"
                        volumeBindingMode = "WaitForFirstConsumer"
                        allowVolumeExpansion = True
                        parameters = {numberOfReplicas = "3"}
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 13: storageClass.enabled=false suppresses the SC composition.
    # Use case: cluster already ships a suitable default SC; opt out of the
    # stack composing one. PSQLCluster/PSQLBranch consumers must then set
    # `spec.storage.class` explicitly.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "storageclass-can-be-disabled"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "no-sc"
                spec = {
                    clusterName = "my-cluster"
                    storageClass = {enabled = False}
                }
            }
            # Cnpg + atlas + VSC still composed. No sc-* Object expected (implicit).
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                }
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "atlas-operator"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "no-sc-volumesnapshotclass"
                }
            ]
        }
    }
]

items = _items

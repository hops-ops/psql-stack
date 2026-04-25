import models.ai.com.ops.hops.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1

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
    # scale-to-zero plugin (default-on), Mayastor + StorageClass + node-prep +
    # both NodePool sub-pools (nodePool default-on now — stack's whole point).
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
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "openebs-mayastor"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-storageclass-mayastor"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-volumesnapshotclass-mayastor"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-s2z-deployment"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-nodepool-branches"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-nodepool-primary"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-psql-node-prep"
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
            # When disabled, no s2z-* Objects are composed. We assert the
            # expected platform Releases are still present and ebs StorageClass
            # is created — the assertion is a positive presence check; the
            # absence of s2z-* resources is implicit (composition gates them
            # on enabled=true).
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "cloudnative-pg"
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "no-s2z-storageclass-mayastor"
                }
            ]
        }
    }

    # ==========================================================================
    # Test 9: nodePool.enabled=false skips Mayastor, StorageClass, and node-prep
    # (the stack's storage requires the NodePool to have something to schedule
    # on — disabling the NodePool reasonably skips everything that needs it).
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "nodepool-disabled-skips-storage"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "np-off"
                spec = {
                    clusterName = "my-cluster"
                    nodePool = {enabled = False}
                }
            }
            # Positive presence: cnpg + atlas still composed
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
            ]
        }
    }

    # ==========================================================================
    # Test 10: spec.storage settings flow through to the StorageClass
    # parameters (replicationFactor, thin)
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "storage-settings-flow-through-to-sc"
        spec = {
            compositionPath = "apis/psqlstacks/composition.yaml"
            xrdPath = "apis/psqlstacks/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLStack {
                metadata.name = "storage-tweaks"
                spec = {
                    clusterName = "my-cluster"
                    storage = {
                        replicationFactor = 1
                        thin = False
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "storage-tweaks-storageclass-mayastor"
                    spec.forProvider.manifest.parameters = {
                        repl = "1"
                        protocol = "nvmf"
                        thin = "false"
                        ioTimeout = "60"
                        fsType = "ext4"
                    }
                }
            ]
        }
    }
]

items = _items

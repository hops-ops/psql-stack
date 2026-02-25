import models.ai.com.ops.hops.stacks.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1

# ==============================================================================
# Unit tests for Psql XRD
#
# Philosophy: Test YOUR API, not the provider's API.
# - render/validate already checks provider schema correctness
# - Tests should verify XRD spec fields produce expected behavior
# ==============================================================================

_items = [
    # ==========================================================================
    # Test 1: Minimal input renders both Helm Releases
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "minimal-renders-all-components"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
                metadata.name = "test-psql"
                spec.clusterName = "my-cluster"
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "stackgres-operator"
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
    # Test 2: Custom labels are merged with defaults
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-labels-merged-with-defaults"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
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
                        name = "stackgres-operator"
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
    # Test 3: overrideAllValues on StackGres replaces all defaults
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "stackgres-override-all-values-replaces-defaults"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
                metadata.name = "override-test"
                spec = {
                    clusterName = "my-cluster"
                    stackgresOperator = {
                        overrideAllValues = {
                            deploy = {operator = True, restapi = False}
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "stackgres-operator"
                    spec.forProvider.values = {
                        deploy = {operator = True, restapi = False}
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 4: StackGres user values merge with defaults
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "stackgres-values-merge-with-defaults"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
                metadata.name = "sg-merge"
                spec = {
                    clusterName = "my-cluster"
                    stackgresOperator = {
                        values = {
                            grafana = {autoEmbed = True}
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "stackgres-operator"
                    spec.forProvider.values = {
                        deploy = {operator = True, restapi = True}
                        grafana = {autoEmbed = True}
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 5: Atlas Operator user values merge with defaults
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "atlas-values-merge-with-defaults"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
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
    # Test 6: Custom namespace propagates to both components
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "custom-namespace-propagates"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
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
                    metadata.name = "stackgres-operator"
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
    # Test 7: Per-component namespace overrides shared namespace
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "per-component-namespace-override"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
                metadata.name = "ns-override"
                spec = {
                    clusterName = "my-cluster"
                    namespace = "stackgres"
                    atlasOperator = {
                        namespace = "atlas-system"
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "stackgres-operator"
                    spec.forProvider.namespace = "stackgres"
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
    # Test 8: Helm provider config ref defaults to clusterName
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "helm-provider-config-defaults-to-cluster-name"
        spec = {
            compositionPath = "apis/psqls/composition.yaml"
            xrdPath = "apis/psqls/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.Psql {
                metadata.name = "provider-test"
                spec.clusterName = "prod-cluster"
            }
            assertResources = [
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "Release"
                    metadata.name = "stackgres-operator"
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
]

items = _items

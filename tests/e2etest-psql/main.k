import datetime
import math
import models.ai.com.ops.hops.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# E2E Test for Psql (Kubernetes-only)
#
# Both components run in-cluster: Helm releases only.
# No cloud credentials needed - uses InjectedIdentity for Helm provider.
#
# Run: make e2e
# Run without cleanup: up test run tests/e2etest-psql --e2e --skip-control-plane-cleanup
# ==============================================================================

_now = str(int(math.floor(datetime.ticks())))
_test_name = "e2e-psql-" + _now

_items = [
    metav1alpha1.E2ETest {
        metadata.name = "psql-e2e"
        spec = {
            crossplane = {
                autoUpgrade.channel = "Rapid"
            }
            defaultConditions = ["Ready"]
            timeoutSeconds = 1800  # 30 minutes - 2 Helm charts + CRDs
            cleanupTimeoutSeconds = 900  # 15 minutes
            skipDelete = False

            # ==============================================================
            # extraResources: RBAC + Helm ProviderConfig
            # These are NOT deleted during cleanup
            # ==============================================================
            extraResources = [
                # Grant cluster-admin to all SAs in crossplane-system namespace
                # Required for Helm provider to create namespaces and install charts
                {
                    apiVersion = "rbac.authorization.k8s.io/v1"
                    kind = "ClusterRoleBinding"
                    metadata.name = "crossplane-system-cluster-admin"
                    roleRef = {
                        apiGroup = "rbac.authorization.k8s.io"
                        kind = "ClusterRole"
                        name = "cluster-admin"
                    }
                    subjects = [
                        {
                            kind = "Group"
                            name = "system:serviceaccounts:crossplane-system"
                            apiGroup = "rbac.authorization.k8s.io"
                        }
                    ]
                }
                # Helm ProviderConfig - uses in-cluster identity
                {
                    apiVersion = "helm.m.crossplane.io/v1beta1"
                    kind = "ProviderConfig"
                    metadata = {
                        name = "default"
                        namespace = "default"
                    }
                    spec = {
                        credentials = {
                            source = "InjectedIdentity"
                        }
                    }
                }
            ]

            # ==============================================================
            # manifests: Psql XR
            # Deleted during cleanup (unless --skip-delete)
            # ==============================================================
            manifests = [
                stacksv1alpha1.PSQLStack {
                    metadata = {
                        name = _test_name
                        namespace = "default"
                    }
                    spec = {
                        clusterName = "default"
                        namespace = "stackgres"
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                        helmProviderConfigRef = {
                            name = "default"
                            kind = "ProviderConfig"
                        }
                        # Minimal resource requests for kind cluster
                        stackgresOperator.values = {
                            deploy = {
                                operator = True
                                restapi = True
                            }
                        }
                        atlasOperator.values = {
                            prewarmDevDB = False
                        }
                    }
                }
            ]
        }
    }
]
items = _items

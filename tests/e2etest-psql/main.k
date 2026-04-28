import datetime
import math
import models.ai.com.ops.hops.v1alpha1 as hopsv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unified E2E Test for psql-stack package
#
# Exercises all three XRs in the package together:
#   - PSQLStack    (installs CNPG operator + atlas-operator via Helm)
#   - PSQLCluster  (per-app Postgres XR; composes a CNPG Cluster CR + ExternalSecret)
#   - PSQLBranch   (ephemeral fork; composes VolumeSnapshot + bootstrapped CNPG Cluster)
#
# Bar: defaultConditions = ["Synced"]. We verify each XR composes its children
# correctly. We do NOT wait for the wrapped CNPG Cluster / VolumeSnapshot to
# reconcile — that requires CNPG + snapshot-controller to be live in-cluster.
#
# TODO (after volume-snapshot-stack v0.1.0 releases): upgrade this test to
# defaultConditions = ["Ready"] using the observe e2e pattern:
#   - initResources: install volume-snapshot-stack Configuration package
#   - extraResources: VolumeSnapshotStack XR (deploys snapshot-controller)
#   - bump timeoutSeconds to ~5400 (PSQLStack Helm install + CNPG bootstrap +
#     real PVC + snapshot + bootstrap-from-snapshot is a long chain)
# Tracked in tasks/merge-psql-client-apis-into-stack progress log.
#
# Run: make e2e
# Run without cleanup: up test run tests/e2etest-psql --e2e --skip-control-plane-cleanup
# ==============================================================================

_now = str(int(math.floor(datetime.ticks())))
_test_name = "e2e-psql-" + _now
_cluster_name = "e2e-psql-cluster-" + _now
_branch_name = "e2e-psql-branch-" + _now

_items = [
    metav1alpha1.E2ETest {
        metadata.name = "psql-e2e"
        spec = {
            crossplane = {
                autoUpgrade.channel = "Rapid"
            }
            defaultConditions = ["Synced"]
            timeoutSeconds = 1800        # 30 min — Helm install + composition apply
            cleanupTimeoutSeconds = 900  # 15 min
            skipDelete = False

            # ==============================================================
            # extraResources: RBAC + Provider configs
            # NOT deleted during cleanup
            # ==============================================================
            extraResources = [
                # cluster-admin to all SAs in crossplane-system so Helm + Kubernetes
                # providers can apply wrapped manifests freely.
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
                # Helm ProviderConfig — for PSQLStack (installs CNPG + atlas-operator)
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
                # Kubernetes ProviderConfig — for PSQLCluster + PSQLBranch
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1beta1"
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
            # manifests: all three XRs applied together
            # Deleted during cleanup (unless --skip-delete)
            # ==============================================================
            manifests = [
                # 1. PSQLStack — Helm-installs CNPG operator + atlas-operator + VolumeSnapshotClass
                hopsv1alpha1.PSQLStack {
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
                # 2. PSQLCluster — per-app Postgres XR (composition only; CNPG CRDs
                #    aren't reconciled in kind without the operator being live)
                hopsv1alpha1.PSQLCluster {
                    metadata = {
                        name = _cluster_name
                        namespace = "default"
                    }
                    spec = {
                        clusterName = "default"
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                        kubernetesProviderConfigRef = {
                            name = "default"
                            kind = "ProviderConfig"
                        }
                        storage = {size = "1Gi"}
                        # Skip ExternalSecret in e2e — no ESO ClusterSecretStore in kind harness.
                        credentials.superuser.managedBy = ""
                    }
                }
                # 3. PSQLBranch — ephemeral fork (composition only; VolumeSnapshot
                #    + recovery bootstrap not exercised without snapshot-controller)
                hopsv1alpha1.PSQLBranch {
                    metadata = {
                        name = _branch_name
                        namespace = "default"
                    }
                    spec = {
                        clusterName = "default"
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                        kubernetesProviderConfigRef = {
                            name = "default"
                            kind = "ProviderConfig"
                        }
                        source = {name = _cluster_name}
                    }
                }
            ]
        }
    }
]
items = _items

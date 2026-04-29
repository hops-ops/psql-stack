import datetime
import math
import models.ai.com.ops.hops.v1alpha1 as hopsv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unified E2E Test for psql-stack package — full Ready integration
#
# Exercises all three XRs in the package end-to-end:
#   - PSQLStack    (installs CNPG operator + atlas-operator via Helm)
#   - PSQLCluster  (per-app Postgres XR; composes a CNPG Cluster CR + ExternalSecret)
#   - PSQLBranch   (ephemeral fork; composes VolumeSnapshot + bootstrapped CNPG Cluster)
#
# Bar: defaultConditions = ["Ready"]. The chain is:
#   1. snapshot-controller installed via VolumeSnapshotStack (initResources +
#      extraResources VolumeSnapshotStack XR)
#   2. PSQLStack reconciles → Helm-installs CNPG + atlas-operator + a
#      VolumeSnapshotClass that PSQLBranch uses as its forking target
#   3. PSQLCluster reconciles → CNPG provisions a real Postgres cluster (the
#      operator is now live) with a real PVC
#   4. PSQLBranch reconciles → snapshots the source cluster's PVC, restores
#      into a new CNPG cluster (snapshot-controller is now live)
#
# Pattern mirrors aws-observe-stack's e2e: install dependent Configuration
# packages via initResources, materialize their XRs in extraResources, then
# the manifests under test depend on them.
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
            defaultConditions = ["Ready"]
            # 90 minutes — long chain: snapshot-controller install → PSQLStack
            # Helm install (CNPG + atlas + VolumeSnapshotClass) → PSQLCluster
            # bootstraps a real Postgres → PSQLBranch snapshots + restores.
            timeoutSeconds = 5400
            cleanupTimeoutSeconds = 1800
            skipDelete = False

            # ==============================================================
            # initResources: dependency Configuration packages
            # Installed BEFORE manifests, NOT deleted during cleanup.
            # ==============================================================
            initResources = [
                # volume-snapshot-stack — provides the cluster-wide
                # snapshot-controller that PSQLBranch's VolumeSnapshot
                # children rely on. EKS Auto Mode + colima ship the snapshot
                # CRDs but no controller; this stack closes that gap.
                {
                    apiVersion = "pkg.crossplane.io/v1"
                    kind = "Configuration"
                    metadata = {
                        name = "hops-ops-volume-snapshot-stack"
                    }
                    spec = {
                        package = "ghcr.io/hops-ops/volume-snapshot-stack:v0.1.0"
                    }
                }
            ]

            # ==============================================================
            # extraResources: RBAC + Provider configs + dependent XRs
            # NOT deleted during cleanup.
            # ==============================================================
            extraResources = [
                # cluster-admin to all SAs in crossplane-system so Helm +
                # Kubernetes providers can apply wrapped manifests freely.
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
                # Helm ProviderConfig — for PSQLStack + VolumeSnapshotStack
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
                # VolumeSnapshotStack XR — installs the cluster-wide
                # snapshot-controller via Helm. PSQLBranch's VolumeSnapshot
                # objects only get reconciled to readyToUse=true when this
                # controller is running.
                {
                    apiVersion = "hops.ops.com.ai/v1alpha1"
                    kind = "VolumeSnapshotStack"
                    metadata = {
                        name = "snapshot"
                        namespace = "default"
                    }
                    spec = {
                        clusterName = "default"
                    }
                }
            ]

            # ==============================================================
            # manifests: all three XRs under test, applied together.
            # Deleted during cleanup (unless --skip-delete).
            # ==============================================================
            manifests = [
                # 1. PSQLStack — Helm-installs CNPG operator + atlas-operator + VolumeSnapshotClass.
                # Defaults: namespace=cnpg-system, ProviderConfigs default to clusterName.
                hopsv1alpha1.PSQLStack {
                    metadata = {
                        name = _test_name
                        namespace = "default"
                    }
                    spec = {
                        clusterName = "default"
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                        helmProviderConfigRef = {
                            name = "default"
                            kind = "ProviderConfig"
                        }
                        kubernetesProviderConfigRef = {
                            name = "default"
                            kind = "ProviderConfig"
                        }
                    }
                }
                # 2. PSQLCluster — per-app Postgres XR. CNPG (installed by
                #    PSQLStack above) provisions a real Postgres cluster with
                #    a real PVC backing the data.
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
                # 3. PSQLBranch — ephemeral fork. Snapshots the source
                #    PSQLCluster's PVC (snapshot-controller installed by the
                #    VolumeSnapshotStack extraResource handles this), restores
                #    into a new CNPG cluster bootstrapped from the snapshot.
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

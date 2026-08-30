import base64
import file
import datetime
import math
import models.ai.com.ops.hops.v1alpha1 as hopsv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unified E2E Test for psql-stack — full Ready integration on a real EKS cluster.
#
# Local-fidelity pattern (mirrors aws-observe-stack): the kind cluster the
# runner spins up is the *management* cluster. The actual XRs target an
# ephemeral EKS Auto Mode cluster provisioned during the test, where the
# `psql` StorageClass + VolumeSnapshotClass composed by PSQLStack land on a
# real `ebs.csi.eks.amazonaws.com` driver — same code path that runs on
# pat-local. No fake CSI on kind; snapshots and forks actually work.
#
# Chain:
#   1. extraResources: AutoEKSCluster XR provisions the EKS cluster
#      (subnets reused from the persistent hops-test network created by the
#      aws-network e2e test). aws-auto-eks-cluster auto-creates Helm +
#      Kubernetes ProviderConfigs named after the cluster.
#   2. extraResources: VolumeSnapshotStack XR installs the cluster-wide
#      snapshot-controller via Helm into the new cluster.
#   3. manifests: PSQLStack reconciles → Helm-installs CNPG + Atlas + S2Z +
#      `psql` StorageClass + `psql` VolumeSnapshotClass.
#   4. manifests: PSQLCluster reconciles → CNPG provisions a real Postgres
#      cluster on a real EBS-backed PVC.
#   5. manifests: PSQLBranch reconciles → snapshots the source PVC via the
#      composed `psql` VSC, restores into a new CNPG cluster bootstrapped
#      from the snapshot.
#
# Run: make e2e
# Run without cleanup: up test run tests/e2etest-psql --e2e --skip-control-plane-cleanup
# ==============================================================================

# Workflow writes credentials + env vars to these files (write-env-files: true).
_creds = file.read("secrets/aws-creds")
_base64_creds = base64.encode(_creds)
_region = file.read("env/AWS_REGION").strip()
_account_id = file.read("env/AWS_ACCOUNT_ID").strip()
_admin_role_arn = file.read("env/ADMIN_ROLE_ARN").strip()
_private_subnet_ids = [
    file.read("env/PRIVATE_SUBNET_ID_A").strip()
    file.read("env/PRIVATE_SUBNET_ID_B").strip()
]

_now = str(int(math.floor(datetime.ticks())))
_test_name = "e2e-psql-" + _now
_cluster_name = "e2e-psql-cluster-" + _now
_branch_name = "e2e-psql-branch-" + _now
_namespace = "default"

_items = [
    metav1alpha1.E2ETest {
        metadata.name = "psql-e2e"
        spec = {
            crossplane = {
                autoUpgrade.channel = "Rapid"
            }
            defaultConditions = ["Ready"]
            # 90 minutes — EKS Auto Mode cold start is ~10–15min; CNPG bootstrap
            # + snapshot fork add another ~10min on top of the platform install.
            timeoutSeconds = 5400
            # 30 minutes for cleanup (delete-extra-resources tears the cluster
            # down; that takes ~10–15min on its own).
            cleanupTimeoutSeconds = 1800
            skipDelete = False

            # ==================================================================
            # initResources: dependency Configuration packages
            # Installed BEFORE manifests, NOT deleted during cleanup.
            # ==================================================================
            initResources = [
                # aws-auto-eks-cluster — provides the AutoEKSCluster XRD.
                {
                    apiVersion = "pkg.crossplane.io/v1"
                    kind = "Configuration"
                    metadata.name = "aws-auto-eks-cluster"
                    spec.package = "ghcr.io/hops-ops/aws-auto-eks-cluster:v2.2.1"
                }
                # volume-snapshot-stack — provides the VolumeSnapshotStack XRD
                # (installs the cluster-wide snapshot-controller). PSQLBranch's
                # VolumeSnapshot only reaches readyToUse=true with this running.
                {
                    apiVersion = "pkg.crossplane.io/v1"
                    kind = "Configuration"
                    metadata.name = "hops-ops-volume-snapshot-stack"
                    spec.package = "ghcr.io/hops-ops/volume-snapshot-stack:v0.1.3"
                }
                # cert-stack — installs cert-manager onto the target cluster.
                # PSQLStack's scaleToZeroPlugin uses cert-manager Issuer +
                # Certificate for the plugin's gRPC mTLS pair, so without this
                # the stack stays NotReady on `s2z-cert-{client,server,issuer}`.
                {
                    apiVersion = "pkg.crossplane.io/v1"
                    kind = "Configuration"
                    metadata.name = "hops-ops-cert-stack"
                    spec.package = "ghcr.io/hops-ops/cert-stack:v0.1.0"
                }
            ]

            # ==================================================================
            # extraResources: AWS creds + ProviderConfigs + the EKS cluster XR
            # itself. NOT deleted during cleanup (the cluster XR is torn down
            # separately via delete-extra-resources in the workflow so it
            # outlives the manifests' cascade delete).
            # ==================================================================
            extraResources = [
                # AWS credentials secret (sourced from the OIDC-assumed role).
                {
                    apiVersion = "v1"
                    kind = "Secret"
                    metadata = {
                        name = "aws-creds"
                        namespace = _namespace
                    }
                    data = {
                        creds = _base64_creds
                    }
                }
                # AWS ProviderConfig — for AutoEKSCluster's IAM/EKS resources.
                {
                    apiVersion = "aws.m.upbound.io/v1beta1"
                    kind = "ProviderConfig"
                    metadata = {
                        name = "default"
                        namespace = _namespace
                    }
                    spec = {
                        credentials = {
                            source = "Secret"
                            secretRef = {
                                namespace = _namespace
                                name = "aws-creds"
                                key = "creds"
                            }
                        }
                    }
                }
                # Kubernetes ProviderConfig "default" — used by aws-auto-eks-cluster
                # to apply the per-cluster Helm + Kubernetes ProviderConfigs into
                # the management cluster (kind). Cluster-targeting XRs reference
                # the per-cluster ProviderConfigs (named after _test_name).
                {
                    apiVersion: "kubernetes.m.crossplane.io/v1alpha1"
                    kind: "ProviderConfig"
                    metadata: {
                        name: "default"
                        namespace: "default"
                    }
                    spec: {
                        credentials: {
                            source: "InjectedIdentity"
                        }
                    }
                }
                # DeploymentRuntimeConfig for provider-kubernetes — gives the
                # provider a known SA name we can grant cluster-admin on the
                # management cluster.
                {
                    apiVersion: "pkg.crossplane.io/v1beta1"
                    kind: "DeploymentRuntimeConfig"
                    metadata: {
                        name: "crossplane-contrib-provider-kubernetes"
                    }
                    spec: {
                        serviceAccountTemplate: {
                            metadata: {
                                name: "crossplane-contrib-provider-kubernetes"
                            }
                        }
                    }
                }
                {
                    apiVersion: "v1"
                    kind: "ServiceAccount"
                    metadata: {
                        name: "crossplane-contrib-provider-kubernetes"
                        namespace: "crossplane-system"
                    }
                }
                {
                    apiVersion: "rbac.authorization.k8s.io/v1"
                    kind: "ClusterRoleBinding"
                    metadata: {
                        name: "crossplane-contrib-provider-kubernetes-admin"
                    }
                    roleRef: {
                        apiGroup: "rbac.authorization.k8s.io"
                        kind: "ClusterRole"
                        name: "cluster-admin"
                    }
                    subjects: [
                        {
                            kind: "ServiceAccount"
                            name: "crossplane-contrib-provider-kubernetes"
                            namespace: "crossplane-system"
                        }
                    ]
                }
                # Pin the K8s provider so the runtime config takes effect.
                {
                    apiVersion: "pkg.crossplane.io/v1"
                    kind: "Provider"
                    metadata: {
                        name: "crossplane-contrib-provider-kubernetes"
                    }
                    spec: {
                        package: "xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v1.2.0"
                        runtimeConfigRef: {
                            name: "crossplane-contrib-provider-kubernetes"
                        }
                    }
                }
                # The ephemeral EKS cluster. Reuses the persistent hops-test
                # network's private subnets so we don't pay VPC create cost
                # per PR. AutoEKSCluster auto-creates Helm + Kubernetes
                # ProviderConfigs named _test_name once Ready.
                {
                    apiVersion = "aws.hops.ops.com.ai/v1alpha1"
                    kind = "AutoEKSCluster"
                    metadata = {
                        name = _test_name
                        namespace = _namespace
                    }
                    spec = {
                        adminRoleArn = _admin_role_arn
                        clusterName = _test_name
                        region = _region
                        accountId = _account_id
                        version = "1.35"
                        subnetIds = _private_subnet_ids
                        providerConfigRef = {
                            name = "default"
                            kind = "ProviderConfig"
                        }
                        kubernetesProviderConfigRef = {
                            name = "default"
                            kind = "ProviderConfig"
                        }
                        tags = {
                            "e2etest" = "true"
                            "test-run" = _now
                            "repo": "https://github.com/hops-ops/psql-stack"
                        }
                        publicAccess = True
                        nodeConfig = {
                            enabled = True
                        }
                        oidc = {
                            enabled = False
                        }
                    }
                }
                # snapshot-controller on the new cluster — gates VolumeSnapshot
                # readiness for PSQLBranch's fork. clusterName = _test_name
                # routes Helm installs through the per-cluster ProviderConfig
                # auto-created by AutoEKSCluster.
                {
                    apiVersion = "hops.ops.com.ai/v1alpha1"
                    kind = "VolumeSnapshotStack"
                    metadata = {
                        name = "snapshot"
                        namespace = _namespace
                    }
                    spec = {
                        clusterName = _test_name
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                    }
                }
                # cert-manager on the new cluster — gates the s2z plugin's TLS
                # pair (Issuer + client/server Certificates). Without this,
                # PSQLStack stays NotReady on s2z-cert-* objects.
                {
                    apiVersion = "hops.ops.com.ai/v1alpha1"
                    kind = "CertStack"
                    metadata = {
                        name = "cert"
                        namespace = _namespace
                    }
                    spec = {
                        clusterName = _test_name
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                    }
                }
            ]

            # ==================================================================
            # manifests: the three psql-stack XRs. Each targets the EKS cluster
            # via clusterName=_test_name, which the compositions translate into
            # providerConfigRef.name on the per-cluster ProviderConfigs created
            # by AutoEKSCluster. Cleaned up cascade-deletes the CNPG primaries +
            # branch + their PVCs/snapshots; the cluster itself stays up until
            # the workflow's delete-extra-resources step tears it down.
            # ==================================================================
            manifests = [
                hopsv1alpha1.PSQLStack {
                    metadata = {
                        name = _test_name
                        namespace = _namespace
                    }
                    spec = {
                        clusterName = _test_name
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                    }
                }
                hopsv1alpha1.PSQLCluster {
                    metadata = {
                        name = _cluster_name
                        namespace = _namespace
                    }
                    spec = {
                        clusterName = _test_name
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                        storage = {size = "1Gi"}
                        # No app block — CNPG auto-generates `<cluster>-app`.
                    }
                }
                hopsv1alpha1.PSQLBranch {
                    metadata = {
                        name = _branch_name
                        namespace = _namespace
                    }
                    spec = {
                        clusterName = _test_name
                        labels = {
                            "hops.ops.com.ai/e2etest" = "true"
                            "hops.ops.com.ai/test-run" = _now
                        }
                        # source.storage.size mirrors the PSQLCluster's
                        # `spec.storage.size = "1Gi"` above. The branch
                        # composition has no automatic visibility into the
                        # source cluster's PVC capacity, so this explicit
                        # mirror lets the rendered Cluster CR set the
                        # required storage.size without forcing the consumer
                        # to also set `branch.storage.size`.
                        source = {
                            name = _cluster_name
                            storage = {size = "1Gi"}
                        }
                    }
                }
            ]
        }
    }
]
items = _items

import models.ai.com.ops.hops.v1alpha1 as stacksv1alpha1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

# ==============================================================================
# Unit tests for PSQLCluster XRD
#
# Philosophy: test YOUR API, not CNPG's. Verify spec fields produce expected
# wiring (intent → mechanics) inside the composed Cluster + ExternalSecret.
# ==============================================================================

_items = [
    # ==========================================================================
    # Test 1: minimal claim renders only the Cluster — no ExternalSecret by
    # default. Bootstrap wires the app role/database; `secret` is omitted so
    # CNPG auto-generates `<cluster-name>-app` and owns it. Branching labels
    # on by default, monitoring on, no plugins, no affinity, no custom storage
    # class.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "minimal-renders-cluster-only"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "test-app", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "10Gi"}
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "test-app-cnpg-cluster"
                    spec.forProvider.manifest = {
                        apiVersion = "postgresql.cnpg.io/v1"
                        kind = "Cluster"
                        metadata = {
                            name = "test-app"
                            namespace = "default"
                            labels = {
                                "hops.ops.com.ai/managed" = "true"
                                "hops.ops.com.ai/psql-cluster" = "test-app"
                                "hops.ops.com.ai/branching-source" = "true"
                                "hops.ops.com.ai/snapshot-class" = "psql"
                            }
                        }
                        spec = {
                            instances = 1
                            imageName = "ghcr.io/cloudnative-pg/postgresql:17"
                            bootstrap.initdb = {
                                database = "app"
                                owner = "app"
                            }
                            storage.size = "10Gi"
                            monitoring.enablePodMonitor = True
                        }
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 2: ha.enabled=true bumps instances + adds zonal anti-affinity.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "ha-enabled-bumps-instances-and-affinity"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "ha-app", namespace = "default"}
                spec = {
                    clusterName = "prod"
                    storage = {size = "20Gi"}
                    ha = {enabled = True, replicas = 3, topologySpreadByZone = True}
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "ha-app-cnpg-cluster"
                    spec.forProvider.manifest.spec = {
                        instances = 3
                        affinity = {
                            enablePodAntiAffinity = True
                            podAntiAffinityType = "preferred"
                            topologyKey = "topology.kubernetes.io/zone"
                        }
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 3: scaleToZero.enabled=true adds annotation + plugins entry.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "scaletozero-enabled-adds-annotation-and-plugin"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "s2z-app", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "5Gi"}
                    scaleToZero = {enabled = True, idleTimeout = "10m"}
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "s2z-app-cnpg-cluster"
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
    # Test 4: branching.enabled=false strips the branching-source labels.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "branching-disabled-strips-labels"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "no-branch", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "5Gi"}
                    branching = {enabled = False}
                }
            }
            # Stack labels remain; branching-* labels do not.
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "no-branch-cnpg-cluster"
                    spec.forProvider.manifest.metadata.labels = {
                        "hops.ops.com.ai/managed" = "true"
                        "hops.ops.com.ai/psql-cluster" = "no-branch"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 5: storage.class set passes through to spec.storage.storageClass.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "storage-class-passes-through"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "sc-app", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "5Gi", class = "gp3"}
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "sc-app-cnpg-cluster"
                    spec.forProvider.manifest.spec.storage = {
                        size = "5Gi"
                        storageClass = "gp3"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 6: postgresql.parameters pass through.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "postgresql-parameters-pass-through"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "tuned-app", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "5Gi"}
                    postgresql = {
                        # renovate: datasource=docker depName=library/postgres registryUrl=https://index.docker.io
                        version = "17"
                        parameters = {
                            shared_buffers = "256MB"
                            max_connections = "200"
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "tuned-app-cnpg-cluster"
                    spec.forProvider.manifest.spec.postgresql.parameters = {
                        shared_buffers = "256MB"
                        max_connections = "200"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 7: app.externalSecret renders an ESO ExternalSecret pulling from
    # the named ClusterSecretStore. Default behavior (Test 1) doesn't render
    # one — this asserts the opt-in path.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "external-secret-renders-when-opted-in"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "es-app", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "5Gi"}
                    app = {
                        externalSecret = {
                            secretStore = {
                                kind = "ClusterSecretStore"
                                name = "hops-aws-secrets-manager"
                            }
                            secretRef = {
                                path = "my-cluster/es-app"
                            }
                        }
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "es-app-cnpg-cluster"
                    spec.forProvider.manifest.spec.bootstrap.initdb = {
                        database = "app"
                        owner = "app"
                        secret.name = "es-app-app"
                    }
                }
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "es-app-external-secret-app"
                    spec.forProvider.manifest = {
                        apiVersion = "external-secrets.io/v1"
                        kind = "ExternalSecret"
                        metadata.name = "es-app-app"
                        spec = {
                            refreshInterval = "1h"
                            secretStoreRef = {
                                name = "hops-aws-secrets-manager"
                                kind = "ClusterSecretStore"
                            }
                            # Both username + password must be mapped from the
                            # JSON blob at secretRef.path. CNPG reads this
                            # Secret as kubernetes.io/basic-auth — a single
                            # remoteRef without `property` would leave one of
                            # the two keys empty and CNPG would fail to
                            # bootstrap the role. Lock in the full shape so
                            # future drift is caught.
                            data = [
                                {
                                    secretKey = "username"
                                    remoteRef = {
                                        key = "my-cluster/es-app"
                                        property = "username"
                                    }
                                }
                                {
                                    secretKey = "password"
                                    remoteRef = {
                                        key = "my-cluster/es-app"
                                        property = "password"
                                    }
                                }
                            ]
                            target = {
                                name = "es-app-app"
                                creationPolicy = "Owner"
                                template = {
                                    type = "kubernetes.io/basic-auth"
                                    data = {
                                        username = "{{ .username }}"
                                        password = "{{ .password }}"
                                    }
                                }
                            }
                        }
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 8: cnpg.overrideAllValues replaces the whole Cluster.spec.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "cnpg-override-replaces-cluster-spec"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "override-app", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "5Gi"}  # required, but overridden by cnpg.overrideAllValues
                    cnpg.overrideAllValues = {
                        instances = 5
                        imageName = "custom/postgres:99"
                        storage = {size = "999Gi"}
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "override-app-cnpg-cluster"
                    spec.forProvider.manifest.spec = {
                        instances = 5
                        imageName = "custom/postgres:99"
                        storage.size = "999Gi"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 9: BYO mode — explicit `app.secretName` (no externalSecret) wires
    # CNPG at the named Secret. Consumer is responsible for pre-creating it.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "byo-secret-name-wires-cnpg-at-named-secret"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "byo-app", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "5Gi"}
                    app = {
                        secretName = "my-precreated-secret"
                    }
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "byo-app-cnpg-cluster"
                    spec.forProvider.manifest.spec.bootstrap.initdb = {
                        database = "app"
                        owner = "app"
                        secret.name = "my-precreated-secret"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # Test 10: kubernetesProviderConfigRef defaults to clusterName.
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "k8s-provider-config-defaults-to-cluster-name"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "p-app", namespace = "default"}
                spec = {
                    clusterName = "prod-cluster"
                    storage = {size = "5Gi"}
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "p-app-cnpg-cluster"
                    spec.providerConfigRef = {
                        name = "prod-cluster"
                        kind = "ProviderConfig"
                    }
                }
            ]
        }
    }

    # ==========================================================================
    # monitoring.enabled=false propagates to the Cluster CR. Default is true
    # (covered by Test 1's monitoring.enablePodMonitor = True assertion); this
    # locks in that explicit `false` is honored — the hasKey guard in
    # state-init distinguishes "explicitly off" from "absent".
    # ==========================================================================
    metav1alpha1.CompositionTest {
        metadata.name = "monitoring-disabled-when-explicit-false"
        spec = {
            compositionPath = "apis/psqlclusters/composition.yaml"
            xrdPath = "apis/psqlclusters/definition.yaml"
            timeoutSeconds = 60
            validate = False
            xr = stacksv1alpha1.PSQLCluster {
                metadata = {name = "no-mon", namespace = "default"}
                spec = {
                    clusterName = "my-cluster"
                    storage = {size = "10Gi"}
                    monitoring.enabled = False
                }
            }
            assertResources = [
                {
                    apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
                    kind = "Object"
                    metadata.name = "no-mon-cnpg-cluster"
                    spec.forProvider.manifest.spec.monitoring.enablePodMonitor = False
                }
            ]
        }
    }
]

items = _items

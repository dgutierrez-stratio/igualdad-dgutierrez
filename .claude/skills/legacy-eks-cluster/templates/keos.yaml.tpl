aws:
  eks: true
  enabled: true
docker_registry:
  auth_required: false
  type: ecr
  url: ${ECR_REGISTRY}
  ecr_pull_through_cache_enabled: true
helm_repository:
  auth_required: false
  type: ecr
  url: oci://${ECR_REGISTRY}/${KEOS_HELM_PATH}
keos:
  cluster_id: ${CLUSTER_NAME}
  domain: cluster.local
  external_domain: ${EXTERNAL_DOMAIN}
  flavour: production
  k8s_installation: false
  storage:
    config:
      csi-aws:
        efs:
        - id: ${EFS_ID}
          name: ${EFS_SC_NAME}
          permissions: '700'
    default_storage_class: keos
    providers:
    - custom
    - csi-aws

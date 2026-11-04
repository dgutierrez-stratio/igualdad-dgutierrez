apiVersion: installer.stratio.com/v1beta1
kind: KeosCluster
metadata:
    name: ${CLUSTER_NAME}
spec:
    control_plane:
        aws:
            associate_oidc_provider: true
            logging:
                api_server: true
                audit: false
                authenticator: true
                controller_manager: false
                scheduler: false
            mp_role_name: eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io
        managed: true
    credentials:
        aws:
            access_key: "${AWS_ACCESS_KEY}"
            account_id: "${AWS_ACCOUNT_ID}"
            region: ${AWS_REGION}
            secret_key: "${AWS_SECRET_KEY}"
    deploy_autoscaler: true
    dns:
        manage_zone: true
    docker_registries:
        - keos_registry: true
          type: ecr
          url: ${ECR_REGISTRY}
          auth_required: false
          ecr_pull_through_cache_enabled: true
    external_domain: ${EXTERNAL_DOMAIN}
    helm_repository:
        auth_required: false
        release_interval: 1m
        release_retries: 3
        release_source_interval: 1m
        repository_interval: 10m
        type: ecr
        url: oci://${ECR_REGISTRY}/${CP_HELM_PATH}
    infra_provider: aws
    k8s_version: ${K8S_VERSION}
    region: ${AWS_REGION}
    networks:
        vpc_id: ${VPC_ID}
        subnets:
            - subnet_id: ${SUBNET_1}
            - subnet_id: ${SUBNET_2}
            - subnet_id: ${SUBNET_3}
    security:
        aws:
            create_iam: true
            nodegroup_extra_policy_arn: ${ECR_POLICY_ARN}
    worker_nodes:
        - ami_type: BOTTLEROCKET_x86_64
          labels:
            disktype: standard
          max_size: ${NODE_MAX}
          min_size: ${NODE_MIN}
          name: ${NODEGROUP_NAME}
          quantity: ${NODE_QTY}
          root_volume:
            encrypted: true
            size: 100
            type: gp3
          size: ${NODE_SIZE}
---
apiVersion: installer.stratio.com/v1beta1
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
spec:
  cluster_operator_version: ${CLUSTER_OPERATOR_VERSION}
  cluster_operator_image_version: ${CLUSTER_OPERATOR_VERSION}
  eks_lb_controller: false
  private_helm_repo: true
  private_registry: true
  gitops_enabled: false

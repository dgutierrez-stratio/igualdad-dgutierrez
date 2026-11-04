---
external_dns_aws_eks_iam_role_sa_arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-external-dns"
flux_deployment_enabled: false
ingress_external_lb: true
ingress_internal_lb: true
ingress_internal_lb_annotations:
  service.beta.kubernetes.io/aws-load-balancer-internal: "true"
  service.beta.kubernetes.io/aws-load-balancer-backend-protocol: tcp
  service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout: "60"
  service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
  service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
ingress_external_access_cidrs: ${INGRESS_EXTERNAL_CIDRS}
prometheus_blackbox_exporter_enabled: true
prometheus_pushgateway_enabled: true
prometheus_ldap_query_exporter_enabled: true
prometheus_certificates_exporter_enabled: true
base_postgres_retries: 100
velero_storage_provider: "aws"
velero_object_storage_configuration_aws_iam_role_sa_enabled: true
velero_object_storage_configuration_aws_iam_role_sa_arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${VELERO_ROLE}"
velero_object_storage_configuration_aws_bucket: "${VELERO_BUCKET}"
velero_object_storage_configuration_aws_region: "${AWS_REGION}"

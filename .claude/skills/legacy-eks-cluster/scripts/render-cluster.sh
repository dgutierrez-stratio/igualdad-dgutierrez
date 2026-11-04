#!/usr/bin/env bash
# render-cluster.sh — paso 4: genera <dir>/cluster.yaml a partir de la plantilla, cluster.env, el JSON de la VPC y las
# claves del usuario IAM cloud-provisioner.
#
# Usage: render-cluster.sh [--dir DIR]
#
# Entradas:
#   <dir>/cluster.env                variables del clúster (init-cluster.sh)
#   <dir>/<cluster>.json             salida de create-test-vpc.sh --output (vpc_id + subnets privadas). Override: NETWORK_JSON=ruta
#   perfil $CP_PROFILE               access/secret key (aws configure get). Override para pruebas: AWS_ACCESS_KEY y AWS_SECRET_KEY
#   templates/cluster.yaml.tpl       de la skill, o <dir>/templates/cluster.yaml.tpl si existe
# Salida: <dir>/cluster.yaml (chmod 600, CONTIENE SECRETOS: no subir a git; nunca se imprimen).
# Falla si falta una variable, si el JSON no tiene exactamente 3 subnets privadas, si queda algún ${...} o si el YAML no parsea.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
DIR=""; while [[ $# -gt 0 ]]; do case "$1" in --dir) DIR="$2"; shift 2 ;; -h|--help) sed -n '2,14p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;; esac; done
DIR="$(resolve_dir "$DIR")"; need_tools jq envsubst yq
load_env "$DIR" CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION CP_PROFILE ECR_REGISTRY K8S_VERSION \
  CLUSTER_OPERATOR_VERSION ECR_POLICY_ARN NODEGROUP_NAME NODE_SIZE NODE_QTY NODE_MIN NODE_MAX
TPL="$(tpl_path "$DIR" cluster.yaml.tpl)"; OUT="$DIR/cluster.yaml"
# Repo de charts de cloud-provisioner (helm_repository.url del descriptor): /helm. NO es el de keos-installer (KEOS_HELM_PATH,
# helm-15.1, solo en keos.yaml): con helm-15.1 cloud-provisioner no encuentra cert-manager y las versiones no son las de la migración.
CP_HELM_PATH="${CP_HELM_PATH:-helm}"

NETWORK_JSON="${NETWORK_JSON:-$DIR/${CLUSTER_NAME}.json}"
[[ -f "$NETWORK_JSON" ]] || die "no existe $NETWORK_JSON (salida de create-test-vpc.sh --output; paso 3)"
VPC_ID="$(jq -er '.vpc_id' "$NETWORK_JSON")" || die "$NETWORK_JSON no tiene vpc_id"
mapfile -t SUBNETS < <(jq -er '.azs[].private_subnet' "$NETWORK_JSON") || die "$NETWORK_JSON no tiene subnets privadas"
[[ "${#SUBNETS[@]}" -eq 3 ]] || die "la plantilla espera 3 subnets privadas y $NETWORK_JSON tiene ${#SUBNETS[@]}"
SUBNET_1="${SUBNETS[0]}"; SUBNET_2="${SUBNETS[1]}"; SUBNET_3="${SUBNETS[2]}"

# Claves del usuario IAM cloud-provisioner: nunca se imprimen.
if [[ -z "${AWS_ACCESS_KEY:-}" || -z "${AWS_SECRET_KEY:-}" ]]; then
  AWS_ACCESS_KEY="$("${AWS_GET_BIN:-aws}" configure get aws_access_key_id --profile "$CP_PROFILE" 2>/dev/null || true)"
  AWS_SECRET_KEY="$("${AWS_GET_BIN:-aws}" configure get aws_secret_access_key --profile "$CP_PROFILE" 2>/dev/null || true)"
fi
[[ -n "$AWS_ACCESS_KEY" && -n "$AWS_SECRET_KEY" ]] || die "el perfil $CP_PROFILE no tiene aws_access_key_id/aws_secret_access_key (paso 1: provision.sh iam-user)"

export CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION ECR_REGISTRY CP_HELM_PATH K8S_VERSION CLUSTER_OPERATOR_VERSION \
       ECR_POLICY_ARN NODEGROUP_NAME NODE_SIZE NODE_QTY NODE_MIN NODE_MAX VPC_ID SUBNET_1 SUBNET_2 SUBNET_3 AWS_ACCESS_KEY AWS_SECRET_KEY
VARS='${CLUSTER_NAME} ${EXTERNAL_DOMAIN} ${AWS_ACCOUNT_ID} ${AWS_REGION} ${ECR_REGISTRY} ${CP_HELM_PATH} ${K8S_VERSION}
${CLUSTER_OPERATOR_VERSION} ${ECR_POLICY_ARN} ${NODEGROUP_NAME} ${NODE_SIZE} ${NODE_QTY} ${NODE_MIN} ${NODE_MAX}
${VPC_ID} ${SUBNET_1} ${SUBNET_2} ${SUBNET_3} ${AWS_ACCESS_KEY} ${AWS_SECRET_KEY}'

render_template "$TPL" "$OUT" "$VARS" 600

# Validación estructural (sin imprimir secretos)
J="$(yaml2json "$OUT")" || die "cluster.yaml no es YAML válido"
jq -e 'length==2 and (map(.kind)|sort==["ClusterConfig","KeosCluster"])' <<<"$J" >/dev/null || die "se esperaban 2 documentos: KeosCluster y ClusterConfig"
jq -e '.[]|select(.kind=="ClusterConfig")|.spec.gitops_enabled==false' <<<"$J" >/dev/null || die "gitops_enabled debe ser false"
jq -e --arg n "$CLUSTER_NAME" 'all(.[]; .metadata.name==$n)' <<<"$J" >/dev/null || die "metadata.name no coincide con $CLUSTER_NAME"

echo "OK: $OUT generado (cluster=$CLUSTER_NAME vpc=$VPC_ID subnets=$SUBNET_1,$SUBNET_2,$SUBNET_3), permisos 600"
echo "AVISO: contiene access/secret key; no lo subas a git."

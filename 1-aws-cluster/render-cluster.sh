#!/usr/bin/env bash
# render-cluster.sh — genera estado/cluster.yaml a partir de cluster.yaml.tpl, cluster.env y la salida de create-test-vpc.sh
#
# Usage (desde cualquier directorio):
#   1-aws-cluster/render-cluster.sh [ENV_FILE]    # por defecto <raiz del workspace>/cluster.env
#
# Entradas:
#   ENV_FILE            variables del clúster (ver cluster.env.example). Si es ruta relativa se resuelve desde el directorio actual.
#   estado/${CLUSTER_NAME}.json  salida de create-test-vpc.sh (vpc_id + subnets privadas). Override: NETWORK_JSON=ruta
#   perfil $CP_PROFILE  access key / secret key del usuario IAM cloud-provisioner (aws configure get).
#                       Override para pruebas: exportar AWS_ACCESS_KEY y AWS_SECRET_KEY
# Salida:
#   estado/cluster.yaml (chmod 600, contiene secretos: no subir a git). Override: OUT=ruta, TPL=ruta
# Rutas (todas con override por entorno): WORKSPACE_DIR (def. el directorio padre de este script), STATE_DIR (def. <este dir>/estado).
#
# Falla si falta alguna variable, si el JSON no tiene exactamente 3 subnets privadas o si queda algún ${...} sin resolver.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/estado}"
ENV_FILE="${1:-$WORKSPACE_DIR/cluster.env}"
TPL="${TPL:-$SCRIPT_DIR/cluster.yaml.tpl}"
OUT="${OUT:-$STATE_DIR/cluster.yaml}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "no existe $ENV_FILE (copia 1-aws-cluster/cluster.env.example a la raíz del workspace como cluster.env)"
[[ -f "$TPL" ]] || die "no existe la plantilla $TPL"
# shellcheck disable=SC1090
source "$ENV_FILE"

REQUIRED=(CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION CP_PROFILE ECR_REGISTRY K8S_VERSION
          CLUSTER_OPERATOR_VERSION ECR_POLICY_ARN NODEGROUP_NAME NODE_SIZE NODE_QTY NODE_MIN NODE_MAX)
for v in "${REQUIRED[@]}"; do
  [[ -n "${!v:-}" ]] || die "la variable $v está vacía o no definida en $ENV_FILE"
done
# Repo de charts de cloud-provisioner (helm_repository.url del descriptor): /helm. El de keos-installer (KEOS_HELM_PATH) es solo para keos.yaml.
CP_HELM_PATH="${CP_HELM_PATH:-helm}"   # cloud-provisioner usa /helm; helm-15.1 es solo de keos-installer (keos.yaml)

# --- Red: salida de create-test-vpc.sh ---
NETWORK_JSON="${NETWORK_JSON:-$STATE_DIR/${CLUSTER_NAME}.json}"
[[ -f "$NETWORK_JSON" ]] || die "no existe $NETWORK_JSON (salida de create-test-vpc.sh --output)"
VPC_ID="$(jq -er '.vpc_id' "$NETWORK_JSON")" || die "$NETWORK_JSON no tiene vpc_id"
mapfile -t SUBNETS < <(jq -er '.azs[].private_subnet' "$NETWORK_JSON") || die "$NETWORK_JSON no tiene subnets privadas"
[[ "${#SUBNETS[@]}" -eq 3 ]] || die "la plantilla espera 3 subnets privadas y $NETWORK_JSON tiene ${#SUBNETS[@]}"
SUBNET_1="${SUBNETS[0]}"; SUBNET_2="${SUBNETS[1]}"; SUBNET_3="${SUBNETS[2]}"

# --- Credenciales del usuario IAM cloud-provisioner (nunca se imprimen) ---
if [[ -z "${AWS_ACCESS_KEY:-}" || -z "${AWS_SECRET_KEY:-}" ]]; then
  AWS_ACCESS_KEY="$(aws configure get aws_access_key_id --profile "$CP_PROFILE" || true)"
  AWS_SECRET_KEY="$(aws configure get aws_secret_access_key --profile "$CP_PROFILE" || true)"
fi
[[ -n "$AWS_ACCESS_KEY" && -n "$AWS_SECRET_KEY" ]] \
  || die "el perfil $CP_PROFILE no tiene aws_access_key_id/aws_secret_access_key (paso 1 de la guía)"

export CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION ECR_REGISTRY CP_HELM_PATH K8S_VERSION CLUSTER_OPERATOR_VERSION \
       ECR_POLICY_ARN NODEGROUP_NAME NODE_SIZE NODE_QTY NODE_MIN NODE_MAX \
       VPC_ID SUBNET_1 SUBNET_2 SUBNET_3 AWS_ACCESS_KEY AWS_SECRET_KEY

# Solo se sustituyen estas variables: cualquier otro ${...} de la plantilla se detecta abajo como error.
VARS='${CLUSTER_NAME} ${EXTERNAL_DOMAIN} ${AWS_ACCOUNT_ID} ${AWS_REGION} ${ECR_REGISTRY} ${CP_HELM_PATH} ${K8S_VERSION}
${CLUSTER_OPERATOR_VERSION} ${ECR_POLICY_ARN} ${NODEGROUP_NAME} ${NODE_SIZE} ${NODE_QTY} ${NODE_MIN} ${NODE_MAX}
${VPC_ID} ${SUBNET_1} ${SUBNET_2} ${SUBNET_3} ${AWS_ACCESS_KEY} ${AWS_SECRET_KEY}'

mkdir -p "$(dirname "$OUT")"
TMP="$(umask 077; mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
envsubst "$VARS" < "$TPL" > "$TMP"

if grep -n '\${' "$TMP" | sed -E 's/(key: ).*/\1<oculto>/' | grep .; then
  die "quedan variables sin resolver en la plantilla (líneas arriba)"
fi

chmod 600 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT

echo "OK: $OUT generado (cluster=$CLUSTER_NAME vpc=$VPC_ID subnets=$SUBNET_1,$SUBNET_2,$SUBNET_3)"
echo "AVISO: $OUT contiene access/secret key; no lo subas a git."

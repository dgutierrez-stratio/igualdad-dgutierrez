#!/usr/bin/env bash
# check-prereqs.sh — paso 0 de la skill: comprobaciones de SOLO LECTURA antes de crear nada.
#
# Usage: check-prereqs.sh [--dir DIR] [--ecr]
#   --ecr   además hace el paso 2b: `docker login` al ECR central (con el perfil CP_PROFILE, que debe existir ya)
#           y `docker manifest inspect` de la imagen de arranque. Escribe un token de 12 h en ~/.docker/config.json.
#
# Salida: líneas "ok  ..." / "KO  ..." / "aviso ...". Código de salida 0 si no hay ningún KO.
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DIR=""; ECR=0
while [[ $# -gt 0 ]]; do
  case "$1" in --dir) DIR="$2"; shift 2 ;; --ecr) ECR=1; shift ;; -h|--help) sed -n '2,10p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;; esac
done
DIR="$(resolve_dir "$DIR")"
load_env "$DIR" CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION CP_PROFILE ECR_REGISTRY CLOUD_PROVISIONER_VERSION VELERO_BUCKET VELERO_ROLE EXTERNAL_DOMAIN

KO=0
ok()  { okmsg "$*"; }
ko()  { komsg "$*"; KO=$((KO+1)); }
av()  { echo "aviso $*"; }

echo "== Herramientas =="
for t in aws jq yq envsubst kubectl helm docker; do command -v "$t" >/dev/null 2>&1 && ok "$t" || ko "falta $t"; done
command -v clusterctl >/dev/null 2>&1 && ok "clusterctl (solo necesario para la desinstalación)" || av "clusterctl no está instalado (necesario solo en la fase 2 del teardown; el contenedor kind lo incluye)"
first_aws="$(type -ap aws | head -1)"
if "$first_aws" --version 2>&1 | grep -q '^aws-cli/1'; then
  av "el primer aws del PATH ($first_aws) es la v1: los scripts bash lo usan salvo que haya v2 (se prefiere v2); en v1 no existen --no-cli-pager ni 'configure list-profiles'"
fi
yq --version >/dev/null 2>&1 && ok "yq: $(yq --version 2>&1 | head -1)"
docker info >/dev/null 2>&1 && ok "docker daemon en marcha" || ko "el daemon de docker no responde (cloud-provisioner crea un clúster kind local)"
free_gb="$(df -Pk "$DIR" | awk 'NR==2{printf "%d", $4/1048576}')"
[[ "${free_gb:-0}" -ge 15 ]] && ok "espacio libre: ${free_gb} GB" || ko "poco espacio libre (${free_gb} GB): se necesitan varios GB para las imágenes de kind"

echo "== cloud-provisioner =="
BIN="${CLOUD_PROVISIONER_BIN:-}"
if [[ -z "$BIN" ]]; then ko "CLOUD_PROVISIONER_BIN vacío en cluster.env (compilar desde el tag $CLOUD_PROVISIONER_VERSION: references/steps.md, paso 0)"
elif [[ ! -x "$BIN" ]]; then ko "CLOUD_PROVISIONER_BIN=$BIN no es ejecutable"
else
  "$BIN" --help >/dev/null 2>&1 && ok "binario: $BIN" || ko "$BIN --help falla"
  "$BIN" version 2>/dev/null | grep -q "$CLOUD_PROVISIONER_VERSION" && ok "versión $CLOUD_PROVISIONER_VERSION" || ko "la versión del binario no coincide con $CLOUD_PROVISIONER_VERSION"
fi
echo "aviso VAULT_PASSWORD debe exportarlo la persona usuaria en SU terminal (nunca se guarda en ficheros)"

echo "== AWS (solo lectura, cuenta $AWS_ACCOUNT_ID, región $AWS_REGION) =="
if [[ -z "${ADMIN_PROFILE:-}" ]]; then
  ko "ADMIN_PROFILE vacío: pregunta a la persona usuaria qué perfil usar (init-cluster.sh --dir $DIR --set ADMIN_PROFILE=...)"
else
  set_aws "$ADMIN_PROFILE" "$AWS_REGION"
  idj="$(awsx sts get-caller-identity --output json 2>/dev/null || true)"
  if [[ -z "$idj" ]]; then ko "sts get-caller-identity falló con el perfil $ADMIN_PROFILE (credenciales caducadas/MFA)"
  else
    acct="$(jq -r .Account <<<"$idj")"
    [[ "$acct" == "$AWS_ACCOUNT_ID" ]] && ok "perfil $ADMIN_PROFILE -> cuenta $acct ($(jq -r .Arn <<<"$idj"))" || ko "el perfil $ADMIN_PROFILE opera en la cuenta $acct, se esperaba $AWS_ACCOUNT_ID"
    if [[ "$acct" == "$AWS_ACCOUNT_ID" ]]; then
      eks="$(awsx eks list-clusters --output json 2>/dev/null | jq -r '.clusters[]?' | grep -x "$CLUSTER_NAME" || true)"
      [[ -z "$eks" ]] && ok "no existe un EKS llamado $CLUSTER_NAME" || ko "ya existe un EKS llamado $CLUSTER_NAME"
      vpcs="$(awsx ec2 describe-vpcs --filters "Name=tag:Name,Values=$CLUSTER_NAME" --output json 2>/dev/null | jq -r '.Vpcs[]?.VpcId')"
      [[ -z "$vpcs" ]] && ok "no existe una VPC con Name=$CLUSTER_NAME" || ko "ya existe una VPC con Name=$CLUSTER_NAME ($vpcs)"
      for r in "${CLUSTER_NAME}-external-dns" "$VELERO_ROLE"; do
        awsx iam get-role --role-name "$r" >/dev/null 2>&1 && av "el rol IAM $r ya existe (¿reanudando una instalación?)" || ok "rol IAM $r libre"
      done
      out="$(awsx s3api head-bucket --bucket "$VELERO_BUCKET" 2>&1)"; rc=$?
      if [[ $rc -eq 0 ]]; then av "el bucket $VELERO_BUCKET ya existe y es accesible (¿reanudando?)"
      elif grep -q '404' <<<"$out"; then ok "bucket $VELERO_BUCKET libre (los nombres S3 son globales)"
      elif grep -q '403' <<<"$out"; then ko "el bucket $VELERO_BUCKET existe en OTRA cuenta (nombre global): cambia VELERO_BUCKET"
      else av "head-bucket $VELERO_BUCKET: respuesta no concluyente"; fi
      zones="$(awsx route53 list-hosted-zones-by-name --dns-name "$EXTERNAL_DOMAIN" --output json 2>/dev/null | jq -r --arg n "${EXTERNAL_DOMAIN}." '[.HostedZones[]|select(.Name==$n)]|length')"
      [[ "${zones:-0}" -eq 0 ]] && ok "no hay zonas Route53 de $EXTERNAL_DOMAIN" || av "ya hay $zones zona(s) Route53 de $EXTERNAL_DOMAIN"
      eips="$(awsx ec2 describe-addresses --output json 2>/dev/null | jq '.Addresses|length')"
      av "EIP en uso en la región: ${eips:-?} (el NAT single necesita 1; cuota por defecto 5). Revisa también cuota de vCPU (3 x m6a.4xlarge = 48)"
    fi
  fi
fi

echo "== keos-installer =="
if getent hosts qa.int.stratio.com >/dev/null 2>&1; then ok "qa.int.stratio.com resuelve (VPN/red interna)"; else av "qa.int.stratio.com no resuelve: sin VPN no se podrá descargar/usar ${KEOS_INSTALLER_IMAGE:-keos-installer}"; fi
if [[ -n "${KEOS_INSTALLER_IMAGE:-}" ]]; then
  docker image inspect "$KEOS_INSTALLER_IMAGE" >/dev/null 2>&1 && ok "imagen $KEOS_INSTALLER_IMAGE ya descargada" || av "imagen $KEOS_INSTALLER_IMAGE no descargada (docker pull al llegar al paso 13)"
fi

if [[ $ECR -eq 1 ]]; then
  echo "== ECR central (paso 2b) =="
  set_aws "$CP_PROFILE" "$AWS_REGION"
  if awsx ecr get-login-password 2>/dev/null | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null 2>&1; then
    ok "docker login a $ECR_REGISTRY"
    docker manifest inspect "$ECR_REGISTRY/stratio/cloud-provisioner:$CLOUD_PROVISIONER_VERSION" >/dev/null 2>&1 \
      && ok "imagen de arranque stratio/cloud-provisioner:$CLOUD_PROVISIONER_VERSION accesible" \
      || ko "no se puede leer la imagen de arranque (denied => pedir acceso a la cuenta dueña del ECR; not found => otra CLOUD_PROVISIONER_VERSION)"
  else ko "docker login al ECR falló (¿existe ya el perfil $CP_PROFILE? paso 1)"; fi
fi

echo
[[ $KO -eq 0 ]] && { echo "RESULTADO: OK (sin KO)"; exit 0; } || { echo "RESULTADO: $KO KO"; exit 1; }

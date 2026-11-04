#!/usr/bin/env bash
# render-keos.sh — genera keos.yaml y override_vars/${CLUSTER_NAME}.yaml para keos-installer
#
# Usage (desde cualquier directorio):
#   1-aws-cluster/render-keos.sh [ENV_FILE]       # por defecto <raiz del workspace>/cluster.env
#
# Entradas: cluster.env, plantillas keos.yaml.tpl y override_vars.yaml.tpl (junto a este script), y el EFS creado
#           en el paso 11 (se localiza por su creation-token = $CLUSTER_NAME; override: EFS_ID=fs-xxxx).
# Salida:   en la RAIZ DEL WORKSPACE de keos-installer (WORKSPACE_DIR, por defecto el directorio padre de este script;
#           es lo que se monta como /workspace): keos.yaml (si ya existe, copia a keos.yaml.cloud-provisioner la primera
#           vez) y override_vars/${CLUSTER_NAME}.yaml.
#           Con ENABLE_BACKUP_VELERO=true también override_charts_values/keos-backup-velero.yaml (no pisa uno existente con
#           useSecret: false; si es otro, lo conserva como .bak.<epoch>). Flags opcionales: ver cluster.env.example.
# Overrides por entorno: WORKSPACE_DIR (destino), TPL_DIR (plantillas, def. este directorio), EFS_ID.
# Sin secretos. Falla si queda algún ${...} sin resolver.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TPL_DIR="${TPL_DIR:-$SCRIPT_DIR}"
ENV_FILE="${1:-$WORKSPACE_DIR/cluster.env}"
die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "no existe $ENV_FILE"
# Los flags opcionales se leen SOLO de cluster.env: se ignora lo heredado del entorno de la shell (así `ENABLE_FALCO=true render-...` no activa nada
# y la skill siempre pregunta antes de activar un opcional). Se activan con `export ENABLE_X=true` en cluster.env.
unset ENABLE_BACKUP_VELERO KEOS_ENABLE_CLAMAV ENABLE_FALCO ENABLE_MONITORING ENABLE_CENTRAL_LOGGING ENABLE_BACKUP_SCHEDULE
# shellcheck disable=SC1090
source "$ENV_FILE"

KEOS_HELM_PATH="${KEOS_HELM_PATH:-helm-15.1}"
REQUIRED=(CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION CP_PROFILE ECR_REGISTRY KEOS_HELM_PATH
          VELERO_BUCKET VELERO_ROLE EFS_SC_NAME INGRESS_EXTERNAL_CIDRS)
for v in "${REQUIRED[@]}"; do
  [[ -n "${!v:-}" ]] || die "la variable $v está vacía o no definida en $ENV_FILE"
done

# --- Flags opcionales (paso 13b; todos false por defecto y con todos a false la salida NO cambia) ---
#   ENABLE_BACKUP_VELERO  keos.backup.storage_class=$EFS_SC_NAME (keos.yaml) + velero_enable_snapshot_volumes: true (override_vars)
#                         + override_charts_values/keos-backup-velero.yaml (credentials.useSecret: false, requisito con IRSA en 1.4.2)
#   KEOS_ENABLE_CLAMAV    keos.security.clamav.enabled: true (lo despliega `keos install`)
#   ENABLE_FALCO          keos.security.falco con enabled: false SIEMPRE (el precheck de `keos install` falla si está a true);
#                         se activa después con los comandos que imprime render-postinstall.sh
ENABLE_BACKUP_VELERO="${ENABLE_BACKUP_VELERO:-false}"; KEOS_ENABLE_CLAMAV="${KEOS_ENABLE_CLAMAV:-false}"; ENABLE_FALCO="${ENABLE_FALCO:-false}"
for _f in ENABLE_BACKUP_VELERO KEOS_ENABLE_CLAMAV ENABLE_FALCO; do
  [[ "${!_f}" == true || "${!_f}" == false ]] || die "$_f debe ser true o false"
done

# insert_block FICHERO ANCLA after|before BLOQUE: inserta BLOQUE junto a la ÚNICA línea que casa con ANCLA (regex de línea completa)
insert_block() {
  local f="$1" re="$2" where="$3" block="$4" tmp
  [[ "$(grep -c -- "$re" "$f" || true)" -eq 1 ]] || die "no encuentro una única línea ancla '$re' en $f (¿plantilla modificada?)"
  tmp="$(mktemp "${f}.XXXXXX")"
  BLK="$block" awk -v re="$re" -v where="$where" '$0 ~ re { if (where=="before") print ENVIRON["BLK"]; print; if (where=="after") print ENVIRON["BLK"]; next } { print }' "$f" > "$tmp"
  chmod 644 "$tmp"; mv "$tmp" "$f"
}

if [[ -z "${EFS_ID:-}" ]]; then
  EFS_ID="$(AWS_PAGER="" aws efs describe-file-systems --creation-token "$CLUSTER_NAME" \
    --profile "$CP_PROFILE" --region "$AWS_REGION" --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || true)"
fi
[[ "${EFS_ID:-}" == fs-* ]] || die "no se encuentra el EFS con creation-token $CLUSTER_NAME (paso 11 de la guía)"

export CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION ECR_REGISTRY KEOS_HELM_PATH \
       VELERO_BUCKET VELERO_ROLE EFS_SC_NAME INGRESS_EXTERNAL_CIDRS EFS_ID

render() {  # render <plantilla> <salida> <lista de variables>
  local tpl="$1" out="$2" vars="$3" tmp
  [[ -f "$tpl" ]] || die "no existe la plantilla $tpl"
  tmp="$(mktemp "${out}.XXXXXX")"
  envsubst "$vars" < "$tpl" > "$tmp"
  if grep -n '\${' "$tmp"; then rm -f "$tmp"; die "quedan variables sin resolver en $tpl (líneas arriba)"; fi
  mv "$tmp" "$out"; chmod 644 "$out"
}

[[ -d "$WORKSPACE_DIR" ]] || die "no existe WORKSPACE_DIR=$WORKSPACE_DIR"
if [[ -f "$WORKSPACE_DIR/keos.yaml" && ! -f "$WORKSPACE_DIR/keos.yaml.cloud-provisioner" ]]; then
  cp "$WORKSPACE_DIR/keos.yaml" "$WORKSPACE_DIR/keos.yaml.cloud-provisioner"
  echo "Copia del keos.yaml generado por cloud-provisioner en $WORKSPACE_DIR/keos.yaml.cloud-provisioner"
fi
render "$TPL_DIR/keos.yaml.tpl" "$WORKSPACE_DIR/keos.yaml" '${ECR_REGISTRY} ${KEOS_HELM_PATH} ${CLUSTER_NAME} ${EXTERNAL_DOMAIN} ${EFS_ID} ${EFS_SC_NAME}'

mkdir -p "$WORKSPACE_DIR/override_vars"
render "$TPL_DIR/override_vars.yaml.tpl" "$WORKSPACE_DIR/override_vars/${CLUSTER_NAME}.yaml" \
  '${AWS_ACCOUNT_ID} ${CLUSTER_NAME} ${INGRESS_EXTERNAL_CIDRS} ${VELERO_ROLE} ${VELERO_BUCKET} ${AWS_REGION}'

# --- Bloques opcionales (la plantilla no se toca: se insertan tras renderizar) ---
if [[ "$ENABLE_BACKUP_VELERO" == true ]]; then
  insert_block "$WORKSPACE_DIR/keos.yaml" '^keos:$' after "  backup:
    storage_class: ${EFS_SC_NAME}"
  printf 'velero_enable_snapshot_volumes: true\n' >> "$WORKSPACE_DIR/override_vars/${CLUSTER_NAME}.yaml"
fi
if [[ "$KEOS_ENABLE_CLAMAV" == true || "$ENABLE_FALCO" == true ]]; then
  SEC="  security:"
  [[ "$KEOS_ENABLE_CLAMAV" == true ]] && SEC+=$'\n    clamav:\n      enabled: true'
  [[ "$ENABLE_FALCO" == true ]] && SEC+=$'\n    falco:\n      enabled: false   # true después de keos install (paso 13b)\n      opensearch_output: true'
  insert_block "$WORKSPACE_DIR/keos.yaml" '^  storage:$' before "$SEC"
fi

# override_charts_values/keos-backup-velero.yaml: con IRSA, keos-installer 1.4.2 no pasa useSecret: false al chart y la BSL queda
# Unavailable ("no EC2 IMDS role found"). Idempotente: si ya existe con useSecret: false no se toca; si es otro, copia .bak.<epoch>.
if [[ "$ENABLE_BACKUP_VELERO" == true ]]; then
  VF="$WORKSPACE_DIR/override_charts_values/keos-backup-velero.yaml"; mkdir -p "$WORKSPACE_DIR/override_charts_values"
  if [[ -f "$VF" ]] && grep -Eq '^[[:space:]]+useSecret:[[:space:]]*false' "$VF"; then
    echo "Ya existe $VF con useSecret: false: no se toca"
  else
    if [[ -f "$VF" ]]; then BK="$VF.bak.$(date +%s)"; mv "$VF" "$BK"; echo "AVISO: $VF no tenía useSecret: false; copia en $BK" >&2; fi
    printf -- '---\ncredentials:\n  useSecret: false\n' > "$VF"; chmod 644 "$VF"
  fi
fi
for _o in "$WORKSPACE_DIR/keos.yaml" "$WORKSPACE_DIR/override_vars/${CLUSTER_NAME}.yaml"; do ! grep -q '\${' "$_o" || die "quedan \${...} sin resolver en $_o tras insertar los bloques opcionales"; done

echo "OK: $WORKSPACE_DIR/keos.yaml y $WORKSPACE_DIR/override_vars/${CLUSTER_NAME}.yaml generados (efs=$EFS_ID)"
[[ "$ENABLE_BACKUP_VELERO$KEOS_ENABLE_CLAMAV$ENABLE_FALCO" == *true* ]] && echo "Opcionales: backup_velero=$ENABLE_BACKUP_VELERO clamav=$KEOS_ENABLE_CLAMAV falco=$ENABLE_FALCO (falco siempre enabled: false en keos.yaml)"
ls -1 "$WORKSPACE_DIR/override_vars"

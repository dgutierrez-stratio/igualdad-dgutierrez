#!/usr/bin/env bash
# render-keos.sh — paso 12: genera <dir>/keos.yaml y <dir>/override_vars/<cluster>.yaml para keos-installer.
#
# Usage: render-keos.sh [--dir DIR]
#
# Entradas: cluster.env, plantillas keos.yaml.tpl / override_vars.yaml.tpl y el EFS del paso 11 (se localiza por su
#           creation-token = $CLUSTER_NAME; override: EFS_ID=fs-xxxx).
# Salida:   keos.yaml (la primera vez conserva el de cloud-provisioner como keos.yaml.cloud-provisioner) y
#           override_vars/<cluster>.yaml. Si INGRESS_EXTERNAL_LB=true y cloud-provisioner dejó override_vars/ingress-nginx.yaml
#           (solo LB interno), lo mueve a ingress-nginx.yaml.cloud-provisioner.bak porque contradice ingress_external_lb: true.
#           Con ENABLE_BACKUP_VELERO=true también override_charts_values/keos-backup-velero.yaml (no pisa uno existente con
#           useSecret: false; si es otro, lo conserva como .bak.<epoch>). Flags opcionales: ver cluster.env.example.
# Sin secretos. Falla si queda algún ${...} sin resolver o el YAML no parsea.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
DIR=""; while [[ $# -gt 0 ]]; do case "$1" in --dir) DIR="$2"; shift 2 ;; -h|--help) sed -n '2,15p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;; esac; done
DIR="$(resolve_dir "$DIR")"; need_tools jq envsubst yq
# Los flags opcionales se leen SOLO de cluster.env: se ignora lo heredado del entorno de la shell (así `ENABLE_FALCO=true render-...` no activa nada
# y la skill siempre pregunta antes de activar un opcional). Se activan con init-cluster.sh --dir D --set ENABLE_X=true.
unset ENABLE_BACKUP_VELERO KEOS_ENABLE_CLAMAV ENABLE_FALCO ENABLE_MONITORING ENABLE_CENTRAL_LOGGING ENABLE_BACKUP_SCHEDULE
load_env "$DIR" CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION CP_PROFILE ECR_REGISTRY \
  VELERO_BUCKET VELERO_ROLE EFS_SC_NAME INGRESS_EXTERNAL_CIDRS
KEOS_HELM_PATH="${KEOS_HELM_PATH:-helm-15.1}"
INGRESS_EXTERNAL_LB="${INGRESS_EXTERNAL_LB:-true}"
[[ "$INGRESS_EXTERNAL_LB" == true || "$INGRESS_EXTERNAL_LB" == false ]] || die "INGRESS_EXTERNAL_LB debe ser true o false"

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
  set_aws "$CP_PROFILE" "$AWS_REGION"
  EFS_ID="$(awsx efs describe-file-systems --creation-token "$CLUSTER_NAME" --output json 2>/dev/null | jq -r '.FileSystems[0].FileSystemId // ""' || true)"
fi
[[ "${EFS_ID:-}" == fs-* ]] || die "no se encuentra el EFS con creation-token $CLUSTER_NAME (paso 11: provision.sh efs)"
export CLUSTER_NAME EXTERNAL_DOMAIN AWS_ACCOUNT_ID AWS_REGION ECR_REGISTRY KEOS_HELM_PATH VELERO_BUCKET VELERO_ROLE \
       EFS_SC_NAME INGRESS_EXTERNAL_CIDRS INGRESS_EXTERNAL_LB EFS_ID

cd "$DIR"
if [[ -f keos.yaml && ! -f keos.yaml.cloud-provisioner ]]; then
  cp keos.yaml keos.yaml.cloud-provisioner; echo "Copia del keos.yaml de cloud-provisioner en keos.yaml.cloud-provisioner"
fi
render_template "$(tpl_path "$DIR" keos.yaml.tpl)" keos.yaml \
  '${ECR_REGISTRY} ${KEOS_HELM_PATH} ${CLUSTER_NAME} ${EXTERNAL_DOMAIN} ${EFS_ID} ${EFS_SC_NAME}' 644
mkdir -p override_vars
render_template "$(tpl_path "$DIR" override_vars.yaml.tpl)" "override_vars/${CLUSTER_NAME}.yaml" \
  '${AWS_ACCOUNT_ID} ${CLUSTER_NAME} ${INGRESS_EXTERNAL_CIDRS} ${INGRESS_EXTERNAL_LB} ${VELERO_ROLE} ${VELERO_BUCKET} ${AWS_REGION}' 644

# --- Bloques opcionales (la plantilla no se toca: se insertan tras renderizar) ---
if [[ "$ENABLE_BACKUP_VELERO" == true ]]; then
  insert_block keos.yaml '^keos:$' after "  backup:
    storage_class: ${EFS_SC_NAME}"
  printf 'velero_enable_snapshot_volumes: true\n' >> "override_vars/${CLUSTER_NAME}.yaml"
fi
if [[ "$KEOS_ENABLE_CLAMAV" == true || "$ENABLE_FALCO" == true ]]; then
  SEC="  security:"
  [[ "$KEOS_ENABLE_CLAMAV" == true ]] && SEC+=$'\n    clamav:\n      enabled: true'
  [[ "$ENABLE_FALCO" == true ]] && SEC+=$'\n    falco:\n      enabled: false   # true después de keos install (paso 13b)\n      opensearch_output: true'
  insert_block keos.yaml '^  storage:$' before "$SEC"
fi

# override_charts_values/keos-backup-velero.yaml: con IRSA, keos-installer 1.4.2 no pasa useSecret: false al chart y la BSL queda
# Unavailable ("no EC2 IMDS role found"). Idempotente: si ya existe con useSecret: false no se toca; si es otro, copia .bak.<epoch>.
if [[ "$ENABLE_BACKUP_VELERO" == true ]]; then
  VF=override_charts_values/keos-backup-velero.yaml; mkdir -p override_charts_values
  if [[ -f "$VF" ]] && grep -Eq '^[[:space:]]+useSecret:[[:space:]]*false' "$VF"; then
    echo "Ya existe $VF con useSecret: false: no se toca"
  else
    if [[ -f "$VF" ]]; then BK="$VF.bak.$(date +%s)"; mv "$VF" "$BK"; warn "$VF no tenía useSecret: false; copia en $BK"; fi
    printf -- '---\ncredentials:\n  useSecret: false\n' > "$VF"; chmod 644 "$VF"
  fi
  yaml2json "$VF" >/dev/null || die "$VF no parsea"
fi
for _o in keos.yaml "override_vars/${CLUSTER_NAME}.yaml"; do ! grep -q '\${' "$_o" || die "quedan \${...} sin resolver en $_o tras insertar los bloques opcionales"; done

if [[ "$INGRESS_EXTERNAL_LB" == true && -f override_vars/ingress-nginx.yaml ]]; then
  mv override_vars/ingress-nginx.yaml override_vars/ingress-nginx.yaml.cloud-provisioner.bak
  echo "Movido override_vars/ingress-nginx.yaml -> .cloud-provisioner.bak (contradecía ingress_external_lb: true)"
fi

yaml2json keos.yaml >/dev/null || die "keos.yaml no parsea"
yaml2json "override_vars/${CLUSTER_NAME}.yaml" >/dev/null || die "override_vars/${CLUSTER_NAME}.yaml no parsea"
echo "OK: keos.yaml y override_vars/${CLUSTER_NAME}.yaml generados (efs=$EFS_ID, ingress_external_lb=$INGRESS_EXTERNAL_LB)"
[[ "$ENABLE_BACKUP_VELERO$KEOS_ENABLE_CLAMAV$ENABLE_FALCO" == *true* ]] && echo "Opcionales: backup_velero=$ENABLE_BACKUP_VELERO clamav=$KEOS_ENABLE_CLAMAV falco=$ENABLE_FALCO (falco siempre enabled: false en keos.yaml)"
ls -1 override_vars

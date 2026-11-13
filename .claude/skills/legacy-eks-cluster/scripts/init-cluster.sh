#!/usr/bin/env bash
# init-cluster.sh — prepara el directorio de trabajo de un clúster a partir de SOLO cuenta AWS + nombre.
#
# Usage:
#   init-cluster.sh --account 123456789012 --name mi-cluster [opciones]
#   init-cluster.sh --dir ./clusters/mi-cluster --set CLAVE=VALOR [--set ...]     # editar un cluster.env existente
#
# Opciones:
#   --account ID          cuenta AWS (12 dígitos)                                  [obligatoria al crear]
#   --name NOMBRE         nombre del clúster (kebab-case, 3-40 caracteres)         [obligatoria al crear]
#   --region R            región (default eu-west-1)
#   --domain D            EXTERNAL_DOMAIN (default <nombre>.desa.int)
#   --admin-profile P     perfil de administración (si no, se descubre con find-admin-profile.sh)
#   --cp-profile P        perfil del usuario IAM cloud-provisioner (default: cloud-provisioner; si ese perfil ya
#                         existe y es de OTRA cuenta, se propone cloud-provisioner-<cuenta>)
#   --base-dir D          directorio padre de los clústeres (default ./clusters)
#   --dir D               directorio de trabajo exacto (default <base-dir>/<nombre>)
#   --set K=V             fija una variable de cluster.env (repetible)
#   --no-detect           no consulta AWS ni busca el binario (pruebas offline)
#   --force               sobrescribe un cluster.env existente
#
# Crea <dir>/{cluster.env,.work/,logs/} (chmod 700 el directorio: acabará con secretos). No crea nada en AWS.
# Salida final: línea "DIR=<ruta>" y, si no se pudo decidir, avisos "PREGUNTAR: ..." para la skill.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ACCOUNT=""; NAME=""; REGION="eu-west-1"; DOMAIN=""; ADMIN=""; CPP=""; BASE="./clusters"; DIR=""; FORCE=0; DETECT=1
SETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account) ACCOUNT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --admin-profile) ADMIN="$2"; shift 2 ;;
    --cp-profile) CPP="$2"; shift 2 ;;
    --base-dir) BASE="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --set) SETS+=("$2"); shift 2 ;;
    --no-detect) DETECT=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "opción desconocida: $1" ;;
  esac
done

# Fija/actualiza `export KEY=VALOR` en un fichero env (sin sed: el valor puede llevar cualquier carácter).
set_env_var() {  # set_env_var FICHERO CLAVE VALOR
  local f="$1" k="$2" v="$3" q tmp
  q="$(printf '%q' "$v")"
  tmp="$(mktemp "${f}.XXXXXX")"
  K="$k" Q="$q" awk 'BEGIN{k=ENVIRON["K"]; q=ENVIRON["Q"]; done=0}
    $0 ~ "^export " k "=" { print "export " k "=" q; done=1; next } { print }
    END{ if(!done) print "export " k "=" q }' "$f" > "$tmp"
  mv "$tmp" "$f"
}

# --- modo edición de un cluster.env existente ---
if [[ -n "$DIR" && -f "$DIR/cluster.env" && $FORCE -eq 0 ]]; then
  [[ ${#SETS[@]} -gt 0 ]] || die "$DIR/cluster.env ya existe (usa --set K=V para editarlo o --force para regenerarlo)"
  for kv in "${SETS[@]}"; do [[ "$kv" == *=* ]] || die "--set espera CLAVE=VALOR"; set_env_var "$DIR/cluster.env" "${kv%%=*}" "${kv#*=}"; done
  echo "actualizado $DIR/cluster.env: ${SETS[*]}"; echo "DIR=$DIR"; exit 0
fi

# --- validaciones de entrada ---
[[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || die "--account debe ser un número de 12 dígitos"
# Límites derivados: rol IAM "<n>-external-dns" <= 64, bucket "<n>-velero-<cuenta>" <= 63, etiqueta DNS <= 63.
[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "--name inválido: kebab-case en minúsculas, 3-40 caracteres, empieza por letra (ej. demo-x)"
[[ "$NAME" != *--* ]] || die "--name no debe contener '--'"
[[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || die "--region inválida: $REGION"
[[ -n "$DIR" ]] || DIR="$BASE/$NAME"
if [[ -f "$DIR/cluster.env" && $FORCE -eq 0 ]]; then die "$DIR/cluster.env ya existe (--force para regenerarlo)"; fi

mkdir -p "$DIR/.work" "$DIR/logs"; chmod 700 "$DIR"
DIR="$(cd "$DIR" && pwd)"
ENVF="$DIR/cluster.env"
cp "$SKILL_DIR/templates/cluster.env.example" "$ENVF"
sed -i '1,/^$/!b' "$ENVF" 2>/dev/null || true
set_env_var "$ENVF" CLUSTER_NAME "$NAME"
set_env_var "$ENVF" AWS_ACCOUNT_ID "$ACCOUNT"
set_env_var "$ENVF" AWS_REGION "$REGION"
if [[ -n "$DOMAIN" ]]; then set_env_var "$ENVF" EXTERNAL_DOMAIN "$DOMAIN"; fi

ASK=()
# --- perfil de CP (usuario IAM cloud-provisioner) ---
CPP_DEFAULT="cloud-provisioner"
if [[ -n "$CPP" ]]; then :
elif [[ $DETECT -eq 1 ]] && command -v aws >/dev/null 2>&1; then
  pick_aws_bin
  if "$AWS_BIN" configure list-profiles 2>/dev/null | grep -qx "$CPP_DEFAULT"; then
    got="$(AWS_PAGER="" timeout 40 "$AWS_BIN" sts get-caller-identity --profile "$CPP_DEFAULT" --query Account --output text 2>/dev/null </dev/null || true)"
    if [[ -z "$got" || "$got" == "$ACCOUNT" ]]; then CPP="$CPP_DEFAULT"
    else CPP="${CPP_DEFAULT}-${ACCOUNT}"; warn "el perfil '$CPP_DEFAULT' existente es de la cuenta $got: se usará '$CPP' para esta cuenta"; fi
  else CPP="$CPP_DEFAULT"; fi
else CPP="$CPP_DEFAULT"; fi
set_env_var "$ENVF" CP_PROFILE "$CPP"

# --- perfil de administración ---
if [[ -z "$ADMIN" && $DETECT -eq 1 ]]; then
  set +e; found="$("$SKILL_DIR/scripts/find-admin-profile.sh" --account "$ACCOUNT" --exclude "$CPP" 2>/dev/null)"; rc=$?; set -e
  case $rc in
    0) ADMIN="$found" ;;
    3) ASK+=("ningún perfil local asume un rol en la cuenta $ACCOUNT: pregunta a la persona usuaria qué perfil usar (--set ADMIN_PROFILE=...)") ;;
    4) ASK+=("varios perfiles candidatos para la cuenta $ACCOUNT: $(echo "$found" | tr '\n' ' '): pregunta cuál usar (--set ADMIN_PROFILE=...)") ;;
    *) ASK+=("no se pudo listar perfiles (necesita aws v2): pregunta el perfil de administración (--set ADMIN_PROFILE=...)") ;;
  esac
fi
set_env_var "$ENVF" ADMIN_PROFILE "${ADMIN:-}"

# --- binario de cloud-provisioner ---
VER="$(grep -E '^export CLOUD_PROVISIONER_VERSION=' "$ENVF" | cut -d= -f2)"
if [[ $DETECT -eq 1 ]]; then
  for cand in "$(command -v cloud-provisioner 2>/dev/null || true)" "$HOME/src/cloud-provisioner-$VER/bin/cloud-provisioner"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    if "$cand" version 2>/dev/null | grep -q "$VER"; then set_env_var "$ENVF" CLOUD_PROVISIONER_BIN "$cand"; break; fi
  done
fi

# --- overrides explícitos ---
for kv in "${SETS[@]:-}"; do [[ -n "$kv" ]] || continue; [[ "$kv" == *=* ]] || die "--set espera CLAVE=VALOR"; set_env_var "$ENVF" "${kv%%=*}" "${kv#*=}"; done
# Bucket de backups de la plataforma (GitOps): activado por defecto en clústeres NUEVOS para que ya exista cuando se migre system-services
# (si no, `flux keos` falla con "The GitOps backups bucket does not exist"). Se puede desactivar con --set ENABLE_BACKUPS_BUCKET=false.
case " ${SETS[*]:-} " in *" ENABLE_BACKUPS_BUCKET="*) ;; *) set_env_var "$ENVF" ENABLE_BACKUPS_BUCKET true ;; esac

# --- resumen (valores ya derivados) ---
( set +u; source "$ENVF"
  echo "Directorio de trabajo: $DIR"
  printf '  %-26s %s\n' CLUSTER_NAME "$CLUSTER_NAME" AWS_ACCOUNT_ID "$AWS_ACCOUNT_ID" AWS_REGION "$AWS_REGION" \
    EXTERNAL_DOMAIN "$EXTERNAL_DOMAIN" ADMIN_PROFILE "${ADMIN_PROFILE:-<sin decidir>}" CP_PROFILE "$CP_PROFILE" \
    VELERO_BUCKET "$VELERO_BUCKET" VELERO_ROLE "$VELERO_ROLE" EFS_SC_NAME "$EFS_SC_NAME" \
    K8S_VERSION "$K8S_VERSION" CLOUD_PROVISIONER_VERSION "$CLOUD_PROVISIONER_VERSION" \
    CLOUD_PROVISIONER_BIN "${CLOUD_PROVISIONER_BIN:-<sin localizar: ver paso 0>}" \
    NODES "$NODE_QTY x $NODE_SIZE (min $NODE_MIN, max $NODE_MAX)" INGRESS_EXTERNAL_CIDRS "$INGRESS_EXTERNAL_CIDRS" )
for a in "${ASK[@]:-}"; do [[ -n "$a" ]] && echo "PREGUNTAR: $a"; done
echo "DIR=$DIR"

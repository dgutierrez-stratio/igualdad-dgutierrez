#!/usr/bin/env bash
# lib.sh - funciones comunes del 2-apps-layer-kit (se hace `source`, no se ejecuta).
#
# Carga de variables (de menor a mayor prioridad):
#   defaults del kit  <  cluster.env  <  kit.env  <  variables ya exportadas en el entorno
# Asi se puede relanzar el proceso en otro cluster/cuenta cambiando solo variables:
#   CLUSTER_NAME=otro AWS_ACCOUNT_ID=222222222222 ./scripts/render-apps-layer.sh
#
# Directorio de ejecucion (APPS_LAYER_DIR): por defecto EFIMERO, ${TMPDIR:-/tmp}/apps-layer-${CLUSTER_NAME}, modo 700 y
# propiedad del usuario actual (ver ensure_private_dir). Contiene secretos (.env, YAML del tenant, kube-config, aws/):
# /tmp puede vaciarse al reiniciar; se regenera con render-apps-layer.sh, s3-requisites.sh env e import-llm-token.sh.
# El workspace de keos-installer (KEOS_WORKSPACE_DIR, se monta como /workspace) es la raiz del repo: <kit>/..
#
# Reglas: AWS_PAGER="" siempre (el aws v1 no tiene --no-cli-pager), salida --output json + jq (robusto entre
# aws v1/v2), y los secretos NUNCA se imprimen ni se pasan por linea de comandos.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$LIB_DIR/.." && pwd)"
export AWS_PAGER=""

if [[ -t 2 ]]; then _R=$'\e[31m'; _G=$'\e[32m'; _Y=$'\e[33m'; _N=$'\e[0m'; else _R=""; _G=""; _Y=""; _N=""; fi

die()   { echo "${_R}ERROR:${_N} $*" >&2; exit 1; }
warn()  { echo "${_Y}AVISO:${_N} $*" >&2; }
info()  { echo "$*" >&2; }
okmsg() { echo "${_G}ok${_N}  $*"; }
komsg() { echo "${_R}KO${_N}  $*"; }
wnmsg() { echo "${_Y}!!${_N}  $*"; }

need_tools() {  # need_tools aws jq ...
  local t miss=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done
  [[ ${#miss[@]} -eq 0 ]] || die "faltan herramientas: ${miss[*]}"
}

# ---------------------------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------------------------
KIT_VARS=(CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION EXTERNAL_DOMAIN TENANT_NAME APPS_LAYER_DIR KEOS_WORKSPACE_DIR
  APPS_LAYER_IMAGE APPS_LAYER_IMAGE_DIGEST S3_BUCKET_NAME S3_USER_NAME STACK_NAME ENVIRONMENT_SIZE
  VIRTUALIZER_CREATE_LOADBALANCER USE_TENANT_HOSTS ENABLE_GENAI KEOS_PROFILE UNIVERSE_VERSION
  KEOS_INSTALLER_EXTRA_ARGS KIT_AWS_PROFILE KUBECONFIG_SRC LLM_PROVIDER LLM_MODEL
  NLB_NAMESPACE NLB_SERVICE NLB_IP UNIVERSE_ZIP_URL UNIVERSE_BRANCH CONNECTORS_LOADER_VERSION S3_INIT_PATH
  ENABLE_BACKUPS_BUCKET BACKUPS_BUCKET_NAME BACKUPS_USER_NAME CUSTOM_SIZES_FILE VELERO_BUCKET VELERO_ROLE SC_POSTGRES)

# load_kit_env: aplica defaults y valida. Idempotente.
load_kit_env() {
  local v pre_set=() pre_val=()
  # 1) memoriza lo que el usuario ya tenia exportado (tiene prioridad sobre los ficheros)
  for v in "${KIT_VARS[@]}"; do
    if [[ -n "${!v+x}" ]]; then pre_set+=("$v"); pre_val+=("${!v}"); fi
  done
  # 2) cluster.env y kit.env (si existen)
  CLUSTER_ENV_FILE="${CLUSTER_ENV_FILE:-$KIT_DIR/../cluster.env}"
  KIT_ENV_FILE="${KIT_ENV_FILE:-$KIT_DIR/kit.env}"
  # shellcheck disable=SC1090
  if [[ -f "$CLUSTER_ENV_FILE" ]]; then source "$CLUSTER_ENV_FILE"; fi
  # shellcheck disable=SC1090
  if [[ -f "$KIT_ENV_FILE" ]]; then source "$KIT_ENV_FILE"; fi
  # 3) restaura lo que venia del entorno
  local i
  for i in "${!pre_set[@]}"; do printf -v "${pre_set[$i]}" '%s' "${pre_val[$i]}"; done

  [[ -n "${CLUSTER_NAME:-}"    ]] || die "CLUSTER_NAME no definido (cluster.env, kit.env o entorno)"
  [[ -n "${AWS_ACCOUNT_ID:-}"  ]] || die "AWS_ACCOUNT_ID no definido (cluster.env, kit.env o entorno)"
  [[ -n "${AWS_REGION:-}"      ]] || die "AWS_REGION no definido (cluster.env, kit.env o entorno)"
  [[ -n "${EXTERNAL_DOMAIN:-}" ]] || die "EXTERNAL_DOMAIN no definido (cluster.env, kit.env o entorno)"

  local parent tmp_base; parent="$(cd "$KIT_DIR/.." && pwd)"
  tmp_base="${TMPDIR:-/tmp}"; tmp_base="${tmp_base%/}"
  TENANT_NAME="${TENANT_NAME:-dev}"
  APPS_LAYER_DIR="${APPS_LAYER_DIR:-$tmp_base/apps-layer-${CLUSTER_NAME}}"
  warn_unexpected_apps_layer_dir "$tmp_base/apps-layer-${CLUSTER_NAME}" "${pre_set[*]:-}"
  KEOS_WORKSPACE_DIR="${KEOS_WORKSPACE_DIR:-$parent}"
  APPS_LAYER_IMAGE="${APPS_LAYER_IMAGE:-qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-M2}"
  APPS_LAYER_IMAGE_DIGEST="${APPS_LAYER_IMAGE_DIGEST:-}"
  S3_BUCKET_NAME="${S3_BUCKET_NAME:-${CLUSTER_NAME}-internal-${AWS_ACCOUNT_ID}}"
  S3_USER_NAME="${S3_USER_NAME:-${CLUSTER_NAME}-s3}"
  STACK_NAME="${STACK_NAME:-${CLUSTER_NAME}-requisites}"
  # Bucket de backups de la plataforma Stratio (OPCIONAL, desactivado por defecto: sin activarlo el stack no cambia). Los nombres de
  # bucket S3 son globales: el defecto lleva el sufijo de cuenta (la referencia aws-clusters-automation usa ${CLUSTER_NAME}-backups, que puede chocar).
  ENABLE_BACKUPS_BUCKET="${ENABLE_BACKUPS_BUCKET:-false}"
  BACKUPS_BUCKET_NAME="${BACKUPS_BUCKET_NAME:-${CLUSTER_NAME}-backups-${AWS_ACCOUNT_ID}}"
  BACKUPS_USER_NAME="${BACKUPS_USER_NAME:-${CLUSTER_NAME}-backups}"
  ENVIRONMENT_SIZE="${ENVIRONMENT_SIZE:-S}"
  # overlay de recursos de ENVIRONMENT_SIZE=CUSTOM (solo se lee con CUSTOM; sustituye por completo al templates/sizes-custom.env del kit)
  CUSTOM_SIZES_FILE="${CUSTOM_SIZES_FILE:-$KIT_DIR/templates/sizes-custom.env}"
  # bucket y rol IAM de Velero (los mismos que cluster.env usa para keos.yaml/override_vars): solo los lee backups-env.sh (enviroment-ready --backups)
  VELERO_BUCKET="${VELERO_BUCKET:-${CLUSTER_NAME}-velero-${AWS_ACCOUNT_ID}}"
  VELERO_ROLE="${VELERO_ROLE:-${CLUSTER_NAME}-velero}"
  SC_POSTGRES="${SC_POSTGRES:-}"
  VIRTUALIZER_CREATE_LOADBALANCER="${VIRTUALIZER_CREATE_LOADBALANCER:-false}"
  USE_TENANT_HOSTS="${USE_TENANT_HOSTS:-false}"
  ENABLE_GENAI="${ENABLE_GENAI:-true}"
  KEOS_PROFILE="${KEOS_PROFILE:-full}"
  UNIVERSE_VERSION="${UNIVERSE_VERSION:-15.1.0}"
  KEOS_INSTALLER_EXTRA_ARGS="${KEOS_INSTALLER_EXTRA_ARGS:---net host}"
  KIT_AWS_PROFILE="${KIT_AWS_PROFILE:-${CP_PROFILE:-cloud-provisioner}}"
  KUBECONFIG_SRC="${KUBECONFIG_SRC:-$KEOS_WORKSPACE_DIR/1-aws-cluster/estado/kubeconfig-${CLUSTER_NAME}}"
  LLM_PROVIDER="${LLM_PROVIDER:-}"
  LLM_MODEL="${LLM_MODEL:-}"
  NLB_NAMESPACE="${NLB_NAMESPACE:-keos-ingress}"
  NLB_SERVICE="${NLB_SERVICE:-ingress-nginx-controller}"
  NLB_IP="${NLB_IP:-}"
  UNIVERSE_ZIP_URL="${UNIVERSE_ZIP_URL:-}"   # vacio = URL derivada de UNIVERSE_VERSION (ver universe_zip_url)
  # ref (tag o rama) de Stratio/kubernetes-universe de la que sale universe-images.lst: por defecto el tag UNIVERSE_VERSION
  # Por defecto el TAG de la version (p. ej. 15.1.0), no la rama branch-<major>.<minor>: la rama avanza (hoy ya es 15.1.1: connectors-loader 2.2.5, rocket 4.1.2...)
  # y mezclaria imagenes posteriores con los descriptores 15.1.0. Si UNIVERSE_VERSION no es X.Y.Z se cae a branch-<major>.<minor>.
  if [[ -z "${UNIVERSE_BRANCH:-}" ]]; then
    if [[ "$UNIVERSE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then UNIVERSE_BRANCH="$UNIVERSE_VERSION"
    elif [[ "$UNIVERSE_VERSION" =~ ^([0-9]+)\.([0-9]+) ]]; then UNIVERSE_BRANCH="branch-${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; fi
  fi
  UNIVERSE_BRANCH="${UNIVERSE_BRANCH:-}"
  # version de connectors-loader que se fija en el env de connectors-management del tenant (como Stratio/keos-fleet#220). Se usa "-" (no ":-"):
  # sin definir => 2.2.0; definida pero VACIA a proposito => no se fija y el hook usa el connectors-loader del universe-images.lst fresco.
  CONNECTORS_LOADER_VERSION="${CONNECTORS_LOADER_VERSION-2.2.0}"
  # INIT_PATH de connector-s3 (agente dg-s3-agent). Se usa "-" (no ":-"): sin definir => "/${S3_BUCKET_NAME}" (ya calculado arriba);
  # definida VACIA => aborta (validate_kit_vars). Necesaria por la errata INTI_PATH de vars.env (sin ella el agente crashea con
  # "Missing environment variable: COMM_SERVICE_INIT_PATH"). El driver S3 NO admite "/" (UnsupportedRootInitPath): validate_kit_vars lo rechaza.
  S3_INIT_PATH="${S3_INIT_PATH-/${S3_BUCKET_NAME}}"
  export CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION EXTERNAL_DOMAIN TENANT_NAME APPS_LAYER_DIR KEOS_WORKSPACE_DIR \
         APPS_LAYER_IMAGE S3_BUCKET_NAME S3_USER_NAME STACK_NAME ENVIRONMENT_SIZE VIRTUALIZER_CREATE_LOADBALANCER \
         USE_TENANT_HOSTS ENABLE_GENAI KEOS_PROFILE UNIVERSE_VERSION KEOS_INSTALLER_EXTRA_ARGS CONNECTORS_LOADER_VERSION S3_INIT_PATH \
         ENABLE_BACKUPS_BUCKET BACKUPS_BUCKET_NAME BACKUPS_USER_NAME
  validate_kit_vars
}

# Aviso (no aborta) si el directorio de ejecucion efectivo no es el esperado ${TMPDIR:-/tmp}/apps-layer-<cluster>.
# Caso real: una APPS_LAYER_DIR exportada en el shell por una sesion anterior pisa el defecto y los scripts escriben
# el .env en una ruta vieja sin que se note. Solo informa de la ruta efectiva y de donde viene.
warn_unexpected_apps_layer_dir() {  # warn_unexpected_apps_layer_dir DEFECTO "NOMBRES-PREEXPORTADOS"
  [[ "$APPS_LAYER_DIR" != "$1" ]] || return 0
  local src="kit.env/cluster.env"
  [[ " $2 " != *" APPS_LAYER_DIR "* ]] || src="una variable APPS_LAYER_DIR exportada en tu shell"
  warn "APPS_LAYER_DIR efectivo = $APPS_LAYER_DIR (distinto del esperado $1; viene de $src). Si no es intencionado: unset APPS_LAYER_DIR"
}

validate_kit_vars() {
  local v
  [[ "$ENVIRONMENT_SIZE" == S || "$ENVIRONMENT_SIZE" == PIT || "$ENVIRONMENT_SIZE" == CUSTOM ]] \
    || die "ENVIRONMENT_SIZE='$ENVIRONMENT_SIZE' no valido: solo S, PIT o CUSTOM (otro valor no carga ningun sizes/ y rompe las plantillas de apps-layer; CUSTOM = overlay del kit, ver README)"
  if [[ "$ENVIRONMENT_SIZE" == CUSTOM ]]; then
    [[ "$CUSTOM_SIZES_FILE" == /* ]] || die "CUSTOM_SIZES_FILE debe ser una ruta absoluta (valor: '$CUSTOM_SIZES_FILE')"
    [[ -f "$CUSTOM_SIZES_FILE" && -r "$CUSTOM_SIZES_FILE" ]] || die "ENVIRONMENT_SIZE=CUSTOM pero no se puede leer el overlay de recursos CUSTOM_SIZES_FILE=$CUSTOM_SIZES_FILE"
  fi
  for v in VIRTUALIZER_CREATE_LOADBALANCER USE_TENANT_HOSTS ENABLE_GENAI ENABLE_BACKUPS_BUCKET; do
    [[ "${!v}" == true || "${!v}" == false ]] || die "$v debe ser true o false (valor: '${!v}')"
  done
  [[ "$UNIVERSE_VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || die "UNIVERSE_VERSION '$UNIVERSE_VERSION' no valida (solo [0-9A-Za-z._-]: forma parte del nombre del zip y de la URL)"
  [[ "$UNIVERSE_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "UNIVERSE_BRANCH '$UNIVERSE_BRANCH' no valida: define UNIVERSE_BRANCH (p. ej. branch-15.1), UNIVERSE_VERSION no permite derivarla"
  [[ "$CONNECTORS_LOADER_VERSION" =~ ^[0-9A-Za-z._-]*$ ]] || die "CONNECTORS_LOADER_VERSION '$CONNECTORS_LOADER_VERSION' no valida (solo [0-9A-Za-z._-], o vacia para usar el universe-images.lst)"
  [[ "$S3_INIT_PATH" != / ]] || die "S3_INIT_PATH='/' no valida: el driver S3 (dg-s3-agent) no admite '/' como init-path (UnsupportedRootInitPath); usa '/<bucket>' o '/<bucket>/<prefijo>' (def. '/\${S3_BUCKET_NAME}')"
  [[ -n "$S3_INIT_PATH" && "$S3_INIT_PATH" == /* && "$S3_INIT_PATH" =~ ^[A-Za-z0-9._/,-]+$ ]] || die "S3_INIT_PATH '$S3_INIT_PATH' no valida: no puede estar vacia y debe empezar por '/' (def. '/<S3_BUCKET_NAME>'; o '/<bucket>/<prefijo>'; solo [A-Za-z0-9._/,-])"
  [[ -z "$UNIVERSE_ZIP_URL" || "$UNIVERSE_ZIP_URL" =~ ^https?://[^[:space:]]+$ ]] || die "UNIVERSE_ZIP_URL debe ser una URL http(s) sin espacios"
  [[ "$KEOS_PROFILE" == full || "$KEOS_PROFILE" == minimal ]] || die "KEOS_PROFILE debe ser full o minimal (valor: '$KEOS_PROFILE')"
  [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS_ACCOUNT_ID debe tener 12 digitos"
  [[ "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "CLUSTER_NAME '$CLUSTER_NAME' no valido (minusculas, digitos y guiones)"
  [[ "$TENANT_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "TENANT_NAME '$TENANT_NAME' no valido (minusculas, digitos y guiones)"
  [[ "$TENANT_NAME" != keos ]] || die "TENANT_NAME no puede ser 'keos': es el tenant de gobierno (YAML raiz)"
  [[ "$S3_BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "S3_BUCKET_NAME '$S3_BUCKET_NAME' no es un nombre de bucket valido (3-63, minusculas)"
  [[ "$S3_USER_NAME" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] || die "S3_USER_NAME '$S3_USER_NAME' no es un nombre de usuario IAM valido"
  [[ "$STACK_NAME" =~ ^[A-Za-z][A-Za-z0-9-]{0,127}$ ]] || die "STACK_NAME '$STACK_NAME' no valido"
  validate_backups_vars
  [[ "$LLM_PROVIDER" =~ ^[A-Za-z0-9._-]*$ ]] || die "LLM_PROVIDER solo admite [A-Za-z0-9._-]"
  [[ "$LLM_MODEL" =~ ^[A-Za-z0-9._:/-]*$ ]] || die "LLM_MODEL solo admite [A-Za-z0-9._:/-]"
  [[ "$KEOS_WORKSPACE_DIR" == /* ]] || die "KEOS_WORKSPACE_DIR debe ser una ruta absoluta"
  [[ "$APPS_LAYER_DIR" == /* ]] || die "APPS_LAYER_DIR debe ser una ruta absoluta"
}

# Bucket de backups: solo se validan nombres si esta habilitado (con ENABLE_BACKUPS_BUCKET=false el kit se comporta como antes,
# aunque un CLUSTER_NAME largo diera un nombre por defecto invalido). Mismas reglas que el bucket/usuario internos, mas:
# distintos de los internos (el secreto de Secrets Manager se llama como el usuario) y nunca una identidad protegida: el usuario IAM
# cloud-provisioner, el perfil igualdad ni el perfil AWS que usa el kit (KIT_AWS_PROFILE / CP_PROFILE).
BACKUPS_PROTECTED_USERS=(cloud-provisioner igualdad)
validate_backups_vars() {
  [[ "$ENABLE_BACKUPS_BUCKET" == true ]] || return 0
  [[ "$BACKUPS_BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "BACKUPS_BUCKET_NAME '$BACKUPS_BUCKET_NAME' no es un nombre de bucket valido (3-63, minusculas)"
  [[ "$BACKUPS_USER_NAME" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] || die "BACKUPS_USER_NAME '$BACKUPS_USER_NAME' no es un nombre de usuario IAM valido"
  [[ "$BACKUPS_BUCKET_NAME" != "$S3_BUCKET_NAME" ]] || die "BACKUPS_BUCKET_NAME no puede ser el bucket interno S3_BUCKET_NAME ($S3_BUCKET_NAME)"
  [[ "$BACKUPS_USER_NAME" != "$S3_USER_NAME" ]] || die "BACKUPS_USER_NAME no puede ser S3_USER_NAME ($S3_USER_NAME): usuario IAM y secreto chocarian"
  local p
  for p in "${BACKUPS_PROTECTED_USERS[@]}" "${KIT_AWS_PROFILE:-}" "${CP_PROFILE:-}"; do
    [[ -z "$p" || "$BACKUPS_USER_NAME" != "$p" ]] || die "BACKUPS_USER_NAME '$BACKUPS_USER_NAME' es una identidad PROTEGIDA (usuario cloud-provisioner, perfil igualdad o el perfil AWS del kit): elige otro"
  done
}

# ---------------------------------------------------------------------------------------------
# Directorio de ejecucion privado (700, del usuario actual)
# ---------------------------------------------------------------------------------------------
# verify_private_dir DIR -> 0 si DIR es un directorio real (no enlace), del usuario actual y sin permisos para grupo/otros.
# Si no, imprime el motivo por stdout y devuelve 1.
verify_private_dir() {
  local d="$1" uid owner mode
  if [[ -L "$d" ]]; then echo "$d es un enlace simbolico"; return 1; fi
  [[ -d "$d" ]] || { echo "$d existe y no es un directorio"; return 1; }
  uid="$(id -u)"; owner="$(stat -c %u "$d")"
  [[ "$owner" == "$uid" ]] || { echo "$d no pertenece al usuario actual (uid $owner, el tuyo es $uid)"; return 1; }
  mode="$(stat -c %a "$d")"
  if (( 8#$mode & 077 )); then echo "$d tiene modo $mode (accesible por otros usuarios): chmod 700 $d"; return 1; fi
  return 0
}

# ensure_private_dir DIR: lo crea con umask 077 + chmod 700 si no existe; si existe, verifica propietario y permisos y
# ABORTA si no es del usuario actual o es accesible por otros (contiene secretos).
ensure_private_dir() {
  local d="$1" why
  if [[ -e "$d" || -L "$d" ]]; then
    why="$(verify_private_dir "$d")" || die "directorio de ejecucion de apps-layer no seguro: $why"
    return 0
  fi
  ( umask 077; mkdir -p "$d" )
  chmod 700 "$d"
  info "creado $d (modo 700; directorio efimero con secretos: si /tmp se vacia, regeneralo con render-apps-layer.sh)"
}

# ---------------------------------------------------------------------------------------------
# Zip del universo de descriptores (se descarga SIEMPRE fresco antes de cada lanzamiento y se monta sobre el de la imagen)
# ---------------------------------------------------------------------------------------------
UNIVERSE_ZIP_MOUNT_DIR="/apps-layer-automation/universe"
universe_zip_name() { echo "kubernetes-universe-descriptors-${UNIVERSE_VERSION}.zip"; }
universe_zip_url()  { echo "${UNIVERSE_ZIP_URL:-http://qa.int.stratio.com/repository/paas/kubernetes-universe/descriptors/$(universe_zip_name)}"; }

# validate_universe_zip FICHERO -> 0 si es un fichero regular, no vacio y un zip integro (unzip -t). Si no, imprime el motivo.
validate_universe_zip() {
  local f="$1"
  [[ -f "$f" && ! -L "$f" ]] || { echo "$f no existe o no es un fichero regular"; return 1; }
  [[ -s "$f" ]] || { echo "$f esta vacio"; return 1; }
  command -v unzip >/dev/null 2>&1 || { echo "falta unzip para validar $f"; return 1; }
  unzip -tqq "$f" >/dev/null 2>&1 || { echo "$f no es un zip valido (unzip -t falla)"; return 1; }
  return 0
}

# fetch_universe_zip: descarga el zip del universo a ${APPS_LAYER_DIR}/<nombre> SIN reutilizar ninguna copia previa:
# curl a un temporal del mismo directorio (700), valida (tamano > 0 y unzip -t) y mv atomico. Si falla, aborta y no toca
# la copia previa (el llamador no debe usarla). Imprime URL, ruta, tamano y sha256 (no hay secretos).
fetch_universe_zip() {
  need_tools curl unzip sha256sum
  ensure_private_dir "$APPS_LAYER_DIR"
  local url dest tmp why size sum
  url="$(universe_zip_url)"; dest="$APPS_LAYER_DIR/$(universe_zip_name)"
  tmp="$(umask 077; mktemp "$APPS_LAYER_DIR/.universe.XXXXXX")"
  info "descargando $url"
  if ! curl -fSL -sS --retry 2 --connect-timeout 20 --max-time 900 -o "$tmp" "$url"; then
    rm -f "$tmp"; die "no se pudo descargar $url (VPN/acceso a qa.int.stratio.com?). No se usa ninguna copia previa: repite la descarga."
  fi
  if ! why="$(validate_universe_zip "$tmp")"; then rm -f "$tmp"; die "descarga invalida de $url: $why"; fi
  chmod 644 "$tmp"; mv -f "$tmp" "$dest"
  size="$(stat -c %s "$dest")"; sum="$(sha256sum "$dest" | cut -d' ' -f1)"
  okmsg "zip del universo $UNIVERSE_VERSION descargado: $dest ($size bytes, sha256 $sum)"
}

# universe-images.lst: lista de imagenes del universo. apps/connectors-management/post-install.sh saca de ahi la version de
# connectors-loader (SOLO si el tenant no fija CONNECTORS_LOADER_VERSION; por defecto el kit fija 2.2.0 como la PR keos-fleet#220 y el hook
# ignora el .lst para el loader) y apps/intelligence/post-upgrade.sh la de analytic-environment: el de la imagen (15.1.0) esta desfasado
# (connectors-loader 2.2.0 frente a 2.2.3 en branch-15.1), asi que tambien se descarga SIEMPRE fresco y se monta (:ro).
UNIVERSE_IMAGES_REPO="Stratio/kubernetes-universe"
universe_lst_name() { echo "${UNIVERSE_VERSION}-universe-images.lst"; }

# validate_universe_lst FICHERO -> 0 si es un fichero regular, no vacio y contiene connectors-loader. Si no, imprime el motivo.
validate_universe_lst() {
  local f="$1"
  [[ -f "$f" && ! -L "$f" ]] || { echo "$f no existe o no es un fichero regular"; return 1; }
  [[ -s "$f" ]] || { echo "$f esta vacio"; return 1; }
  grep -q 'connectors-loader' "$f" || { echo "$f no contiene connectors-loader (connectors-management lo necesita)"; return 1; }
  return 0
}

# fetch_universe_lst: gh api (Accept raw) de universe-images.lst en la rama UNIVERSE_BRANCH de Stratio/kubernetes-universe a un
# temporal, valida y mv atomico a ${APPS_LAYER_DIR}/<version>-universe-images.lst. Exige gh autenticado con acceso al repo.
fetch_universe_lst() {
  need_tools gh sha256sum
  ensure_private_dir "$APPS_LAYER_DIR"
  gh auth status >/dev/null 2>&1 || die "gh no esta autenticado (gh auth login) o no tiene sesion valida: se necesita acceso a $UNIVERSE_IMAGES_REPO para descargar universe-images.lst. Parado."
  local dest tmp why line
  dest="$APPS_LAYER_DIR/$(universe_lst_name)"
  tmp="$(umask 077; mktemp "$APPS_LAYER_DIR/.universe-lst.XXXXXX")"
  info "descargando universe-images.lst de $UNIVERSE_IMAGES_REPO@$UNIVERSE_BRANCH"
  if ! GH_PROMPT_DISABLED=1 gh api -H 'Accept: application/vnd.github.raw' "repos/$UNIVERSE_IMAGES_REPO/contents/universe-images.lst?ref=$UNIVERSE_BRANCH" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; die "gh api no pudo leer universe-images.lst de $UNIVERSE_IMAGES_REPO@$UNIVERSE_BRANCH (sin acceso al repo, rama inexistente o red). Parado: no se usa ninguna copia previa."
  fi
  if ! why="$(validate_universe_lst "$tmp")"; then rm -f "$tmp"; die "descarga invalida de universe-images.lst: $why"; fi
  chmod 644 "$tmp"; mv -f "$tmp" "$dest"
  line="$(grep -m1 'connectors-loader' "$dest" | tr -d '[:space:]')"
  okmsg "universe-images.lst ($UNIVERSE_BRANCH) descargado: $dest ($(stat -c %s "$dest") bytes, $(wc -l < "$dest") lineas, sha256 $(sha256sum "$dest" | cut -d' ' -f1)); $line"
}

# Zip + lst: siempre los dos, siempre frescos.
fetch_universe_assets() { fetch_universe_zip; fetch_universe_lst; }

# Ficheros de salida (nombres como en el lab: <cluster>.yaml raiz, <cluster>-<tenant>.yaml tenant)
root_yaml_name()   { echo "${CLUSTER_NAME}.yaml"; }
tenant_yaml_name() { echo "${CLUSTER_NAME}-${TENANT_NAME}.yaml"; }

# ---------------------------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------------------------
# Prefiere aws v2 (en bash puede haber una v1 antes en el PATH). AWS_BIN preexistente se respeta (tests).
pick_aws_bin() {
  local p first=""
  if [[ -n "${AWS_BIN:-}" ]]; then return 0; fi
  while IFS= read -r p; do
    [[ -n "$first" ]] || first="$p"
    if "$p" --version 2>&1 | grep -q '^aws-cli/2'; then AWS_BIN="$p"; export AWS_BIN; return 0; fi
  done < <(type -ap aws 2>/dev/null)
  [[ -n "$first" ]] || die "no se encuentra el binario aws"
  AWS_BIN="$first"; export AWS_BIN
}
AWS_BIN="${AWS_BIN:-}"
KIT_READONLY="${KIT_READONLY:-0}"

# awsr: lectura. awsw: escritura (aborta si KIT_READONLY=1: red de seguridad del subcomando plan/status/check).
awsr() { [[ -n "$AWS_BIN" ]] || pick_aws_bin; AWS_PAGER="" "$AWS_BIN" --profile "$KIT_AWS_PROFILE" --region "$AWS_REGION" "$@"; }
awsw() {
  [[ "$KIT_READONLY" != 1 ]] || die "operacion de ESCRITURA bloqueada en modo solo lectura: aws $1 $2"
  awsr "$@"
}

# Aborta si la cuenta del perfil no es AWS_ACCOUNT_ID.
assert_account() {
  local id acct
  id="$(awsr sts get-caller-identity --output json 2>/dev/null)" \
    || die "sts get-caller-identity fallo con el perfil $KIT_AWS_PROFILE (credenciales caducadas o perfil inexistente)"
  acct="$(jq -r '.Account' <<<"$id")"
  [[ "$acct" == "$AWS_ACCOUNT_ID" ]] \
    || die "cuenta incorrecta: el perfil $KIT_AWS_PROFILE opera en $acct y se esperaba $AWS_ACCOUNT_ID. Abortado sin tocar nada."
}

# ---------------------------------------------------------------------------------------------
# YAML / plantillas
# ---------------------------------------------------------------------------------------------
# YAML (multi-documento) -> array JSON. Soporta yq de kislyuk (python, sintaxis jq) y mikefarah v4.
yaml2json() {  # yaml2json FICHERO
  need_tools yq jq
  if yq --version 2>&1 | grep -qi 'mikefarah\|version v\?4'; then
    yq -o=json '.' "$1" | jq -s '.'
  else
    yq '.' "$1" | jq -s '.'
  fi
}

# Preprocesador de condicionales de linea: #%if NOMBRE / #%if !NOMBRE / #%else / #%end (anidable).
# NOMBRE es verdadero si la variable de entorno vale exactamente "true".
preprocess_tpl() {  # preprocess_tpl PLANTILLA > salida
  awk '
    function active(   i) { for (i = 1; i <= depth; i++) if (!cond[i]) return 0; return 1 }
    /^[ \t]*#%if[ \t]/ {
      n = $2; neg = 0
      if (substr(n, 1, 1) == "!") { neg = 1; n = substr(n, 2) }
      v = (ENVIRON[n] == "true"); if (neg) v = !v
      depth++; cond[depth] = v; next
    }
    /^[ \t]*#%else[ \t]*$/ { if (depth < 1) { print "ERROR: #%else sin #%if" > "/dev/stderr"; exit 2 } cond[depth] = !cond[depth]; next }
    /^[ \t]*#%end[ \t]*$/  { if (depth < 1) { print "ERROR: #%end sin #%if" > "/dev/stderr"; exit 2 } depth--; next }
    { if (active()) print }
    END { if (depth != 0) { print "ERROR: #%if sin cerrar" > "/dev/stderr"; exit 2 } }
  ' "$1"
}

# Placeholders CCT legitimos que NO son variables del kit (los resuelve Command Center en el cluster).
CCT_PLACEHOLDERS_RE='\$\{(tenantId|external_domain)\}'

# Comprueba que no quede ninguna ${...} sin resolver (salvo placeholders CCT). No imprime el contenido de lineas
# con claves; solo numero de linea.
assert_no_residual() {  # assert_no_residual FICHERO ORIGEN
  local f="$1" what="$2" lines
  lines="$(sed -E "s/$CCT_PLACEHOLDERS_RE//g" "$f" | grep -n '\${' | cut -d: -f1 | tr '\n' ' ' || true)"
  [[ -z "${lines// /}" ]] || die "quedan variables \${...} sin resolver en $what (lineas: $lines)"
}

# render_tpl PLANTILLA SALIDA 'LISTA ${VAR}...' [MODO]
# preprocesa (#%if), sustituye SOLO las variables listadas, aborta si queda ${ sin resolver.
render_tpl() {
  local tpl="$1" out="$2" vars="$3" mode="${4:-644}" tmp
  [[ -f "$tpl" ]] || die "no existe la plantilla $tpl"
  need_tools envsubst awk
  tmp="$(umask 077; mktemp "${out}.XXXXXX")"
  if ! preprocess_tpl "$tpl" | envsubst "$vars" > "$tmp"; then rm -f "$tmp"; die "fallo al preprocesar $tpl"; fi
  assert_no_residual "$tmp" "$tpl" || { rm -f "$tmp"; exit 1; }
  chmod "$mode" "$tmp"
  mv "$tmp" "$out"
}

# ---------------------------------------------------------------------------------------------
# ENVIRONMENT_SIZE=CUSTOM: overlay de recursos por app (templates/sizes-custom.env o CUSTOM_SIZES_FILE)
# ---------------------------------------------------------------------------------------------
# apps-layer-automation (branch-15.1-0.1) solo carga apps/<app>/sizes/S|PIT; con otro valor no carga nada y envsubst deja VACIAS las variables de recursos que
# falten (no valida). Por eso el kit inyecta las variables en el `env:` de cada app y comprueba aqui que no falta ninguna.
CUSTOM_COMMON_VARS="CPU_REQUESTS CPU_LIMITS MEMORY_REQUESTS MEMORY_LIMITS"
CUSTOM_REQ_ONLY_VARS="CPU_REQUESTS CPU_LIMITS MEMORY_REQUESTS"     # plantillas que NO consumen MEMORY_LIMITS (discovery, intelligence, rocket*)
CUSTOM_ROCKET_VARS="DEBUG_CPU_REQUESTS DEBUG_CPU_LIMITS DEBUG_MEMORY_REQUESTS CATALOG_CPU_REQUESTS CATALOG_CPU_LIMITS CATALOG_MEMORY_REQUESTS
  VALIDATOR_CPU_REQUESTS VALIDATOR_CPU_LIMITS VALIDATOR_MEMORY_REQUESTS EXTERNAL_SERVICES_CPU_REQUESTS EXTERNAL_SERVICES_CPU_LIMITS EXTERNAL_SERVICES_MEMORY_REQUESTS"

# custom_required_vars APP -> imprime (en una linea) las variables de recursos que consume apps/<app>/<app>.json.tmpl de branch-15.1-0.1 (lista CERRADA:
# se obtuvo con grep de CPU|MEMORY|SHARED_BUFFERS|MAINTENANCE_WORK_MEM en cada plantilla). Linea vacia = la app no consume ninguna (virtualizer, pit).
# Devuelve 1 si la app no esta en la lista: al anadir una app a las plantillas del kit hay que anadirla aqui (y a templates/sizes-custom.env).
custom_required_vars() {
  case "$1" in
    virtualizer|pit) echo "" ;;
    discovery|intelligence|rocket-catalog-standalone) echo "$CUSTOM_REQ_ONLY_VARS" ;;
    rocket) echo "$CUSTOM_REQ_ONLY_VARS $CUSTOM_ROCKET_VARS" | tr -s ' \n' ' ' | sed 's/ $//' ;;
    postgres) echo "$CUSTOM_COMMON_VARS SHARED_BUFFERS MAINTENANCE_WORK_MEM" ;;
    dg-businessglossary-api|dg-ontology-graph-api|dg-discovery-manager|governance-map|governance-ui|opensearch|opensearch-agent|se-searcher|se-manager|se-indexer|\
    dg-scheduler-agent|dg-datamarket-api|governance-datamarket-ui|kafka|connectors-management|postgres-agent|pgbouncer|opensearch-dashboards|genai-litellm|genai-api|\
    genai-ui|eureka-agent|connector-s3|connector-rdbms-postgres-internal|dlc-entity|virtualizer-monitor|virtualizer-ui|datamarket-agent|dg-datarest-pgi)
      echo "$CUSTOM_COMMON_VARS" ;;
    *) return 1 ;;
  esac
}

# load_custom_sizes FICHERO SALIDA_TSV: parsea el overlay INI ([app] / VARIABLE=valor), lo valida contra custom_required_vars y escribe app<TAB>VAR<TAB>valor
# (en el orden del fichero). Aborta con fichero:linea si la sintaxis es mala, la app no esta en la lista, la variable no la consume la app o el valor es vacio/repetido.
load_custom_sizes() {
  local f="$1" out="$2" line app="" var val allowed
  need_tools awk
  awk -v F="$f" '
    function fail(m) { printf "%s:%d: %s\n", F, NR, m > "/dev/stderr"; bad = 1; exit 1 }
    { sub(/\r$/, "") }
    /^[ \t]*(#.*)?$/ { next }
    /^\[[a-z0-9][a-z0-9-]*\][ \t]*$/ { gsub(/[\[\] \t]/, ""); app = $0; if (app in seen) fail("seccion [" app "] repetida"); seen[app] = 1; next }
    /^[A-Z][A-Z0-9_]*=[A-Za-z0-9._+-]+[ \t]*$/ {
      if (app == "") fail("variable fuera de una seccion [app]")
      gsub(/[ \t]+$/, ""); k = $0; sub(/=.*/, "", k); v = $0; sub(/^[^=]*=/, "", v)
      if ((app SUBSEP k) in vars) fail(k " repetida en [" app "]")
      vars[app SUBSEP k] = 1; printf "%s\t%s\t%s\n", app, k, v; next }
    { fail("linea no valida (formato: [app] o VARIABLE=valor; valor [A-Za-z0-9._+-]+, sin comillas ni comentarios tras el valor)") }
  ' "$f" > "$out" || die "overlay de recursos CUSTOM invalido (ver arriba): $f"
  while IFS=$'\t' read -r app var val; do
    allowed="$(custom_required_vars "$app")" || die "overlay CUSTOM $f: la app '$app' no esta en la lista del kit (scripts/lib.sh, custom_required_vars)"
    [[ " $allowed " == *" $var "* ]] || die "overlay CUSTOM $f: la plantilla de '$app' no consume $var (variables validas: ${allowed:-ninguna}); p. ej. discovery, intelligence y rocket ignoran MEMORY_LIMITS"
  done < "$out"
}

# inject_custom_sizes FICHERO_YAML TSV: anade, como entradas de `env:` (valores entre comillas simples) justo despues del nombre de cada app `    - name: <app>`
# del YAML renderizado, las variables de ese app del TSV (si la app no tiene `env:` lo crea). Edita el fichero in situ conservando su modo. Solo se llama con CUSTOM.
inject_custom_sizes() {
  local f="$1" tsv="$2" tmp
  [[ -s "$tsv" ]] || return 0     # (con el TSV vacio awk leeria el YAML como si fuera el TSV)
  tmp="$(umask 077; mktemp "${f}.XXXXXX")"
  awk -F'\t' '
    function emit(   i) { for (i = 1; i <= n[app]; i++) printf "        %s: %c%s%c\n", vn[app, i], 39, vv[app, i], 39; pend = 0 }
    NR == FNR { n[$1]++; vn[$1, n[$1]] = $2; vv[$1, n[$1]] = $3; next }
    pend {
      if ($0 ~ /^      env:[ \t]*$/) { print; emit(); next }
      print "      env:"; emit()
    }
    { print }
    /^    - name: [A-Za-z0-9-]+[ \t]*$/ { app = $0; sub(/^    - name: /, "", app); sub(/[ \t]+$/, "", app); if (n[app] > 0) pend = 1 }
    END { if (pend) { print "      env:"; emit() } }
  ' "$tsv" "$f" > "$tmp" || { rm -f "$tmp"; die "fallo al inyectar los recursos CUSTOM en $f"; }
  chmod --reference="$f" "$tmp"; mv "$tmp" "$f"
}

# custom_sizes_missing JSON_DEL_YAML -> imprime una linea "app<TAB>variable" por cada variable de recursos ausente o vacia en alguna instancia de app del YAML
# (JSON = salida de yaml2json); "app<TAB>*" si la app no esta en la lista cerrada. Sin salida = completo.
custom_sizes_missing() {
  local json="$1" a req_json='{}' vars
  while IFS= read -r a; do
    if vars="$(custom_required_vars "$a")"; then
      req_json="$(jq -c --arg a "$a" --arg v "$vars" '. + {($a): ($v | split(" ") | map(select(. != "")))}' <<<"$req_json")"
    fi
  done < <(jq -r '[.[0].tenants[]?.apps[]? | (.parallel[]? // .) | select(type == "object" and has("name")) | .name] | unique[]' <<<"$json")
  jq -r --argjson req "$req_json" '
    .[0].tenants[]?.apps[]? | (.parallel[]? // .) | select(type == "object" and has("name")) | . as $a
    | ($req[$a.name]) as $r
    | if $r == null then "\($a.name)\t*"
      else $r[] | . as $v | (($a.env // {})[$v]) as $x | select($x == null or ($x | tostring) == "") | "\($a.name)\t\($v)" end' <<<"$json" | sort -u
}

# assert_custom_sizes JSON ETIQUETA: aborta (nombrando app y variable) si custom_sizes_missing no esta vacio.
assert_custom_sizes() {
  local json="$1" what="$2" miss
  miss="$(custom_sizes_missing "$json")"
  [[ -z "$miss" ]] || die "ENVIRONMENT_SIZE=CUSTOM: en $what faltan variables de recursos (envsubst las dejaria vacias en el JSON de la app y el despliegue fallaria):
$(awk -F'\t' '{ if ($2 == "*") printf "  - app %s: no esta en la lista cerrada del kit (scripts/lib.sh, custom_required_vars)\n", $1; else printf "  - app %s: falta %s\n", $1, $2 }' <<<"$miss")
  Completa el overlay: $CUSTOM_SIZES_FILE"
}

# ---------------------------------------------------------------------------------------------
# .env (secretos): nunca se imprimen valores
# ---------------------------------------------------------------------------------------------
SECRET_ENV_NAMES=(LLM_TOKEN S3_BUCKET_ACCESS_KEY S3_BUCKET_SECRET_KEY BACKUPS_S3_BUCKET_ACCESS_KEY BACKUPS_S3_BUCKET_SECRET_KEY)

# env_line_re NOMBRE -> regex de linea de asignacion en un .env
env_line_re() { printf '^[[:space:]]*(export[[:space:]]+)?%s=' "$1"; }

# env_has_var FICHERO NOMBRE -> 0 si hay una asignacion NO vacia (solo comprueba, no imprime)
env_has_var() {
  [[ -f "$1" ]] || return 1
  local line; line="$(grep -E "$(env_line_re "$2")" "$1" | tail -1 || true)"
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  [[ -n "$line" && "$line" != '""' && "$line" != "''" ]]
}

# env_get_var FICHERO NOMBRE -> imprime el valor (USAR SOLO capturando en variable, nunca a pantalla/log)
env_get_var() {
  [[ -f "$1" ]] || return 1
  local line v; line="$(grep -E "$(env_line_re "$2")" "$1" | tail -1 || true)"
  [[ -n "$line" ]] || return 1
  v="${line#*=}"
  if [[ "$v" == \'*\' && ${#v} -ge 2 ]]; then
    v="${v:1:${#v}-2}"; v="${v//\'\\\'\'/\'}"
  elif [[ "$v" == \"*\" && ${#v} -ge 2 ]]; then
    v="${v:1:${#v}-2}"; v="${v//\\\"/\"}"; v="${v//\\\$/\$}"; v="${v//\\\`/\`}"; v="${v//\\\\/\\}"
  fi
  printf '%s' "$v"
}

# env_replace FICHERO NOMBRE  < linea completa por stdin
# Quita las lineas previas de NOMBRE y anade la nueva (idempotente, sin duplicados). chmod 600.
env_replace() {
  local f="$1" name="$2" tmp
  tmp="$(umask 077; mktemp "${f}.XXXXXX")"
  if [[ -f "$f" ]]; then grep -vE "$(env_line_re "$name")" "$f" > "$tmp" || true; fi
  cat >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$f"; chmod 600 "$f"
}

# env_remove FICHERO NOMBRE
env_remove() {
  [[ -f "$1" ]] || return 0
  local tmp; tmp="$(umask 077; mktemp "${1}.XXXXXX")"
  grep -vE "$(env_line_re "$2")" "$1" > "$tmp" || true
  chmod 600 "$tmp"; mv "$tmp" "$1"; chmod 600 "$1"
}

# Escribe 'export NOMBRE='valor'' (comillas simples escapadas) por stdout. Valor por argumento interno (printf es
# builtin: no aparece en ps).
emit_export() {  # emit_export NOMBRE VALOR
  local v="$2"; v="${v//\'/\'\\\'\'}"
  printf "export %s='%s'\n" "$1" "$v"
}

# ---------------------------------------------------------------------------------------------
# Interaccion
# ---------------------------------------------------------------------------------------------
# Exige terminal interactiva (stdin) salvo KIT_TEST_ALLOW_NOTTY=1 (SOLO para las pruebas offline).
require_tty() {
  if [[ ! -t 0 && "${KIT_TEST_ALLOW_NOTTY:-0}" != 1 ]]; then
    die "esta operacion exige una terminal interactiva (confirmacion manual). Ejecutala tu desde tu terminal."
  fi
}

# confirm_typed 'texto esperado' 'pregunta' -> 0 si la persona lo escribe exactamente
confirm_typed() {
  local expected="$1" prompt="$2" a
  read -r -p "$prompt " a || return 1
  [[ "$a" == "$expected" ]]
}

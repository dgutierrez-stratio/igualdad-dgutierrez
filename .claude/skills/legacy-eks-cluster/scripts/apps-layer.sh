#!/usr/bin/env bash
# apps-layer.sh — paso 14 de la skill: apps-layer-automation DESPUÉS de `keos install`. Envoltorio fino del
# 2-apps-layer-kit (no lo copia: lo parametriza desde <dir>/cluster.env para no divergir de él).
#
# Usage: apps-layer.sh [--dir DIR] [--kit DIR] [--apps-layer-dir RUTA] <subcomando> [args...]
#   env                    variables efectivas que se pasan al kit (sin secretos) y avisos
#   prereqs                SOLO LECTURA: keos install terminado (tenant keos Active, cct-orchestrator Running, NLB), sts, docker,
#                          qa.int.stratio.com, gh autenticado con acceso a Stratio/kubernetes-universe, herramientas
#   plan                   prereqs + `s3-requisites.sh plan` + `render-apps-layer.sh --dry-run` (no escribe nada, ni AWS ni disco)
#   s3 plan|status|env     requisitos S3 (stack CloudFormation <cluster>-requisites): `env` escribe las claves SOLO en el .env (600, sin imprimirlas)
#   s3 backups-info        SOLO LECTURA, sin secretos: bucket de backups OPCIONAL (ENABLE_BACKUPS_BUCKET=true en cluster.env; defecto false): nombre, región,
#                          usuario IAM, ARN del secreto y el comando get-secret-value (no se ejecuta). Es para migrar a GitOps; apps-layer no lo usa
#   s3 apply --apply       CREA stack+bucket+usuario IAM+access key (sin --apply se queda en `plan`; exige terminal y escribir el clúster). Con
#                          ENABLE_BACKUPS_BUCKET=true sobre un stack existente es una ACTUALIZACIÓN que solo AÑADE el bucket de backups (+usuario, clave, secreto)
#   token [yaml]           import-llm-token.sh: LLM_TOKEN al .env sin leerlo ni imprimirlo
#   render [--apply]       render-apps-layer.sh; DRY-RUN por defecto, con --apply escribe en el directorio efímero
#   fetch                  fetch-universe.sh: zip del universo + universe-images.lst SIEMPRE frescos (curl + gh)
#   check [--no-aws|--no-cluster]   check-apps-layer.sh (solo lectura; debe acabar en "sin KO")
#   launch                 launch-apps-layer.sh: descarga fresco zip+lst e IMPRIME el docker run. La skill nunca lo ejecuta (--run/--force rechazados)
#   backups-env [--dry-run]  OPCIONAL (paso 14h): backups-env.sh del kit. Escribe SOLO <APPS_LAYER_DIR>/backups.env (600, sin comillas, sin secretos: cuenta, región,
#                          VELERO_BUCKET y VELERO_ROLE de cluster.env) e imprime los avisos de `enviroment-ready --backups/--reporter`. No ejecuta enviroment-ready,
#                          ni docker, ni kubectl, ni aws: eso lo lanza la persona usuaria dentro del contenedor de apps-layer
# El borrado (contenedores, directorio efímero, bucket S3 Retain, bucket de backups con --delete-backups) NO está aquí: teardown.sh fase A (references/teardown.md).
#
# Directorio efímero (700, con secretos): ${TMPDIR:-/tmp}/apps-layer-<cluster>. Una APPS_LAYER_DIR exportada en el shell se IGNORA
# (avisando) para que una variable vieja no mande el .env a otra ruta; para otra ubicación: --apps-layer-dir. El workspace de keos
# (/workspace en el contenedor) es el directorio de trabajo del clúster (<dir>), donde está keos.yaml.
# Variables opcionales de cluster.env: TENANT_NAME ENABLE_GENAI KEOS_PROFILE ENVIRONMENT_SIZE UNIVERSE_VERSION UNIVERSE_BRANCH APPS_LAYER_IMAGE
#   ENABLE_BACKUPS_BUCKET (false) BACKUPS_BUCKET_NAME (<c>-backups-<cuenta>) BACKUPS_USER_NAME (<c>-backups) ...
#   ENVIRONMENT_SIZE acepta S|PIT|CUSTOM (CUSTOM = overlay de recursos del kit; CUSTOM_SIZES_FILE=<ruta absoluta> lo sustituye); VELERO_BUCKET VELERO_ROLE SC_POSTGRES (solo backups-env)
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DIR=""; KIT_ARG=""; AL_DIR_ARG=""; SUB=""; SUBARGS=()
# Variables del bucket de backups que la persona usuaria exportó en SU shell: se reenvían al kit tal cual (cluster.env, que se carga abajo, no las pisa)
FWD_VARS=(); FWD_VALS=()
for v in ENABLE_BACKUPS_BUCKET BACKUPS_BUCKET_NAME BACKUPS_USER_NAME; do if [[ -n "${!v+x}" ]]; then FWD_VARS+=("$v"); FWD_VALS+=("${!v}"); fi; done
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;; --kit) KIT_ARG="$2"; shift 2 ;; --apps-layer-dir) AL_DIR_ARG="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) die "opción desconocida antes del subcomando: $1" ;;
    *) SUB="$1"; shift; SUBARGS=("$@"); break ;;
  esac
done
[[ -n "$SUB" ]] || { sed -n '2,30p' "$0"; exit 1; }
DIR="$(resolve_dir "$DIR")"
load_env "$DIR" CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION CP_PROFILE EXTERNAL_DOMAIN
C="$CLUSTER_NAME"
UNIVERSE_VERSION="${UNIVERSE_VERSION:-15.1.0}"
if [[ -z "${UNIVERSE_BRANCH:-}" && "$UNIVERSE_VERSION" =~ ^([0-9]+)\.([0-9]+) ]]; then UNIVERSE_BRANCH="branch-${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; fi
UNIVERSE_BRANCH="${UNIVERSE_BRANCH:-}"
AL_DEFAULT="$(apps_layer_default_dir "$C")"
KIT=""
KIT="$(find_apps_layer_kit "$KIT_ARG" "$DIR")" || KIT=""

# APPS_LAYER_DIR del entorno: se ignora salvo --apps-layer-dir (gotcha: una variable vieja mandó el .env a la ruta antigua)
if [[ -n "$AL_DIR_ARG" ]]; then AL_EFFECTIVE="$AL_DIR_ARG"
else
  AL_EFFECTIVE="$AL_DEFAULT"
  if [[ -n "${APPS_LAYER_DIR:-}" && "${APPS_LAYER_DIR%/}" != "$AL_DEFAULT" ]]; then
    warn "APPS_LAYER_DIR=$APPS_LAYER_DIR está exportada en tu shell y se IGNORA (se usa $AL_DEFAULT). Hazlo explícito con --apps-layer-dir o: unset APPS_LAYER_DIR"
  fi
fi
[[ "$AL_EFFECTIVE" == /* ]] || die "el directorio de ejecución debe ser una ruta absoluta: $AL_EFFECTIVE"

KUBECFG="$DIR/kubeconfig-${C}"
need_kit() { [[ -n "$KIT" ]] || die "no encuentro el 2-apps-layer-kit (probado: --kit, APPS_LAYER_KIT, <skill>/../../../2-apps-layer-kit, $DIR/2-apps-layer-kit, $DIR/../2-apps-layer-kit). Cópialo junto al workspace o exporta APPS_LAYER_KIT=<ruta>."; }

# Ejecuta un script del kit con las variables del clúster (subshell: no contamina este proceso)
run_kit() {  # run_kit SCRIPT [args...]
  need_kit
  local s="$1"; shift
  (
    export CLUSTER_ENV_FILE="$DIR/cluster.env" KEOS_WORKSPACE_DIR="$DIR" KIT_AWS_PROFILE="$CP_PROFILE" APPS_LAYER_DIR="$AL_EFFECTIVE"
    export UNIVERSE_VERSION
    local i; for i in "${!FWD_VARS[@]}"; do export "${FWD_VARS[$i]}=${FWD_VALS[$i]}"; done
    [[ -z "$UNIVERSE_BRANCH" ]] || export UNIVERSE_BRANCH
    [[ ! -f "$KUBECFG" ]] || export KUBECONFIG_SRC="$KUBECFG"
    [[ -z "${AWS_BIN:-}" ]] || export AWS_BIN
    exec bash "$KIT/scripts/$s" "$@"
  )
}

KO=0
ok()  { okmsg "$*"; }
ko()  { komsg "$*"; KO=$((KO+1)); }
av()  { echo "aviso $*"; }

do_env() {
  echo "cluster=$C cuenta=$AWS_ACCOUNT_ID región=$AWS_REGION dominio=$EXTERNAL_DOMAIN perfil=$CP_PROFILE"
  echo "workspace keos (/workspace)=$DIR"
  echo "directorio efímero (/apps-layer)=$AL_EFFECTIVE   (esperado: $AL_DEFAULT)"
  echo "kit=${KIT:-<no encontrado>}"
  echo "tenant=${TENANT_NAME:-dev} genai=${ENABLE_GENAI:-true} perfil-keos=${KEOS_PROFILE:-full} size=${ENVIRONMENT_SIZE:-S} universo=$UNIVERSE_VERSION rama-lst=${UNIVERSE_BRANCH:-<definir UNIVERSE_BRANCH>}"
  if [[ "${ENVIRONMENT_SIZE:-S}" == CUSTOM ]]; then echo "ENVIRONMENT_SIZE=CUSTOM: overlay de recursos=${CUSTOM_SIZES_FILE:-<templates/sizes-custom.env del kit>} (el render aborta si a una app le falta una variable)"; fi
  echo "imagen=${APPS_LAYER_IMAGE:-qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-SNAPSHOT}"
  echo "bucket de backups (opcional, GitOps)=enabled:${ENABLE_BACKUPS_BUCKET:-false} bucket=${BACKUPS_BUCKET_NAME:-${C}-backups-${AWS_ACCOUNT_ID}} usuario=${BACKUPS_USER_NAME:-${C}-backups}   (kit.env puede cambiarlos)"
  echo "kubeconfig propio=$KUBECFG$([[ -f "$KUBECFG" ]] || echo ' (aún no existe: lo genera prereqs)')"
}

do_prereqs() {
  echo "== apps-layer: prerrequisitos (solo lectura) =="
  if [[ -n "$KIT" ]]; then ok "kit: $KIT"; else ko "no se encuentra el 2-apps-layer-kit (--kit / APPS_LAYER_KIT)"; fi
  local t; for t in aws jq yq envsubst kubectl docker curl unzip sha256sum gh; do command -v "$t" >/dev/null 2>&1 && ok "$t" || ko "falta $t"; done
  # gh: el universe-images.lst fresco sale de Stratio/kubernetes-universe
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      ok "gh autenticado"
      if [[ -n "$UNIVERSE_BRANCH" ]] && GH_PROMPT_DISABLED=1 gh api -H 'Accept: application/vnd.github.raw' "repos/Stratio/kubernetes-universe/contents/universe-images.lst?ref=$UNIVERSE_BRANCH" >/dev/null 2>&1; then
        ok "gh lee Stratio/kubernetes-universe universe-images.lst@$UNIVERSE_BRANCH"
      else ko "gh no puede leer universe-images.lst de Stratio/kubernetes-universe@${UNIVERSE_BRANCH:-<sin rama>}: pide acceso al repo o define UNIVERSE_BRANCH en cluster.env"; fi
    else ko "gh no está autenticado (gh auth login con una cuenta con acceso a Stratio/kubernetes-universe): sin él no se puede descargar universe-images.lst. PARAR."; fi
  fi
  docker info >/dev/null 2>&1 && ok "docker daemon en marcha" || ko "el daemon de docker no responde"
  if getent hosts qa.int.stratio.com >/dev/null 2>&1; then ok "qa.int.stratio.com resuelve (VPN/red interna: imagen y zip del universo)"
  else av "qa.int.stratio.com no resuelve: sin VPN no se podrá descargar el zip ni la imagen de apps-layer"; fi
  local img="${APPS_LAYER_IMAGE:-qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-SNAPSHOT}"
  docker image inspect "$img" >/dev/null 2>&1 && ok "imagen $img ya descargada" || av "imagen $img no descargada (docker pull al lanzar)"
  # contenedores keos-installer en marcha (un keos install sin terminar escribe en el mismo workspace)
  local run; run="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk '$2 ~ /keos-installer/ && $1 !~ /^keos-installer_/ {print $1}' | tr '\n' ' ')"
  [[ -z "${run// /}" ]] && ok "ningún contenedor keos-installer ajeno en marcha" || av "contenedor(es) keos-installer en marcha: ${run}(¿keos install sin terminar? apps-layer lanza su propio keos-installer_$C sobre el mismo workspace)"
  [[ -f "$DIR/keos.yaml" ]] && ok "workspace keos: $DIR/keos.yaml" || ko "no existe $DIR/keos.yaml (paso 12): el workspace de keos-installer es $DIR"
  # AWS + clúster
  set_aws "$CP_PROFILE" "$AWS_REGION"
  local idj acct; idj="$(awsx sts get-caller-identity --output json 2>/dev/null || true)"; [[ -n "$idj" ]] || idj='{}'; acct="$(jq -r '.Account // ""' <<<"$idj")"
  if [[ "$acct" == "$AWS_ACCOUNT_ID" ]]; then ok "sts: el perfil $CP_PROFILE opera en la cuenta $AWS_ACCOUNT_ID"
  else ko "sts: el perfil $CP_PROFILE opera en '${acct:-<sin respuesta>}' y se esperaba $AWS_ACCOUNT_ID"; return 0; fi
  eks_kubeconfig "$DIR" >/dev/null 2>&1 && ok "kubeconfig propio: $KUBECFG" || { ko "no se pudo generar $KUBECFG (¿existe el EKS $C?)"; return 0; }
  local kc=(kubectl --kubeconfig "$KUBECFG") st pods nlb
  st="$("${kc[@]}" get tenant keos -o jsonpath='{.status.state}' 2>/dev/null || true)"
  [[ "$st" == Active ]] && ok "tenant keos Active" || ko "tenant keos no está Active ('${st:-sin respuesta}'): keos install no ha terminado"
  pods="$("${kc[@]}" -n keos-cct get pods --no-headers 2>/dev/null || true)"
  if awk '$1 ~ /^cct-orchestrator/ && $3=="Running" {f=1} END{exit !f}' <<<"$pods"; then ok "cct-orchestrator Running en keos-cct"; else ko "cct-orchestrator no está Running en keos-cct (CCT es lo que usa apps-layer)"; fi
  nlb="$("${kc[@]}" -n keos-ingress get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$nlb" ]]; then
    ok "NLB del ingress: $nlb"
    getent hosts "$nlb" >/dev/null 2>&1 && ok "el NLB resuelve a IP (se usará en --add-host admin.$EXTERNAL_DOMAIN)" || av "el NLB no resuelve desde aquí: fija NLB_IP=<ip> en cluster.env o resuélvela a mano"
  else ko "sin hostname de NLB en keos-ingress/ingress-nginx-controller"; fi
  av "desa.int no está delegado: admin.$EXTERNAL_DOMAIN no resuelve fuera de la VPC (el docker run lleva --add-host con la IP del NLB)"
}

case "$SUB" in
  env) do_env ;;
  prereqs) do_prereqs; echo; [[ $KO -eq 0 ]] && { echo "RESULTADO: OK (sin KO)"; exit 0; } || { echo "RESULTADO: $KO KO"; exit 1; } ;;
  plan)
    do_env; echo; do_prereqs; echo
    echo "== s3-requisites plan (solo lectura) =="; run_kit s3-requisites.sh plan || ko "s3-requisites plan falló"
    echo; echo "== render --dry-run (no escribe nada) =="; run_kit render-apps-layer.sh --dry-run || av "render --dry-run falló (¿falta LLM_TOKEN? scripts: apps-layer.sh token <yaml>)"
    echo; echo "Siguiente (cada uno lo confirma la persona usuaria): s3 apply --apply · s3 env · token <yaml> · render --apply · check · launch"
    [[ $KO -eq 0 ]] || { echo "RESULTADO: $KO KO"; exit 1; }; echo "RESULTADO: plan sin KO (no se ha escrito nada)" ;;
  s3)
    sub="${SUBARGS[0]:-plan}"; rest=("${SUBARGS[@]:1}")
    case "$sub" in
      plan|status|env|backups-info) run_kit s3-requisites.sh "$sub" "${rest[@]}" ;;
      apply)
        if [[ "${rest[*]:-}" == "--apply" ]]; then run_kit s3-requisites.sh apply
        else echo "DRY-RUN: 'apply' crea stack, bucket (Retain), usuario IAM con access key y secreto en la cuenta $AWS_ACCOUNT_ID (con ENABLE_BACKUPS_BUCKET=true, además el bucket de backups, su usuario, clave y secreto). Mostrando el plan; para crear: s3 apply --apply (desde una terminal)."; run_kit s3-requisites.sh plan; fi ;;
      delete) die "el borrado del stack/bucket S3 lo hace teardown.sh (fase A, --delete-s3-requisites; el bucket de backups solo con --delete-backups): dry-run por defecto y con guardas" ;;
      *) die "s3: subcomando desconocido: $sub (plan|status|env|backups-info|apply --apply)" ;;
    esac ;;
  token) run_kit import-llm-token.sh "${SUBARGS[@]}" ;;
  backups-env) run_kit backups-env.sh "${SUBARGS[@]}" ;;
  render)
    apply=0; others=(); for a in "${SUBARGS[@]}"; do if [[ "$a" == --apply ]]; then apply=1; else others+=("$a"); fi; done
    if [[ $apply -eq 1 ]]; then run_kit render-apps-layer.sh "${others[@]}"
    else echo "DRY-RUN (render --dry-run): para escribir en $AL_EFFECTIVE añade --apply"; run_kit render-apps-layer.sh --dry-run "${others[@]}"; fi ;;
  fetch) run_kit fetch-universe.sh "${SUBARGS[@]}" ;;
  check) run_kit check-apps-layer.sh "${SUBARGS[@]}" ;;
  launch)
    for a in "${SUBARGS[@]}"; do case "$a" in --run|--force) die "la skill nunca ejecuta docker run (ni borra contenedores): copia el comando impreso y lánzalo en TU terminal" ;; esac; done
    run_kit launch-apps-layer.sh "${SUBARGS[@]}" ;;
  *) die "subcomando desconocido: $SUB (env|prereqs|plan|s3|token|render|fetch|check|launch|backups-env)" ;;
esac

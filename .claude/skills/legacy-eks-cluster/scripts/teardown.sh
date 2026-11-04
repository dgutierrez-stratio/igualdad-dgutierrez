#!/usr/bin/env bash
# teardown.sh — desinstalación SEGURA de un clúster legacy EKS y de lo que la skill creó a su alrededor.
#
# Usage:
#   teardown.sh [--dir DIR]                         # DRY-RUN (por defecto): lista qué borraría, con IDs. No escribe nada.
#   teardown.sh [--dir DIR] --apply                 # borra de verdad tras confirmación interactiva (nombre + cuenta)
#   teardown.sh --apply --phase 3,4                 # solo ciertas fases (reanudar tras un fallo: se vuelve a lanzar igual)
#   teardown.sh --apply --phase 9 --purge-account-shared --profile <admin>   # recursos de CUENTA compartidos (aparte)
#
# Fases (orden inverso a la creación; cada una hace su comprobación de solo lectura y aborta si algo es ambiguo):
#   A apps-layer   ANTES de borrar el EKS: contenedores apps-layer-<C> y keos-installer_<C>, directorio efímero /tmp/apps-layer-<C>
#                  y requisitos S3 (stack <C>-requisites; el bucket es Retain: solo con --delete-s3-requisites + confirmación)
#   1 in-cluster   Ingress, Services LoadBalancer, workloads y PVC/PV (si no, quedan ELB/ENI/SG/EBS huérfanos)
#   2 cluster      borra el EKS con el mecanismo de cloud-provisioner (clusterctl move -> kind local -> delete cl)
#   3 efs          mount targets -> access points -> file system
#   4 route53      registros (menos NS/SOA del apex) -> zonas privada y pública
#   5 s3           vaciar bucket Velero (objetos, versiones, multipart) -> bucket   (--keep-bucket para conservarlo)
#   6 iam          roles/policies del clúster (+ desadjuntar ${CLUSTER}-efs-csi del rol de nodos), OIDC, log group
#   7 network      NAT, EIP, IGW, subnets, route tables, SG sobrantes, VPC (create-test-vpc.sh --delete)
#   8 local        contenedor kind retenido y ficheros locales (con --delete-local; pregunta por grupos)
#   9 shared       SOLO con --purge-account-shared: pila CloudFormation CAPA, policy ECR, usuario IAM cloud-provisioner (el último)
#   V verify       comprueba que no queda nada con los tags/nombres del clúster (siempre al final)
#
# Opciones: --dir DIR | --apply | --phase LISTA | --profile P | --keep-bucket | --skip-incluster | --method capi|aws-api
#           --accept-zone ID (repetible) | --delete-local | --purge-account-shared
#           --delete-s3-requisites   (fase A) vacía y borra bucket+stack+usuario IAM+secreto S3 de apps-layer (irreversible; por defecto se CONSERVAN)
#           --delete-backups         (fase A, solo junto a --delete-s3-requisites) ADEMÁS vacía y borra el bucket de BACKUPS opcional (ENABLE_BACKUPS_BUCKET) con
#                                    sus versiones: irreversible, exige teclear su nombre. Sin este flag el bucket de backups SE CONSERVA siempre (solo se informa;
#                                    si el stack lo tenía, su usuario IAM/clave/secreto sí se van con el stack al usar --delete-s3-requisites).
# Seguridad: ver references/teardown.md. Resumen:
#   * comprueba sts get-caller-identity == cuenta esperada y aborta si no;
#   * descubrimiento por tags / nombres derivados / JSON de la VPC; ambiguo => aborta;
#   * guarda de recursos PROTEGIDOS (denylist + ARN del llamador + role_arn de los perfiles) en CADA borrado;
#   * en dry-run, cualquier operación AWS que no sea de lectura aborta el script (red de seguridad);
#   * no toca ~/.aws ni el perfil/rol con el que se accede a la cuenta.
# Log sin secretos: <dir>/logs/teardown-<fecha>.log. Estado no recuperable tras borrar el EKS: <dir>/logs/teardown-state.env
# Variables solo para pruebas con mocks: TEARDOWN_NO_WAIT=1 (no esperar), TEARDOWN_ALLOW_NONTTY=1 (confirmaciones por stdin).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DIR=""; APPLY=0; PHASES=""; PROFILE_OVR=""; KEEP_BUCKET=0; SKIP_INCLUSTER=0; METHOD=capi; ACCEPT_ZONES=(); DELETE_LOCAL=0; PURGE=0; DELETE_S3=0; DELETE_BK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;; --apply) APPLY=1; shift ;; --phase) PHASES="$2"; shift 2 ;; --profile) PROFILE_OVR="$2"; shift 2 ;;
    --keep-bucket) KEEP_BUCKET=1; shift ;; --skip-incluster) SKIP_INCLUSTER=1; shift ;; --method) METHOD="$2"; shift 2 ;;
    --accept-zone) ACCEPT_ZONES+=("$2"); shift 2 ;; --delete-local) DELETE_LOCAL=1; shift ;; --purge-account-shared) PURGE=1; shift ;; --delete-s3-requisites) DELETE_S3=1; shift ;; --delete-backups) DELETE_BK=1; shift ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;;
  esac
done
[[ "$METHOD" == capi || "$METHOD" == aws-api ]] || die "--method debe ser capi o aws-api"
DIR="$(resolve_dir "$DIR")"; need_tools aws jq
load_env "$DIR" CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION CP_PROFILE EXTERNAL_DOMAIN VELERO_BUCKET VELERO_ROLE
ADMIN_PROFILE="${ADMIN_PROFILE:-}"; ECR_POLICY_NAME="${ECR_POLICY_NAME:-ecr-pull-through-cache-machinepool}"
C="$CLUSTER_NAME"; ACCT="$AWS_ACCOUNT_ID"
MODE="DRY-RUN"; [[ $APPLY -eq 1 ]] && MODE="APPLY"
mkdir -p "$DIR/logs"; LOG="$DIR/logs/teardown-$(date +%Y%m%d-%H%M%S).log"; STATE="$DIR/logs/teardown-state.env"
CAPA_STACK=cluster-api-provider-aws-sigs-k8s-io
NODE_ROLE=eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io
KIND_CTR="${C}-control-plane"
# apps-layer (2-apps-layer-kit): nombres por defecto del kit; se pueden fijar en cluster.env (S3_BUCKET_NAME, S3_USER_NAME, STACK_NAME)
S3_STACK="${STACK_NAME:-${C}-requisites}"; S3_BUCKET="${S3_BUCKET_NAME:-${C}-internal-${ACCT}}"; S3_USER="${S3_USER_NAME:-${C}-s3}"
# bucket de backups OPCIONAL del mismo stack (kit: ENABLE_BACKUPS_BUCKET, BACKUPS_BUCKET_NAME, BACKUPS_USER_NAME): por defecto SE CONSERVA
BK_BUCKET="${BACKUPS_BUCKET_NAME:-${C}-backups-${ACCT}}"; BK_USER="${BACKUPS_USER_NAME:-${C}-backups}"; BK_ANY=0; BK_BACKUPS_BUCKET_EXISTS=0
AL_CTR="apps-layer-${C}"; AL_KEOS_CTR="keos-installer_${C}"
PLANNED=0; DONE_OPS=0

# Fases a ejecutar
if [[ -z "$PHASES" ]]; then PHASES="A,1,2,3,4,5,6,7,8"; [[ $PURGE -eq 1 ]] && PHASES="$PHASES,9"; fi
PHASES="$PHASES,V"
has_phase() { [[ ",$PHASES," == *",$1,"* ]]; }
if [[ $DELETE_S3 -eq 1 ]] && ! has_phase A; then die "--delete-s3-requisites pertenece a la fase A (apps-layer): inclúyela en --phase"; fi
if [[ $DELETE_BK -eq 1 && $DELETE_S3 -ne 1 ]]; then die "--delete-backups solo se admite junto a --delete-s3-requisites (el bucket de backups es un recurso del stack ${S3_STACK}); sin él se conserva"; fi
if has_phase 9 && [[ $PURGE -ne 1 ]]; then die "la fase 9 (recursos de cuenta compartidos) exige --purge-account-shared"; fi

logl() { echo "$(date -u +%FT%TZ) [$MODE] $*" >> "$LOG"; }
say()  { echo "$*"; logl "$*"; }
hdr()  { echo; echo "=== $* ==="; logl "=== $* ==="; }

# ---------------------------------------------------------------------------------------------------------------
# Perfil / cuenta
# ---------------------------------------------------------------------------------------------------------------
PROFILE="${PROFILE_OVR:-$CP_PROFILE}"
if has_phase 9 && [[ -z "$PROFILE_OVR" ]]; then PROFILE="${ADMIN_PROFILE:?la fase 9 debe ejecutarse con el perfil de administración (--profile) para no borrar la identidad del llamador}"; fi
case "$PROFILE" in "$CP_PROFILE"|"$ADMIN_PROFILE"|cloud-provisioner|igualdad) : ;; *) [[ -n "$PROFILE_OVR" ]] && warn "perfil no habitual: $PROFILE" ;; esac
set_aws "$PROFILE" "$AWS_REGION"

# Red de seguridad: en dry-run solo se permiten operaciones de lectura
_RO_RE='^(describe|list|get|head|batch-get|lookup|search|update-kubeconfig)'
awsx() {
  local op="${2:-}"
  if [[ $APPLY -ne 1 && ! "$op" =~ $_RO_RE ]]; then die "BUG: operación de escritura '$1 $op' en dry-run (abortado)"; fi
  AWS_PAGER="" "$AWS_BIN" --profile "$_AWS_PROFILE" --region "$_AWS_REGION" "$@"
}
awsr() { local r="$1"; shift; local save="$_AWS_REGION"; _AWS_REGION="$r"; awsx "$@"; local rc=$?; _AWS_REGION="$save"; return $rc; }
kc() {  # kubectl contra el EKS del clúster; dry-run: solo lectura
  local verb=""; for a in "$@"; do case "$a" in get|config|version|api-resources|auth) verb="$a"; break ;; delete|scale|patch|apply|annotate|label|edit|drain|cordon|create|replace) verb="$a"; break ;; esac; done
  if [[ $APPLY -ne 1 && "$verb" != get && "$verb" != config && "$verb" != version && "$verb" != api-resources && "$verb" != auth ]]; then die "BUG: kubectl '$verb' en dry-run"; fi
  kubectl --kubeconfig "$KUBECFG" "$@"
}
dk() {  # docker: dry-run solo lectura
  local v="${1:-}"
  if [[ $APPLY -ne 1 && ! "$v" =~ ^(ps|inspect|info|version|image|images)$ ]]; then die "BUG: docker '$v' en dry-run"; fi
  docker "$@"
}

hdr "teardown $C — cuenta $ACCT región $AWS_REGION perfil $PROFILE [$MODE]"
assert_account "$ACCT"
echo "llamador: $CALLER_ARN"; logl "llamador $CALLER_ARN"

# ---------------------------------------------------------------------------------------------------------------
# GUARDA de recursos protegidos
# ---------------------------------------------------------------------------------------------------------------
PROT_NAMES=(OrganizationAccountAccessRole)
PROT_ARNS=("$CALLER_ARN" "$(caller_base_arn "$CALLER_ARN")")
if [[ "$CALLER_ARN" =~ :user/(.+)$ ]]; then PROT_NAMES+=("${BASH_REMATCH[1]##*/}"); fi
if [[ "$CALLER_ARN" =~ :assumed-role/([^/]+)/ ]]; then PROT_NAMES+=("${BASH_REMATCH[1]}"); fi
# role_arn de los perfiles implicados (solo `aws configure get`, nunca ~/.aws/credentials)
for p in "$PROFILE" "$CP_PROFILE" "$ADMIN_PROFILE" igualdad; do
  [[ -n "$p" ]] || continue
  ra="$("${AWS_GET_BIN:-$(type -ap aws | head -1)}" configure get role_arn --profile "$p" 2>/dev/null || true)"
  if [[ -n "$ra" ]]; then PROT_ARNS+=("$ra"); PROT_NAMES+=("${ra##*/}"); fi
done
if [[ -n "${PROTECTED_IAM_NAMES:-}" ]]; then for n in $PROTECTED_IAM_NAMES; do PROT_NAMES+=("$n"); done; fi
if [[ -n "${PROTECTED_ARNS:-}" ]]; then for n in $PROTECTED_ARNS; do PROT_ARNS+=("$n"); done; fi

guard() {  # guard <identificador>: aborta si coincide con algo protegido
  local t="$1" n a
  [[ -n "$t" ]] || die "guard: identificador vacío"
  for n in "${PROT_NAMES[@]}"; do [[ -n "$n" && ( "$t" == "$n" || "$t" == */"$n" ) ]] && die "GUARDA: '$t' es un recurso/identidad PROTEGIDO ($n). Abortado sin borrar nada más."; done
  for a in "${PROT_ARNS[@]}"; do [[ -n "$a" && "$t" == "$a" ]] && die "GUARDA: '$t' coincide con el ARN protegido $a (identidad del llamador o rol de acceso). Abortado."; done
  [[ "$t" =~ ^AWSServiceRole || "$t" =~ ^AWSReservedSSO_ || "$t" == *aws-service-role/* ]] && die "GUARDA: '$t' es un rol gestionado por AWS/SSO. Abortado."
  return 0
}

# Pre-chequeo estático: todos los nombres IAM que este script podría borrar contra la guarda, antes de tocar nada
STATIC_TARGETS=("${C}-external-dns" "$VELERO_ROLE" "${C}-iam-service-role" "${C}-velero" "${C}-efs-csi")
has_phase 9 && STATIC_TARGETS+=(cloud-provisioner "$ECR_POLICY_NAME")
[[ $DELETE_S3 -eq 1 ]] && STATIC_TARGETS+=("$S3_USER" "$BK_USER")
# el usuario IAM de backups jamás puede ser el usuario cloud-provisioner, el perfil igualdad ni los perfiles del clúster (el kit lo valida igual al activarlo)
if [[ $DELETE_S3 -eq 1 ]]; then
  case "$BK_USER" in cloud-provisioner|igualdad|"$CP_PROFILE"|"${ADMIN_PROFILE:-__sin_perfil_admin__}") die "GUARDA: BACKUPS_USER_NAME '$BK_USER' es una identidad PROTEGIDA (usuario cloud-provisioner o perfil igualdad/del clúster). Abortado sin borrar nada." ;; esac
fi
for t in "${STATIC_TARGETS[@]}"; do guard "$t"; done
echo "guarda: ${#STATIC_TARGETS[@]} nombres IAM planificados comprobados contra ${#PROT_NAMES[@]} nombres y ${#PROT_ARNS[@]} ARN protegidos: OK"

# del <descripción> <identificador-objetivo> <args aws...>: guarda + (dry-run | ejecución) + tolerancia a "ya no existe"
del() {
  local desc="$1" target="$2"; shift 2
  guard "$target"
  PLANNED=$((PLANNED+1))
  if [[ $APPLY -ne 1 ]]; then echo "[DRY-RUN] borraría: $desc"; logl "planificado: $desc"; return 0; fi
  echo "[APPLY]   $desc"; logl "ejecutando: $desc"
  local out
  if ! out="$(awsx "$@" 2>&1)"; then
    if grep -qiE 'NoSuchEntity|NotFound|does not exist|NoSuchBucket|NoSuchHostedZone|FileSystemNotFound|ResourceNotFoundException|InvalidAllocationID|MountTargetNotFound|AccessPointNotFound|ValidationError.*does not exist' <<<"$out"; then
      echo "          (ya no existe: se continúa)"; logl "ya no existe: $desc"
    else
      logl "FALLO: $desc"; die "falló: $desc"$'\n'"$(echo "$out" | head -5)"$'\n'"Revisa la causa y vuelve a lanzar: el script es reanudable."
    fi
  fi
  DONE_OPS=$((DONE_OPS+1)); logl "hecho: $desc"
}

wait_for() {  # wait_for "<descripción>" <segundos> <función-que-devuelve-0-cuando-listo>
  local d="$1" max="$2" f="$3" t=0
  [[ $APPLY -eq 1 && -z "${TEARDOWN_NO_WAIT:-}" ]] || return 0
  echo -n "          esperando: $d "
  until "$f"; do (( t >= max )) && { echo; die "timeout (${max}s) esperando: $d. Comprueba el estado y vuelve a lanzar."; }; echo -n "."; sleep 15; t=$((t+15)); done; echo " ok"
}

confirm_typed() {  # confirm_typed "texto" "esperado"
  if [[ ! -t 0 && -z "${TEARDOWN_ALLOW_NONTTY:-}" ]]; then die "las confirmaciones exigen una terminal interactiva"; fi
  local a; read -r -p "$1" a || die "sin respuesta"
  [[ "$a" == "$2" ]] || die "confirmación incorrecta: se esperaba '$2'. Abortado sin borrar nada."
}
confirm_step() { # confirm_step "pregunta" (solo apply)
  [[ $APPLY -eq 1 ]] || return 0
  if [[ ! -t 0 && -z "${TEARDOWN_ALLOW_NONTTY:-}" ]]; then die "se requiere terminal interactiva"; fi
  confirm_yes "$1" || die "cancelado por la persona usuaria"
}

# ---------------------------------------------------------------------------------------------------------------
# Estado persistente (sin secretos) para poder reanudar cuando el EKS ya no existe
# ---------------------------------------------------------------------------------------------------------------
[[ -f "$STATE" ]] && source "$STATE"
save_state() { local k="$1" v="$2"; [[ -n "$v" ]] || return 0; [[ $APPLY -eq 1 ]] || return 0
  grep -q "^${k}=" "$STATE" 2>/dev/null || printf '%s=%q\n' "$k" "$v" >> "$STATE"; }
VPC_ID="${VPC_ID_S:-}"; OIDC_ISSUER="${OIDC_ISSUER_S:-}"; EFS_ID="${EFS_ID_S:-}"; EKS_EXISTS=0

# ---------------------------------------------------------------------------------------------------------------
# Fase 0: descubrimiento
# ---------------------------------------------------------------------------------------------------------------
hdr "Fase 0 — descubrimiento por pertenencia al clúster"
EKSJ="$(awsx eks describe-cluster --name "$C" --output json 2>/dev/null || true)"
if [[ -n "$EKSJ" ]] && jq -e '.cluster' <<<"$EKSJ" >/dev/null 2>&1; then
  EKS_EXISTS=1
  tag_ok="$(jq -r --arg c "$C" '.cluster.tags["kubernetes.io/cluster/"+$c] // .cluster.tags["sigs.k8s.io/cluster-api-provider-aws/cluster/"+$c] // ""' <<<"$EKSJ")"
  [[ -n "$tag_ok" ]] || die "el EKS $C existe pero NO lleva los tags de pertenencia (kubernetes.io/cluster/$C): no es el clúster de este directorio. Abortado."
  EKS_VPC="$(jq -r '.cluster.resourcesVpcConfig.vpcId' <<<"$EKSJ")"
  EKS_OIDC="$(jq -r '.cluster.identity.oidc.issuer // ""' <<<"$EKSJ" | sed 's#^https://##')"
  EKS_STATUS="$(jq -r '.cluster.status' <<<"$EKSJ")"
  say "EKS $C: $EKS_STATUS vpc=$EKS_VPC oidc=${EKS_OIDC##*/}"
  VPC_ID="${VPC_ID:-$EKS_VPC}"; OIDC_ISSUER="${OIDC_ISSUER:-$EKS_OIDC}"
  [[ "$VPC_ID" == "$EKS_VPC" ]] || die "la VPC del estado ($VPC_ID) no coincide con la del EKS ($EKS_VPC)"
  NGS="$(awsx eks list-nodegroups --cluster-name "$C" --output json | jq -r '.nodegroups|join(" ")')"
  say "nodegroups (uno por AZ; se descubren, no se asumen): ${NGS:-ninguno}"
else
  say "EKS $C: no existe (ya borrado o nunca creado)"; NGS=""
fi
# VPC: por JSON de create-test-vpc.sh y por tag Name (deben coincidir)
JSON_VPC=""; [[ -f "$DIR/${C}.json" ]] && JSON_VPC="$(jq -r '.vpc_id // ""' "$DIR/${C}.json")"
NAME_VPCS="$(awsx ec2 describe-vpcs --filters "Name=tag:Name,Values=$C" --output json | jq -r '[.Vpcs[]|select(.IsDefault!=true)|.VpcId]|join(" ")')"
if [[ -n "$JSON_VPC" ]]; then
  if [[ -n "$NAME_VPCS" && " $NAME_VPCS " != *" $JSON_VPC "* ]]; then die "${C}.json dice $JSON_VPC pero las VPC con Name=$C son: $NAME_VPCS. Ambiguo: abortado."; fi
  VPC_ID="${VPC_ID:-$JSON_VPC}"; [[ "$VPC_ID" == "$JSON_VPC" ]] || die "VPC del EKS/estado ($VPC_ID) distinta de ${C}.json ($JSON_VPC): abortado"
elif [[ -n "$NAME_VPCS" ]]; then
  [[ $(wc -w <<<"$NAME_VPCS") -eq 1 ]] || die "varias VPC con Name=$C ($NAME_VPCS) y sin ${C}.json: abortado"
  VPC_ID="${VPC_ID:-$NAME_VPCS}"
fi
say "VPC: ${VPC_ID:-ninguna} (JSON=${JSON_VPC:-no} Name=${NAME_VPCS:-no})"
say "OIDC issuer: ${OIDC_ISSUER:-<desconocido>}"
if [[ $EKS_EXISTS -eq 1 || -n "$VPC_ID" ]]; then save_state VPC_ID_S "$VPC_ID"; save_state OIDC_ISSUER_S "$OIDC_ISSUER"; fi

CONFIRMED=0
confirm_all() {
  [[ $APPLY -eq 1 && $CONFIRMED -eq 0 ]] || return 0
  echo
  echo "VAS A BORRAR de forma irreversible los recursos del clúster '$C' en la cuenta $ACCT (fases: $PHASES)."
  confirm_typed "Escribe el nombre del clúster para confirmar: " "$C"
  confirm_typed "Escribe el número de cuenta para confirmar: " "$ACCT"
  CONFIRMED=1
}
confirm_all

KUBECFG=""

# ---------------------------------------------------------------------------------------------------------------
# Fase A: apps-layer-automation (ANTES de borrar el EKS)
# ---------------------------------------------------------------------------------------------------------------
wipe_private_dir() {  # wipe_private_dir RUTA: solo apps-layer-<C> propio; shred de los ficheros (secretos) y rm -rf
  local d="$1"
  [[ "$d" == /* && "$(basename "$d")" == "apps-layer-${C}" ]] || die "guarda: '$d' no es un directorio apps-layer-${C}: no se borra"
  if [[ -L "$d" ]]; then warn "$d es un enlace simbólico: no se sigue ni se borra (bórralo tú tras comprobar adónde apunta)"; return 0; fi
  [[ -d "$d" ]] || { warn "$d no es un directorio: no se toca"; return 0; }
  if [[ ! -O "$d" ]]; then warn "$d pertenece a otro usuario: ejecuta tú:  sudo rm -rf '$d'"; return 0; fi
  PLANNED=$((PLANNED+1))
  say "directorio efímero de apps-layer (secretos: .env, YAML del tenant, kube-config, aws/): $d  [$(ls -A "$d" | tr '\n' ' ')]"
  if [[ $APPLY -ne 1 ]]; then echo "[DRY-RUN] borraría de forma segura (shred + rm -rf) $d"; return 0; fi
  confirm_step "¿Borrar de forma segura $d? (se regenera con apps-layer.sh render; las claves S3 y el LLM_TOKEN habrá que volver a importarlos)"
  logl "borrar directorio efímero $d"
  if command -v shred >/dev/null 2>&1; then find "$d" -xdev -type f -exec shred -u {} + 2>/dev/null || true; fi
  rm -rf "$d" || warn "no se pudo borrar todo $d (¿ficheros de root creados por docker?): ejecuta tú:  sudo rm -rf '$d'"
}
phaseA() {
  hdr "Fase A — apps-layer-automation (contenedores, directorio efímero, requisitos S3)"
  say "(no hay desinstalador completo de las apps de apps-layer: apps, tenant y datos del clúster desaparecen con el EKS; la fase 1 limpia Ingress/LB/PVC antes)"
  # 1) contenedores: SOLO por nombre exacto y con la imagen esperada
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local spec name want ctr img
    for spec in "${AL_CTR}|apps-layer-automation" "${AL_KEOS_CTR}|keos-installer"; do
      name="${spec%%|*}"; want="${spec##*|}"
      ctr="$(dk ps -a --filter "name=^/${name}\$" --format '{{.Names}}')"
      if [[ -z "$ctr" ]]; then say "no hay contenedor $name"; continue; fi
      img="$(dk inspect -f '{{.Config.Image}}' "$name")"
      [[ "$img" == *"$want"* ]] || die "el contenedor $name usa la imagen $img: no parece de $want. Abortado."
      PLANNED=$((PLANNED+1))
      if [[ $APPLY -eq 1 ]]; then
        confirm_step "¿Parar y borrar el contenedor $name ($img)? (un apps-installer en curso se interrumpe; su trap ejecuta helm rollback cct al salir)"
        logl "docker stop/rm $name"
        dk stop -t 30 "$name" >/dev/null 2>&1 || true
        [[ -z "$(dk ps -a --filter "name=^/${name}\$" --format '{{.Names}}')" ]] || dk rm -f "$name" >/dev/null
      else echo "[DRY-RUN] pararía y borraría el contenedor $name ($img)"; fi
    done
    local others; others="$(dk ps --format '{{.Names}} {{.Image}}' | awk -v n="$AL_CTR" '$2 ~ /apps-layer-automation/ && $1 != n {print $1}' | tr '\n' ' ')"
    [[ -z "${others// /}" ]] || warn "hay contenedores de la imagen apps-layer lanzados a mano que NO se tocan por nombre: ${others}: páralos tú (docker stop <nombre>)"
  else say "docker no disponible: se omiten los contenedores apps-layer-${C} y ${AL_KEOS_CTR}"; fi
  # 2) directorio efímero (solo el esperado; una APPS_LAYER_DIR exportada se valida por nombre)
  local d0 d; d0="$(apps_layer_default_dir "$C")"
  local cands=("$d0")
  if [[ -n "${APPS_LAYER_DIR:-}" && "${APPS_LAYER_DIR%/}" != "$d0" ]]; then
    if [[ "$(basename "${APPS_LAYER_DIR%/}")" == "apps-layer-${C}" ]]; then cands+=("${APPS_LAYER_DIR%/}")
    else warn "APPS_LAYER_DIR=$APPS_LAYER_DIR (exportada en tu shell) no se llama apps-layer-${C}: NO se borra; si contiene secretos de apps-layer, revísalo y bórralo a mano"; fi
  fi
  for d in "${cands[@]}"; do
    if [[ -e "$d" || -L "$d" ]]; then wipe_private_dir "$d"; else say "no existe $d (efímero: ya limpio)"; fi
  done
  [[ ! -e "$DIR/apps-layer" ]] || warn "existe $DIR/apps-layer (ubicación ANTIGUA del directorio de ejecución, puede tener .env con claves): revísalo y bórralo tú; la skill no lo toca"
  # 3) requisitos S3 de apps-layer (stack CloudFormation <C>-requisites: bucket Retain + usuario IAM + access key + secreto)
  local sj stack_ok=0 b_ok=0 u_ok=0 sec_ok=0 so
  sj="$(awsx cloudformation describe-stacks --stack-name "$S3_STACK" --output json 2>/dev/null || true)"
  if [[ -n "$sj" ]] && jq -e '.Stacks[0].StackName' <<<"$sj" >/dev/null 2>&1; then
    stack_ok=1
    so="$(jq -r --arg c "$C" --arg b "$S3_BUCKET" '[((.Stacks[0].Tags // [])[]|select(.Key=="cluster" and .Value==$c)|"tag"), ((.Stacks[0].Outputs // [])[]|select(.OutputKey=="InternalS3BucketName" and .OutputValue==$b)|"output")]|first // ""' <<<"$sj")"
    [[ -n "$so" ]] || die "el stack $S3_STACK existe pero no es de este clúster (ni tag cluster=$C ni output InternalS3BucketName=$S3_BUCKET): abortado"
  fi
  awsx s3api head-bucket --bucket "$S3_BUCKET" --expected-bucket-owner "$ACCT" >/dev/null 2>&1 && b_ok=1
  awsx iam get-user --user-name "$S3_USER" >/dev/null 2>&1 && u_ok=1
  awsx secretsmanager describe-secret --secret-id "$S3_USER" >/dev/null 2>&1 && sec_ok=1
  say "requisitos S3 de apps-layer: stack $S3_STACK=$([[ $stack_ok -eq 1 ]] && echo existe || echo no) bucket $S3_BUCKET=$([[ $b_ok -eq 1 ]] && echo existe || echo no) usuario IAM $S3_USER=$([[ $u_ok -eq 1 ]] && echo existe || echo no) secreto=$([[ $sec_ok -eq 1 ]] && echo existe || echo no)"
  # bucket de backups opcional (mismo stack): solo se informa si existe algo; por defecto SE CONSERVA
  local bk_stack=0 bk_b=0 bk_u=0 bk_sec=0
  if [[ $stack_ok -eq 1 ]] && jq -e --arg b "$BK_BUCKET" '(.Stacks[0].Outputs // [])[] | select(.OutputKey=="BackupsS3BucketName" and .OutputValue==$b)' <<<"$sj" >/dev/null 2>&1; then bk_stack=1; fi
  awsx s3api head-bucket --bucket "$BK_BUCKET" --expected-bucket-owner "$ACCT" >/dev/null 2>&1 && bk_b=1
  awsx iam get-user --user-name "$BK_USER" >/dev/null 2>&1 && bk_u=1
  awsx secretsmanager describe-secret --secret-id "$BK_USER" >/dev/null 2>&1 && bk_sec=1
  BK_BACKUPS_BUCKET_EXISTS=$bk_b
  if [[ $((bk_stack+bk_b+bk_u+bk_sec)) -gt 0 ]]; then
    BK_ANY=1
    say "bucket de BACKUPS (opcional, plataforma Stratio/GitOps): en el stack=$([[ $bk_stack -eq 1 ]] && echo si || echo no) bucket $BK_BUCKET=$([[ $bk_b -eq 1 ]] && echo existe || echo no) usuario IAM $BK_USER=$([[ $bk_u -eq 1 ]] && echo existe || echo no) secreto=$([[ $bk_sec -eq 1 ]] && echo existe || echo no)"
  fi
  if [[ $((stack_ok+b_ok+u_ok+sec_ok+bk_b+bk_u+bk_sec)) -eq 0 ]]; then say "no hay requisitos S3 de apps-layer: nada que hacer"; return 0; fi
  if [[ $DELETE_S3 -ne 1 ]]; then
    say "se CONSERVAN (el bucket tiene DeletionPolicy Retain y puede tener datos del usuario): para borrarlos, relanza esta fase con --delete-s3-requisites (vacía versiones y delete markers, borra stack, bucket, usuario IAM, access key y secreto)"
    [[ $BK_ANY -eq 0 ]] || say "el bucket de backups $BK_BUCKET, su usuario $BK_USER y su secreto se CONSERVAN también; son copias de seguridad de la plataforma: solo se borra el bucket con --delete-s3-requisites --delete-backups (y escribiendo su nombre)"
    return 0
  fi
  guard "$S3_USER"; guard "$BK_USER"
  if [[ $BK_ANY -eq 1 ]]; then
    if [[ $DELETE_BK -eq 1 ]]; then
      say "--delete-backups: se borrará TAMBIÉN el bucket de BACKUPS $BK_BUCKET con todas sus versiones (irreversible), su usuario IAM $BK_USER, su access key y su secreto"
    else
      say "el bucket de backups $BK_BUCKET se CONSERVA (sin --delete-backups); ojo: si el stack lo tiene, al borrar el stack se borran su usuario IAM $BK_USER, su access key y su secreto (el bucket y sus datos quedan, sin credenciales ni gestión del stack)"
    fi
  elif [[ $DELETE_BK -eq 1 ]]; then say "--delete-backups: no hay bucket de backups $BK_BUCKET ni usuario/secreto de backups: nada extra que borrar"; fi
  PLANNED=$((PLANNED+1))
  if [[ $APPLY -ne 1 ]]; then
    echo "[DRY-RUN] ejecutaría 2-apps-layer-kit/scripts/s3-requisites.sh delete: vaciar bucket $S3_BUCKET (objetos, versiones, delete markers, multipart) -> borrar stack $S3_STACK -> borrar bucket -> liberar secreto $S3_USER"
    if [[ $DELETE_BK -eq 1 && $BK_BACKUPS_BUCKET_EXISTS -eq 1 ]]; then echo "[DRY-RUN] con --delete-backups ('s3-requisites.sh delete --delete-backups'): vaciar y borrar también el bucket de BACKUPS $BK_BUCKET (confirmación extra tecleando su nombre)"; fi
    return 0
  fi
  local kit; kit="$(find_apps_layer_kit "" "$DIR")" || die "no encuentro el 2-apps-layer-kit para ejecutar 's3-requisites.sh delete' (APPS_LAYER_KIT=<ruta>). No se ha borrado nada de S3."
  echo "ATENCIÓN: se borrarán DE FORMA IRREVERSIBLE todos los objetos del bucket $S3_BUCKET, el stack $S3_STACK, el usuario IAM $S3_USER y su secreto."
  confirm_typed "Escribe el nombre del bucket ($S3_BUCKET) para confirmar: " "$S3_BUCKET"
  local kit_args=(delete)
  if [[ $DELETE_BK -eq 1 && $BK_BACKUPS_BUCKET_EXISTS -eq 1 ]]; then
    echo "ATENCIÓN EXTRA: se borrarán DE FORMA IRREVERSIBLE las COPIAS DE SEGURIDAD de la plataforma: todos los objetos y versiones del bucket de BACKUPS $BK_BUCKET, el propio bucket, el usuario IAM $BK_USER y su secreto."
    confirm_typed "Escribe el nombre del bucket de BACKUPS ($BK_BUCKET) para confirmar: " "$BK_BUCKET"
    kit_args+=(--delete-backups)
  fi
  logl "s3-requisites.sh ${kit_args[*]} ($S3_BUCKET, $S3_STACK$([[ $DELETE_BK -eq 1 ]] && echo ", backups $BK_BUCKET"))"
  ( export CLUSTER_ENV_FILE="$DIR/cluster.env" KEOS_WORKSPACE_DIR="$DIR" KIT_AWS_PROFILE="$PROFILE" APPS_LAYER_DIR="$(apps_layer_default_dir "$C")" AWS_BIN
    [[ -z "${TEARDOWN_ALLOW_NONTTY:-}" ]] || export KIT_TEST_ALLOW_NOTTY=1
    bash "$kit/scripts/s3-requisites.sh" "${kit_args[@]}" ) 2>&1 | tee -a "$LOG" | sed 's/^/      /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "s3-requisites.sh delete falló: revisa la salida y relanza --phase A --delete-s3-requisites (es reanudable)"
  DONE_OPS=$((DONE_OPS+1))
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 1: dentro del clúster
# ---------------------------------------------------------------------------------------------------------------
phase1() {
  hdr "Fase 1 — dentro del clúster (LB, Ingress, workloads, PVC/PV)"
  [[ $SKIP_INCLUSTER -eq 0 ]] || { say "omitida (--skip-incluster)"; return 0; }
  [[ $EKS_EXISTS -eq 1 ]] || { say "el EKS no existe: nada que hacer dentro del clúster"; return 0; }
  need_tools kubectl
  # kubeconfig propio fuera de .kube/ (tras keos install ese directorio es de root)
  KUBECFG="$(eks_kubeconfig "$DIR")" || { warn "no se pudo generar el kubeconfig"; [[ $APPLY -eq 1 ]] && die "sin kubeconfig no se puede limpiar el clúster (usa --skip-incluster bajo tu responsabilidad)"; return 0; }
  say "kubeconfig propio: $KUBECFG (chmod 600)"
  local ep srv; ep="$(jq -r '.cluster.endpoint' <<<"$EKSJ")"
  srv="$(kc config view --minify -o json 2>/dev/null | jq -r '.clusters[0].cluster.server // ""')"
  [[ "$srv" == "$ep" ]] || die "el kubeconfig apunta a '$srv' y el EKS $C es '$ep': abortado"
  if ! timeout 40 kubectl --kubeconfig "$KUBECFG" get ns >/dev/null 2>&1; then
    [[ $APPLY -eq 1 ]] && die "no se alcanza el API server (¿endpoint privado? lánzalo desde la VPC) — o usa --skip-incluster"
    warn "no se alcanza el API server: en dry-run no se puede listar lo que hay dentro del clúster"; return 0
  fi
  local sysre="^(kube-.*|default|cert-manager|capi-.*|capa-.*|cluster-${C}|flux-system)$"
  local ing svc pvc pv
  ing="$(kc get ingress -A -o json 2>/dev/null | jq -r '.items[]?|.metadata.namespace+"/"+.metadata.name')"
  svc="$(kc get svc -A -o json | jq -r '.items[]|select(.spec.type=="LoadBalancer")|.metadata.namespace+"/"+.metadata.name')"
  pvc="$(kc get pvc -A -o json | jq -r '.items[]|.metadata.namespace+"/"+.metadata.name')"
  pv="$(kc get pv -o json | jq -r '.items[]|.metadata.name+"("+.spec.persistentVolumeReclaimPolicy+")"')"
  say "Ingress: $(wc -w <<<"$ing")  Services LoadBalancer: $(wc -w <<<"$svc")  PVC: $(wc -w <<<"$pvc")  PV: $(wc -w <<<"$pv")"
  [[ -n "$ing$svc$pvc$pv" ]] || say "no hay Ingress/LB/PVC/PV (normal si keos install no llegó a crearlos): nada que borrar aquí"
  say "(no hay 'keos uninstall' documentado: se limpian los recursos que crean cargas externas y el resto lo borra la fase 2)"
  [[ -n "$ing$svc$pvc$pv" ]] || return 0
  [[ -z "$ing" ]] || echo "  Ingress: $ing"; [[ -z "$svc" ]] || echo "  LB: $svc"; [[ -z "$pvc" ]] || echo "  PVC: $pvc"; [[ -z "$pv" ]] || echo "  PV: $pv"
  local nsl; nsl="$(kc get ns -o json | jq -r --arg re "$sysre" '.items[]|.metadata.name|select(test($re)|not)')"
  say "namespaces de aplicación cuyos workloads se escalarán a 0 antes de borrar PVC: $(echo $nsl)"
  PLANNED=$((PLANNED+1))
  if [[ $APPLY -ne 1 ]]; then echo "[DRY-RUN] borraría: Ingress, Services LoadBalancer, escalaría a 0 deploy/sts de los namespaces de aplicación y borraría los PVC"; return 0; fi
  confirm_step "¿Borrar Ingress/LB/PVC del clúster $C?"
  local i
  for i in $ing; do logl "kubectl delete ingress $i"; kc delete ingress "${i#*/}" -n "${i%%/*}" --wait=false; done
  for i in $svc; do logl "kubectl delete svc $i"; kc delete svc "${i#*/}" -n "${i%%/*}" --wait=false; done
  for i in $nsl; do kc scale deploy,sts --all --replicas=0 -n "$i" >/dev/null 2>&1 || true; done
  for i in $pvc; do logl "kubectl delete pvc $i"; kc delete pvc "${i#*/}" -n "${i%%/*}" --wait=false; done
  pv_gone() { [[ -z "$(kc get svc -A -o json | jq -r '.items[]|select(.spec.type=="LoadBalancer")|.metadata.name')" && "$(kc get pv -o json | jq '.items|length')" -eq 0 ]]; }
  wait_for "Services LoadBalancer y PV eliminados" 900 pv_gone || true
  # Un owner (helm/operator) puede recrear lo borrado: se comprueba de nuevo
  local left; left="$(kc get svc -A -o json | jq -r '.items[]|select(.spec.type=="LoadBalancer")|.metadata.namespace+"/"+.metadata.name')"
  [[ -z "$left" || -n "${TEARDOWN_NO_WAIT:-}" ]] || die "siguen Services LoadBalancer: $left (¿los recrea un controlador? desinstala su release y reintenta)"
  left="$(kc get pv -o json | jq -r '.items[]|.metadata.name')"
  [[ -z "$left" ]] || warn "quedan PV: $(echo $left): si tienen reclaimPolicy Retain sus volúmenes EBS se limpiarán en la verificación/fase 7"
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 2: borrado del EKS
# ---------------------------------------------------------------------------------------------------------------
eks_gone() { ! awsx eks describe-cluster --name "$C" >/dev/null 2>&1; }
# Las fases 6 y 7 exigen que el EKS ya no exista. En dry-run (o con mocks) solo se avisa y se muestra el plan.
require_eks_gone() {  # require_eks_gone <fase>
  if eks_gone; then EKS_EXISTS=0; return 0; fi
  EKS_EXISTS=1
  if [[ $APPLY -eq 1 && -z "${TEARDOWN_NO_WAIT:-}" ]]; then die "el EKS $C sigue existiendo: la fase $1 va después del borrado del clúster (fase 2). Abortado."; fi
  warn "el EKS $C sigue existiendo: con --apply la fase $1 abortaría si no se ha borrado antes (fase 2). Se muestra el plan."
}
phase2() {
  hdr "Fase 2 — borrado del clúster EKS (método: $METHOD)"
  if [[ $EKS_EXISTS -eq 0 && -z "$NGS" ]]; then say "el EKS ya no existe: nada que hacer"; return 0; fi
  PLANNED=$((PLANNED+1))
  if [[ "$METHOD" == capi ]]; then
    say "mecanismo documentado (manual de operaciones de Stratio/kind, 'Deletion of the cluster'). Pasos:"
    cat <<EOF
   a) cloud-provisioner create cluster --name $C --descriptor cluster.yaml --avoid-creation --delete-previous   (kind local sin crear nada en AWS; pide la contraseña del vault)
   b) kubectl -n kube-system scale deployment keoscluster-controller-manager --replicas 0                      (en el EKS)
   c) clusterctl --kubeconfig <EKS> move -n cluster-$C --to-kubeconfig <kind>                                  (debe decir "Moving Cluster API objects Clusters=1")
   d) kubectl -n cluster-$C delete cl --all   (en el kind) -> CAPA borra nodegroups, EKS y sus SG/ENI; se espera a que desaparezcan en AWS
   e) cloud-provisioner delete cluster --name $C                                                               (borra solo el contenedor kind)
EOF
  else
    say "fallback por API de EKS (NO usa CAPI; úsalo solo si el camino capi no es viable): borra los nodegroups ${NGS:-<ninguno>} y el clúster $C"
  fi
  if [[ $APPLY -ne 1 ]]; then echo "[DRY-RUN] borraría el EKS $C (nodegroups: ${NGS:-ninguno})"; return 0; fi

  if [[ "$METHOD" == aws-api ]]; then
    confirm_typed "Método aws-api: puede dejar objetos CAPI huérfanos en el kind retenido. Escribe FORCE para continuar: " FORCE
    for ng in $NGS; do del "nodegroup $ng del EKS $C" "$ng" eks delete-nodegroup --cluster-name "$C" --nodegroup-name "$ng"; done
    ng_gone() { [[ "$(awsx eks list-nodegroups --cluster-name "$C" --output json | jq '.nodegroups|length')" -eq 0 ]]; }
    wait_for "nodegroups eliminados" 2400 ng_gone
    del "cluster EKS $C" "$C" eks delete-cluster --name "$C"
    wait_for "EKS eliminado" 2400 eks_gone
    return 0
  fi

  # --- método capi ---
  local BIN="${CLOUD_PROVISIONER_BIN:-}"
  [[ -x "$BIN" ]] || die "CLOUD_PROVISIONER_BIN no es ejecutable ($BIN)"
  [[ -f "$DIR/cluster.yaml" && -f "$DIR/secrets.yml" ]] || die "faltan cluster.yaml y/o secrets.yml en $DIR (los necesita cloud-provisioner; si se borraron, usa --method aws-api)"
  need_tools docker kubectl
  [[ -n "$KUBECFG" ]] || KUBECFG="$(eks_kubeconfig "$DIR")" || die "sin kubeconfig del EKS"
  if [[ -n "$(dk ps -a --filter "name=^/${KIND_CTR}\$" --format '{{.Names}}')" ]]; then
    local img; img="$(dk inspect -f '{{.Config.Image}}' "$KIND_CTR")"
    [[ "$img" == *cloud-provisioner* ]] || die "el contenedor $KIND_CTR usa la imagen $img: no parece de cloud-provisioner. Abortado."
    say "existe un contenedor kind retenido ($KIND_CTR, $img): --delete-previous lo recreará (el backup de objetos ya está en $DIR/backup)"
  fi
  command -v clusterctl >/dev/null 2>&1 || say "clusterctl no está en el host: se usará el del contenedor kind"
  confirm_step "a) ¿Crear el kind local de gestión con --avoid-creation (pedirá la contraseña del vault)?"
  local rc
  set +e; ( cd "$DIR" && "$BIN" create cluster --name "$C" --descriptor cluster.yaml --avoid-creation --delete-previous ) 2>&1 | tee -a "$LOG" | sed 's/^/      /'; rc=${PIPESTATUS[0]}; set -e
  [[ $rc -eq 0 ]] || die "cloud-provisioner --avoid-creation falló: NO se ha borrado nada en AWS. Revisa el error y reintenta."
  [[ -n "$(dk ps --filter "name=^/${KIND_CTR}\$" --format '{{.Names}}')" ]] || die "el kind local $KIND_CTR no está en marcha"
  confirm_step "b) ¿Pausar keoscluster-controller-manager en el EKS?"
  kc -n kube-system scale deployment keoscluster-controller-manager --replicas 0 || warn "no se pudo escalar keoscluster-controller-manager (¿no existe?)"
  confirm_step "c) ¿Mover la gestión CAPI del EKS al kind local (clusterctl move)?"
  # kubeconfig con token de corta vida (15 min) para clusterctl dentro del contenedor; no se imprime y se borra después
  local tok kcf="$DIR/.work/eks-token.kubeconfig"
  tok="$(awsx eks get-token --cluster-name "$C" --output json | jq -r '.status.token')"
  ( umask 077; jq -n --arg s "$(jq -r .cluster.endpoint <<<"$EKSJ")" --arg ca "$(jq -r .cluster.certificateAuthority.data <<<"$EKSJ")" --arg t "$tok" --arg n "$C" \
    '{apiVersion:"v1",kind:"Config",clusters:[{name:$n,cluster:{server:$s,"certificate-authority-data":$ca}}],users:[{name:$n,user:{token:$t}}],contexts:[{name:$n,context:{cluster:$n,user:$n}}],"current-context":$n}' > "$kcf" )
  unset tok
  dk cp "$kcf" "$KIND_CTR:/kind/eks-token.kubeconfig"; rm -f "$kcf"
  local mv_out
  mv_out="$(dk exec "$KIND_CTR" sh -c "clusterctl --kubeconfig /kind/eks-token.kubeconfig move -n cluster-${C} --to-kubeconfig \"\${KUBECONFIG:-/root/.kube/config}\"" 2>&1)" || { echo "$mv_out" | tail -15; dk exec "$KIND_CTR" rm -f /kind/eks-token.kubeconfig || true; die "clusterctl move falló: NO se borra nada. Revisa y reintenta (el EKS sigue gestionado desde sí mismo)"; }
  dk exec "$KIND_CTR" rm -f /kind/eks-token.kubeconfig || true
  echo "$mv_out" | tail -5 | sed 's/^/      /'
  grep -q 'Clusters=1' <<<"$mv_out" || die "la salida de clusterctl move no contiene 'Moving Cluster API objects Clusters=1': abortado antes de borrar"
  say "objetos CAPI en el kind local:"
  dk exec "$KIND_CTR" kubectl -n "cluster-${C}" get cluster,awsmanagedcontrolplane,machinepool 2>&1 | sed 's/^/      /'
  dk exec "$KIND_CTR" kubectl -n "cluster-${C}" get awsmanagedcontrolplane -o jsonpath='{.items[*].spec.identityRef}' 2>&1 | sed 's/^/      identityRef: /'; echo
  dk exec "$KIND_CTR" kubectl get awsclustercontrolleridentity,awsclusterroleidentity 2>&1 | sed 's/^/      /' || true
  confirm_step "d) ¿Borrar el Cluster '$C' desde el kind local? (CAPA destruirá nodegroups y EKS)"
  dk exec "$KIND_CTR" kubectl -n "cluster-${C}" delete cl --all --wait=false 2>&1 | sed 's/^/      /'
  ng_all_gone() { [[ "$(awsx eks list-nodegroups --cluster-name "$C" --output json 2>/dev/null | jq '.nodegroups|length' 2>/dev/null || echo 0)" -eq 0 ]]; }
  wait_for "nodegroups eliminados por CAPA" 3000 ng_all_gone
  wait_for "EKS $C eliminado" 3000 eks_gone
  cl_gone() { [[ -z "$(dk exec "$KIND_CTR" kubectl -n "cluster-${C}" get cl -o name 2>/dev/null)" ]]; }
  wait_for "objeto Cluster eliminado en el kind" 900 cl_gone
  confirm_step "e) ¿Borrar el kind local ($KIND_CTR)?"
  ( cd "$DIR" && "$BIN" delete cluster --name "$C" ) 2>&1 | sed 's/^/      /'
  say "EKS eliminado. Las ENIs/SG de CAPA tardan unos minutos en desaparecer; la fase 7 aborta si siguen en uso."
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 3: EFS
# ---------------------------------------------------------------------------------------------------------------
phase3() {
  hdr "Fase 3 — EFS (mount targets -> access points -> file system)"
  local fsj ids
  fsj="$(awsx efs describe-file-systems --output json)"
  # pertenencia: creation-token == nombre del clúster, o tag Name/owner == nombre del clúster
  ids="$(jq -r --arg c "$C" '[.FileSystems[]|select(.CreationToken==$c or any(.Tags[]?; (.Key=="Name" or .Key=="keos.stratio.com/owner") and .Value==$c))|.FileSystemId]|join(" ")' <<<"$fsj")"
  [[ -n "$EFS_ID" ]] && ids="$(echo "$ids $EFS_ID" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)"
  if [[ -z "$ids" ]]; then say "no hay EFS del clúster: nada que hacer"; return 0; fi
  [[ $(wc -w <<<"$ids") -eq 1 ]] || die "varios EFS candidatos ($ids): ambiguo, abortado"
  EFS_ID="$ids"; save_state EFS_ID_S "$EFS_ID"
  local owner; owner="$(jq -r --arg f "$EFS_ID" '.FileSystems[]|select(.FileSystemId==$f)|(.Tags//[])|map(select(.Key=="keos.stratio.com/owner"))|.[0].Value // ""' <<<"$fsj")"
  [[ -z "$owner" || "$owner" == "$C" ]] || die "el EFS $EFS_ID pertenece a '$owner', no a $C: abortado"
  say "EFS del clúster: $EFS_ID"
  local mt ap
  mt="$(awsx efs describe-mount-targets --file-system-id "$EFS_ID" --output json | jq -r '.MountTargets[].MountTargetId')"
  ap="$(awsx efs describe-access-points --file-system-id "$EFS_ID" --output json | jq -r '.AccessPoints[].AccessPointId')"
  local m a
  for m in $mt; do del "mount target $m de $EFS_ID" "$m" efs delete-mount-target --mount-target-id "$m"; done
  mt_gone() { [[ "$(awsx efs describe-mount-targets --file-system-id "$EFS_ID" --output json | jq '.MountTargets|length')" -eq 0 ]]; }
  [[ -z "$mt" ]] || wait_for "mount targets eliminados" 900 mt_gone
  for a in $ap; do del "access point $a de $EFS_ID" "$a" efs delete-access-point --access-point-id "$a"; done
  del "file system $EFS_ID" "$EFS_ID" efs delete-file-system --file-system-id "$EFS_ID"
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 4: Route53
# ---------------------------------------------------------------------------------------------------------------
phase4() {
  hdr "Fase 4 — Route53 ($EXTERNAL_DOMAIN)"
  local zj zids z
  zj="$(awsx route53 list-hosted-zones --output json)"
  zids="$(jq -r --arg n "${EXTERNAL_DOMAIN}." '[.HostedZones[]|select(.Name==$n)|.Id|sub("/hostedzone/";"")]|join(" ")' <<<"$zj")"
  if [[ -z "$zids" ]]; then say "no hay zonas de $EXTERNAL_DOMAIN: nada que hacer"; return 0; fi
  [[ $(wc -w <<<"$zids") -le 2 ]] || die "más de 2 zonas llamadas $EXTERNAL_DOMAIN ($zids): ambiguo, abortado"
  # prueba de pertenencia de cada zona
  for z in $zids; do
    local zd tags cref priv vpcs proof=""
    zd="$(awsx route53 get-hosted-zone --id "$z" --output json)"
    cref="$(jq -r '.HostedZone.CallerReference // ""' <<<"$zd")"
    priv="$(jq -r '.HostedZone.Config.PrivateZone' <<<"$zd")"
    tags="$(awsx route53 list-tags-for-resource --resource-type hostedzone --resource-id "$z" --output json 2>/dev/null | jq -r '[.ResourceTagSet.Tags[]?|select(.Key=="keos.stratio.com/owner")|.Value]|first // ""')"
    vpcs="$(jq -r '[.VPCs[]?.VPCId]|join(" ")' <<<"$zd")"
    [[ "$tags" == "$C" ]] && proof="tag owner"
    [[ -z "$proof" && "$cref" == "${C}-"* ]] && proof="CallerReference $cref"
    [[ -z "$proof" && "$priv" == true && -n "$VPC_ID" && " $vpcs " == *" $VPC_ID "* ]] && proof="asociada a la VPC $VPC_ID"
    if [[ -z "$proof" ]]; then for az in "${ACCEPT_ZONES[@]:-}"; do [[ "$az" == "$z" ]] && proof="--accept-zone"; done; fi
    [[ -n "$proof" ]] || die "la zona $z ($EXTERNAL_DOMAIN, privada=$priv) no demuestra pertenencia a $C (sin tag owner, CallerReference '$cref' ajena y sin VPC del clúster). Si es tuya: --accept-zone $z. Abortado."
    say "zona $z privada=$priv pertenencia: $proof"
    # registros (todos menos NS/SOA del apex)
    local rrs n
    rrs="$(awsx route53 list-resource-record-sets --hosted-zone-id "$z" --output json | jq -c --arg n "${EXTERNAL_DOMAIN}." '[.ResourceRecordSets[]|select((.Type=="NS" or .Type=="SOA") and .Name==$n|not)]')"
    n="$(jq 'length' <<<"$rrs")"
    say "  registros a vaciar: $n"
    [[ "$n" -eq 0 ]] || jq -r '.[]|"    "+.Type+" "+.Name' <<<"$rrs" | head -20
    if [[ "$n" -gt 0 ]]; then
      PLANNED=$((PLANNED+1))
      if [[ $APPLY -eq 1 ]]; then
        local i=0 batch
        while [[ $i -lt $n ]]; do
          batch="$(jq -c --argjson s "$i" '{Changes:(.[$s:$s+100]|map({Action:"DELETE",ResourceRecordSet:.}))}' <<<"$rrs")"
          echo "[APPLY]   borrar registros $i..$((i+100)) de la zona $z"; logl "borrar registros de $z desde $i"
          awsx route53 change-resource-record-sets --hosted-zone-id "$z" --change-batch "$batch" >/dev/null || die "falló el borrado de registros de $z"
          i=$((i+100))
        done
      else echo "[DRY-RUN] borraría $n registros de la zona $z"; fi
    fi
    del "zona hospedada $z ($EXTERNAL_DOMAIN, privada=$priv)" "$z" route53 delete-hosted-zone --id "$z"
  done
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 5: bucket de Velero
# ---------------------------------------------------------------------------------------------------------------
phase5() {
  hdr "Fase 5 — bucket de Velero ($VELERO_BUCKET)"
  if [[ $KEEP_BUCKET -eq 1 ]]; then say "omitida (--keep-bucket): se conserva el bucket y los backups de Velero"; return 0; fi
  if ! awsx s3api head-bucket --bucket "$VELERO_BUCKET" --expected-bucket-owner "$ACCT" >/dev/null 2>&1; then
    say "el bucket no existe en la cuenta $ACCT (o no es accesible/propio): nada que hacer"; return 0; fi
  local tj owner
  tj="$(awsx s3api get-bucket-tagging --bucket "$VELERO_BUCKET" --output json 2>/dev/null || true)"; [[ -n "$tj" ]] || tj='{}'
  owner="$(jq -r '[.TagSet[]?|select(.Key=="keos.stratio.com/owner")|.Value]|first // ""' <<<"$tj" 2>/dev/null || true)"
  [[ -z "$owner" || "$owner" == "$C" ]] || die "el bucket $VELERO_BUCKET pertenece a '$owner': abortado"
  [[ "$VELERO_BUCKET" == *"$C"* && "$VELERO_BUCKET" == *"$ACCT"* ]] || die "el nombre del bucket no contiene el clúster y la cuenta: no parece derivado. Abortado."
  local vj nv
  vj="$(awsx s3api list-object-versions --bucket "$VELERO_BUCKET" --max-keys 1000 --no-paginate --output json)"
  nv="$(jq '[.Versions[]?,.DeleteMarkers[]?]|length' <<<"$vj")"
  say "bucket del clúster: objetos/versiones/delete-markers en la primera página: $nv$(jq -r 'if .IsTruncated then " (hay más)" else "" end' <<<"$vj")  [AVISO: se pierden los backups de Velero]"
  PLANNED=$((PLANNED+1))
  if [[ $APPLY -ne 1 ]]; then echo "[DRY-RUN] vaciaría (objetos, versiones, multipart) y borraría el bucket $VELERO_BUCKET"; return 0; fi
  confirm_step "¿Vaciar y borrar el bucket $VELERO_BUCKET (backups de Velero incluidos)?"
  local guard_n=0
  while :; do
    vj="$(awsx s3api list-object-versions --bucket "$VELERO_BUCKET" --max-keys 1000 --no-paginate --output json)"
    nv="$(jq '[.Versions[]?,.DeleteMarkers[]?]|length' <<<"$vj")"; [[ "$nv" -gt 0 ]] || break
    echo "[APPLY]   borrando $nv versiones/markers"; logl "s3 delete-objects $nv de $VELERO_BUCKET"
    awsx s3api delete-objects --bucket "$VELERO_BUCKET" --delete "$(jq -c '{Objects:([.Versions[]?,.DeleteMarkers[]?]|map({Key:.Key,VersionId:.VersionId})),Quiet:true}' <<<"$vj")" >/dev/null
    guard_n=$((guard_n+1)); [[ $guard_n -lt 100000 ]] || die "demasiadas iteraciones vaciando el bucket"
    [[ -z "${TEARDOWN_NO_WAIT:-}" ]] || break
  done
  local mu
  mu="$(awsx s3api list-multipart-uploads --bucket "$VELERO_BUCKET" --output json | jq -c '.Uploads[]?|{k:.Key,u:.UploadId}')"
  while IFS= read -r u; do [[ -n "$u" ]] || continue
    awsx s3api abort-multipart-upload --bucket "$VELERO_BUCKET" --key "$(jq -r .k <<<"$u")" --upload-id "$(jq -r .u <<<"$u")" >/dev/null
  done <<<"$mu"
  del "bucket $VELERO_BUCKET" "$VELERO_BUCKET" s3api delete-bucket --bucket "$VELERO_BUCKET"
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 6: IAM del clúster, OIDC, log group
# ---------------------------------------------------------------------------------------------------------------
check_iam_owner() {  # check_iam_owner role|policy NOMBRE -> aborta si lleva owner de otro clúster
  local kind="$1" name="$2" tags
  if [[ "$kind" == role ]]; then tags="$(awsx iam get-role --role-name "$name" --output json | jq -r '[.Role.Tags[]?|select(.Key=="keos.stratio.com/owner")|.Value]|first // ""')"
  else tags="$(awsx iam list-policy-tags --policy-arn "arn:aws:iam::${ACCT}:policy/${name}" --output json 2>/dev/null | jq -r '[.Tags[]?|select(.Key=="keos.stratio.com/owner")|.Value]|first // ""')"; fi
  [[ -z "$tags" || "$tags" == "$C" ]] || die "$kind $name pertenece a '$tags', no a $C: abortado"
}
delete_role() {  # delete_role NOMBRE (desadjunta todo lo que cuelga y borra el rol)
  local r="$1" p ip
  guard "$r"
  awsx iam get-role --role-name "$r" >/dev/null 2>&1 || { say "rol $r: no existe"; return 0; }
  check_iam_owner role "$r"
  for p in $(awsx iam list-attached-role-policies --role-name "$r" --output json | jq -r '.AttachedPolicies[].PolicyArn'); do
    del "desadjuntar $p del rol $r" "$r" iam detach-role-policy --role-name "$r" --policy-arn "$p"
  done
  for p in $(awsx iam list-role-policies --role-name "$r" --output json | jq -r '.PolicyNames[]'); do
    del "borrar policy inline $p del rol $r" "$r" iam delete-role-policy --role-name "$r" --policy-name "$p"
  done
  for ip in $(awsx iam list-instance-profiles-for-role --role-name "$r" --output json | jq -r '.InstanceProfiles[].InstanceProfileName'); do
    del "sacar el rol $r del instance profile $ip" "$r" iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$r"
    del "borrar instance profile $ip" "$r" iam delete-instance-profile --instance-profile-name "$ip"
  done
  del "rol IAM $r" "$r" iam delete-role --role-name "$r"
}
delete_policy() {  # delete_policy NOMBRE_POLICY (solo de este clúster)
  local n="$1" arn="arn:aws:iam::${ACCT}:policy/$1" ent e v
  guard "$n"; guard "$arn"
  awsx iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || { say "policy $n: no existe"; return 0; }
  check_iam_owner policy "$n"
  ent="$(awsx iam list-entities-for-policy --policy-arn "$arn" --output json)"
  [[ "$(jq '[.PolicyUsers[]?,.PolicyGroups[]?]|length' <<<"$ent")" -eq 0 ]] || die "la policy $n está adjunta a usuarios/grupos: ambiguo, abortado"
  for e in $(jq -r '.PolicyRoles[]?.RoleName' <<<"$ent"); do
    # solo se desadjunta de los roles del clúster y del rol de nodos de cuenta (nuestra policy -efs-csi)
    if [[ "$e" == "${C}-external-dns" || "$e" == "$VELERO_ROLE" || ( "$e" == "$NODE_ROLE" && "$n" == "${C}-efs-csi" ) ]]; then
      del "desadjuntar $n del rol $e" "$e" iam detach-role-policy --role-name "$e" --policy-arn "$arn"
    else die "la policy $n está adjunta al rol inesperado '$e': ambiguo, abortado"; fi
  done
  for v in $(awsx iam list-policy-versions --policy-arn "$arn" --output json | jq -r '.Versions[]|select(.IsDefaultVersion|not)|.VersionId'); do
    del "versión $v de la policy $n" "$n" iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  del "policy IAM $n" "$n" iam delete-policy --policy-arn "$arn"
}
phase6() {
  hdr "Fase 6 — IAM del clúster, OIDC y logs"
  require_eks_gone 6
  delete_role "${C}-external-dns"
  delete_role "$VELERO_ROLE"
  delete_role "${C}-iam-service-role"      # rol del plano de control creado por CAPA; normalmente ya lo borra CAPA
  delete_policy "${C}-external-dns"
  delete_policy "${C}-velero"
  delete_policy "${C}-efs-csi"             # primero se desadjunta del rol de nodos de cuenta (ver delete_policy)
  if [[ -n "$OIDC_ISSUER" ]]; then
    local oarn="arn:aws:iam::${ACCT}:oidc-provider/${OIDC_ISSUER}"
    if awsx iam get-open-id-connect-provider --open-id-connect-provider-arn "$oarn" >/dev/null 2>&1; then
      del "proveedor OIDC $oarn (issuer del EKS ya borrado)" "$oarn" iam delete-open-id-connect-provider --open-id-connect-provider-arn "$oarn"
    else say "proveedor OIDC del clúster: no existe (CAPA ya lo borró)"; fi
  else say "issuer OIDC desconocido (sin estado): se omite; la verificación listará los proveedores OIDC por si queda alguno"; fi
  local lg="/aws/eks/${C}/cluster"
  if [[ "$(awsx logs describe-log-groups --log-group-name-prefix "$lg" --output json | jq -r --arg n "$lg" '[.logGroups[]|select(.logGroupName==$n)]|length')" -gt 0 ]]; then
    del "log group $lg" "$lg" logs delete-log-group --log-group-name "$lg"
  else say "log group $lg: no existe"; fi
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 7: red
# ---------------------------------------------------------------------------------------------------------------
phase7() {
  hdr "Fase 7 — red (NAT, EIP, IGW, subnets, route tables, SG, VPC)"
  require_eks_gone 7
  [[ -n "$VPC_ID" ]] || { say "no hay VPC del clúster: nada que hacer"; return 0; }
  local args=(--delete --name "$C" --expect-account "$ACCT" --profile "$PROFILE" --region "$AWS_REGION" --vpc-id "$VPC_ID")
  [[ -f "$DIR/${C}.json" ]] && args+=(--from-json "$DIR/${C}.json")
  [[ $APPLY -eq 1 ]] && args+=(--apply)
  PLANNED=$((PLANNED+1))
  logl "create-test-vpc.sh ${args[*]}"
  local rc
  set +e; AWS_BIN="$AWS_BIN" bash "$SKILL_DIR/scripts/create-test-vpc.sh" "${args[@]}" 2>&1 | tee -a "$LOG" | sed 's/^/  /'; rc=${PIPESTATUS[0]}; set -e
  if [[ $rc -ne 0 ]]; then
    [[ $APPLY -eq 1 ]] && die "el borrado de red abortó (ver arriba): corrige la causa y reanuda con --phase 7"
    warn "el dry-run de red informa de bloqueos (esperable mientras el clúster exista); con --apply abortaría hasta que se resuelvan"
  fi
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 8: local
# ---------------------------------------------------------------------------------------------------------------
secure_rm() {  # secure_rm RUTA... (shred si hay; si no es nuestro, imprime el comando con sudo para la persona usuaria)
  local f
  for f in "$@"; do
    [[ -e "$f" || -L "$f" ]] || continue
    if [[ ! -O "$f" || ( -d "$f" && ! -w "$f" ) ]]; then
      warn "$f pertenece a otro usuario (root, creado por el contenedor de keos-installer): ejecuta tú:  sudo rm -rf '$f'"; continue; fi
    logl "borrar local $f"
    if [[ -f "$f" ]] && command -v shred >/dev/null 2>&1; then shred -u "$f"; else rm -rf "$f"; fi
  done
}
phase8() {
  hdr "Fase 8 — local (kind retenido y ficheros del directorio de trabajo)"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local ctr; ctr="$(dk ps -a --filter "name=^/${KIND_CTR}\$" --format '{{.Names}}')"
    if [[ -n "$ctr" ]]; then
      local img; img="$(dk inspect -f '{{.Config.Image}}' "$KIND_CTR")"
      [[ "$img" == *cloud-provisioner* ]] || die "el contenedor $KIND_CTR usa la imagen $img: no parece de cloud-provisioner. Abortado."
      PLANNED=$((PLANNED+1))
      if [[ $APPLY -eq 1 ]]; then confirm_step "¿Borrar el contenedor kind $KIND_CTR?"; logl "docker rm -f $KIND_CTR"
        if [[ -x "${CLOUD_PROVISIONER_BIN:-}" ]]; then ( cd "$DIR" && "$CLOUD_PROVISIONER_BIN" delete cluster --name "$C" ) || true; fi
        [[ -z "$(dk ps -a --filter "name=^/${KIND_CTR}\$" --format '{{.Names}}')" ]] || dk rm -f "$KIND_CTR" >/dev/null
      else echo "[DRY-RUN] borraría el contenedor kind $KIND_CTR ($img)"; fi
    else say "no hay contenedor kind $KIND_CTR"; fi
  else say "docker no disponible: se omite el contenedor kind"; fi

  local ga=("$DIR/kubeconfig-${C}" "$DIR/${C}.json" "$DIR/keos.yaml" "$DIR/keos.yaml.cloud-provisioner" "$DIR/override_vars" "$DIR/override_charts_values" "$DIR/.work")
  local gb=("$DIR/cluster.yaml" "$DIR/secrets.yml" "$DIR/.kube" "$DIR/backup")
  # lo que apps-layer deja en el workspace (/workspace): YAML de tenant, JSON de grupos/roles, apps/ y el certificado/clave del admin
  local extra_a; shopt -s nullglob; extra_a=("$DIR"/*-tenant.yaml "$DIR"/*_group.json "$DIR"/*-users_role.json); shopt -u nullglob
  ga+=("${extra_a[@]}" "$DIR/apps"); gb+=("$DIR/admin.key" "$DIR/admin.cert")
  say "ficheros locales (cluster.env y logs/ se conservan siempre):"
  echo "  grupo A (regenerables, sin secretos): $(for f in "${ga[@]}"; do [[ -e "$f" ]] && printf '%s ' "${f#$DIR/}"; done)"
  echo "  grupo B (SECRETOS: claves IAM, credenciales cifradas, kubeconfigs, backup CAPI con Secrets, admin.key/admin.cert de apps-layer): $(for f in "${gb[@]}"; do [[ -e "$f" ]] && printf '%s ' "${f#$DIR/}"; done)"
  if [[ $DELETE_LOCAL -ne 1 ]]; then echo "  (no se borra nada local sin --delete-local)"; return 0; fi
  if [[ $APPLY -ne 1 ]]; then echo "[DRY-RUN] con --apply --delete-local se preguntaría por cada grupo"; PLANNED=$((PLANNED+1)); return 0; fi
  if confirm_yes "¿Borrar el grupo A (regenerables)?"; then secure_rm "${ga[@]}"; fi
  if confirm_yes "¿Borrar de forma segura el grupo B (SECRETOS)? Tras esto no podrás usar cloud-provisioner con este clúster"; then secure_rm "${gb[@]}"; fi
  echo "  nota: ~/.aws (perfil $CP_PROFILE con la access key del usuario IAM) NO se toca; elimínalo tú si el usuario IAM se borró (fase 9)"
}

# ---------------------------------------------------------------------------------------------------------------
# Fase 9: recursos de cuenta compartidos
# ---------------------------------------------------------------------------------------------------------------
phase9() {
  hdr "Fase 9 — recursos de CUENTA compartidos (--purge-account-shared)"
  [[ "$CALLER_ARN" != *":user/cloud-provisioner" ]] || die "esta fase no puede ejecutarse como el usuario cloud-provisioner (se borraría a sí mismo): usa --profile <administración>"
  # 1) no debe quedar ningún otro EKS en la cuenta (todas las regiones habilitadas)
  local regs r left=""
  regs="$(awsx ec2 describe-regions --output json | jq -r '.Regions[].RegionName')"
  for r in $regs; do
    local l; l="$(awsr "$r" eks list-clusters --output json 2>/dev/null | jq -r '.clusters[]?' | sed "s/^/$r:/")"
    [[ -z "$l" ]] || left="$left $l"
  done
  [[ -z "$left" ]] || die "quedan clústeres EKS en la cuenta ($left): los recursos compartidos de CAPA los usan. Abortado."
  say "no queda ningún EKS en la cuenta (regiones habilitadas comprobadas)"
  # 2) el rol de nodos solo debe llevar policies de CAPA/AWS/ECR_POLICY
  local extra=""
  if awsx iam get-role --role-name "$NODE_ROLE" >/dev/null 2>&1; then
    extra="$(awsx iam list-attached-role-policies --role-name "$NODE_ROLE" --output json | jq -r --arg a "arn:aws:iam::${ACCT}:policy/" --arg e "$ECR_POLICY_NAME" '[.AttachedPolicies[]|select(.PolicyArn|startswith($a))|select(.PolicyName!=$e)|.PolicyName]|join(" ")')"
    [[ -z "$extra" ]] || die "el rol $NODE_ROLE lleva policies de cliente ajenas ($extra): son de otro entorno/clúster. Abortado."
  fi
  PLANNED=$((PLANNED+1))
  if [[ $APPLY -eq 1 ]]; then
    confirm_typed "Se borrarán la pila $CAPA_STACK, la policy $ECR_POLICY_NAME y el usuario IAM cloud-provisioner. Escribe PURGE $ACCT: " "PURGE $ACCT"
  fi
  # 3) pila CloudFormation de CAPA (roles *.cluster-api-provider-aws.sigs.k8s.io, instance profiles, policies gestionadas)
  local st
  st="$(awsx cloudformation describe-stacks --stack-name "$CAPA_STACK" --output json 2>/dev/null | jq -r '.Stacks[0].StackStatus // ""' || true)"
  if [[ -n "$st" ]]; then
    say "pila $CAPA_STACK: $st"
    del "pila CloudFormation $CAPA_STACK" "$CAPA_STACK" cloudformation delete-stack --stack-name "$CAPA_STACK"
    stack_gone() { local s; s="$(awsx cloudformation describe-stacks --stack-name "$CAPA_STACK" --output json 2>/dev/null | jq -r '.Stacks[0].StackStatus // "GONE"' || echo GONE)"; [[ "$s" == GONE || "$s" == DELETE_COMPLETE ]] || { [[ "$s" == DELETE_FAILED ]] && die "la pila quedó en DELETE_FAILED: revisa los eventos en CloudFormation"; return 1; }; }
    wait_for "pila CloudFormation eliminada" 1800 stack_gone
  else say "pila $CAPA_STACK: no existe"; fi
  # 4) policy ECR pull-through
  local parn="arn:aws:iam::${ACCT}:policy/${ECR_POLICY_NAME}"
  if awsx iam get-policy --policy-arn "$parn" >/dev/null 2>&1; then
    guard "$ECR_POLICY_NAME"
    local ent; ent="$(awsx iam list-entities-for-policy --policy-arn "$parn" --output json | jq -r '[.PolicyRoles[]?.RoleName,.PolicyUsers[]?.UserName,.PolicyGroups[]?.GroupName]|join(" ")')"
    [[ -z "$ent" || $APPLY -ne 1 ]] || die "la policy $ECR_POLICY_NAME sigue adjunta a: $ent. Abortado."
    [[ -z "$ent" ]] || say "(dry-run) la policy sigue adjunta a: $ent (se espera que la pila lo desadjunte)"
    local v; for v in $(awsx iam list-policy-versions --policy-arn "$parn" --output json | jq -r '.Versions[]|select(.IsDefaultVersion|not)|.VersionId'); do del "versión $v de $ECR_POLICY_NAME" "$ECR_POLICY_NAME" iam delete-policy-version --policy-arn "$parn" --version-id "$v"; done
    del "policy $ECR_POLICY_NAME" "$ECR_POLICY_NAME" iam delete-policy --policy-arn "$parn"
  else say "policy $ECR_POLICY_NAME: no existe"; fi
  # 5) usuario IAM cloud-provisioner: EL ÚLTIMO (CAPA usa sus claves mientras exista el clúster)
  local U=cloud-provisioner
  guard "$U"
  if awsx iam get-user --user-name "$U" >/dev/null 2>&1; then
    [[ $EKS_EXISTS -eq 0 ]] || die "el EKS existe todavía: el usuario $U no se puede borrar"
    [[ -z "$(awsx iam list-mfa-devices --user-name "$U" --output json | jq -r '.MFADevices[]?.SerialNumber')" ]] || die "el usuario $U tiene dispositivos MFA: revisar a mano"
    local k p g
    for k in $(awsx iam list-access-keys --user-name "$U" --output json | jq -r '.AccessKeyMetadata[].AccessKeyId'); do del "access key $k de $U" "$U" iam delete-access-key --user-name "$U" --access-key-id "$k"; done
    for p in $(awsx iam list-attached-user-policies --user-name "$U" --output json | jq -r '.AttachedPolicies[].PolicyArn'); do del "desadjuntar $p de $U" "$U" iam detach-user-policy --user-name "$U" --policy-arn "$p"; done
    for p in $(awsx iam list-user-policies --user-name "$U" --output json | jq -r '.PolicyNames[]'); do del "policy inline $p de $U" "$U" iam delete-user-policy --user-name "$U" --policy-name "$p"; done
    for g in $(awsx iam list-groups-for-user --user-name "$U" --output json | jq -r '.Groups[].GroupName'); do del "sacar a $U del grupo $g" "$U" iam remove-user-from-group --user-name "$U" --group-name "$g"; done
    awsx iam get-login-profile --user-name "$U" >/dev/null 2>&1 && del "login profile de $U" "$U" iam delete-login-profile --user-name "$U"
    del "usuario IAM $U" "$U" iam delete-user --user-name "$U"
    say "recuerda: el perfil local '$CP_PROFILE' de ~/.aws conserva una access key ya borrada; elimínalo tú (no se toca)"
  else say "usuario IAM $U: no existe"; fi
}

# ---------------------------------------------------------------------------------------------------------------
# Verificación final
# ---------------------------------------------------------------------------------------------------------------
LEFT=0
vk() { komsg "$*"; LEFT=$((LEFT+1)); logl "QUEDA: $*"; }
vo() { okmsg "$*"; }
phaseV() {
  hdr "Verificación — no debe quedar nada con los tags/nombres del clúster"
  local x
  awsx eks describe-cluster --name "$C" >/dev/null 2>&1 && vk "EKS $C" || vo "EKS"
  x="$(awsx eks list-nodegroups --cluster-name "$C" --output json 2>/dev/null | jq -r '.nodegroups|join(" ")' || true)"; [[ -z "$x" ]] && vo "nodegroups" || vk "nodegroups: $x"
  x="$(awsx ec2 describe-vpcs --filters "Name=tag:Name,Values=$C" --output json | jq -r '[.Vpcs[]?|select(.IsDefault!=true)|.VpcId]|join(" ")')"; [[ -z "$x" ]] && vo "VPC (Name=$C)" || vk "VPC: $x"
  if [[ -n "$VPC_ID" ]]; then
    x="$(awsx ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --output json | jq -r '[.NatGateways[]?|select(.State!="deleted")|.NatGatewayId]|join(" ")')"; [[ -z "$x" ]] && vo "NAT gateways" || vk "NAT: $x"
    x="$(awsx ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --output json | jq -r '[.NetworkInterfaces[]?|.NetworkInterfaceId]|join(" ")')"; [[ -z "$x" ]] && vo "ENIs de la VPC" || vk "ENIs: $x"
  fi
  x="$(awsx ec2 describe-addresses --filters "Name=tag:Name,Values=${C}-nat*" --output json | jq -r '[.Addresses[]?|.AllocationId]|join(" ")')"; [[ -z "$x" ]] && vo "EIP (Name=${C}-nat*)" || vk "EIP: $x"
  x="$(awsx ec2 describe-volumes --filters "Name=tag-key,Values=kubernetes.io/cluster/$C" --output json | jq -r '[.Volumes[]?|.VolumeId]|join(" ")')"
  x="$x $(awsx ec2 describe-volumes --filters "Name=tag:KubernetesCluster,Values=$C" --output json | jq -r '[.Volumes[]?|.VolumeId]|join(" ")')"; x="$(echo $x)"
  [[ -z "$x" ]] && vo "volúmenes EBS" || vk "volúmenes EBS: $x"
  x="$(awsx ec2 describe-security-groups --filters "Name=tag-key,Values=kubernetes.io/cluster/$C" --output json | jq -r '[.SecurityGroups[]?|.GroupId]|join(" ")')"; [[ -z "$x" ]] && vo "security groups con tag del clúster" || vk "SG: $x"
  x="$(awsx ec2 describe-instances --filters "Name=tag-key,Values=kubernetes.io/cluster/$C" "Name=instance-state-name,Values=pending,running,stopping,stopped" --output json | jq -r '[.Reservations[]?.Instances[]?.InstanceId]|join(" ")')"; [[ -z "$x" ]] && vo "instancias EC2" || vk "instancias: $x"
  local tf
  for tf in "kubernetes.io/cluster/$C" "sigs.k8s.io/cluster-api-provider-aws/cluster/$C" "keos.stratio.com/owner"; do
    if [[ "$tf" == keos.stratio.com/owner ]]; then x="$(awsx resourcegroupstaggingapi get-resources --tag-filters "Key=$tf,Values=$C" --output json | jq -r '[.ResourceTagMappingList[]?.ResourceARN]|join(" ")')"
    else x="$(awsx resourcegroupstaggingapi get-resources --tag-filters "Key=$tf" --output json | jq -r '[.ResourceTagMappingList[]?.ResourceARN]|join(" ")')"; fi
    [[ -z "$x" ]] && vo "tagging API: nada con $tf" || vk "tagging API ($tf): $x"
  done
  x="$(awsx efs describe-file-systems --output json | jq -r --arg c "$C" '[.FileSystems[]|select(.CreationToken==$c or any(.Tags[]?;.Key=="Name" and .Value==$c))|.FileSystemId]|join(" ")')"; [[ -z "$x" ]] && vo "EFS" || vk "EFS: $x"
  if [[ $KEEP_BUCKET -eq 1 ]]; then echo "     bucket $VELERO_BUCKET conservado a propósito (--keep-bucket)"
  else awsx s3api head-bucket --bucket "$VELERO_BUCKET" >/dev/null 2>&1 && vk "bucket $VELERO_BUCKET" || vo "bucket Velero"; fi
  x="$(awsx route53 list-hosted-zones --output json | jq -r --arg n "${EXTERNAL_DOMAIN}." '[.HostedZones[]|select(.Name==$n)|.Id]|join(" ")')"; [[ -z "$x" ]] && vo "zonas Route53" || vk "zonas Route53: $x"
  for x in "${C}-external-dns" "$VELERO_ROLE" "${C}-iam-service-role"; do awsx iam get-role --role-name "$x" >/dev/null 2>&1 && vk "rol IAM $x" || vo "rol IAM $x"; done
  for x in "${C}-external-dns" "${C}-velero" "${C}-efs-csi"; do awsx iam get-policy --policy-arn "arn:aws:iam::${ACCT}:policy/$x" >/dev/null 2>&1 && vk "policy IAM $x" || vo "policy IAM $x"; done
  x="$(awsx iam list-attached-role-policies --role-name "$NODE_ROLE" --output json 2>/dev/null | jq -r --arg n "${C}-efs-csi" '[.AttachedPolicies[]?|select(.PolicyName==$n)|.PolicyName]|join(" ")' || true)"; [[ -z "$x" ]] && vo "rol de nodos sin ${C}-efs-csi" || vk "rol de nodos aún lleva $x"
  if [[ -n "$OIDC_ISSUER" ]]; then awsx iam get-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::${ACCT}:oidc-provider/${OIDC_ISSUER}" >/dev/null 2>&1 && vk "proveedor OIDC $OIDC_ISSUER" || vo "proveedor OIDC"; fi
  x="$(awsx logs describe-log-groups --log-group-name-prefix "/aws/eks/${C}/" --output json | jq -r '[.logGroups[]?.logGroupName]|join(" ")')"; [[ -z "$x" ]] && vo "log groups" || vk "log groups: $x"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    x="$(dk ps -a --filter "name=^/${KIND_CTR}\$" --format '{{.Names}}')"; [[ -z "$x" ]] && vo "contenedor kind" || vk "contenedor kind $x"; fi
  if has_phase A; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      for x in "$AL_CTR" "$AL_KEOS_CTR"; do [[ -z "$(dk ps -a --filter "name=^/${x}\$" --format '{{.Names}}')" ]] && vo "contenedor $x" || vk "contenedor $x"; done
    fi
    x="$(apps_layer_default_dir "$C")"; [[ ! -e "$x" ]] && vo "directorio efímero $x" || vk "directorio efímero $x (con secretos)"
    if [[ $DELETE_S3 -eq 1 ]]; then
      awsx s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 && vk "bucket S3 de apps-layer $S3_BUCKET" || vo "bucket S3 de apps-layer"
      awsx cloudformation describe-stacks --stack-name "$S3_STACK" >/dev/null 2>&1 && vk "stack $S3_STACK" || vo "stack $S3_STACK"
      awsx iam get-user --user-name "$S3_USER" >/dev/null 2>&1 && vk "usuario IAM $S3_USER" || vo "usuario IAM $S3_USER"
    else echo "     requisitos S3 de apps-layer (stack $S3_STACK, bucket $S3_BUCKET Retain, usuario $S3_USER) conservados a propósito: --delete-s3-requisites los borra"; fi
    if [[ $BK_ANY -eq 1 ]]; then
      if [[ $DELETE_S3 -eq 1 && $DELETE_BK -eq 1 ]]; then
        awsx s3api head-bucket --bucket "$BK_BUCKET" >/dev/null 2>&1 && vk "bucket de backups $BK_BUCKET" || vo "bucket de backups"
        awsx iam get-user --user-name "$BK_USER" >/dev/null 2>&1 && vk "usuario IAM de backups $BK_USER" || vo "usuario IAM de backups $BK_USER"
      else echo "     bucket de backups $BK_BUCKET (Retain) conservado a propósito: solo --delete-s3-requisites --delete-backups lo borra"; fi
    fi
  fi
  echo
  echo "Retenidos a propósito (de CUENTA, compartidos; solo se borran con --purge-account-shared): pila CloudFormation $CAPA_STACK / roles *.cluster-api-provider-aws.sigs.k8s.io, policy $ECR_POLICY_NAME, usuario IAM cloud-provisioner"
  if has_phase 9; then
    awsx cloudformation describe-stacks --stack-name "$CAPA_STACK" >/dev/null 2>&1 && vk "pila $CAPA_STACK" || vo "pila CAPA"
    awsx iam get-policy --policy-arn "arn:aws:iam::${ACCT}:policy/${ECR_POLICY_NAME}" >/dev/null 2>&1 && vk "policy $ECR_POLICY_NAME" || vo "policy ECR"
    awsx iam get-user --user-name cloud-provisioner >/dev/null 2>&1 && vk "usuario IAM cloud-provisioner" || vo "usuario IAM"
  fi
  echo "Para un barrido más amplio (otros tipos de recurso) usa tu finder/remover de marketplace (conda 'marketplace'); no se ejecuta desde aquí."
  if [[ $LEFT -eq 0 ]]; then echo "VERIFICACIÓN: OK, no queda nada con los tags/nombres de $C"; else echo "VERIFICACIÓN: quedan $LEFT elementos (ver KO). Si el borrado aún no se aplicó es lo esperado en dry-run."; fi
}

# ---------------------------------------------------------------------------------------------------------------
IFS=',' read -ra PL <<<"${PHASES//V/}"
for p in "${PL[@]}"; do
  [[ -n "$p" ]] || continue
  case "$p" in
    A) phaseA ;; 1) phase1 ;; 2) phase2 ;; 3) phase3 ;; 4) phase4 ;; 5) phase5 ;; 6) phase6 ;; 7) phase7 ;; 8) phase8 ;; 9) phase9 ;;
    *) die "fase desconocida: $p" ;;
  esac
done
phaseV
echo
if [[ $APPLY -eq 1 ]]; then echo "RESUMEN: $DONE_OPS operaciones de borrado ejecutadas. Log: $LOG"
else echo "RESUMEN DRY-RUN: $PLANNED operaciones/grupos de borrado planificados, NADA borrado. Para ejecutar: añade --apply. Log: $LOG"; fi
[[ $LEFT -eq 0 || $APPLY -ne 1 ]] || exit 2

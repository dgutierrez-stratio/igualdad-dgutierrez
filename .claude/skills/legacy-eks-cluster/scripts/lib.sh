#!/usr/bin/env bash
# lib.sh — funciones comunes de los scripts de la skill legacy-eks-cluster (se hace `source`, no se ejecuta).
#
# Convenciones:
#   - Todos los scripts trabajan sobre un directorio de trabajo por clúster (--dir, por defecto el cwd si
#     contiene cluster.env, o ./clusters/<cluster>). Nunca dentro de la skill.
#   - Las plantillas se buscan primero en <dir>/templates/<nombre> (override por clúster) y luego en la skill.
#   - AWS: siempre AWS_PAGER="" (el paginador cuelga el terminal; --no-cli-pager no existe en aws v1) y salida
#     --output json + jq (robusto entre aws v1/v2). Los secretos nunca se imprimen.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/.." && pwd)"
export AWS_PAGER=""

if [[ -t 2 ]]; then _R=$'\e[31m'; _G=$'\e[32m'; _Y=$'\e[33m'; _N=$'\e[0m'; else _R=""; _G=""; _Y=""; _N=""; fi

die()  { echo "${_R}ERROR:${_N} $*" >&2; exit 1; }
warn() { echo "${_Y}AVISO:${_N} $*" >&2; }
info() { echo "$*" >&2; }
okmsg(){ echo "${_G}ok${_N}  $*"; }
komsg(){ echo "${_R}KO${_N}  $*"; }

need_tools() {  # need_tools aws jq ...
  local t miss=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done
  [[ ${#miss[@]} -eq 0 ]] || die "faltan herramientas: ${miss[*]}"
}

# Resuelve el directorio de trabajo: $1 (explícito) | cwd si tiene cluster.env.
resolve_dir() {
  local d="${1:-}"
  if [[ -z "$d" ]]; then
    if [[ -f ./cluster.env ]]; then d="$PWD"; else die "no hay cluster.env en el directorio actual: usa --dir ./clusters/<cluster> (o init-cluster.sh)"; fi
  fi
  [[ -d "$d" ]] || die "no existe el directorio de trabajo $d"
  (cd "$d" && pwd)
}

# Carga <dir>/cluster.env y exige las variables dadas.
load_env() {  # load_env DIR VAR...
  local dir="$1"; shift
  [[ -f "$dir/cluster.env" ]] || die "no existe $dir/cluster.env (ejecuta init-cluster.sh)"
  # shellcheck disable=SC1091
  source "$dir/cluster.env"
  local v
  for v in "$@"; do [[ -n "${!v:-}" ]] || die "la variable $v está vacía o no definida en $dir/cluster.env"; done
}

tpl_path() {  # tpl_path DIR NOMBRE -> ruta de la plantilla (override por clúster o la de la skill)
  if [[ -f "$1/templates/$2" ]]; then echo "$1/templates/$2"; else echo "$SKILL_DIR/templates/$2"; fi
}

# Renderiza una plantilla con envsubst usando SOLO la lista explícita de variables; aborta si queda ${ sin resolver.
render_template() {  # render_template PLANTILLA SALIDA 'LISTA ${VAR}...' [MODO]
  local tpl="$1" out="$2" vars="$3" mode="${4:-644}" tmp
  [[ -f "$tpl" ]] || die "no existe la plantilla $tpl"
  need_tools envsubst
  tmp="$(umask 077; mktemp "${out}.XXXXXX")"
  envsubst "$vars" < "$tpl" > "$tmp"
  if grep -n '\${' "$tmp" | sed -E 's/((access|secret)_key: ).*/\1<oculto>/' | grep .; then
    rm -f "$tmp"; die "quedan variables sin resolver en $tpl (líneas arriba)"
  fi
  chmod "$mode" "$tmp"
  mv "$tmp" "$out"
}

# YAML (multi-documento) -> array JSON. Soporta yq de kislyuk (python, sintaxis jq) y mikefarah v4.
yaml2json() {  # yaml2json FICHERO
  need_tools yq jq
  if yq --version 2>&1 | grep -qi 'mikefarah\|version v\?4'; then
    yq -o=json '.' "$1" | jq -s '.'
  else
    yq '.' "$1" | jq -s '.'
  fi
}

# Elige el binario aws: prefiere una v2 (en bash puede haber una v1 antes en el PATH, p. ej. ~/.local/bin/aws,
# sin `configure list-profiles` ni --no-cli-pager). Si no hay v2 usa el primero del PATH.
pick_aws_bin() {
  local p first=""
  while IFS= read -r p; do
    [[ -n "$first" ]] || first="$p"
    if "$p" --version 2>&1 | grep -q '^aws-cli/2'; then AWS_BIN="$p"; export AWS_BIN; return 0; fi
  done < <(type -ap aws 2>/dev/null)
  [[ -n "$first" ]] || die "no se encuentra el binario aws"
  AWS_BIN="$first"; export AWS_BIN
}
AWS_BIN="${AWS_BIN:-}"

# AWS con perfil/región fijados. Usar tras `set_aws PERFIL REGIÓN`.
_AWS_PROFILE=""; _AWS_REGION=""
set_aws() { _AWS_PROFILE="$1"; _AWS_REGION="$2"; [[ -n "$AWS_BIN" ]] || pick_aws_bin; }
awsx() { AWS_PAGER="" "$AWS_BIN" --profile "$_AWS_PROFILE" --region "$_AWS_REGION" "$@"; }

# Identidad del llamador (JSON). Aborta si la cuenta no es la esperada.
assert_account() {  # assert_account CUENTA_ESPERADA
  local id acct
  id="$(awsx sts get-caller-identity --output json 2>/dev/null)" || die "sts get-caller-identity falló con el perfil $_AWS_PROFILE (¿credenciales caducadas o IAM aún propagando?)"
  acct="$(jq -r '.Account' <<<"$id")"
  [[ "$acct" == "$1" ]] || die "cuenta incorrecta: el perfil $_AWS_PROFILE opera en $acct y se esperaba $1. Abortado sin tocar nada."
  CALLER_ARN="$(jq -r '.Arn' <<<"$id")"
  export CALLER_ARN
}

# ARN de rol/usuario "base" de un ARN de sts: arn:aws:sts::A:assumed-role/ROL/sesión -> arn:aws:iam::A:role/ROL
caller_base_arn() {
  local arn="$1"
  if [[ "$arn" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/ ]]; then
    echo "arn:aws:iam::${BASH_REMATCH[1]}:role/${BASH_REMATCH[2]}"
  else
    echo "$arn"
  fi
}

confirm_yes() {  # confirm_yes "pregunta" -> 0 si responde s/S/y/Y (lee de stdin)
  local a; read -r -p "$1 [s/N] " a || return 1
  [[ "$a" =~ ^[sSyY]$ ]]
}

# Variables derivadas del clúster EKS ya creado (solo lectura). Requiere set_aws y load_env previos.
# Define: VPC_ID SUBNET_IDS CLUSTER_SG OIDC_ISSUER (sin https://) PUBLIC_ZONE_ID PRIVATE_ZONE_ID (sin /hostedzone/)
derive_vars() {
  local j zj
  j="$(awsx eks describe-cluster --name "$CLUSTER_NAME" --output json 2>/dev/null)" || die "no se encuentra el EKS $CLUSTER_NAME (¿creado? ¿perfil/región correctos?)"
  VPC_ID="$(jq -r '.cluster.resourcesVpcConfig.vpcId' <<<"$j")"
  SUBNET_IDS="$(jq -r '.cluster.resourcesVpcConfig.subnetIds | join(" ")' <<<"$j")"
  CLUSTER_SG="$(jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId' <<<"$j")"
  OIDC_ISSUER="$(jq -r '.cluster.identity.oidc.issuer // ""' <<<"$j" | sed 's#^https://##')"
  [[ -n "$OIDC_ISSUER" && "$VPC_ID" != null ]] || die "el EKS $CLUSTER_NAME no tiene issuer OIDC/VPC: no seguir"
  zj="$(awsx route53 list-hosted-zones --output json)"
  PUBLIC_ZONE_ID="$(jq -r --arg n "${EXTERNAL_DOMAIN}." '[.HostedZones[]|select(.Name==$n and (.Config.PrivateZone|not))|.Id|sub("/hostedzone/";"")]|join(" ")' <<<"$zj")"
  PRIVATE_ZONE_ID="$(jq -r --arg n "${EXTERNAL_DOMAIN}." '[.HostedZones[]|select(.Name==$n and .Config.PrivateZone)|.Id|sub("/hostedzone/";"")]|join(" ")' <<<"$zj")"
  export VPC_ID SUBNET_IDS CLUSTER_SG OIDC_ISSUER PUBLIC_ZONE_ID PRIVATE_ZONE_ID
}

# Kubeconfig PROPIO (fuera de .kube/: tras keos install ese directorio pasa a ser de root). chmod 600.
eks_kubeconfig() {  # eks_kubeconfig DIR -> imprime la ruta ./kubeconfig-<cluster>
  local f="$1/kubeconfig-${CLUSTER_NAME}"
  KUBECONFIG="$f" awsx eks update-kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$f" >/dev/null 2>&1 || return 1
  chmod 600 "$f"; echo "$f"
}

# ---------------------------------------------------------------------------------------------------------------
# apps-layer (paso 14): la skill NO copia el 2-apps-layer-kit (divergiria): lo parametriza desde cluster.env
# ---------------------------------------------------------------------------------------------------------------
# Localiza el kit: $1 explícito | $APPS_LAYER_KIT | <skill>/../../../2-apps-layer-kit (workspace igualdad) | <dir>/2-apps-layer-kit | <dir>/../2-apps-layer-kit
# Imprime la ruta absoluta; devuelve 1 si no hay ninguno con scripts/lib.sh y scripts/s3-requisites.sh.
find_apps_layer_kit() {  # find_apps_layer_kit [EXPLICITO] [DIR]
  local c
  for c in "${1:-}" "${APPS_LAYER_KIT:-}" "$SKILL_DIR/../../../2-apps-layer-kit" "${2:+$2/2-apps-layer-kit}" "${2:+$2/../2-apps-layer-kit}"; do
    [[ -n "$c" && -f "$c/scripts/lib.sh" && -f "$c/scripts/s3-requisites.sh" ]] && { (cd "$c" && pwd); return 0; }
  done
  return 1
}

# Directorio de ejecución EFÍMERO esperado de apps-layer para un clúster (lo crea el kit, 700, con secretos).
apps_layer_default_dir() {  # apps_layer_default_dir CLUSTER
  local t="${TMPDIR:-/tmp}"; echo "${t%/}/apps-layer-$1"
}

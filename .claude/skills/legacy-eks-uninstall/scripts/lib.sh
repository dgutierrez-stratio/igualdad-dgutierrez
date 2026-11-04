#!/usr/bin/env bash
# lib.sh — funciones comunes de legacy-eks-uninstall (se hace `source`, no se ejecuta).
# Autocontenido: NO depende de la skill de instalación (solo lee el cluster.env que esa skill deja en el directorio de trabajo).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$LIB_DIR/.." && pwd)"
export AWS_PAGER=""

if [[ -t 2 ]]; then _R=$'\e[31m'; _G=$'\e[32m'; _Y=$'\e[33m'; _N=$'\e[0m'; else _R=""; _G=""; _Y=""; _N=""; fi
die()   { echo "${_R}ERROR:${_N} $*" >&2; exit 1; }
warn()  { echo "${_Y}AVISO:${_N} $*" >&2; }
info()  { echo "$*" >&2; }
okmsg() { echo "${_G}ok${_N}  $*"; }
komsg() { echo "${_R}KO${_N}  $*"; }

need_tools() { local t miss=(); for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done; [[ ${#miss[@]} -eq 0 ]] || die "faltan herramientas: ${miss[*]}"; }

# --- Herramientas de Stratio (aws-marketplace-toolkit) -------------------------------------------------------------
# Sobrescribibles por entorno: MARKETPLACE_TOOLKIT, FINDER_PY, REMOVER_PY, MARKETPLACE_PYTHON.
resolve_toolkit() {
  MARKETPLACE_TOOLKIT="${MARKETPLACE_TOOLKIT:-/stratio/aws/aws-marketplace-toolkit}"
  FINDER_PY="${FINDER_PY:-$MARKETPLACE_TOOLKIT/aws-marketplace-finder/src/stratio/finder.py}"
  REMOVER_PY="${REMOVER_PY:-$MARKETPLACE_TOOLKIT/aws-marketplace-remover/src/stratio/remover.py}"
  if [[ -z "${MARKETPLACE_PYTHON:-}" ]]; then
    local c
    for c in "$HOME/miniconda3/envs/marketplace/bin/python" "$HOME/anaconda3/envs/marketplace/bin/python" "$HOME/mambaforge/envs/marketplace/bin/python"; do
      [[ -x "$c" ]] && { MARKETPLACE_PYTHON="$c"; break; }
    done
  fi
  [[ -n "${MARKETPLACE_PYTHON:-}" ]] || die "no encuentro el python del entorno conda 'marketplace' (define MARKETPLACE_PYTHON)"
  [[ -f "$FINDER_PY" ]]  || die "no existe el finder: $FINDER_PY (define MARKETPLACE_TOOLKIT o FINDER_PY)"
  [[ -f "$REMOVER_PY" ]] || die "no existe el remover: $REMOVER_PY (define MARKETPLACE_TOOLKIT o REMOVER_PY)"
  export MARKETPLACE_TOOLKIT FINDER_PY REMOVER_PY MARKETPLACE_PYTHON
}
# Esta skill asume la PR Stratio/aws-marketplace-toolkit#51 (PLT-5240) mergeada: sin estos handlers el remover no puede dejar la cuenta limpia.
REQUIRED_HANDLERS=(_delete_efs_file_system _delete_route53_hosted_zone _delete_autoscaling_group)
check_remover_handlers() {
  local h miss=()
  for h in "${REQUIRED_HANDLERS[@]}"; do grep -q "def $h" "$REMOVER_PY" || miss+=("$h"); done
  [[ ${#miss[@]} -eq 0 ]] || die "el remover ($REMOVER_PY) no tiene los handlers de PLT-5240: ${miss[*]}. Actualiza aws-marketplace-toolkit (PR #51 mergeada) o usa SKIP_HANDLER_CHECK=1 bajo tu responsabilidad."
}

# --- AWS --------------------------------------------------------------------------------------------------------
pick_aws_bin() {
  local p first=""
  while IFS= read -r p; do
    [[ -n "$first" ]] || first="$p"
    if "$p" --version 2>&1 | grep -q '^aws-cli/2'; then AWS_BIN="$p"; return 0; fi
  done < <(type -ap aws 2>/dev/null)
  [[ -n "$first" ]] || die "no se encuentra el binario aws"
  AWS_BIN="$first"
}
AWS_BIN="${AWS_BIN:-}"; _PROFILE=""; _REGION=""
set_aws() { _PROFILE="$1"; _REGION="$2"; [[ -n "$AWS_BIN" ]] || pick_aws_bin; }
# Solo lectura: esta skill no llama a AWS para escribir (los borrados los hace el remover).
_RO_RE='^(describe|list|get|head|batch-get|lookup|search)'
awsx() {
  local svc="${1:-}" op="${2:-}"
  [[ "$op" =~ $_RO_RE ]] || die "BUG: operación AWS no de lectura bloqueada ($svc $op): los borrados los hace solo el remover"
  AWS_PAGER="" "$AWS_BIN" --profile "$_PROFILE" --region "$_REGION" "$@"
}
awsr() { local r="$1"; shift; local s="$_REGION"; _REGION="$r"; awsx "$@"; local rc=$?; _REGION="$s"; return $rc; }

resolve_dir() {
  local d="${1:-}"
  if [[ -z "$d" ]]; then [[ -f ./cluster.env ]] && d="$PWD" || die "indica --dir ./clusters/<cluster> (no hay cluster.env aquí)"; fi
  [[ -d "$d" ]] || die "no existe el directorio $d"
  (cd "$d" && pwd)
}
load_env() { local dir="$1"; shift; [[ -f "$dir/cluster.env" ]] || die "no existe $dir/cluster.env"; source "$dir/cluster.env"; local v; for v in "$@"; do [[ -n "${!v:-}" ]] || die "$v vacío en $dir/cluster.env"; done; }

#!/usr/bin/env bash
# find-admin-profile.sh — localiza el perfil local de AWS CLI que da acceso de administración a una cuenta.
#
# Usage: find-admin-profile.sh --account 123456789012 [--exclude PERFIL]... [--verify]
#
# Busca, entre los perfiles de `aws configure list-profiles`, los que asumen un rol de ESA cuenta
# (role_arn = arn:aws:iam::<cuenta>:role/...) o tienen sso_account_id = <cuenta>. Solo usa
# `aws configure get role_arn|sso_account_id` (nunca lee ~/.aws/credentials ni secretos).
# --verify: confirma cada candidato con `sts get-caller-identity` (solo lectura).
#
# Salida: nombres de perfil candidatos, uno por línea (stdout).
# Código de salida: 0 = exactamente uno | 3 = ninguno | 4 = varios (la skill debe preguntar a la persona usuaria)
#                   | 5 = no hay aws v2 para listar perfiles.
set -euo pipefail
export AWS_PAGER=""
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
pick_aws_bin
if ! PROFILES="$("$AWS_BIN" configure list-profiles 2>/dev/null)"; then
  echo "ERROR: ningún aws del PATH soporta 'configure list-profiles' (hace falta aws v2; v1 no lo tiene)." >&2
  echo "       Ejecuta tú 'aws configure list-profiles' y pasa el perfil a init-cluster.sh con --admin-profile." >&2
  exit 5
fi
aws() { "$AWS_BIN" "$@"; }

ACCOUNT=""; VERIFY=0; EXCLUDE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account) ACCOUNT="$2"; shift 2 ;;
    --exclude) EXCLUDE+=("$2"); shift 2 ;;
    --verify)  VERIFY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "opción desconocida: $1" >&2; exit 1 ;;
  esac
done
[[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || { echo "ERROR: --account debe ser un número de 12 dígitos" >&2; exit 1; }

# `aws configure get` tarda ~1-3 s por llamada (arranque de aws v2): se consultan los perfiles en paralelo.
# (para `configure get` vale cualquier aws, y la v1 arranca mucho más rápido que la v2; v2 solo para list-profiles)
AWS_GET_BIN="$(type -ap aws | head -1)"; export AWS_BIN AWS_GET_BIN
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
probe() {  # probe PERFIL -> fichero con "perfil<TAB>role_arn<TAB>sso_account_id"
  local p="$1" role sso
  role="$("$AWS_GET_BIN" configure get role_arn --profile "$p" 2>/dev/null || true)"
  sso="";  [[ -n "$role" ]] || sso="$("$AWS_GET_BIN" configure get sso_account_id --profile "$p" 2>/dev/null || true)"
  printf '%s\t%s\t%s\n' "$p" "$role" "$sso" > "$TMPD/$(printf '%s' "$p" | tr -c 'A-Za-z0-9_.-' '_')"
}
export -f probe; export TMPD
printf '%s\n' "$PROFILES" | grep -v '^$' | xargs -P 4 -I{} bash -c 'probe "$1"' _ {}

cands=()
while IFS=$'\t' read -r p role sso; do
  [[ -n "$p" ]] || continue
  skip=0; for e in "${EXCLUDE[@]:-}"; do [[ -n "$e" && "$p" == "$e" ]] && skip=1; done
  [[ $skip -eq 0 ]] || continue
  if [[ "$role" == arn:aws:iam::"$ACCOUNT":role/* || "$sso" == "$ACCOUNT" ]]; then
    if [[ $VERIFY -eq 1 ]]; then
      got="$("$AWS_BIN" sts get-caller-identity --profile "$p" --query Account --output text 2>/dev/null </dev/null || true)"
      [[ "$got" == "$ACCOUNT" ]] || { echo "aviso: el perfil $p parece de la cuenta pero sts no confirma" >&2; continue; }
    fi
    cands+=("$p")
  fi
done < <(cat "$TMPD"/* 2>/dev/null | sort)

if [[ ${#cands[@]} -gt 0 ]]; then printf '%s\n' "${cands[@]}"; fi
case ${#cands[@]} in
  0) exit 3 ;;
  1) exit 0 ;;
  *) exit 4 ;;
esac

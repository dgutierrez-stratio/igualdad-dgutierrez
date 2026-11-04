#!/usr/bin/env bash
# import-llm-token.sh - guarda LLM_TOKEN en ${APPS_LAYER_DIR}/.env SIN imprimirlo.
#
# Usage: import-llm-token.sh [FICHERO_YAML_ORIGEN]
#   Con fichero: extrae la clave LLM_TOKEN (a cualquier nivel: env global, env de tenant o env de app) con yq.
#                Si hay varios valores DISTINTOS aborta y lista solo las rutas de las claves (nunca los valores).
#   Sin fichero: usa la variable LLM_TOKEN ya exportada en el entorno.
# Escribe 'export LLM_TOKEN=...' en el .env (chmod 600, idempotente: sustituye la linea existente, sin duplicar).
# Salida: solo 'LLM_TOKEN importado (N caracteres)'. El valor no sale por stdout/stderr, no va en argv (ps) y se
# desactiva xtrace. Despues, render-apps-layer.sh lo inyecta tambien en el YAML del tenant.
set -euo pipefail
{ set +x; } 2>/dev/null
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
{ set +x; } 2>/dev/null

case "${1:-}" in -h|--help) sed -n '2,11p' "$0"; exit 0 ;; esac
[[ $# -le 1 ]] || die "se espera como mucho un fichero YAML"
SRC="${1:-}"

need_tools jq yq
load_kit_env
ENV_FILE="$APPS_LAYER_DIR/.env"
ensure_private_dir "$APPS_LAYER_DIR"   # 700 y del usuario actual (aborta si no)

TOKEN=""
if [[ -n "$SRC" ]]; then
  [[ -f "$SRC" ]] || die "no existe $SRC"
  J="$(yaml2json "$SRC")" || die "$SRC no es YAML valido"
  # rutas de todas las claves LLM_TOKEN con valor de texto no vacio (solo rutas, nunca valores)
  PATHS="$(jq -r '[paths(scalars) as $p | select(($p|last) == "LLM_TOKEN") | select((getpath($p)|tostring|length) > 0 and getpath($p) != null) | $p]
                  | map(map(tostring) | join(".")) | .[]' <<<"$J")"
  [[ -n "$PATHS" ]] || die "no hay ninguna clave LLM_TOKEN con valor en $SRC"
  N="$(jq -r '[paths(scalars) as $p | select(($p|last) == "LLM_TOKEN") | getpath($p) | select(. != null and (tostring|length) > 0) | tostring] | unique | length' <<<"$J")"
  if [[ "$N" != 1 ]]; then
    echo "${_R}ERROR:${_N} hay $N valores distintos de LLM_TOKEN en $SRC; claves (solo rutas):" >&2
    sed 's/^/  - /' <<<"$PATHS" >&2
    exit 1
  fi
  TOKEN="$(jq -r '[paths(scalars) as $p | select(($p|last) == "LLM_TOKEN") | getpath($p) | select(. != null and (tostring|length) > 0) | tostring] | first' <<<"$J")"
  unset J
else
  TOKEN="${LLM_TOKEN:-}"
  [[ -n "$TOKEN" ]] || die "sin fichero origen y sin LLM_TOKEN exportado en el entorno"
fi

[[ "$TOKEN" != *$'\n'* ]] || die "el token contiene saltos de linea"
[[ "$TOKEN" =~ ^[^[:space:]*?\[]+$ ]] || die "el token contiene espacios o comodines (* ? [): apps-layer exporta el env del tenant sin comillas y lo rompería"

[[ -f "$ENV_FILE" ]] || ( umask 077; : > "$ENV_FILE" )
chmod 600 "$ENV_FILE"
emit_export LLM_TOKEN "$TOKEN" | env_replace "$ENV_FILE" LLM_TOKEN
LEN=${#TOKEN}
unset TOKEN
echo "LLM_TOKEN importado ($LEN caracteres)"

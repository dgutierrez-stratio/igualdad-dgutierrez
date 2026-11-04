#!/usr/bin/env bash
# render-apps-layer.sh - genera en ${APPS_LAYER_DIR} los ficheros que consume apps-layer-automation:
#   <CLUSTER_NAME>.yaml            YAML raiz (tenant keos)
#   <CLUSTER_NAME>-<TENANT>.yaml   YAML del tenant con S3 (lleva LLM_TOKEN si ENABLE_GENAI=true => chmod 600)
#   .env                           variables del contenedor (chmod 600); conserva las lineas secretas existentes
#   kube-config                    solo si falta (chmod 600); nunca se sobrescribe. Se copia de KUBECONFIG_SRC
#                                  (1-aws-cluster/estado/kubeconfig-<cluster>) o, si no existe, `aws eks update-kubeconfig`
#   aws/                           se monta como /root/.aws (ro): SOLO el perfil KIT_AWS_PROFILE (cloud-provisioner):
#                                  credentials (600, copiadas de ~/.aws con `aws configure get`, sin imprimirlas) y config (region)
#
# Usage: render-apps-layer.sh [--dry-run] [--no-aws-creds] [-h]
#   --dry-run        renderiza y valida en un directorio temporal, no escribe en APPS_LAYER_DIR
#   --no-aws-creds   no crea ni toca ${APPS_LAYER_DIR}/aws (si prefieres montar tu propio directorio de credenciales)
#
# APPS_LAYER_DIR es EFIMERO por defecto: ${TMPDIR:-/tmp}/apps-layer-${CLUSTER_NAME} (700, del usuario actual; si ya existe
# con permisos abiertos o de otro usuario, aborta). Si /tmp se vacia, este script lo regenera (luego import-llm-token.sh y
# s3-requisites.sh env para el token y las claves S3).
#
# Garantias: no sobrescribe un fichero distinto sin dejar antes una copia .bak (.bak.<fecha> si ya existia);
# renderiza con envsubst y lista explicita de variables; aborta si queda ${ sin resolver (salvo los placeholders
# ${tenantId}/${external_domain}, que resuelve Command Center); valida los YAML con yq y comprueba que no queda
# nada de hdfs en el tenant. Los secretos nunca se imprimen.
# Si ENABLE_GENAI=true y no hay LLM_TOKEN (entorno o .env) aborta: no quita las apps genai en silencio.
# ENVIRONMENT_SIZE=CUSTOM (opcional; con S/PIT esto no se ejecuta y el resultado es identico al de siempre): inyecta en el env: de cada app las variables de recursos
# de templates/sizes-custom.env (o CUSTOM_SIZES_FILE) y ABORTA, nombrando app y variable, si a alguna app le falta alguna de las que consume su plantilla upstream.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
{ set +x; } 2>/dev/null

DRY=0; AWS_CREDS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-aws-creds) AWS_CREDS=0; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done

need_tools envsubst jq yq awk cmp
load_kit_env

ROOT_NAME="$(root_yaml_name)"; TENANT_FILE="$(tenant_yaml_name)"
OUT="$APPS_LAYER_DIR"; ENV_OUT="$OUT/.env"

# directorio de ejecucion: 700 y del usuario actual (se comprueba ANTES de leer el .env existente)
if [[ "$DRY" == 1 ]]; then
  if [[ -e "$OUT" || -L "$OUT" ]]; then why="$(verify_private_dir "$OUT")" || die "directorio de ejecucion de apps-layer no seguro: $why"; fi
else
  ensure_private_dir "$OUT"
fi

# --- 1) LLM_TOKEN (entorno > .env existente). Nunca se imprime. ------------------------------------------------
TOKEN=""
if [[ "$ENABLE_GENAI" == true ]]; then
  if [[ -n "${LLM_TOKEN:-}" ]]; then TOKEN="$LLM_TOKEN"
  elif env_has_var "$ENV_OUT" LLM_TOKEN; then TOKEN="$(env_get_var "$ENV_OUT" LLM_TOKEN)"; fi
  [[ -n "$TOKEN" ]] || die "ENABLE_GENAI=true pero no hay LLM_TOKEN ni en el entorno ni en $ENV_OUT.
       Importalo del YAML del lab SIN imprimirlo:  scripts/import-llm-token.sh <fichero.yaml>
       (o exporta LLM_TOKEN y ejecuta ese mismo script sin argumentos). Si NO quieres genai: ENABLE_GENAI=false."
  [[ "$TOKEN" =~ ^[^[:space:]*?\[]+$ ]] \
    || die "LLM_TOKEN contiene espacios, saltos de linea o comodines (* ? [): apps-layer exporta el env del tenant sin comillas y lo rompería."
else
  # sin genai: solo se conserva en .env si ya estaba (o venia del entorno); no se inyecta en el YAML
  if [[ -n "${LLM_TOKEN:-}" ]]; then TOKEN="$LLM_TOKEN"
  elif env_has_var "$ENV_OUT" LLM_TOKEN; then TOKEN="$(env_get_var "$ENV_OUT" LLM_TOKEN)"; fi
fi

# --- 2) banderas para el preprocesador de plantillas -----------------------------------------------------------
KEOS_MINIMAL="$([[ "$KEOS_PROFILE" == minimal ]] && echo true || echo false)"
GENAI_ON="$ENABLE_GENAI"
TENANT_HOSTS_ON="$USE_TENANT_HOSTS"
LLM_PROVIDER_SET="$([[ -n "$LLM_PROVIDER" ]] && echo true || echo false)"
LLM_MODEL_SET="$([[ -n "$LLM_MODEL" ]] && echo true || echo false)"
INJECT_LLM_TOKEN="$([[ "$ENABLE_GENAI" == true && -n "$TOKEN" ]] && echo true || echo false)"
LOADER_PIN_SET="$([[ -n "$CONNECTORS_LOADER_VERSION" ]] && echo true || echo false)"
if [[ "$USE_TENANT_HOSTS" == true ]]; then
  HOSTS_MODE_TEXT="por tenant (genai|rocket|discovery|virtualizer|dlc.<tenant>.<dominio>): exigen DNS y certificado que los cubra"
else
  HOSTS_MODE_TEXT="por defecto de cada app (admin.<dominio> + path), sin DNS ni certificado adicionales"
fi
SIZE_CUSTOM="$([[ "$ENVIRONMENT_SIZE" == CUSTOM ]] && echo true || echo false)"
export KEOS_MINIMAL GENAI_ON TENANT_HOSTS_ON LLM_PROVIDER_SET LLM_MODEL_SET INJECT_LLM_TOKEN LOADER_PIN_SET HOSTS_MODE_TEXT SIZE_CUSTOM

# --- 3) render a un directorio de preparacion (700) -------------------------------------------------------------
STG="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/apps-layer-kit.XXXXXX")"
trap 'rm -rf "$STG"' EXIT

VARS_ROOT='${CLUSTER_NAME} ${EXTERNAL_DOMAIN} ${KEOS_PROFILE} ${UNIVERSE_VERSION} ${ENVIRONMENT_SIZE} ${KEOS_WORKSPACE_DIR} ${KEOS_INSTALLER_EXTRA_ARGS}'
VARS_TENANT='${CLUSTER_NAME} ${TENANT_NAME} ${APPS_LAYER_DIR} ${UNIVERSE_VERSION} ${ENVIRONMENT_SIZE} ${KEOS_WORKSPACE_DIR} ${KEOS_INSTALLER_EXTRA_ARGS} ${S3_BUCKET_NAME} ${VIRTUALIZER_CREATE_LOADBALANCER} ${LLM_PROVIDER} ${LLM_MODEL} ${CONNECTORS_LOADER_VERSION} ${S3_INIT_PATH} ${HOSTS_MODE_TEXT}'
VARS_ENV='${APPS_LAYER_DIR} ${KEOS_WORKSPACE_DIR} ${KEOS_INSTALLER_EXTRA_ARGS} ${AWS_REGION}'

render_tpl "$KIT_DIR/templates/root.yaml.tpl"   "$STG/$ROOT_NAME"   "$VARS_ROOT"   644
render_tpl "$KIT_DIR/templates/tenant.yaml.tpl" "$STG/$TENANT_FILE" "$VARS_TENANT" 644
render_tpl "$KIT_DIR/templates/env.tpl"         "$STG/.env.base"    "$VARS_ENV"    600

# ENVIRONMENT_SIZE=CUSTOM: overlay de recursos por app (apps-layer solo conoce S/PIT). Valida el overlay y lo inyecta en el env: de cada app de los dos YAML;
# la comprobacion de que no falta ninguna variable se hace en el paso 4, sobre el YAML ya renderizado.
if [[ "$SIZE_CUSTOM" == true ]]; then
  load_custom_sizes "$CUSTOM_SIZES_FILE" "$STG/.sizes.tsv"
  inject_custom_sizes "$STG/$ROOT_NAME"   "$STG/.sizes.tsv"
  inject_custom_sizes "$STG/$TENANT_FILE" "$STG/.sizes.tsv"
fi

# inyeccion del token en el YAML del tenant (el token viaja por el entorno de awk, no por argv)
TENANT_MODE=644
if [[ "$INJECT_LLM_TOKEN" == true ]]; then
  TOK="$TOKEN" awk '
    { i = index($0, "__LLM_TOKEN_PLACEHOLDER__")
      if (i > 0) {
        q = sprintf("%c", 39); t = ENVIRON["TOK"]; gsub(q, q q, t)
        $0 = substr($0, 1, i - 1) q t q substr($0, i + length("__LLM_TOKEN_PLACEHOLDER__"))
      }
      print }' "$STG/$TENANT_FILE" > "$STG/$TENANT_FILE.tok"
  mv "$STG/$TENANT_FILE.tok" "$STG/$TENANT_FILE"
  TENANT_MODE=600
fi
chmod "$TENANT_MODE" "$STG/$TENANT_FILE"
grep -q '__LLM_TOKEN_PLACEHOLDER__' "$STG/$TENANT_FILE" && die "quedo el marcador del token sin sustituir"

# .env final = base + lineas secretas conservadas + LLM_TOKEN
{
  cat "$STG/.env.base"
  # (BACKUPS_S3_BUCKET_*: solo si s3-requisites.sh env ya las escribio con ENABLE_BACKUPS_BUCKET=true; apps-layer no las usa)
  for n in S3_BUCKET_ACCESS_KEY S3_BUCKET_SECRET_KEY BACKUPS_S3_BUCKET_ACCESS_KEY BACKUPS_S3_BUCKET_SECRET_KEY BACKUPS_S3_BUCKET_NAME BACKUPS_S3_BUCKET_REGION; do
    if [[ -f "$ENV_OUT" ]] && grep -qE "$(env_line_re "$n")" "$ENV_OUT"; then
      grep -E "$(env_line_re "$n")" "$ENV_OUT" | tail -1
    fi
  done
  if [[ -n "$TOKEN" ]]; then emit_export LLM_TOKEN "$TOKEN"; fi
} > "$STG/.env"
rm -f "$STG/.env.base"; chmod 600 "$STG/.env"

# --- 4) validaciones estructurales (sin imprimir contenido secreto) ---------------------------------------------
RJ="$(yaml2json "$STG/$ROOT_NAME")"   || die "$ROOT_NAME no es YAML valido"
TJ="$(yaml2json "$STG/$TENANT_FILE")" || die "$TENANT_FILE no es YAML valido"
jq -e '.[0].tenants|map(.name)==["keos"]' <<<"$RJ" >/dev/null || die "el YAML raiz debe tener solo el tenant keos"
if [[ "$SIZE_CUSTOM" == true ]]; then
  assert_custom_sizes "$RJ" "$ROOT_NAME"
  assert_custom_sizes "$TJ" "$TENANT_FILE"
fi
jq -e --arg t "$TENANT_NAME" '.[0].tenants|map(.name)==[$t]' <<<"$TJ" >/dev/null || die "el YAML del tenant debe tener solo el tenant $TENANT_NAME"
jq -e '[.. | objects | select(has("name")) | .name] | (index("connector-s3") != null) and (index("hdfs") == null) and (index("connector-dfs-hdfs") == null)' \
  <<<"$TJ" >/dev/null || die "el tenant debe incluir connector-s3 y no incluir hdfs ni connector-dfs-hdfs"
jq -e '[.. | objects | keys[] | select(test("_HDFS$|^DEPENDENCIES_HDFS|^HDFS_VERSION"))] | length == 0' <<<"$TJ" >/dev/null \
  || die "el tenant no debe tener variables de hdfs"
jq -e --arg b "$S3_BUCKET_NAME" '.[0].tenants[0].env.S3_BUCKET_NAME == $b' <<<"$TJ" >/dev/null || die "S3_BUCKET_NAME no esta en el env del tenant"
if [[ "$USE_TENANT_HOSTS" == false ]]; then
  jq -e '[.. | objects | keys[] | select(test("HAPROXY_HOST$|HAPROXY_PATH$|SERVER_HOST$"))] | length == 0' <<<"$TJ" >/dev/null \
    || die "USE_TENANT_HOSTS=false pero hay hosts/paths por tenant en el YAML"
fi
if [[ "$ENABLE_GENAI" == true ]]; then
  jq -e '[.. | objects | select(has("name")) | .name] | (index("genai-litellm") != null) and (index("genai-api") != null) and (index("genai-ui") != null)' \
    <<<"$TJ" >/dev/null || die "ENABLE_GENAI=true pero faltan apps genai-*"
  jq -e '.[0].tenants[0].env.LLM_TOKEN | type == "string" and length > 0' <<<"$TJ" >/dev/null || die "LLM_TOKEN no quedo en el env del tenant"
else
  jq -e '[.. | objects | select(has("name")) | .name | select(startswith("genai-"))] | length == 0' <<<"$TJ" >/dev/null \
    || die "ENABLE_GENAI=false pero hay apps genai-*"
  jq -e '.[0].tenants[0].env | has("LLM_TOKEN") | not' <<<"$TJ" >/dev/null || die "ENABLE_GENAI=false: no debe haber LLM_TOKEN en el YAML"
fi
unset RJ TJ

# --- 5) instalacion con copia .bak ------------------------------------------------------------------------------
install_file() {  # install_file ORIGEN DESTINO MODO
  local src="$1" dst="$2" mode="$3" bak
  if [[ -f "$dst" ]]; then
    if cmp -s "$src" "$dst"; then chmod "$mode" "$dst"; echo "sin cambios: $dst"; return 0; fi
    bak="$dst.bak"; [[ ! -e "$bak" ]] || bak="$dst.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$dst" "$bak"; chmod 600 "$bak"
    echo "copia de seguridad: $bak"
  fi
  install -m "$mode" "$src" "$dst"
  echo "generado: $dst (modo $mode)"
}

# setup_aws_dir DIR: crea DIR (700) con SOLO el perfil $KIT_AWS_PROFILE: credentials (600) y config (region).
# Las claves se leen con `aws configure get` (del perfil local) y se escriben con printf (builtin: no salen en argv ni en
# pantalla). Idempotente: sin cambios si el contenido ya coincide. Si el perfil no tiene claves estaticas, avisa y no crea nada.
setup_aws_dir() {
  local d="$1" ak sk tmpc tmpf
  pick_aws_bin
  ak="$("$AWS_BIN" configure get aws_access_key_id --profile "$KIT_AWS_PROFILE" 2>/dev/null || true)"
  sk="$("$AWS_BIN" configure get aws_secret_access_key --profile "$KIT_AWS_PROFILE" 2>/dev/null || true)"
  if [[ -z "$ak" || -z "$sk" ]]; then
    unset ak sk
    warn "el perfil $KIT_AWS_PROFILE no tiene aws_access_key_id/aws_secret_access_key estaticas: no se crea $d (usa --no-aws-creds y monta tu propio directorio, o configura el perfil)"
    return 0
  fi
  [[ -d "$d" ]] || ( umask 077; mkdir -p "$d" )
  chmod 700 "$d"
  tmpc="$(umask 077; mktemp "$d/.credentials.XXXXXX")"; tmpf="$(umask 077; mktemp "$d/.config.XXXXXX")"
  { printf '[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$KIT_AWS_PROFILE" "$ak" "$sk"; } > "$tmpc"
  unset ak sk
  printf '[profile %s]\nregion = %s\n' "$KIT_AWS_PROFILE" "$AWS_REGION" > "$tmpf"
  if [[ -f "$d/credentials" ]] && cmp -s "$tmpc" "$d/credentials"; then rm -f "$tmpc"; echo "sin cambios: $d/credentials"
  else chmod 600 "$tmpc"; mv "$tmpc" "$d/credentials"; echo "generado: $d/credentials (perfil $KIT_AWS_PROFILE, modo 600; valores no mostrados)"; fi
  if [[ -f "$d/config" ]] && cmp -s "$tmpf" "$d/config"; then rm -f "$tmpf"; echo "sin cambios: $d/config"
  else chmod 600 "$tmpf"; mv "$tmpf" "$d/config"; echo "generado: $d/config (region $AWS_REGION, modo 600)"; fi
  chmod 600 "$d/credentials" "$d/config"
}

describe_apps() {  # lista de apps de un YAML
  yaml2json "$1" | jq -r '[.[0].tenants[].apps[]?.parallel[]?.name] | join(", ")'
}

if [[ "$DRY" == 1 ]]; then
  echo "--dry-run: validado en $STG (se borra al salir); no se escribe nada en $OUT"
  echo "tenant keos: $(describe_apps "$STG/$ROOT_NAME")"
  echo "tenant $TENANT_NAME: $(describe_apps "$STG/$TENANT_FILE")"
else
  install_file "$STG/$ROOT_NAME"   "$OUT/$ROOT_NAME"   644
  install_file "$STG/$TENANT_FILE" "$OUT/$TENANT_FILE" "$TENANT_MODE"
  install_file "$STG/.env"         "$ENV_OUT"          600
  if [[ ! -f "$OUT/kube-config" ]]; then
    if [[ -f "$KUBECONFIG_SRC" ]]; then
      install -m 600 "$KUBECONFIG_SRC" "$OUT/kube-config"; echo "generado: $OUT/kube-config (copia de $KUBECONFIG_SRC, modo 600)"
    else
      pick_aws_bin
      if awsr eks update-kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$OUT/kube-config" >/dev/null 2>&1; then
        chmod 600 "$OUT/kube-config"; echo "generado: $OUT/kube-config (aws eks update-kubeconfig, modo 600)"
      else
        rm -f "$OUT/kube-config"; warn "no se pudo generar kube-config (ni existe $KUBECONFIG_SRC ni aws eks update-kubeconfig funciono): crealo a mano"
      fi
    fi
  else
    chmod 600 "$OUT/kube-config"; echo "sin cambios: $OUT/kube-config (existente, no se sobrescribe)"
  fi
  if [[ "$AWS_CREDS" == 1 ]]; then
    setup_aws_dir "$OUT/aws"
  else
    echo "omitido: $OUT/aws (--no-aws-creds)"
    [[ -d "$OUT/aws" ]] || warn "falta $OUT/aws (se monta en solo lectura como /root/.aws para 'aws eks get-token'): crealo tu o quita --no-aws-creds"
  fi
  echo "tenant keos: $(describe_apps "$OUT/$ROOT_NAME")"
  echo "tenant $TENANT_NAME: $(describe_apps "$OUT/$TENANT_FILE")"
fi

# --- 6) avisos ----------------------------------------------------------------------------------------------------
if [[ "$ENABLE_GENAI" == false ]]; then
  warn "ENABLE_GENAI=false: NO se instalan genai-litellm/api/ui ni datamarket-agent ni pit (sus hooks dependen de roles/grupos de genai-api)."
fi
if ! env_has_var "$STG/.env" S3_BUCKET_ACCESS_KEY || ! env_has_var "$STG/.env" S3_BUCKET_SECRET_KEY; then
  warn ".env aun no tiene S3_BUCKET_ACCESS_KEY/S3_BUCKET_SECRET_KEY: ejecuta scripts/s3-requisites.sh apply y luego env (sin ellas las apps vuelven a la rama HDFS)."
fi
[[ "$INJECT_LLM_TOKEN" != true ]] || echo "LLM_TOKEN inyectado en $TENANT_FILE (modo 600) y conservado en .env (${#TOKEN} caracteres; valor no mostrado)"
[[ "$SIZE_CUSTOM" != true ]] || echo "ENVIRONMENT_SIZE=CUSTOM: recursos inyectados desde $CUSTOM_SIZES_FILE ($(wc -l < "$STG/.sizes.tsv") variables en el overlay; todas las apps de ambos YAML llevan las que consume su plantilla)"
echo "OK: render completado (cluster=$CLUSTER_NAME tenant=$TENANT_NAME perfil=$KEOS_PROFILE genai=$ENABLE_GENAI hosts-por-tenant=$USE_TENANT_HOSTS size=$ENVIRONMENT_SIZE)"

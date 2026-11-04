#!/usr/bin/env bash
# check-apps-layer.sh - comprobaciones de SOLO LECTURA antes y durante el lanzamiento de apps-layer.
#
# Usage: check-apps-layer.sh [--no-aws] [--no-cluster] [-h]
#   Secciones: 1) variables, 2) AWS (stack, bucket, usuario, secreto: solo nombres), 3) ficheros de ${APPS_LAYER_DIR}
#   (permisos, nombres presentes en .env, zip del universo y universe-images.lst validos, LLM_TOKEN sin imprimirlo, YAML validos y sin hdfs), 4) cluster
#   (tenants, pods del tenant, apps en CCT, punto de control sscc-s3 tras connectors-management).
# Los valores secretos nunca se imprimen (solo nombres y longitudes). Sale con 1 si hay algun KO.
#
# Punto de control critico (riesgo no verificado: que el connectors-loader usado (CONNECTORS_LOADER_VERSION, def. 2.2.0; vacia => el del .lst, 2.2.3 en branch-15.1) incluya sscc-s3). Tras la tanda 1 del
# tenant (connectors-management), este script ejecuta un GET dentro del pod de connectors-management:
#   curl -s http://connectors-management.<tenant>-apps/v1/api/connector/findByName?name=sscc-s3
# Si viene vacio: PARAR (virtualizer, rocket, eureka-agent y connector-s3 no funcionaran).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
{ set +x; } 2>/dev/null

DO_AWS=1; DO_CLUSTER=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-aws) DO_AWS=0; shift ;;
    --no-cluster) DO_CLUSTER=0; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done
need_tools jq yq
load_kit_env
export KIT_READONLY=1

KO=0; WN=0
ok()   { okmsg "$*"; }
ko()   { komsg "$*"; KO=$((KO + 1)); }
wn()   { wnmsg "$*"; WN=$((WN + 1)); }
hdr()  { echo; echo "== $*"; }

ENV_FILE="$APPS_LAYER_DIR/.env"
ROOT_YAML="$APPS_LAYER_DIR/$(root_yaml_name)"; TENANT_YAML="$APPS_LAYER_DIR/$(tenant_yaml_name)"
LLM_LINE=""

mode_of() { stat -c '%a' "$1" 2>/dev/null || echo "?"; }

# ---------------------------------------------------------------------------------------------------------
hdr "1) Variables"
echo "cluster=$CLUSTER_NAME cuenta=$AWS_ACCOUNT_ID region=$AWS_REGION dominio=$EXTERNAL_DOMAIN tenant=$TENANT_NAME size=$ENVIRONMENT_SIZE"
echo "bucket=$S3_BUCKET_NAME usuario=$S3_USER_NAME stack=$STACK_NAME genai=$ENABLE_GENAI hosts-por-tenant=$USE_TENANT_HOSTS perfil-keos=$KEOS_PROFILE"
echo "apps-layer=$APPS_LAYER_DIR workspace=$KEOS_WORKSPACE_DIR imagen=${APPS_LAYER_IMAGE}${APPS_LAYER_IMAGE_DIGEST:+ @ $APPS_LAYER_IMAGE_DIGEST}"
ok "variables validas (ENVIRONMENT_SIZE, booleanos, perfil, nombres)"

# ---------------------------------------------------------------------------------------------------------
if [[ $DO_AWS == 1 ]]; then
  hdr "2) AWS (solo lectura)"
  pick_aws_bin
  if assert_account_quiet=$(awsr sts get-caller-identity --output json 2>/dev/null); then
    acct="$(jq -r '.Account' <<<"$assert_account_quiet")"
    if [[ "$acct" == "$AWS_ACCOUNT_ID" ]]; then ok "sts: el perfil $KIT_AWS_PROFILE opera en la cuenta $AWS_ACCOUNT_ID"
    else ko "sts: cuenta $acct distinta de la esperada $AWS_ACCOUNT_ID"; fi
    if sj="$(awsr cloudformation describe-stacks --stack-name "$STACK_NAME" --output json 2>/dev/null)"; then
      st="$(jq -r '.Stacks[0].StackStatus' <<<"$sj")"
      if [[ "$st" == CREATE_COMPLETE || "$st" == UPDATE_COMPLETE ]]; then ok "stack $STACK_NAME: $st"; else ko "stack $STACK_NAME en estado $st"; fi
      for o in InternalS3BucketName S3StratioAppsSecretArn; do
        if jq -e --arg k "$o" '(.Stacks[0].Outputs // [])[] | select(.OutputKey==$k)' <<<"$sj" >/dev/null; then ok "output $o presente"; else ko "falta el output $o"; fi
      done
    else ko "no existe el stack $STACK_NAME (scripts/s3-requisites.sh apply)"; fi
    rc=0; out="$(awsr s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]]; then ok "bucket $S3_BUCKET_NAME accesible"; else ko "bucket $S3_BUCKET_NAME no accesible/no existe"; fi
    if awsr iam get-user --user-name "$S3_USER_NAME" --output json >/dev/null 2>&1; then ok "usuario IAM $S3_USER_NAME existe"; else ko "usuario IAM $S3_USER_NAME no existe"; fi
    if awsr secretsmanager describe-secret --secret-id "$S3_USER_NAME" --output json >/dev/null 2>&1; then ok "secreto $S3_USER_NAME existe"; else ko "secreto $S3_USER_NAME no existe"; fi
  else
    ko "sts get-caller-identity fallo con el perfil $KIT_AWS_PROFILE (credenciales caducadas?)"
  fi
fi

# ---------------------------------------------------------------------------------------------------------
hdr "3) Ficheros de $APPS_LAYER_DIR"
if [[ -d "$APPS_LAYER_DIR" ]]; then
  if why="$(verify_private_dir "$APPS_LAYER_DIR")"; then ok "$APPS_LAYER_DIR es un directorio privado (700, del usuario actual)"; else ko "directorio no seguro: $why"; fi
else
  ko "no existe $APPS_LAYER_DIR (directorio efimero: scripts/render-apps-layer.sh lo regenera)"
fi
if [[ -f "$ENV_FILE" ]]; then
  m="$(mode_of "$ENV_FILE")"; if [[ "$m" == 600 ]]; then ok ".env modo 600"; else ko ".env con modo $m (debe ser 600: chmod 600 $ENV_FILE)"; fi
  for n in DOCKER_DIND_ENABLED KEOS_WORKSPACE_DIR KEOS_INSTALLER_EXTRA_ARGS AWS_REGION; do
    if env_has_var "$ENV_FILE" "$n"; then ok ".env define $n"; else ko ".env no define $n (scripts/render-apps-layer.sh)"; fi
  done
  for n in S3_BUCKET_ACCESS_KEY S3_BUCKET_SECRET_KEY; do
    if env_has_var "$ENV_FILE" "$n"; then ok ".env define $n (valor no mostrado)"
    else ko ".env NO define $n: sin ella las apps vuelven a la rama HDFS y fallan lejos del origen (scripts/s3-requisites.sh env)"; fi
  done
  c="$(grep -cE "$(env_line_re S3_BUCKET_ACCESS_KEY)" "$ENV_FILE" || true)"; [[ "$c" -le 1 ]] || ko "S3_BUCKET_ACCESS_KEY duplicada en .env ($c lineas)"
else
  ko "no existe $ENV_FILE (scripts/render-apps-layer.sh)"
fi
if [[ -f "$APPS_LAYER_DIR/kube-config" ]]; then
  m="$(mode_of "$APPS_LAYER_DIR/kube-config")"; if [[ "$m" == 600 ]]; then ok "kube-config modo 600"; else ko "kube-config con modo $m (chmod 600)"; fi
else ko "falta $APPS_LAYER_DIR/kube-config"; fi
if [[ -d "$APPS_LAYER_DIR/aws" ]]; then ok "existe $APPS_LAYER_DIR/aws (se monta como /root/.aws)"; else wn "falta $APPS_LAYER_DIR/aws (se monta en el contenedor para 'aws eks get-token')"; fi

# zip del universo (lo descarga launch-apps-layer.sh / fetch-universe.sh antes de cada lanzamiento y se monta en el contenedor)
UZIP="$APPS_LAYER_DIR/$(universe_zip_name)"
if uwhy="$(validate_universe_zip "$UZIP")"; then
  ok "zip del universo $UNIVERSE_VERSION valido: $(basename "$UZIP") ($(stat -c %s "$UZIP") bytes, unzip -t ok)"
  if [[ -n "$(find "$UZIP" -mmin +1440 2>/dev/null)" ]]; then wn "el zip del universo tiene mas de 24 h: launch-apps-layer.sh lo vuelve a descargar siempre (o scripts/fetch-universe.sh)"; fi
else
  ko "zip del universo: $uwhy (scripts/fetch-universe.sh; launch-apps-layer.sh lo descarga siempre antes de lanzar)"
fi
LSTF="$APPS_LAYER_DIR/$(universe_lst_name)"
if lwhy="$(validate_universe_lst "$LSTF")"; then
  ok "$(basename "$LSTF") valido ($(grep -c . "$LSTF") lineas; $(grep -m1 'connectors-loader' "$LSTF" | tr -d '[:space:]'))"
  if [[ -n "$CONNECTORS_LOADER_VERSION" ]]; then
    ok "connectors-loader que se usara: $CONNECTORS_LOADER_VERSION (fijado por CONNECTORS_LOADER_VERSION; el hook ignora el .lst para el loader). Vacia la variable para usar el del .lst"
  else
    ok "connectors-loader que se usara: el del $(basename "$LSTF") ($(grep -m1 'connectors-loader' "$LSTF" | tr -d '[:space:]' | sed 's/.*://')), CONNECTORS_LOADER_VERSION vacia"
  fi
  if [[ -n "$(find "$LSTF" -mmin +1440 2>/dev/null)" ]]; then wn "$(basename "$LSTF") tiene mas de 24 h: launch-apps-layer.sh lo vuelve a descargar siempre (o scripts/fetch-universe.sh)"; fi
else
  ko "universe-images.lst: $lwhy (scripts/fetch-universe.sh; exige gh autenticado con acceso a Stratio/kubernetes-universe)"
fi

TJ=""
for f in "$ROOT_YAML" "$TENANT_YAML"; do
  if [[ -f "$f" ]]; then
    if yaml2json "$f" >/dev/null 2>&1; then ok "$(basename "$f") parsea con yq"; else ko "$(basename "$f") no es YAML valido"; fi
  else ko "falta $f (scripts/render-apps-layer.sh)"; fi
done
if [[ -f "$TENANT_YAML" ]] && TJ="$(yaml2json "$TENANT_YAML" 2>/dev/null)"; then
  jq -e --arg t "$TENANT_NAME" '.[0].tenants|map(.name)==[$t]' <<<"$TJ" >/dev/null && ok "tenant del YAML = $TENANT_NAME" || ko "el tenant del YAML no es $TENANT_NAME"
  jq -e --arg b "$S3_BUCKET_NAME" '.[0].tenants[0].env.S3_BUCKET_NAME == $b' <<<"$TJ" >/dev/null && ok "S3_BUCKET_NAME del YAML = bucket esperado" || ko "S3_BUCKET_NAME del YAML no coincide con $S3_BUCKET_NAME"
  jq -e '[.. | objects | select(has("name")) | .name] | index("connector-s3") != null' <<<"$TJ" >/dev/null && ok "connector-s3 presente" || ko "falta connector-s3 en el tenant"
  # INIT_PATH de connector-s3: la errata INTI_PATH de vars.env lo dejaria vacio y el agente crashearia (COMM_SERVICE_INIT_PATH). No es secreto: se muestra.
  ip="$(jq -r '[.. | objects | select(.name=="connector-s3") | .env.INIT_PATH // empty][0] // empty' <<<"$TJ")"
  if [[ "$ip" == "/" ]]; then ko "connector-s3 INIT_PATH = '/': el driver S3 (dg-s3-agent) no admite '/' como init-path y falla con UnsupportedRootInitPath; usa '/<bucket>' o '/<bucket>/<prefijo>' (S3_INIT_PATH, render-apps-layer.sh)"
  elif [[ -n "$ip" ]]; then ok "connector-s3 INIT_PATH = $ip (evita la errata INTI_PATH de vars.env)"
  else ko "connector-s3 sin INIT_PATH (o vacio) en el YAML del tenant: la errata INTI_PATH de vars.env lo renderiza vacio y el agente crashea con 'Missing environment variable: COMM_SERVICE_INIT_PATH' (S3_INIT_PATH, render-apps-layer.sh)"; fi
  unset ip
  jq -e '([.. | objects | select(has("name")) | .name] | (index("hdfs") == null and index("connector-dfs-hdfs") == null)) and ([.. | objects | keys[] | select(test("_HDFS$|^DEPENDENCIES_HDFS|^HDFS_VERSION"))] | length == 0)' \
    <<<"$TJ" >/dev/null && ok "sin app hdfs/connector-dfs-hdfs ni variables hdfs" || ko "el tenant aun referencia hdfs"
  m="$(mode_of "$TENANT_YAML")"
  if [[ "$ENABLE_GENAI" == true ]]; then
    if [[ "$m" == 600 ]]; then ok "$(basename "$TENANT_YAML") modo 600 (lleva secretos)"; else ko "$(basename "$TENANT_YAML") con modo $m: lleva LLM_TOKEN, debe ser 600"; fi
  fi
fi

# --- ENVIRONMENT_SIZE=CUSTOM: cada app de los YAML lleva todas las variables de recursos que consume su plantilla (envsubst no avisa si faltan) ---
if [[ "$ENVIRONMENT_SIZE" == CUSTOM ]]; then
  for f in "$ROOT_YAML" "$TENANT_YAML"; do
    [[ -f "$f" ]] || continue
    miss="$(custom_sizes_missing "$(yaml2json "$f" 2>/dev/null || echo '[]')" || true)"
    if [[ -z "$miss" ]]; then ok "CUSTOM: $(basename "$f") lleva las variables de recursos de todas sus apps (overlay: $CUSTOM_SIZES_FILE)"
    else
      while IFS=$'\t' read -r a v; do
        if [[ "$v" == "*" ]]; then ko "CUSTOM: $(basename "$f"): app $a no esta en la lista cerrada del kit (scripts/lib.sh, custom_required_vars)"
        else ko "CUSTOM: $(basename "$f"): app $a sin la variable de recursos $v (envsubst la dejaria vacia: completa el overlay y repite render-apps-layer.sh)"; fi
      done <<<"$miss"
    fi
  done
fi

# --- LLM_TOKEN (sin imprimir el valor) ---------------------------------------------------------------------
if [[ "$ENABLE_GENAI" == true ]]; then
  env_len=0; yaml_len=0; same=0
  if env_has_var "$ENV_FILE" LLM_TOKEN; then
    ev="$(env_get_var "$ENV_FILE" LLM_TOKEN)"; env_len=${#ev}
  else ev=""; fi
  yv=""
  if [[ -n "$TJ" ]]; then yv="$(jq -j --arg t "$TENANT_NAME" '.[0].tenants[] | select(.name==$t) | .env.LLM_TOKEN // empty' <<<"$TJ")"; yaml_len=${#yv}; fi
  [[ "$env_len" -gt 0 ]] && ok "LLM_TOKEN en .env ($env_len caracteres)" || ko "LLM_TOKEN ausente o vacio en .env (scripts/import-llm-token.sh <yaml>)"
  [[ "$yaml_len" -gt 0 ]] && ok "LLM_TOKEN en el YAML del tenant ($yaml_len caracteres)" || ko "LLM_TOKEN ausente o vacio en el env del tenant del YAML (render-apps-layer.sh)"
  if [[ "$env_len" -gt 0 && "$yaml_len" -gt 0 ]]; then
    if [[ "$(printf '%s' "$ev" | sha256sum)" == "$(printf '%s' "$yv" | sha256sum)" ]]; then same=1; ok ".env y YAML llevan el mismo LLM_TOKEN"
    else ko "el LLM_TOKEN del .env y el del YAML difieren: vuelve a ejecutar render-apps-layer.sh"; fi
  fi
  if [[ "$yaml_len" -gt 0 && "$env_len" -gt 0 && $same == 1 ]]; then
    consumers="$(jq -r '[.. | objects | select(has("name")) | .name | select(. == "genai-litellm" or . == "genai-api")] | unique | join(", ")' <<<"$TJ")"
    LLM_LINE="LLM_TOKEN OK ($yaml_len caracteres) → genai-*: ${consumers:-ninguna} (genai-litellm registra la credencial/modelo, genai-api la guarda en Vault; genai-ui no lo usa)"
  fi
  unset ev yv
else
  if [[ -n "$TJ" ]] && jq -e --arg t "$TENANT_NAME" '.[0].tenants[]|select(.name==$t)|.env|has("LLM_TOKEN")' <<<"$TJ" >/dev/null; then ko "ENABLE_GENAI=false pero el YAML lleva LLM_TOKEN"; else ok "ENABLE_GENAI=false: sin genai-* ni LLM_TOKEN en el YAML"; fi
  wn "genai desactivado: tampoco se instalan datamarket-agent ni pit"
fi

# ---------------------------------------------------------------------------------------------------------
if [[ $DO_CLUSTER == 1 ]]; then
  hdr "4) Cluster (solo lectura)"
  KC=""
  for c in "$APPS_LAYER_DIR/kube-config" "$KUBECONFIG_SRC"; do [[ -f "$c" ]] && { KC="$c"; break; }; done
  if [[ -z "$KC" ]] || ! command -v kubectl >/dev/null 2>&1; then
    wn "sin kubectl o sin kubeconfig: se omite la seccion de cluster"
  else
    kc() { AWS_PROFILE="$KIT_AWS_PROFILE" AWS_PAGER="" kubectl --kubeconfig "$KC" "$@"; }
    if tn="$(kc get tenant -o name 2>/dev/null)"; then
      grep -q '/keos$' <<<"$tn" && ok "tenant keos existe" || ko "no existe el tenant keos"
      if grep -q "/${TENANT_NAME}\$" <<<"$tn"; then ok "tenant $TENANT_NAME existe"; else wn "el tenant $TENANT_NAME aun no existe (lo crea apps-installer al ejecutar el YAML del tenant)"; fi
    else ko "kubectl get tenant fallo (kubeconfig/credenciales)"; fi

    pods="$(kc get pods -A --no-headers 2>/dev/null || true)"
    if [[ -n "$pods" ]]; then
      bad="$(awk -v p="^${TENANT_NAME}-" '$1 ~ p && $4 != "Running" && $4 != "Completed" {print $1"/"$2" ("$4")"}' <<<"$pods")"
      n="$(awk -v p="^${TENANT_NAME}-" '$1 ~ p {c++} END{print c+0}' <<<"$pods")"
      if [[ "$n" -eq 0 ]]; then wn "no hay pods en namespaces ${TENANT_NAME}-* (instalacion del tenant aun no lanzada)"
      elif [[ -z "$bad" ]]; then ok "$n pods en ${TENANT_NAME}-*, todos Running/Completed"
      else ko "pods del tenant que no estan Running/Completed:"; sed 's/^/      /' <<<"$bad"; fi
    fi

    # apps en CCT: pods con la etiqueta cct.stratio.com/application_id
    if aj="$(kc get pods -A -l cct.stratio.com/application_id -o json 2>/dev/null)"; then
      installed="$(jq -r '[.items[].metadata.labels["cct.stratio.com/application_id"]] | unique | join(" ")' <<<"$aj")"
      expected=""
      if [[ -n "$TJ" ]]; then expected="$(jq -r '[.[0].tenants[0].apps[]?.parallel[]? | (.env.APP_NAME // .name)] | unique | join(" ")' <<<"$TJ")"; fi
      missing=""
      for a in $expected; do grep -qE "(^| )${a}\\.${TENANT_NAME}-" <<<" $installed" || missing+="$a "; done
      if [[ -z "${missing// /}" && -n "$expected" ]]; then ok "todas las apps del YAML del tenant tienen pods en CCT"
      else wn "apps del YAML sin pods aun: ${missing:-todas}"; fi
    fi

    # punto de control sscc-s3
    capp="connectors-management"; cns="${TENANT_NAME}-apps"
    if [[ -n "$TJ" ]]; then
      cns="${TENANT_NAME}-$(jq -r '[.[0].tenants[0].apps[]?.parallel[]? | select(.name=="connectors-management") | .env.APP_NAMESPACE_SUFFIX][0] // "apps"' <<<"$TJ")"
    fi
    cpod="$(kc -n "$cns" get pods -l "cct.stratio.com/application_id=${capp}.${cns}" -o name 2>/dev/null | head -1 || true)"
    if [[ -n "$cpod" ]]; then
      resp="$(kc -n "$cns" exec "${cpod#pod/}" -- curl -s "http://${capp}.${cns}/v1/api/connector/findByName?name=sscc-s3" 2>/dev/null || true)"
      if [[ -z "$resp" || "$resp" == "[]" || "$resp" == "{}" || "$resp" == "null" ]]; then
        ko "PUNTO DE CONTROL sscc-s3: findByName?name=sscc-s3 viene VACIO. PARAR: virtualizer, rocket, eureka-agent y connector-s3 no funcionaran (hay que subir el conector sscc-s3 al connectors-management)"
      elif grep -q 'sscc-s3' <<<"$resp"; then ok "PUNTO DE CONTROL sscc-s3: connectors-management lo devuelve (${#resp} bytes)"
      else wn "PUNTO DE CONTROL sscc-s3: respuesta no reconocida (${#resp} bytes); revisalo a mano"; fi
    else
      wn "connectors-management aun no desplegado en $cns: tras su tanda, comprueba sscc-s3 con:"
      echo "      kubectl -n $cns exec \$(kubectl -n $cns get pods -l cct.stratio.com/application_id=${capp}.${cns} -o name | head -1 | cut -d/ -f2) -- curl -s \"http://${capp}.${cns}/v1/api/connector/findByName?name=sscc-s3\""
      echo "      (vacio => PARAR; el instalador de apps no lo hace por ti)"
    fi
  fi
fi

# ---------------------------------------------------------------------------------------------------------
echo
if [[ -n "$LLM_LINE" ]]; then echo "$LLM_LINE"; fi
if [[ "$KO" -eq 0 ]]; then echo "${_G}RESULTADO: sin KO${_N} ($WN avisos)"; exit 0; fi
echo "${_R}RESULTADO: $KO KO${_N} ($WN avisos): no lances apps-installer hasta resolverlos"
exit 1

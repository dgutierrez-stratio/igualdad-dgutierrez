#!/usr/bin/env bash
# run-offline-tests.sh - pruebas offline del 2-apps-layer-kit. Sin red, sin AWS, sin cluster, sin docker real.
# Usa datos ficticios (cuenta 111111111111, cluster demo-x, tenant dev, token FAKE-TOKEN-0000), un directorio temporal
# y los mocks de tests/mock/bin (aws, kubectl, docker, getent). NUNCA toca el directorio vivo apps-layer/.
# Cada script se ejecuta con `env -i` para aislarlo del entorno real del usuario.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
S="$KIT/scripts"
W="$(mktemp -d "${TMPDIR:-/tmp}/kit-tests.XXXXXX")"
trap 'rm -rf "$W"' EXIT
LOGF="$W/all-output.log"; : > "$LOGF"      # toda la salida de los scripts: se comprueba que no contiene el token
export MOCK_LOG="$W/mock.log"; : > "$MOCK_LOG"
FAKE="FAKE-TOKEN-0000"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has()  { grep -qF -- "$2" "$1"; }
hasre(){ grep -qE -- "$2" "$1"; }

# cluster.env ficticio (el kit deriva los defaults de el)
cat > "$W/cluster.env" <<'EOF'
export CLUSTER_NAME=demo-x
export EXTERNAL_DOMAIN="${CLUSTER_NAME}.example.test"
export AWS_ACCOUNT_ID=111111111111
export AWS_REGION=eu-west-1
export CP_PROFILE=cloud-provisioner
EOF

BASEENV=(PYTHONUSERBASE="$HOME/.local" PATH="$HERE/mock/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin" HOME="$W/home" TMPDIR="$W"
  CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" MOCK_LOG="$MOCK_LOG" MOCK_STATE="$W"
  AWS_BIN="$HERE/mock/bin/aws" KEOS_WORKSPACE_DIR="$W/ws" MOCK_UNIVERSE_ZIP="$W/universe-fixture.zip" MOCK_UNIVERSE_LST="$W/universe-images-fixture.lst")
mkdir -p "$W/home" "$W/ws"
# universe-images.lst ficticio (lo "descarga" el gh falso)
printf 'stratio-releases.repo.stratio.com/stratio/connectors-loader:2.2.3\nstratio-releases.repo.stratio.com/stratio/keos-installer:1.4.6\n' > "$W/universe-images-fixture.lst"
# zip ficticio del universo (lo "descarga" el curl falso)
python3 -I -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('descriptors/demo.json','{\"fake\":true}'); z.close()" "$W/universe-fixture.zip"

# run_s OUTFILE script [args...] ; variables extra: EXTRA=(K=V ...) ; devuelve el codigo de salida del script
EXTRA=()
run_s() {
  local out="$1"; shift
  env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/$1" "${@:2}" > "$out" 2>&1 < "${STDIN_FILE:-/dev/null}"
  local rc=$?; cat "$out" >> "$LOGF"; return $rc
}
newdir() { local d="$W/$1"; rm -rf "$d"; mkdir -p "$d"; chmod 700 "$d"; echo "$d"; }   # el kit exige 700 en APPS_LAYER_DIR

echo "== 0) sintaxis (bash -n)"
for f in "$S"/*.sh "$HERE/run-offline-tests.sh" "$HERE"/mock/bin/*; do
  check "bash -n $(basename "$f")" bash -n "$f"
done

echo "== 1) render: matriz perfil x hosts, con token"
for prof in full minimal; do for hosts in false true; do
  D="$(newdir "r-$prof-$hosts")"; EXTRA=(APPS_LAYER_DIR="$D" KEOS_PROFILE="$prof" USE_TENANT_HOSTS="$hosts" LLM_TOKEN="$FAKE")
  label="perfil=$prof hosts=$hosts"
  if run_s "$W/o.txt" render-apps-layer.sh; then ok "render $label"; else bad "render $label"; sed 's/^/      /' "$W/o.txt"; continue; fi
  R="$D/demo-x.yaml"; T="$D/demo-x-dev.yaml"
  check "$label: ficheros generados" test -f "$R" -a -f "$T" -a -f "$D/.env"
  if [[ "$hosts" == false ]]; then check "$label: sin \${ residuales" bash -c "! grep -F '\${' '$R' '$T'"
  else check "$label: solo placeholders CCT \${tenantId}/\${external_domain}" bash -c "! sed -E 's/\\\$\{(tenantId|external_domain)\}//g' '$T' | grep -F '\${'"; fi
  check "$label: yq parsea root y tenant" bash -c "yq . '$R' >/dev/null && yq . '$T' >/dev/null"
  TJ="$(yq . "$T" | jq -s .)"
  check "$label: sin app hdfs/connector-dfs-hdfs" jq -e '[.. | objects | select(has("name")) | .name] | (index("hdfs")==null and index("connector-dfs-hdfs")==null)' <<<"$TJ"
  check "$label: sin variables *_HDFS (solo HDFS_USAGE_POLICY_POLICY_ENABLED de pit)" jq -e '[.. | objects | keys[] | select(test("HDFS"))] | unique == ["HDFS_USAGE_POLICY_POLICY_ENABLED"]' <<<"$TJ"
  check "$label: aparece connector-s3" jq -e '[.. | objects | select(has("name")) | .name] | index("connector-s3") != null' <<<"$TJ"
  check "$label: aparece S3_BUCKET_NAME correcto" jq -e '.[0].tenants[0].env.S3_BUCKET_NAME == "demo-x-internal-111111111111"' <<<"$TJ"
  check "$label: tenant dev, grupos dev-stratio-owners" bash -c "grep -q 'name: dev\$' '$T' && grep -q 'dev-stratio-owners' '$T'"
  check "$label: VIRTUALIZER_CREATE_LOADBALANCER false" jq -e '[.. | objects | select(has("VIRTUALIZER_CREATE_LOADBALANCER")) | .VIRTUALIZER_CREATE_LOADBALANCER][0] == false' <<<"$TJ"
  if [[ "$hosts" == false ]]; then
    check "$label: sin *_HAPROXY_HOST/PATH/SERVER_HOST por tenant" jq -e '[.. | objects | keys[] | select(test("HAPROXY_HOST$|HAPROXY_PATH$|SERVER_HOST$"))] | length == 0' <<<"$TJ"
    check "$label: un solo dlc-entity" jq -e '[.. | objects | select(.name? == "dlc-entity")] | length == 1' <<<"$TJ"
  else
    check "$label: hosts por tenant presentes" jq -e '[.. | objects | keys[] | select(test("HAPROXY_HOST$"))] | length > 5' <<<"$TJ"
    check "$label: dos dlc-entity (como el lab)" jq -e '[.. | objects | select(.name? == "dlc-entity")] | length == 2' <<<"$TJ"
  fi
  RJ="$(yq . "$R" | jq -s .)"
  check "$label: root solo tenant keos" jq -e '.[0].tenants|map(.name)==["keos"]' <<<"$RJ"
  if [[ "$prof" == minimal ]]; then
    check "$label: gobierno minimo (GOVERNANCE_UI_ENABLE_SEARCHER false, sin se-searcher)" bash -c "grep -q 'GOVERNANCE_UI_ENABLE_SEARCHER: \"false\"' '$R' && ! grep -q 'se-searcher' '$R'"
  else
    check "$label: gobierno completo (se-searcher, dg-datamarket-api)" bash -c "grep -q 'name: se-searcher' '$R' && grep -q 'name: dg-datamarket-api' '$R'"
  fi
  check "$label: .env modo 600" test "$(stat -c %a "$D/.env")" = 600
  check "$label: tenant YAML con token modo 600" test "$(stat -c %a "$T")" = 600
  check "$label: root YAML modo 644 (sin secretos)" test "$(stat -c %a "$R")" = 644
  check "$label: LLM_TOKEN inyectado en env del tenant" jq -e --arg t "$FAKE" '.[0].tenants[0].env.LLM_TOKEN == $t' <<<"$TJ"
  check "$label: cabecera 'contiene secretos' en el tenant" has "$T" "CONTIENE SECRETOS"
  check "$label: .env tiene LLM_TOKEN, AWS_REGION y KEOS_WORKSPACE_DIR" bash -c "grep -q '^export LLM_TOKEN=' '$D/.env' && grep -q '^export AWS_REGION=eu-west-1' '$D/.env' && grep -q '^export KEOS_WORKSPACE_DIR=$W/ws' '$D/.env'"
  check "$label: el token no sale por la salida del render" bash -c "! grep -F '$FAKE' '$W/o.txt'"
  check "$label: root sin LLM_TOKEN" bash -c "! grep -q 'LLM_TOKEN' '$R'"
  check "$label: kube-config generado 600" test "$(stat -c %a "$D/kube-config")" = 600
done; done

echo "== 2) render: genai, token y errores"
D="$(newdir r-notoken)"; EXTRA=(APPS_LAYER_DIR="$D")
if run_s "$W/o.txt" render-apps-layer.sh; then bad "sin token y genai activo debe abortar"; else ok "sin LLM_TOKEN y ENABLE_GENAI=true aborta"; fi
check "aborto: mensaje claro (LLM_TOKEN, import-llm-token.sh)" bash -c "grep -q 'LLM_TOKEN' '$W/o.txt' && grep -q 'import-llm-token.sh' '$W/o.txt'"
check "aborto: no escribe YAML" bash -c "[ ! -e '$D/demo-x.yaml' ] && [ ! -e '$D/demo-x-dev.yaml' ]"
D="$(newdir r-nogenai)"; EXTRA=(APPS_LAYER_DIR="$D" ENABLE_GENAI=false)
if run_s "$W/o.txt" render-apps-layer.sh; then ok "ENABLE_GENAI=false renderiza sin token"; else bad "ENABLE_GENAI=false"; cat "$W/o.txt"; fi
TJ="$(yq . "$D/demo-x-dev.yaml" | jq -s .)"
check "genai=false: sin apps genai-*, pit ni datamarket-agent" jq -e '[.. | objects | select(has("name")) | .name | select(startswith("genai-") or .=="pit" or .=="datamarket-agent")] | length == 0' <<<"$TJ"
check "genai=false: sin LLM_TOKEN ni variables *GENAI* en el YAML" jq -e '[.. | objects | keys[] | select(test("GENAI|LLM_TOKEN"))] | length == 0' <<<"$TJ"
check "genai=false: avisa en la salida" has "$W/o.txt" "ENABLE_GENAI=false"
check "genai=false: tenant 644 (sin secretos)" test "$(stat -c %a "$D/demo-x-dev.yaml")" = 644
D="$(newdir r-genai-env)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENABLE_GENAI=false)
run_s "$W/o.txt" render-apps-layer.sh
check "genai=false con token en entorno: no se inyecta en el YAML" bash -c "! grep -F '$FAKE' '$D/demo-x-dev.yaml'"
TJ="$(yq . "$W/r-full-false/demo-x-dev.yaml" | jq -s .)"
check "genai=true: genai-litellm/api/ui y pit presentes" jq -e '[.. | objects | select(has("name")) | .name] | (index("genai-litellm")!=null and index("genai-api")!=null and index("genai-ui")!=null and index("pit")!=null)' <<<"$TJ"
check "genai=true: ROCKET_GENAI_ENABLED / INTELLIGENCE_GENAI_ENABLED" jq -e '[.. | objects | keys[]] | (index("ROCKET_GENAI_ENABLED")!=null and index("INTELLIGENCE_GENAI_ENABLED")!=null)' <<<"$TJ"
D="$(newdir r-spaces)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="has space")
if run_s "$W/o.txt" render-apps-layer.sh; then bad "token con espacios debe abortar"; else ok "token con espacios aborta"; fi
D="$(newdir r-llm)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" LLM_PROVIDER=openai LLM_MODEL=gpt-5.4-mini)
run_s "$W/o.txt" render-apps-layer.sh
check "LLM_PROVIDER/LLM_MODEL opcionales (no secretos) se reproducen" bash -c "grep -q 'LLM_PROVIDER: \"openai\"' '$D/demo-x-dev.yaml' && grep -q 'LLM_MODEL: \"gpt-5.4-mini\"' '$D/demo-x-dev.yaml'"

echo "== 3) ENVIRONMENT_SIZE y variables invalidas"
D="$(newdir r-size)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=XL)
if run_s "$W/o.txt" render-apps-layer.sh; then bad "ENVIRONMENT_SIZE=XL debe abortar"; else ok "ENVIRONMENT_SIZE=XL aborta en render"; fi
check "mensaje de ENVIRONMENT_SIZE" has "$W/o.txt" "ENVIRONMENT_SIZE"
check "no se genera nada con size invalido" bash -c "[ ! -e '$D/demo-x.yaml' ]"
for s in s3-requisites.sh launch-apps-layer.sh check-apps-layer.sh; do
  EXTRA=(APPS_LAYER_DIR="$D" ENVIRONMENT_SIZE=XL); if run_s "$W/o.txt" "$s"; then bad "$s con size invalido"; else ok "$s aborta con ENVIRONMENT_SIZE invalido"; fi
done
D="$(newdir r-pit)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=PIT)
check "ENVIRONMENT_SIZE=PIT es valido" run_s "$W/o.txt" render-apps-layer.sh
check "PIT queda en el YAML" has "$D/demo-x-dev.yaml" 'ENVIRONMENT_SIZE: "PIT"'
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENABLE_GENAI=maybe); if run_s "$W/o.txt" render-apps-layer.sh; then bad "ENABLE_GENAI=maybe"; else ok "ENABLE_GENAI invalido aborta"; fi
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" KEOS_PROFILE=tiny); if run_s "$W/o.txt" render-apps-layer.sh; then bad "KEOS_PROFILE=tiny"; else ok "KEOS_PROFILE invalido aborta"; fi
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" TENANT_NAME=keos); if run_s "$W/o.txt" render-apps-layer.sh; then bad "TENANT_NAME=keos"; else ok "TENANT_NAME=keos aborta"; fi

echo "== 4) render: .bak, idempotencia y conservacion de secretos"
D="$(newdir r-keep)"
cat > "$D/.env" <<'EOF'
export DOCKER_DIND_ENABLED=true
export S3_BUCKET_ACCESS_KEY='AKIAFAKEKEEP0001'
export S3_BUCKET_SECRET_KEY='fake/secret+keep'
export LLM_TOKEN='FAKE-TOKEN-0000'
export OTRA_COSA=1
EOF
chmod 644 "$D/.env"; echo "viejo" > "$D/demo-x.yaml"
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" render-apps-layer.sh
check "render con .env previo: ok sin LLM_TOKEN en entorno (lo toma del .env)" test -f "$D/demo-x-dev.yaml"
check ".env previo: copia .env.bak" test -f "$D/.env.bak"
check ".env.bak es 600 (puede tener secretos)" test "$(stat -c %a "$D/.env.bak")" = 600
check "YAML previo: copia demo-x.yaml.bak con el contenido viejo" bash -c "[ \"\$(cat '$D/demo-x.yaml.bak')\" = viejo ]"
check ".env regenerado conserva S3_BUCKET_ACCESS_KEY/SECRET_KEY/LLM_TOKEN (1 linea cada una)" bash -c "[ \$(grep -c '^export S3_BUCKET_ACCESS_KEY=' '$D/.env') = 1 ] && [ \$(grep -c '^export S3_BUCKET_SECRET_KEY=' '$D/.env') = 1 ] && [ \$(grep -c '^export LLM_TOKEN=' '$D/.env') = 1 ]"
check ".env regenerado: modo 600" test "$(stat -c %a "$D/.env")" = 600
check ".env regenerado: DOCKER_DIND_ENABLED=false (del template)" has "$D/.env" "export DOCKER_DIND_ENABLED=false"
check "el token del .env previo se inyecto en el YAML del tenant" has "$D/demo-x-dev.yaml" "$FAKE"
run_s "$W/o2.txt" render-apps-layer.sh
check "segundo render idempotente (sin cambios, sin nuevas copias)" bash -c "grep -c 'sin cambios' '$W/o2.txt' | grep -qE '^[5-6]\$' && ! grep -q 'copia de seguridad' '$W/o2.txt'"
EXTRA=(APPS_LAYER_DIR="$D" ENVIRONMENT_SIZE=PIT); run_s "$W/o3.txt" render-apps-layer.sh
check "cambio de variable: segunda copia con fecha (.bak ya existia)" bash -c "ls '$D'/demo-x.yaml.bak.* >/dev/null 2>&1"
check "dry-run no escribe" bash -c "D2='$W/r-dry'; mkdir -p \$D2; chmod 700 \$D2; env -i ${BASEENV[*]} APPS_LAYER_DIR=\$D2 LLM_TOKEN=$FAKE bash '$S/render-apps-layer.sh' --dry-run >/dev/null 2>&1 && [ -z \"\$(ls -A \$D2)\" ]"

echo "== 5) import-llm-token.sh"
Y="$W/lab.yaml"
cat > "$Y" <<EOF
env:
  UNIVERSE_VERSION: "15.1.0"
tenants:
- name: stratio
  env:
    LLM_TOKEN: $FAKE
  apps:
  - parallel:
    - name: genai-api
EOF
D="$(newdir i-1)"; EXTRA=(APPS_LAYER_DIR="$D")
run_s "$W/o.txt" import-llm-token.sh "$Y"; rc=$?
check "import: exit 0" test $rc -eq 0
check "import: salida exacta 'LLM_TOKEN importado (15 caracteres)' (sin contar el aviso de APPS_LAYER_DIR)" bash -c "[ \"\$(grep -v 'APPS_LAYER_DIR efectivo' '$W/o.txt')\" = 'LLM_TOKEN importado (15 caracteres)' ]"
check "import: el token no sale en la salida" bash -c "! grep -F '$FAKE' '$W/o.txt'"
check "import: .env 600 con la linea" bash -c "[ \$(stat -c %a '$D/.env') = 600 ] && grep -q '^export LLM_TOKEN=' '$D/.env'"
run_s "$W/o.txt" import-llm-token.sh "$Y"
check "import idempotente: una sola linea" bash -c "[ \$(grep -c 'LLM_TOKEN' '$D/.env') = 1 ]"
check "import: el valor del .env es el del YAML" bash -c "env -i bash -c 'source \"$D/.env\"; [ \"\$LLM_TOKEN\" = \"$FAKE\" ]'"
echo "export KEEP_ME=1" >> "$D/.env"; run_s "$W/o.txt" import-llm-token.sh "$Y"
check "import conserva otras lineas del .env" has "$D/.env" "KEEP_ME=1"
# mismo valor en varios sitios: valido; valores distintos: error solo con rutas
cat > "$W/multi-same.yaml" <<EOF
env:
  LLM_TOKEN: $FAKE
tenants:
- name: a
  env:
    LLM_TOKEN: $FAKE
EOF
cat > "$W/multi-diff.yaml" <<EOF
env:
  LLM_TOKEN: $FAKE
tenants:
- name: a
  apps:
  - parallel:
    - name: genai-api
      env:
        LLM_TOKEN: OTRO-FAKE-9999
EOF
D="$(newdir i-2)"; EXTRA=(APPS_LAYER_DIR="$D"); check "import: mismo valor en varios niveles es valido" run_s "$W/o.txt" import-llm-token.sh "$W/multi-same.yaml"
D="$(newdir i-3)"; EXTRA=(APPS_LAYER_DIR="$D")
if run_s "$W/o.txt" import-llm-token.sh "$W/multi-diff.yaml"; then bad "valores distintos deben abortar"; else ok "valores distintos abortan"; fi
check "valores distintos: lista solo rutas (sin valores)" bash -c "grep -q 'LLM_TOKEN' '$W/o.txt' && ! grep -qE 'FAKE-TOKEN-0000|OTRO-FAKE-9999' '$W/o.txt'"
check "valores distintos: no escribe .env" bash -c "[ ! -e '$D/.env' ]"
printf 'env:\n  X: 1\n' > "$W/none.yaml"; D="$(newdir i-4)"; EXTRA=(APPS_LAYER_DIR="$D")
if run_s "$W/o.txt" import-llm-token.sh "$W/none.yaml"; then bad "sin token debe fallar"; else ok "YAML sin LLM_TOKEN falla"; fi
D="$(newdir i-5)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" import-llm-token.sh
check "import desde variable de entorno" bash -c "grep -q '^export LLM_TOKEN=' '$D/.env' && ! grep -F '$FAKE' '$W/o.txt'"
D="$(newdir i-6)"; EXTRA=(APPS_LAYER_DIR="$D"); if run_s "$W/o.txt" import-llm-token.sh; then bad "sin fuente"; else ok "sin fichero ni entorno falla"; fi
check "import con 'set -x' no filtra el token" bash -c "env -i ${BASEENV[*]} APPS_LAYER_DIR='$W/i-7' bash -x '$S/import-llm-token.sh' '$Y' > '$W/o.txt' 2>&1; ! grep -F '$FAKE' '$W/o.txt'"
roundtrip() {
  ( source "$S/lib.sh"; local t="a'b\"c\$d e" f="$W/rt.env"; : > "$f"
    emit_export X "$t" | env_replace "$f" X
    [[ "$(env_get_var "$f" X)" == "$t" ]] || exit 1
    # y el .env debe poder hacerse source con bash (como hace el entrypoint)
    got="$(env -i bash -c 'source "$1"; printf %s "$X"' _ "$f")"; [[ "$got" == "$t" ]] )
}
check "round-trip de comillas simples/dobles y \$ en el .env (emit_export/env_get_var/source)" roundtrip

echo "== 6) s3-requisites.sh (aws simulado)"
D="$(newdir s-1)"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_BUCKET=0 MOCK_STACK=0)
check "plan (defecto) termina bien" run_s "$W/o.txt" s3-requisites.sh
check "plan muestra el comando de apply y el bucket" bash -c "grep -q 'cloudformation deploy' '$W/o.txt' && grep -q 'demo-x-internal-111111111111' '$W/o.txt'"
WRITE_RE='cloudformation (deploy|delete-stack|create-stack|update-stack)|s3 (rm|mb|rb|cp|sync)|s3api (create-|put-|delete-|abort-)|iam (create|put|delete|attach|detach|update)|secretsmanager (create|put|delete|update)'
check "plan: ninguna operacion de escritura en las llamadas a aws" bash -c "! grep -E '$WRITE_RE' '$MOCK_LOG'"
check "plan: solo lecturas conocidas (sts, describe, head, get, validate)" bash -c "! grep -vE '^(sts get-caller-identity|cloudformation (describe-stacks|validate-template)|s3api head-bucket|iam get-user|secretsmanager describe-secret) ' '$MOCK_LOG'"
check "plan no crea .env" bash -c "[ ! -e '$D/.env' ]"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_ACCOUNT=999999999999)
if run_s "$W/o.txt" s3-requisites.sh plan; then bad "cuenta distinta debe abortar"; else ok "plan con cuenta distinta aborta"; fi
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D")
if run_s "$W/o.txt" s3-requisites.sh apply; then bad "apply sin tty debe abortar"; else ok "apply sin tty aborta"; fi
check "apply sin tty: mensaje de terminal interactiva" has "$W/o.txt" "terminal interactiva"
check "apply sin tty: no se llamo a deploy" bash -c "! grep -q 'cloudformation deploy' '$MOCK_LOG'"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1); printf 'otro\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"
if run_s "$W/o.txt" s3-requisites.sh apply; then bad "apply con confirmacion erronea"; else ok "apply con confirmacion erronea aborta"; fi
check "apply erroneo: no se llamo a deploy" bash -c "! grep -q 'cloudformation deploy' '$MOCK_LOG'"
: > "$MOCK_LOG"; printf 'demo-x\n' > "$W/in.txt"; EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=0)
run_s "$W/o.txt" s3-requisites.sh apply   # el stack simulado no existe tras el deploy: debe fallar al comprobar el estado, pero SI llama a deploy
check "apply confirmado: llama a deploy con CAPABILITY_NAMED_IAM y parametros" bash -c "grep 'cloudformation deploy' '$MOCK_LOG' | grep -q 'CAPABILITY_NAMED_IAM' && grep 'cloudformation deploy' '$MOCK_LOG' | grep -q 'InternalS3BucketUser=demo-x-s3' && grep 'cloudformation deploy' '$MOCK_LOG' | grep -q -- '--stack-name demo-x-requisites'"
STDIN_FILE=""
# conflicto: bucket existente sin stack
: > "$MOCK_LOG"; printf 'demo-x\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"; EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_BUCKET=1 MOCK_STACK=0)
if run_s "$W/o.txt" s3-requisites.sh apply; then bad "bucket ajeno"; else ok "apply con bucket preexistente no gestionado aborta"; fi
check "conflicto de bucket: no deploy" bash -c "! grep -q 'cloudformation deploy' '$MOCK_LOG'"
STDIN_FILE=""
# env: claves al .env sin imprimir, idempotente
D="$(newdir s-2)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1)
check "env termina bien" run_s "$W/o.txt" s3-requisites.sh env
run_s "$W/o2.txt" s3-requisites.sh env
check "env: .env 600" test "$(stat -c %a "$D/.env")" = 600
check "env: ACCESS/SECRET/REGION presentes una sola vez" bash -c "[ \$(grep -c '^export S3_BUCKET_ACCESS_KEY=' '$D/.env') = 1 ] && [ \$(grep -c '^export S3_BUCKET_SECRET_KEY=' '$D/.env') = 1 ] && [ \$(grep -c '^export AWS_REGION=' '$D/.env') = 1 ]"
check "env: valores correctos al hacer source" bash -c "env -i bash -c 'source \"$D/.env\"; [ \"\$S3_BUCKET_ACCESS_KEY\" = AKIAMOCKFAKE0000 ] && [ \"\$S3_BUCKET_SECRET_KEY\" = \"FAKE/secret+KEY0000\" ] && [ \"\$AWS_REGION\" = eu-west-1 ]'"
check "env: las claves no salen por la salida" bash -c "! grep -qE 'AKIAMOCKFAKE0000|FAKE/secret\\+KEY0000' '$W/o.txt' '$W/o2.txt'"
check "env: solo lecturas AWS" bash -c "! grep -E '$WRITE_RE' '$MOCK_LOG'"
printf 'export KEEP=1\nexport S3_BUCKET_ACCESS_KEY=old\n' > "$D/.env"; run_s "$W/o.txt" s3-requisites.sh env
check "env sustituye la clave vieja y conserva otras lineas" bash -c "grep -q KEEP=1 '$D/.env' && [ \$(grep -c S3_BUCKET_ACCESS_KEY '$D/.env') = 1 ] && ! grep -q '=old' '$D/.env'"
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=0); if run_s "$W/o.txt" s3-requisites.sh env; then bad "env sin stack"; else ok "env sin stack falla"; fi
# status
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si); check "status" run_s "$W/o.txt" s3-requisites.sh status
check "status muestra solo nombres (no valores)" bash -c "grep -q 'S3_BUCKET_ACCESS_KEY presente' '$W/o.txt' && ! grep -qE 'AKIA|FAKE/secret' '$W/o.txt'"
# delete
D="$(newdir s-3)"; printf 'export S3_BUCKET_ACCESS_KEY=x\nexport S3_BUCKET_SECRET_KEY=y\nexport KEEP=1\n' > "$D/.env"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si)
if run_s "$W/o.txt" s3-requisites.sh delete; then bad "delete sin tty"; else ok "delete sin tty aborta"; fi
check "delete sin tty: sin operaciones de borrado" bash -c "! grep -E 'delete-|abort-' '$MOCK_LOG'"
EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si MOCK_VERSIONS=1)
: > "$MOCK_LOG"; printf 'demo-x\n999999999999\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"
if run_s "$W/o.txt" s3-requisites.sh delete; then bad "delete con cuenta mal escrita"; else ok "delete con confirmacion (cuenta) erronea aborta"; fi
check "delete erroneo: sin operaciones de borrado" bash -c "! grep -E 'delete-|abort-' '$MOCK_LOG'"
: > "$MOCK_LOG"; printf 'nombre-malo\n' > "$W/in.txt"
if run_s "$W/o.txt" s3-requisites.sh delete; then bad "delete con nombre mal escrito"; else ok "delete con confirmacion (nombre) erronea aborta"; fi
check "delete erroneo (nombre): sin operaciones de borrado" bash -c "! grep -E 'delete-|abort-' '$MOCK_LOG'"
rm -f "$W/versions_done"; : > "$MOCK_LOG"; printf 'demo-x\n111111111111\n' > "$W/in.txt"
check "delete con confirmacion correcta termina bien" run_s "$W/o.txt" s3-requisites.sh delete
check "delete: vacia versiones, borra stack y luego bucket" bash -c "grep -n 'delete-objects' '$MOCK_LOG' >/dev/null && a=\$(grep -n 'delete-objects' '$MOCK_LOG' | head -1 | cut -d: -f1) && b=\$(grep -n 'cloudformation delete-stack' '$MOCK_LOG' | head -1 | cut -d: -f1) && c=\$(grep -n 's3api delete-bucket' '$MOCK_LOG' | head -1 | cut -d: -f1) && [ \$a -lt \$b ] && [ \$b -lt \$c ]"
check "delete: limpia las claves S3 del .env y conserva el resto" bash -c "! grep -q S3_BUCKET '$D/.env' && grep -q KEEP=1 '$D/.env'"
: > "$MOCK_LOG"; printf 'demo-x\n111111111111\n' > "$W/in.txt"; EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BUCKET=1 MOCK_CLUSTER=otro-cluster)
if run_s "$W/o.txt" s3-requisites.sh delete; then ok "delete con etiqueta distinta pero bucket declarado por el stack: permitido"; else bad "delete debe pasar: el stack declara el bucket (pertenencia)"; fi
: > "$MOCK_LOG"; printf 'demo-x\n111111111111\n' > "$W/in.txt"; EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=0 MOCK_BUCKET=1 MOCK_CLUSTER=otro-cluster)
if run_s "$W/o.txt" s3-requisites.sh delete; then bad "bucket de otro cluster"; else ok "delete de un bucket que no es del cluster (sin stack, etiqueta distinta) aborta"; fi
check "bucket ajeno: sin borrados" bash -c "! grep -E 'delete-|abort-' '$MOCK_LOG'"
STDIN_FILE=""

echo "== 7) launch-apps-layer.sh"
D="$(newdir l-1)"; mkdir -p "$D/aws"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" KUBECONFIG_SRC="$D/kube-config")
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" > "$W/launch.out" 2> "$W/launch.err"; rc=$?
cat "$W/launch.out" "$W/launch.err" >> "$LOGF"
check "launch (sin --run) termina bien" test $rc -eq 0
check "launch imprime docker run con nombre apps-layer-demo-x" bash -c "grep -q '^docker run -it --rm' '$W/launch.out' && grep -q -- '--name apps-layer-demo-x' '$W/launch.out'"
check "launch: mounts /apps-layer, /workspace, docker.sock y aws ro" bash -c "grep -q -- '-v $D:/apps-layer' '$W/launch.out' && grep -q -- '-v $W/ws:/workspace' '$W/launch.out' && grep -q 'docker.sock' '$W/launch.out' && grep -q -- '$D/aws:/root/.aws:ro' '$W/launch.out'"
check "launch: --add-host admin.<dominio>:<IP del NLB>" has "$W/launch.out" "--add-host admin.demo-x.example.test:10.1.2.3"
check "launch: --net host --cgroupns host + imagen por defecto" bash -c "grep -q -- '--net host' '$W/launch.out' && grep -q -- '--cgroupns host' '$W/launch.out' && grep -q 'qa.int.stratio.com/stratio/apps-layer-automation:15.1-0.1.0-SNAPSHOT' '$W/launch.out'"
check "launch: NO ejecuta docker sin --run" bash -c "! grep -q '^docker ' '$MOCK_LOG'"
check "launch: kubectl solo lectura (get svc)" bash -c "grep -q '^kubectl .*get svc' '$MOCK_LOG' && ! grep -qE '^kubectl .*(apply|delete|exec|patch|create)' '$MOCK_LOG'"
DIG="sha256:a745cac6f9a30b68e9e5ff5312c0b584ac78ffb2dc955ad3430661617de6d37a"
EXTRA=(APPS_LAYER_DIR="$D" APPS_LAYER_IMAGE_DIGEST="$DIG"); run_s "$W/o.txt" launch-apps-layer.sh
check "launch: imagen fijada por digest" has "$W/o.txt" "apps-layer-automation:15.1-0.1.0-SNAPSHOT@$DIG"
EXTRA=(APPS_LAYER_DIR="$D" APPS_LAYER_IMAGE_DIGEST="sha256:corto"); if run_s "$W/o.txt" launch-apps-layer.sh; then bad "digest invalido"; else ok "digest invalido aborta"; fi
EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9); run_s "$W/o.txt" launch-apps-layer.sh
check "launch: NLB_IP fijado manualmente" has "$W/o.txt" "admin.demo-x.example.test:10.9.9.9"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9)
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --run > "$W/o.txt" 2>&1; rc=$?; cat "$W/o.txt" >> "$LOGF"
check "launch --run ejecuta docker run (mock)" bash -c "grep -q '^docker run -it --rm --name apps-layer-demo-x' '$MOCK_LOG'"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9 MOCK_DOCKER_PS="apps-layer-other qa.int.stratio.com/stratio/apps-layer-automation:15.1")
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --run > "$W/o.txt" 2>&1; rc=$?; cat "$W/o.txt" >> "$LOGF"
check "launch --run aborta si ya hay un contenedor apps-layer en marcha" bash -c "[ $rc -ne 0 ] && ! grep -q '^docker run' '$MOCK_LOG'"
D2="$(newdir l-2)"; EXTRA=(APPS_LAYER_DIR="$D2" NLB_IP=10.9.9.9)
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --run > "$W/o.txt" 2>&1; rc=$?
check "launch --run aborta si faltan ficheros (no lanza)" bash -c "[ $rc -ne 0 ]"

echo "== 8) check-apps-layer.sh"
D="$W/l-1"; : > "$MOCK_LOG"
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si)
run_s "$W/o.txt" check-apps-layer.sh --no-cluster; rc=$?
check "check: KO por faltar claves S3 en .env (nombres)" bash -c "[ $rc -ne 0 ] && grep -q 'S3_BUCKET_ACCESS_KEY' '$W/o.txt' && grep -q 'RESULTADO' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si); run_s "$W/o.txt" s3-requisites.sh env
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si)
run_s "$W/o.txt" check-apps-layer.sh --no-cluster; rc=$?
check "check completo OK (exit 0)" test $rc -eq 0
check "check: 'LLM_TOKEN OK (15 caracteres) → genai-*: genai-api, genai-litellm'" has "$W/o.txt" "LLM_TOKEN OK (15 caracteres) → genai-*: genai-api, genai-litellm"
check "check: no imprime secretos" bash -c "! grep -qE '$FAKE|AKIAMOCKFAKE0000|FAKE/secret' '$W/o.txt'"
check "check: solo lecturas AWS" bash -c "! grep -E '$WRITE_RE' '$MOCK_LOG'"
chmod 644 "$D/.env"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster; rc=$?
check "check: .env 644 es KO" bash -c "[ $rc -ne 0 ] && grep -q '.env con modo 644' '$W/o.txt'"; chmod 600 "$D/.env"
sed -i "s/^export LLM_TOKEN=.*/export LLM_TOKEN='OTRO'/" "$D/.env"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster; rc=$?
check "check: LLM_TOKEN distinto entre .env y YAML es KO" bash -c "[ $rc -ne 0 ] && grep -q 'difieren' '$W/o.txt'"
sed -i "/^export LLM_TOKEN=/d" "$D/.env"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster; rc=$?
check "check: sin LLM_TOKEN en .env es KO" bash -c "[ $rc -ne 0 ] && grep -q 'LLM_TOKEN ausente' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si MOCK_TENANT_DEV=1 MOCK_SSCC="")
run_s "$W/o.txt" check-apps-layer.sh --no-aws; true
check "check cluster: sin pod de connectors-management propone el comando sscc-s3" has "$W/o.txt" "findByName?name=sscc-s3"
check "check: kubectl solo de lectura" bash -c "! grep -E '^kubectl .*(apply|delete|patch|create|scale)' '$MOCK_LOG'"

echo "== 9) el token no aparece en plantillas, scripts, logs ni README"
check "plantillas/scripts/README/kit.env.example sin el token ficticio" bash -c "! grep -rlF '$FAKE' '$KIT/templates' '$KIT/scripts' '$KIT/README.md' '$KIT/kit.env.example'"
check "plantillas sin ningun valor de LLM_TOKEN (solo el marcador)" bash -c "! grep -E 'LLM_TOKEN: *[^_ #]' '$KIT/templates/tenant.yaml.tpl'"
check "ninguna salida de los scripts contiene el token" bash -c "! grep -F '$FAKE' '$LOGF'"
check "ninguna salida de los scripts contiene claves S3 ficticias" bash -c "! grep -qE 'AKIAMOCKFAKE0000|FAKE/secret\\+KEY0000' '$LOGF'"
check "ninguna salida de los scripts contiene las claves ficticias del perfil AWS" bash -c "! grep -qE 'AKIAMOCKPROFILE0000|FAKE/profile\\+SECRET0000' '$LOGF'"
check "no se ha tocado el directorio vivo apps-layer (los tests usan $W)" bash -c "! grep -q '/stratio/e/igualdad/apps-layer' '$MOCK_LOG'"

echo "== 10) directorio de ejecucion efimero: default en /tmp, 700 y verificacion de permisos"
# default sin APPS_LAYER_DIR: ${TMPDIR:-/tmp}/apps-layer-<cluster> (TMPDIR=$W en los tests)
EXTRA=(LLM_TOKEN="$FAKE"); rm -rf "$W/apps-layer-demo-x"
check "default: render sin APPS_LAYER_DIR usa \$TMPDIR/apps-layer-<cluster>" run_s "$W/o.txt" render-apps-layer.sh
D="$W/apps-layer-demo-x"
check "default: el directorio existe con modo 700" test "$(stat -c %a "$D" 2>/dev/null)" = 700
check "default: contiene YAML raiz, tenant y .env" test -f "$D/demo-x.yaml" -a -f "$D/demo-x-dev.yaml" -a -f "$D/.env"
check "default: el .env lleva APPS_LAYER_DIR/KEOS_WORKSPACE_DIR del entorno" bash -c "grep -q '^export KEOS_WORKSPACE_DIR=$W/ws' '$D/.env'"
check "default: avisa de que el directorio es efimero" has "$W/o.txt" "efimero"
# default real (/tmp) sin crear nada: solo se resuelve la variable
got="$(env -i HOME="$W/home" PATH="$PATH" CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" bash -c "source '$S/lib.sh'; load_kit_env; printf %s \"\$APPS_LAYER_DIR\"" 2>/dev/null)"
check "default sin TMPDIR: /tmp/apps-layer-demo-x" test "$got" = "/tmp/apps-layer-demo-x"
got="$(env -i HOME="$W/home" PATH="$PATH" TMPDIR="$W/otro/" CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" bash -c "source '$S/lib.sh'; load_kit_env; printf %s \"\$APPS_LAYER_DIR\"" 2>/dev/null)"
check "default con TMPDIR (barra final normalizada): \$TMPDIR/apps-layer-demo-x" test "$got" = "$W/otro/apps-layer-demo-x"
got="$(env -i HOME="$W/home" PATH="$PATH" CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" bash -c "source '$S/lib.sh'; load_kit_env; printf %s \"\$KEOS_WORKSPACE_DIR|\$KUBECONFIG_SRC\"" 2>/dev/null)"
PARENT="$(cd "$KIT/.." && pwd)"
check "KEOS_WORKSPACE_DIR por defecto = raiz del workspace (<kit>/..) y kubeconfig en 1-aws-cluster/estado" test "$got" = "$PARENT|$PARENT/1-aws-cluster/estado/kubeconfig-demo-x"
# un directorio ya existente y privado se acepta
D="$(newdir e-ok)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); check "directorio existente 700 del usuario: se acepta" run_s "$W/o.txt" render-apps-layer.sh
# aborto con permisos abiertos: render, import y s3 env no escriben nada
for mode in 775 755 770 701; do
  D="$W/e-open-$mode"; rm -rf "$D"; mkdir -p "$D"; chmod "$mode" "$D"
  EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE")
  if run_s "$W/o.txt" render-apps-layer.sh; then bad "render con directorio modo $mode debe abortar"; else ok "render aborta si el directorio existe con modo $mode"; fi
  check "modo $mode: mensaje 'no seguro' y chmod 700 sugerido" bash -c "grep -q 'no seguro' '$W/o.txt' && grep -q 'chmod 700' '$W/o.txt'"
  check "modo $mode: no se escribe ningun fichero" bash -c "[ -z \"\$(ls -A '$D')\" ]"
  check "modo $mode: el directorio no se modifica (sigue $mode)" test "$(stat -c %a "$D")" = "$mode"
done
D="$W/e-open-775"
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); if run_s "$W/o.txt" import-llm-token.sh; then bad "import con directorio abierto"; else ok "import-llm-token.sh aborta con el directorio abierto"; fi
check "import abortado: no crea .env" bash -c "[ ! -e '$D/.env' ]"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1)
if run_s "$W/o.txt" s3-requisites.sh env; then bad "s3 env con directorio abierto"; else ok "s3-requisites.sh env aborta con el directorio abierto"; fi
check "s3 env abortado: no lee el secreto ni escribe .env" bash -c "[ ! -e '$D/.env' ] && ! grep -q 'get-secret-value' '$MOCK_LOG'"
EXTRA=(APPS_LAYER_DIR="$D"); if run_s "$W/o.txt" render-apps-layer.sh --dry-run; then bad "dry-run con directorio abierto"; else ok "render --dry-run tambien verifica el directorio existente"; fi
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" launch-apps-layer.sh; true
check "launch avisa del directorio no seguro" has "$W/o.txt" "no seguro"
EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9); env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --run > "$W/o.txt" 2>&1; rc=$?; cat "$W/o.txt" >> "$LOGF"
check "launch --run aborta con el directorio abierto" test $rc -ne 0
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check marca KO el directorio no seguro" bash -c "[ $rc -ne 0 ] && grep -q 'directorio no seguro' '$W/o.txt'"
# enlace simbolico y propietario distinto
rm -rf "$W/e-real" "$W/e-link"; mkdir -p "$W/e-real"; chmod 700 "$W/e-real"; ln -s "$W/e-real" "$W/e-link"
EXTRA=(APPS_LAYER_DIR="$W/e-link" LLM_TOKEN="$FAKE"); if run_s "$W/o.txt" render-apps-layer.sh; then bad "enlace simbolico"; else ok "render aborta si APPS_LAYER_DIR es un enlace simbolico"; fi
check "enlace simbolico: mensaje y nada escrito" bash -c "grep -q 'enlace simbolico' '$W/o.txt' && [ -z \"\$(ls -A '$W/e-real')\" ]"
check "verify_private_dir: un directorio de otro usuario (/) no es aceptable" bash -c "source '$S/lib.sh'; ! verify_private_dir / >/dev/null"
check "verify_private_dir: un fichero no es aceptable" bash -c "source '$S/lib.sh'; ! verify_private_dir '$W/cluster.env' >/dev/null"
check "ensure_private_dir crea con 700 aunque umask sea 000 y anidado" bash -c "source '$S/lib.sh'; umask 000; ensure_private_dir '$W/nest/a/b' 2>/dev/null && [ \$(stat -c %a '$W/nest/a/b') = 700 ]"

echo "== 11) kube-config y aws/ (perfil cloud-provisioner) generados por render-apps-layer.sh"
# kube-config: copia de KUBECONFIG_SRC cuando existe
printf 'FAKE-KUBECONFIG-CONTENT\n' > "$W/src-kubeconfig"; chmod 600 "$W/src-kubeconfig"
D="$(newdir k-1)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" KUBECONFIG_SRC="$W/src-kubeconfig")
check "render con KUBECONFIG_SRC existente" run_s "$W/o.txt" render-apps-layer.sh
check "kube-config copiado de KUBECONFIG_SRC (modo 600)" bash -c "cmp -s '$W/src-kubeconfig' '$D/kube-config' && [ \$(stat -c %a '$D/kube-config') = 600 ]"
check "kube-config copiado: no se llamo a eks update-kubeconfig" bash -c "! grep -q 'eks update-kubeconfig' '$MOCK_LOG'"
# kube-config: aws eks update-kubeconfig cuando no hay origen
D="$(newdir k-2)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" KUBECONFIG_SRC="$W/no-existe")
check "render sin KUBECONFIG_SRC" run_s "$W/o.txt" render-apps-layer.sh
check "kube-config generado con aws eks update-kubeconfig --name demo-x (modo 600)" bash -c "grep -q 'eks update-kubeconfig.*--name demo-x' '$MOCK_LOG' && grep -q -- '--kubeconfig $D/kube-config' '$MOCK_LOG' && [ \$(stat -c %a '$D/kube-config') = 600 ]"
echo "contenido-previo" > "$D/kube-config"; run_s "$W/o2.txt" render-apps-layer.sh
check "kube-config existente no se sobrescribe (idempotente)" bash -c "[ \"\$(cat '$D/kube-config')\" = contenido-previo ] && grep -q 'sin cambios: $D/kube-config' '$W/o2.txt'"
# aws/: solo el perfil cloud-provisioner
D="$(newdir a-1)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE")
run_s "$W/o.txt" render-apps-layer.sh; rc=$?
check "aws/: render termina bien" test $rc -eq 0
check "aws/: directorio 700 y ficheros credentials/config 600" bash -c "[ \$(stat -c %a '$D/aws') = 700 ] && [ \$(stat -c %a '$D/aws/credentials') = 600 ] && [ \$(stat -c %a '$D/aws/config') = 600 ]"
check "aws/: solo contiene credentials y config (sin temporales)" bash -c "[ \"\$(ls -A '$D/aws' | sort | tr '\n' ' ')\" = 'config credentials ' ]"
check "aws/credentials: una sola seccion [cloud-provisioner] con las dos claves" bash -c "[ \$(grep -c '^\[' '$D/aws/credentials') = 1 ] && grep -q '^\[cloud-provisioner\]\$' '$D/aws/credentials' && grep -q '^aws_access_key_id = AKIAMOCKPROFILE0000\$' '$D/aws/credentials' && grep -q '^aws_secret_access_key = FAKE/profile+SECRET0000\$' '$D/aws/credentials'"
check "aws/config: [profile cloud-provisioner] con region eu-west-1 y nada mas" bash -c "[ \"\$(cat '$D/aws/config')\" = \"\$(printf '[profile cloud-provisioner]\nregion = eu-west-1')\" ]"
check "aws/: las claves del perfil no salen por la salida" bash -c "! grep -qE 'AKIAMOCKPROFILE0000|FAKE/profile\\+SECRET0000' '$W/o.txt'"
check "aws/: se leyeron con 'configure get --profile cloud-provisioner' (nunca por argv las claves)" bash -c "grep -q 'configure get aws_access_key_id' '$MOCK_LOG' && ! grep -qE 'AKIAMOCKPROFILE0000|FAKE/profile' '$MOCK_LOG'"
run_s "$W/o2.txt" render-apps-layer.sh
check "aws/: segunda ejecucion idempotente (sin cambios)" bash -c "grep -q 'sin cambios: $D/aws/credentials' '$W/o2.txt' && grep -q 'sin cambios: $D/aws/config' '$W/o2.txt'"
chmod 644 "$D/aws/credentials"; run_s "$W/o2.txt" render-apps-layer.sh
check "aws/: credentials vuelve a 600 si estaba abierto" test "$(stat -c %a "$D/aws/credentials")" = 600
echo "[otro]" > "$D/aws/credentials"; run_s "$W/o2.txt" render-apps-layer.sh
check "aws/: credentials alterado se regenera con solo el perfil" bash -c "grep -q 'AKIAMOCKPROFILE0000' '$D/aws/credentials' && ! grep -q 'otro' '$D/aws/credentials'"
check "launch ya no avisa de falta de aws/ tras el render" bash -c "env -i ${BASEENV[*]} APPS_LAYER_DIR='$D' NLB_IP=10.9.9.9 bash '$S/launch-apps-layer.sh' 2>&1 >/dev/null | grep -q 'falta .*aws'; [ \$? -ne 0 ]"
# --no-aws-creds
D="$(newdir a-2)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE")
check "--no-aws-creds: render termina bien" run_s "$W/o.txt" render-apps-layer.sh --no-aws-creds
check "--no-aws-creds: no crea aws/ ni lee credenciales" bash -c "[ ! -e '$D/aws' ] && ! grep -q 'configure get' '$MOCK_LOG'"
check "--no-aws-creds: avisa de que falta aws/" has "$W/o.txt" "--no-aws-creds"
# perfil sin claves estaticas
D="$(newdir a-3)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" MOCK_NOKEYS=1)
check "perfil sin claves estaticas: render termina bien (solo avisa)" run_s "$W/o.txt" render-apps-layer.sh
check "perfil sin claves estaticas: no crea aws/ y lo avisa" bash -c "[ ! -e '$D/aws' ] && grep -q 'no tiene aws_access_key_id' '$W/o.txt'"
# aws/ existente: se respeta el directorio y se deja 700
D="$(newdir a-4)"; mkdir -m 755 "$D/aws"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
check "aws/ preexistente con modo abierto: queda en 700 con credentials 600" bash -c "[ \$(stat -c %a '$D/aws') = 700 ] && [ \$(stat -c %a '$D/aws/credentials') = 600 ]"
# dry-run no toca aws/
D="$(newdir a-5)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh --dry-run
check "--dry-run no crea aws/ ni kube-config" bash -c "[ ! -e '$D/aws' ] && [ ! -e '$D/kube-config' ] && ! grep -q 'configure get' '$MOCK_LOG'"
# la opcion desconocida sigue fallando
EXTRA=(APPS_LAYER_DIR="$D"); if run_s "$W/o.txt" render-apps-layer.sh --nope; then bad "opcion desconocida"; else ok "opcion desconocida aborta"; fi

echo "== 12) zip del universo y universe-images.lst: descarga SIEMPRE fresca (curl/gh falsos), launch los monta, check los valida"
ZN="kubernetes-universe-descriptors-15.1.0.zip"
D="$(newdir u-1)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D")
check "fetch-universe.sh descarga (mock curl)" run_s "$W/o.txt" fetch-universe.sh
check "fetch: URL de qa.int.stratio.com con la version y curl -fSL" bash -c "grep -q '^curl .*-fSL.* http://qa.int.stratio.com/repository/paas/kubernetes-universe/descriptors/$ZN\$' '$MOCK_LOG'"
check "fetch: deja $ZN en APPS_LAYER_DIR, valido, sin temporales" bash -c "unzip -tqq '$D/$ZN' >/dev/null && [ -z \"\$(ls -A '$D' | grep '^\\.universe')\" ]"
check "fetch: imprime tamano y sha256 del zip" bash -c "grep -q 'bytes, sha256 '\$(sha256sum '$D/$ZN' | cut -d' ' -f1) '$W/o.txt'"
: > "$MOCK_LOG"; run_s "$W/o.txt" fetch-universe.sh
check "fetch: una segunda ejecucion vuelve a descargar (nunca reutiliza la copia previa)" bash -c "grep -c '^curl ' '$MOCK_LOG' | grep -qx 1"
echo "copia-previa-vieja" > "$D/$ZN"; run_s "$W/o.txt" fetch-universe.sh
check "fetch: sustituye una copia previa invalida por la descarga" bash -c "unzip -tqq '$D/$ZN'"
for mode in MOCK_CURL_FAIL MOCK_CURL_EMPTY MOCK_CURL_BAD; do
  D="$(newdir "u-$mode")"; EXTRA=(APPS_LAYER_DIR="$D" "$mode=1")
  if run_s "$W/o.txt" fetch-universe.sh; then bad "fetch con $mode debe abortar"; else ok "fetch aborta con $mode"; fi
  check "$mode: no queda zip ni temporales en el directorio" bash -c "[ -z \"\$(ls -A '$D')\" ]"
done
D="$(newdir u-url)"; EXTRA=(APPS_LAYER_DIR="$D" UNIVERSE_VERSION=15.2.0 UNIVERSE_ZIP_URL=); : > "$MOCK_LOG"; run_s "$W/o.txt" fetch-universe.sh
check "UNIVERSE_VERSION cambia nombre y URL (15.2.0)" bash -c "grep -q 'descriptors/kubernetes-universe-descriptors-15.2.0.zip\$' '$MOCK_LOG' && [ -f '$D/kubernetes-universe-descriptors-15.2.0.zip' ]"
EXTRA=(APPS_LAYER_DIR="$D" UNIVERSE_VERSION='../x'); if run_s "$W/o.txt" fetch-universe.sh; then bad "UNIVERSE_VERSION con barra"; else ok "UNIVERSE_VERSION invalida aborta"; fi
D="$W/u-open"; rm -rf "$D"; mkdir -p "$D"; chmod 775 "$D"; EXTRA=(APPS_LAYER_DIR="$D"); : > "$MOCK_LOG"
if run_s "$W/o.txt" fetch-universe.sh; then bad "fetch con directorio abierto"; else ok "fetch aborta con el directorio abierto"; fi
check "directorio abierto: no se descarga nada" bash -c "! grep -q '^curl ' '$MOCK_LOG' && [ -z \"\$(ls -A '$D')\" ]"
# launch: siempre descarga, monta el zip y no lanza docker
D="$(newdir u-2)"; mkdir -p "$D/aws"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9)
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" > "$W/launch.out" 2> "$W/launch.err"; rc=$?; cat "$W/launch.out" "$W/launch.err" >> "$LOGF"
check "launch descarga el zip (curl) y termina bien" bash -c "[ $rc -eq 0 ] && grep -q '^curl .*$ZN' '$MOCK_LOG' && unzip -tqq '$D/$ZN'"
check "launch: docker run monta el zip sobre el de la imagen" has "$W/launch.out" "-v $D/$ZN:/apps-layer-automation/universe/$ZN"
check "launch: stdout solo lleva el comando (la descarga va por stderr)" bash -c "head -1 '$W/launch.out' | grep -q '^docker run' && ! grep -q 'descargado' '$W/launch.out'"
check "launch: sin --run no ejecuta docker" bash -c "! grep -q '^docker ' '$MOCK_LOG'"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9)
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" > "$W/launch.out" 2> "$W/launch.err"
check "launch: vuelve a descargar en cada lanzamiento" bash -c "grep -c '^curl ' '$MOCK_LOG' | grep -qx 1"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9 MOCK_CURL_FAIL=1)
if run_s "$W/o.txt" launch-apps-layer.sh; then bad "launch con descarga fallida"; else ok "launch aborta si la descarga falla (no se usa la copia previa)"; fi
check "descarga fallida: launch no imprime docker run" bash -c "! grep -q '^docker run' '$W/o.txt'"
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9 MOCK_CURL_FAIL=1)
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --skip-fetch > "$W/launch.out" 2>&1; rc=$?
check "launch --skip-fetch usa el zip valido sin descargar" bash -c "[ $rc -eq 0 ] && ! grep -q '^curl ' '$MOCK_LOG' && grep -q -- '-v $D/$ZN:/apps-layer-automation/universe/$ZN' '$W/launch.out'"
touch -d '3 days ago' "$D/$ZN"; env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --skip-fetch > "$W/launch.out" 2>&1
check "launch --skip-fetch avisa si el zip tiene mas de 24 h" has "$W/launch.out" "mas de 24 h"
echo "x" > "$D/$ZN"; env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --skip-fetch > "$W/launch.out" 2>&1; rc=$?
check "launch --skip-fetch aborta con un zip invalido" test $rc -ne 0
rm -f "$D/$ZN"; env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --skip-fetch > "$W/launch.out" 2>&1; rc=$?
check "launch --skip-fetch aborta si no hay zip" test $rc -ne 0
# check-apps-layer: zip existe y es valido
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO si falta el zip del universo" bash -c "[ $rc -ne 0 ] && grep -q 'zip del universo: .*no existe' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" fetch-universe.sh; EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws
check "check: zip valido marcado ok" hasre "$W/o.txt" "ok .*zip del universo 15.1.0 valido"
printf 'vacio' > "$D/$ZN"; : > "$D/$ZN"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO con zip vacio" bash -c "[ $rc -ne 0 ] && grep -q 'esta vacio' '$W/o.txt'"
echo "no zip" > "$D/$ZN"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO con un zip corrupto" bash -c "[ $rc -ne 0 ] && grep -q 'no es un zip valido' '$W/o.txt'"
touch -d '3 days ago' "$D/$ZN"; run_s "$W/o.txt" fetch-universe.sh >/dev/null; touch -d '3 days ago' "$D/$ZN"
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws
check "check: zip de mas de 24 h es solo aviso" has "$W/o.txt" "mas de 24 h"

echo "== 12b) universe-images.lst (gh api, rama derivada de UNIVERSE_VERSION)"
LN="15.1.0-universe-images.lst"
D="$(newdir g-1)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D")
check "fetch descarga tambien el lst" run_s "$W/o.txt" fetch-universe.sh
check "fetch: gh api con Accept raw, repo Stratio/kubernetes-universe y ref=branch-15.1" bash -c "grep -q \"^gh api -H Accept: application/vnd.github.raw repos/Stratio/kubernetes-universe/contents/universe-images.lst?ref=branch-15.1\\$\" '$MOCK_LOG'"
check "fetch: comprueba gh auth status antes" bash -c "grep -q '^gh auth status' '$MOCK_LOG'"
check "fetch: deja $LN con connectors-loader, sin temporales" bash -c "grep -q connectors-loader '$D/$LN' && [ -z \"\$(ls -A '$D' | grep '^\\.universe')\" ]"
check "fetch: imprime la linea de connectors-loader y sha256 del lst" bash -c "grep -q 'connectors-loader:2.2.3' '$W/o.txt' && grep -q \"sha256 \$(sha256sum '$D/$LN' | cut -d' ' -f1)\" '$W/o.txt'"
: > "$MOCK_LOG"; run_s "$W/o.txt" fetch-universe.sh
check "fetch: vuelve a llamar a gh en cada ejecucion (nunca reutiliza)" bash -c "grep -c '^gh api' '$MOCK_LOG' | grep -qx 1"
for mode in MOCK_GH_NOAUTH MOCK_GH_FAIL MOCK_GH_EMPTY MOCK_GH_NOLOADER; do
  D="$(newdir "g-$mode")"; EXTRA=(APPS_LAYER_DIR="$D" "$mode=1")
  if run_s "$W/o.txt" fetch-universe.sh; then bad "fetch con $mode debe abortar"; else ok "fetch aborta con $mode"; fi
  check "$mode: no queda ningun $LN ni temporales del lst" bash -c "[ ! -e '$D/$LN' ] && [ -z \"\$(ls -A '$D' | grep '^\\.universe-lst')\" ]"
done
D="$(newdir g-noauth)"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_GH_NOAUTH=1); : > "$MOCK_LOG"; run_s "$W/o.txt" fetch-universe.sh
check "gh sin autenticar: mensaje claro (gh auth login / Stratio/kubernetes-universe) y no llama a gh api" bash -c "grep -q 'gh auth login' '$W/o.txt' && grep -q 'Stratio/kubernetes-universe' '$W/o.txt' && ! grep -q '^gh api' '$MOCK_LOG'"
D="$(newdir g-ver)"; EXTRA=(APPS_LAYER_DIR="$D" UNIVERSE_VERSION=15.2.0); : > "$MOCK_LOG"; run_s "$W/o.txt" fetch-universe.sh
check "UNIVERSE_VERSION 15.2.0: rama derivada branch-15.2 y fichero 15.2.0-universe-images.lst" bash -c "grep -q 'ref=branch-15.2\$' '$MOCK_LOG' && [ -f '$D/15.2.0-universe-images.lst' ]"
D="$(newdir g-br)"; EXTRA=(APPS_LAYER_DIR="$D" UNIVERSE_BRANCH=branch-15.1-devel); : > "$MOCK_LOG"; run_s "$W/o.txt" fetch-universe.sh
check "UNIVERSE_BRANCH configurable" bash -c "grep -q 'ref=branch-15.1-devel\$' '$MOCK_LOG'"
D="$(newdir g-nobr)"; EXTRA=(APPS_LAYER_DIR="$D" UNIVERSE_VERSION=latest); if run_s "$W/o.txt" fetch-universe.sh; then bad "version sin rama derivable"; else ok "version sin major.minor y sin UNIVERSE_BRANCH aborta"; fi
check "version no derivable: pide UNIVERSE_BRANCH" has "$W/o.txt" "UNIVERSE_BRANCH"
# launch
D="$(newdir g-2)"; mkdir -p "$D/aws"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
: > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9)
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" > "$W/launch.out" 2> "$W/launch.err"; rc=$?; cat "$W/launch.out" "$W/launch.err" >> "$LOGF"
check "launch descarga el lst (gh api) y lo monta :ro sobre el de la imagen" bash -c "[ $rc -eq 0 ] && grep -q '^gh api' '$MOCK_LOG' && grep -q -- '-v $D/$LN:/apps-layer-automation/universe/$LN:ro' '$W/launch.out'"
EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9 MOCK_GH_NOAUTH=1)
if run_s "$W/o.txt" launch-apps-layer.sh; then bad "launch sin gh autenticado"; else ok "launch aborta si gh no esta autenticado"; fi
check "gh sin autenticar: launch no imprime docker run" bash -c "! grep -q '^docker run' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D" NLB_IP=10.9.9.9 MOCK_GH_NOAUTH=1 MOCK_CURL_FAIL=1); : > "$MOCK_LOG"
env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --skip-fetch > "$W/launch.out" 2>&1; rc=$?
check "launch --skip-fetch con zip y lst validos no llama a curl ni a gh" bash -c "[ $rc -eq 0 ] && ! grep -qE '^(curl|gh api)' '$MOCK_LOG'"
rm -f "$D/$LN"; env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --skip-fetch > "$W/launch.out" 2>&1; rc=$?
check "launch --skip-fetch aborta si falta el lst" test $rc -ne 0
echo "otra-imagen:1" > "$D/$LN"; env -i "${BASEENV[@]}" "${EXTRA[@]}" bash "$S/launch-apps-layer.sh" --skip-fetch > "$W/launch.out" 2>&1; rc=$?
check "launch --skip-fetch aborta si el lst no tiene connectors-loader" test $rc -ne 0
# check
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO si el lst no contiene connectors-loader" bash -c "[ $rc -ne 0 ] && grep -q 'no contiene connectors-loader' '$W/o.txt'"
rm -f "$D/$LN"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO si falta el lst" bash -c "[ $rc -ne 0 ] && grep -q 'universe-images.lst: .*no existe' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" fetch-universe.sh; run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws
check "check: lst valido ok con la version de connectors-loader" hasre "$W/o.txt" "ok .*$LN valido .*connectors-loader:2.2.3"

echo "== 12c) CONNECTORS_LOADER_VERSION: pin 2.2.0 por defecto (como keos-fleet#220); vacio => manda universe-images.lst"
check "defecto: el YAML del tenant lleva 'CONNECTORS_LOADER_VERSION: 2.2.0' (sin comillas)" bash -c "grep -qx ' *CONNECTORS_LOADER_VERSION: 2.2.0' '$W/g-2/demo-x-dev.yaml' && [ \$(grep -c 'CONNECTORS_LOADER_VERSION' '$W/g-2/demo-x-dev.yaml') -eq 2 ]"
check "defecto: yq lo lee como connectors-management.env.CONNECTORS_LOADER_VERSION == \"2.2.0\"" bash -c "yq -o=json . '$W/g-2/demo-x-dev.yaml' | jq -e '[.. | objects | select(.name==\"connectors-management\") | .env.CONNECTORS_LOADER_VERSION][0] == \"2.2.0\"' >/dev/null"
D="$(newdir cl-empty)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" CONNECTORS_LOADER_VERSION=); run_s "$W/o.txt" render-apps-layer.sh
check "variable vacia: no aparece la linea CONNECTORS_LOADER_VERSION: en el YAML" bash -c "! grep -q '^ *CONNECTORS_LOADER_VERSION:' '$D/demo-x-dev.yaml' && yq . '$D/demo-x-dev.yaml' >/dev/null"
D="$(newdir cl-other)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" CONNECTORS_LOADER_VERSION=2.2.3); run_s "$W/o.txt" render-apps-layer.sh
check "otro valor: el YAML lleva ese valor" bash -c "grep -qx ' *CONNECTORS_LOADER_VERSION: 2.2.3' '$D/demo-x-dev.yaml' && ! grep -q 'CONNECTORS_LOADER_VERSION: 2.2.0' '$D/demo-x-dev.yaml'"
D="$(newdir cl-bad)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" "CONNECTORS_LOADER_VERSION=2.2 x"); if run_s "$W/o.txt" render-apps-layer.sh; then bad "CONNECTORS_LOADER_VERSION con espacio debe abortar"; else ok "CONNECTORS_LOADER_VERSION invalida aborta"; fi
check "kit.env.example documenta CONNECTORS_LOADER_VERSION y lib.sh la declara en KIT_VARS" bash -c "grep -q 'CONNECTORS_LOADER_VERSION=2.2.0' '$KIT/kit.env.example' && sed -n '/^KIT_VARS=/,/)\$/p' '$KIT/scripts/lib.sh' | grep -q CONNECTORS_LOADER_VERSION"
D="$(newdir cl-chk)"; cp "$W/universe-images-fixture.lst" "$D/$LN" 2>/dev/null || true
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws
check "check: informa del loader fijado (2.2.0 por defecto)" hasre "$W/o.txt" "connectors-loader que se usara: 2.2.0"
EXTRA=(APPS_LAYER_DIR="$D" CONNECTORS_LOADER_VERSION=); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws
check "check: con variable vacia informa del loader del .lst (2.2.3)" hasre "$W/o.txt" "connectors-loader que se usara: el del .*2.2.3"

echo "== 12d) S3_INIT_PATH: INIT_PATH de connector-s3 (errata INTI_PATH de vars.env); def. /<bucket>; '/' solo se rechaza (UnsupportedRootInitPath)"
BK=demo-x-internal-111111111111
check "defecto: connector-s3 lleva INIT_PATH == \"/<bucket esperado>\" en el YAML renderizado" bash -c "yq -o=json . '$W/g-2/demo-x-dev.yaml' | jq -e '[.. | objects | select(.name==\"connector-s3\") | .env.INIT_PATH][0] == \"/$BK\"' >/dev/null"
check "defecto: la linea 'INIT_PATH: /<bucket>' aparece en el YAML y no queda ningun \${S3_INIT_PATH} sin sustituir" bash -c "grep -qx ' *INIT_PATH: /$BK' '$W/g-2/demo-x-dev.yaml' && ! grep -qF '\${S3_INIT_PATH}' '$W/g-2/demo-x-dev.yaml'"
check "defecto: el INIT_PATH de connector-rdbms-postgres-internal no cambia" bash -c "grep -qx ' *INIT_PATH: /psql,/testatdlc' '$W/g-2/demo-x-dev.yaml'"
D="$(newdir ip-bucket)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" S3_INIT_PATH=/bucket-x); run_s "$W/o.txt" render-apps-layer.sh
check "S3_INIT_PATH=/bucket-x: connector-s3 lleva INIT_PATH == /bucket-x (se respeta)" bash -c "yq -o=json . '$D/demo-x-dev.yaml' | jq -e '[.. | objects | select(.name==\"connector-s3\") | .env.INIT_PATH][0] == \"/bucket-x\"' >/dev/null"
D="$(newdir ip-prefix)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" S3_INIT_PATH=/bucket-x/pre.fix); run_s "$W/o.txt" render-apps-layer.sh
check "S3_INIT_PATH=/bucket-x/pre.fix (bucket/prefijo) se respeta" bash -c "yq -o=json . '$D/demo-x-dev.yaml' | jq -e '[.. | objects | select(.name==\"connector-s3\") | .env.INIT_PATH][0] == \"/bucket-x/pre.fix\"' >/dev/null"
D="$(newdir ip-bk2)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" S3_BUCKET_NAME=otro-bucket-1); run_s "$W/o.txt" render-apps-layer.sh
check "S3_BUCKET_NAME propio sin S3_INIT_PATH: el defecto sigue al bucket (/otro-bucket-1)" bash -c "yq -o=json . '$D/demo-x-dev.yaml' | jq -e '[.. | objects | select(.name==\"connector-s3\") | .env.INIT_PATH][0] == \"/otro-bucket-1\"' >/dev/null"
D="$(newdir ip-root)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" S3_INIT_PATH=/); if run_s "$W/o.txt" render-apps-layer.sh; then bad "S3_INIT_PATH='/' debe abortar"; else check "S3_INIT_PATH='/' aborta: el driver S3 no admite '/' (sugiere /<bucket>)" bash -c "grep -q \"no admite '/'\" '$W/o.txt' && grep -q '/<bucket>' '$W/o.txt' && [ ! -e '$D/demo-x-dev.yaml' ]"; fi
D="$(newdir ip-empty)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" S3_INIT_PATH=); if run_s "$W/o.txt" render-apps-layer.sh; then bad "S3_INIT_PATH vacia debe abortar"; else check "S3_INIT_PATH vacia aborta con mensaje claro" has "$W/o.txt" "S3_INIT_PATH"; fi
D="$(newdir ip-noslash)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" S3_INIT_PATH=bucket-x); if run_s "$W/o.txt" render-apps-layer.sh; then bad "S3_INIT_PATH sin '/' inicial debe abortar"; else check "S3_INIT_PATH sin '/' inicial aborta con mensaje claro" has "$W/o.txt" "debe empezar por '/'"; fi
check "kit.env.example documenta S3_INIT_PATH (def. /\${S3_BUCKET_NAME}, rechaza '/') y lib.sh la declara en KIT_VARS" bash -c "grep -q 'S3_INIT_PATH=/\${S3_BUCKET_NAME} ' '$KIT/kit.env.example' && grep -q 'NO usar \"/\"' '$KIT/kit.env.example' && sed -n '/^KIT_VARS=/,/)\$/p' '$KIT/scripts/lib.sh' | grep -q S3_INIT_PATH"
D="$(newdir ip-chk)"; cp "$W/universe-images-fixture.lst" "$D/$LN" 2>/dev/null || true
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
EXTRA=(APPS_LAYER_DIR="$D"); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws
check "check: con INIT_PATH muestra 'connector-s3 INIT_PATH = /<bucket>' como ok" hasre "$W/o.txt" "ok .*connector-s3 INIT_PATH = /$BK( |$)"
cp "$D/demo-x-dev.yaml" "$D/demo-x-dev.yaml.orig"
sed -i "s|^\( *\)INIT_PATH: /$BK\$|\1INIT_PATH: /|" "$D/demo-x-dev.yaml"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO si connector-s3 INIT_PATH es exactamente '/' (explica UnsupportedRootInitPath)" bash -c "[ $rc -ne 0 ] && grep -q \"INIT_PATH = '/'\" '$W/o.txt' && grep -q 'UnsupportedRootInitPath' '$W/o.txt'"
cp "$D/demo-x-dev.yaml.orig" "$D/demo-x-dev.yaml"
sed -i "/^ *INIT_PATH: \/$BK\$/d" "$D/demo-x-dev.yaml"; run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO si connector-s3 no tiene INIT_PATH (cita la errata)" bash -c "[ $rc -ne 0 ] && grep -q 'connector-s3 sin INIT_PATH' '$W/o.txt' && grep -q 'INTI_PATH' '$W/o.txt'"
D2="$(newdir ip-chk2)"; cp "$W/universe-images-fixture.lst" "$D2/$LN" 2>/dev/null || true
EXTRA=(APPS_LAYER_DIR="$D2" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
sed -i "s|^\( *\)INIT_PATH: /$BK\$|\1INIT_PATH: \"\"|" "$D2/demo-x-dev.yaml"
EXTRA=(APPS_LAYER_DIR="$D2"); run_s "$W/o.txt" check-apps-layer.sh --no-cluster --no-aws; rc=$?
check "check: KO si connector-s3 tiene INIT_PATH vacio" bash -c "[ $rc -ne 0 ] && grep -q 'connector-s3 sin INIT_PATH' '$W/o.txt'"

echo "== 13) aviso si APPS_LAYER_DIR efectivo no es el esperado (variable exportada de una sesion anterior)"
D="$(newdir w-1)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
check "variable exportada distinta del defecto: avisa con ruta efectiva y 'unset APPS_LAYER_DIR'" bash -c "grep -q 'AVISO.*APPS_LAYER_DIR efectivo = $D' '$W/o.txt' && grep -q 'unset APPS_LAYER_DIR' '$W/o.txt' && grep -q 'exportada en tu shell' '$W/o.txt'"
rm -rf "$W/apps-layer-demo-x"; EXTRA=(LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
check "sin APPS_LAYER_DIR (defecto): no avisa" bash -c "! grep -q 'APPS_LAYER_DIR efectivo' '$W/o.txt'"
D="$(newdir w-2)"; EXTRA=(APPS_LAYER_DIR="$W/apps-layer-demo-x"); run_s "$W/o.txt" render-apps-layer.sh --dry-run
check "APPS_LAYER_DIR igual al defecto: no avisa" bash -c "! grep -q 'APPS_LAYER_DIR efectivo' '$W/o.txt'"
printf 'export APPS_LAYER_DIR=%s\n' "$D" > "$W/kit-w.env"; EXTRA=(KIT_ENV_FILE="$W/kit-w.env" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh --dry-run
check "APPS_LAYER_DIR de kit.env distinto del defecto: avisa citando kit.env/cluster.env" bash -c "grep -q 'viene de kit.env/cluster.env' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si); run_s "$W/o.txt" s3-requisites.sh env
check "s3-requisites env con ruta no esperada: avisa y escribe en la efectiva (nunca en otra)" bash -c "grep -q 'APPS_LAYER_DIR efectivo' '$W/o.txt' && grep -q 'escritas en $D/.env' '$W/o.txt'"

echo "== 14) bucket de backups opcional: plantilla CloudFormation (yq)"
TPLF="$KIT/templates/requisites-s3.cfn.yaml"; FIX="$HERE/fixtures"
TJ="$(yq . "$TPLF")"
check "plantilla: YAML valido" bash -c "yq . '$TPLF' >/dev/null"
check "plantilla: Condition CreateBackups = EnableBackupsBucket == true" jq -e '.Conditions.CreateBackups == ["EnableBackupsBucket","true"]' <<<"$TJ"
check "plantilla: EnableBackupsBucket String, defecto \"false\", AllowedValues true|false" jq -e '.Parameters.EnableBackupsBucket | (.Type=="String" and .Default=="false" and .AllowedValues==["true","false"])' <<<"$TJ"
check "plantilla: BackupsS3BucketName/User con defecto vacio" jq -e '.Parameters | (.BackupsS3BucketName.Default=="" and .BackupsS3BucketUser.Default=="" and .BackupsS3BucketName.Type=="String" and .BackupsS3BucketUser.Type=="String")' <<<"$TJ"
PB="$(jq -r '.Parameters.BackupsS3BucketName.AllowedPattern' <<<"$TJ")"; PU="$(jq -r '.Parameters.BackupsS3BucketUser.AllowedPattern' <<<"$TJ")"
check "plantilla: patrones de backups = los internos precedidos de '^\$|' (aceptan vacio)" jq -e '.Parameters | (.BackupsS3BucketName.AllowedPattern == "^$|" + .InternalS3BucketName.AllowedPattern and .BackupsS3BucketUser.AllowedPattern == "^$|" + .InternalS3BucketUser.AllowedPattern)' <<<"$TJ"
check "patron bucket de backups: acepta vacio y demo-x-backups-111111111111" bash -c "[[ '' =~ $PB ]] && [[ demo-x-backups-111111111111 =~ $PB ]]"
check "patron bucket de backups: rechaza mayusculas, corto y guion final" bash -c "! [[ Demo =~ $PB ]] && ! [[ ab =~ $PB ]] && ! [[ abc- =~ $PB ]]"
check "patron usuario de backups: acepta vacio y demo-x-backups; rechaza espacios" bash -c "[[ '' =~ $PU ]] && [[ demo-x-backups =~ $PU ]] && ! [[ 'a b' =~ $PU ]]"
check "plantilla: exactamente 4 recursos nuevos, los 4 con Condition CreateBackups" jq -e '[.Resources|to_entries[]|select(.value.Condition=="CreateBackups")|.key]|sort == ["BackupsS3Bucket","BackupsS3IAMUser","BackupsS3IAMUserAccessKey","BackupsS3Secret"]' <<<"$TJ"
check "plantilla: los recursos ya existentes NO llevan Condition" jq -e '[.Resources|to_entries[]|select(.key|test("^(InternalS3Bucket|S3StratioApps)"))|.value|has("Condition")]|any|not' <<<"$TJ"
check "plantilla: 8 recursos en total (4 existentes + 4 de backups)" jq -e '.Resources|length==8' <<<"$TJ"
check "backups bucket: Retain + UpdateReplacePolicy Retain" jq -e '.Resources.BackupsS3Bucket | (.DeletionPolicy=="Retain" and .UpdateReplacePolicy=="Retain" and .Type=="AWS::S3::Bucket")' <<<"$TJ"
check "backups bucket: versionado, AES256, PublicAccessBlock completo" jq -e '.Resources.BackupsS3Bucket.Properties | (.VersioningConfiguration.Status=="Enabled" and .BucketEncryption.ServerSideEncryptionConfiguration[0].ServerSideEncryptionByDefault.SSEAlgorithm=="AES256" and ([.PublicAccessBlockConfiguration[]]|all))' <<<"$TJ"
check "backups bucket: tags Name y cluster (como el interno)" jq -e '.Resources.BackupsS3Bucket.Properties.Tags | (map(.Key)==["Name","cluster"])' <<<"$TJ"
check "backups bucket: BucketName y tag Name salen del parametro" bash -c "yq -r '.Resources.BackupsS3Bucket.Properties.BucketName' '$TPLF' | grep -q BackupsS3BucketName"
check "backups user: politica s3-backups con ListAllMyBuckets, s3:* solo sobre el bucket de backups y Deny NotAction" jq -e '.Resources.BackupsS3IAMUser.Properties | (.Policies[0].PolicyName=="s3-backups" and (.Policies[0].PolicyDocument.Statement|map(.Effect)==["Allow","Allow","Deny"]) and .Policies[0].PolicyDocument.Statement[0].Action=="s3:ListAllMyBuckets" and .Policies[0].PolicyDocument.Statement[1].Action=="s3:*" and .Policies[0].PolicyDocument.Statement[2].NotAction=="s3:*" and (.Policies[0].PolicyDocument.Statement[1].Resource|length)==2)' <<<"$TJ"
check "backups user: la politica solo referencia el bucket de backups (no el interno)" bash -c "! yq '.Resources.BackupsS3IAMUser' '$TPLF' | grep -q InternalS3BucketName"
check "backups user: tag cluster" jq -e '.Resources.BackupsS3IAMUser.Properties.Tags|map(.Key)==["cluster"]' <<<"$TJ"
check "backups access key: Active, usuario BackupsS3IAMUser" jq -e '.Resources.BackupsS3IAMUserAccessKey.Properties.Status=="Active"' <<<"$TJ"
check "backups secret: nombre = usuario, formato ACCESS_KEY/SECRET_KEY, tag cluster" bash -c "yq -r '.Resources.BackupsS3Secret.Properties.SecretString' '$TPLF' | grep -qF '\"ACCESS_KEY\":\"\${BackupsS3IAMUserAccessKey}\",\"SECRET_KEY\":\"\${BackupsS3IAMUserAccessKey.SecretAccessKey}\"' && yq -r '.Resources.BackupsS3Secret.Properties.Name' '$TPLF' | grep -q BackupsS3BucketUser && yq -r '.Resources.BackupsS3Secret.Properties.Tags[0].Key' '$TPLF' | grep -qx cluster"
check "plantilla: Rules exige nombre y usuario no vacios si EnableBackupsBucket=true (y distintos de los internos)" jq -e '.Rules.BackupsNamesRequired | (.RuleCondition==["EnableBackupsBucket","true"] and (.Assertions|length)==4 and all(.Assertions[]; has("AssertDescription")))' <<<"$TJ"
check "plantilla: outputs de backups condicionales (BackupsS3BucketName/User/SecretArn)" jq -e '.Outputs | (.BackupsS3BucketName.Condition=="CreateBackups" and .BackupsS3BucketUser.Condition=="CreateBackups" and .BackupsS3SecretArn.Condition=="CreateBackups")' <<<"$TJ"
check "plantilla: outputs existentes sin Condition" jq -e '.Outputs | (.InternalS3BucketName|has("Condition")|not) and (.InternalS3BucketUser|has("Condition")|not) and (.S3StratioAppsSecretArn|has("Condition")|not)' <<<"$TJ"
check "plantilla: parametros, recursos y outputs EXISTENTES identicos a la base (golden, estructura)" bash -c "yq '.' '$TPLF' | jq -e --slurpfile b '$FIX/requisites-s3.base.json' '. as \$n | ([\$b[0].Parameters|to_entries[]|.key as \$k|(\$n.Parameters[\$k]==.value)]|all) and ([\$b[0].Resources|to_entries[]|.key as \$k|(\$n.Resources[\$k]==.value)]|all) and ([\$b[0].Outputs|to_entries[]|.key as \$k|(\$n.Outputs[\$k]==.value)]|all)'"
check "plantilla: bloques Resources/Outputs existentes IDENTICOS en texto (tags !Ref/!Sub incluidos)" python3 -I -c "import sys; t=open(sys.argv[1]).read(); sys.exit(0 if open(sys.argv[2]).read() in t and open(sys.argv[3]).read() in t else 1)" "$TPLF" "$FIX/requisites-s3.base-resources.txt" "$FIX/requisites-s3.base-outputs.txt"
check "plantilla: la cabecera documenta Retain y el secreto con clave por diseno" bash -c "grep -q 'Backups (optional' '$TPLF' && grep -q 'holds the access key by design' '$TPLF' && grep -qi 'DeletionPolicy/UpdateReplacePolicy Retain' '$TPLF'"

echo "== 14b) variables del kit para backups (defectos y validacion)"
kitvars() { env -i HOME="$W/home" PATH="$PATH" CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" "$@" bash -c "source '$S/lib.sh'; load_kit_env; printf '%s|%s|%s' \"\$ENABLE_BACKUPS_BUCKET\" \"\$BACKUPS_BUCKET_NAME\" \"\$BACKUPS_USER_NAME\"" 2>&1; }
check "defectos: false | demo-x-backups-111111111111 | demo-x-backups" test "$(kitvars)" = "false|demo-x-backups-111111111111|demo-x-backups"
check "ENABLE_BACKUPS_BUCKET=true con nombres propios se respeta" test "$(kitvars ENABLE_BACKUPS_BUCKET=true BACKUPS_BUCKET_NAME=mi-backups-1 BACKUPS_USER_NAME=mi-bk)" = "true|mi-backups-1|mi-bk"
out="$(env -i HOME="$W/home" PATH="$PATH" CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" ENABLE_BACKUPS_BUCKET=maybe bash -c "source '$S/lib.sh'; load_kit_env" 2>&1)"; rc=$?
check "ENABLE_BACKUPS_BUCKET=maybe aborta (debe ser true o false)" bash -c "[ $rc -ne 0 ] && grep -q 'ENABLE_BACKUPS_BUCKET debe ser true o false' <<<\"$out\""
for badcase in "BACKUPS_BUCKET_NAME=Mayus_Invalido|BACKUPS_BUCKET_NAME" "BACKUPS_USER_NAME=mal/usuario|BACKUPS_USER_NAME" "BACKUPS_BUCKET_NAME=demo-x-internal-111111111111|bucket interno" "BACKUPS_USER_NAME=demo-x-s3|S3_USER_NAME" \
               "BACKUPS_USER_NAME=cloud-provisioner|PROTEGIDA" "BACKUPS_USER_NAME=igualdad|PROTEGIDA" "KIT_AWS_PROFILE=perfil-kit BACKUPS_USER_NAME=perfil-kit|PROTEGIDA"; do
  assign="${badcase%%|*}"; want="${badcase##*|}"
  out="$(env -i HOME="$W/home" PATH="$PATH" CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" ENABLE_BACKUPS_BUCKET=true $assign bash -c "source '$S/lib.sh'; load_kit_env" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -q "$want" <<<"$out"; then ok "habilitado + $assign: aborta ($want)"; else bad "habilitado + $assign: debia abortar ($want)"; fi
done
out="$(env -i HOME="$W/home" PATH="$PATH" CLUSTER_ENV_FILE="$W/cluster.env" KIT_ENV_FILE="$W/no-kit.env" bash -c "export BACKUPS_BUCKET_NAME=Mayus_Invalido BACKUPS_USER_NAME=cloud-provisioner; source '$S/lib.sh'; load_kit_env; echo cargado" 2>&1)"
check "deshabilitado: nombres de backups invalidos NO abortan (comportamiento anterior intacto)" grep -qx cargado <<<"$out"
check "lib.sh: KIT_VARS declara las 3 variables y kit.env.example las documenta" bash -c "sed -n '/^KIT_VARS=/,/)\$/p' '$S/lib.sh' | grep -q 'ENABLE_BACKUPS_BUCKET BACKUPS_BUCKET_NAME BACKUPS_USER_NAME' && grep -q 'ENABLE_BACKUPS_BUCKET=false' '$KIT/kit.env.example' && grep -q 'BACKUPS_BUCKET_NAME=\${CLUSTER_NAME}-backups-\${AWS_ACCOUNT_ID}' '$KIT/kit.env.example' && grep -q 'BACKUPS_USER_NAME=\${CLUSTER_NAME}-backups' '$KIT/kit.env.example' && grep -qi 'GLOBALES' '$KIT/kit.env.example'"

echo "== 14c) s3-requisites.sh sin habilitar: igual que antes"
BKB=demo-x-backups-111111111111; BKU=demo-x-backups
D="$(newdir b-off)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si)
check "plan deshabilitado termina bien" run_s "$W/o.txt" s3-requisites.sh plan
check "plan deshabilitado: dice 'no habilitado' y el comando lleva EnableBackupsBucket=false" bash -c "grep -q 'no habilitado (ENABLE_BACKUPS_BUCKET=false)' '$W/o.txt' && grep 'parameter-overrides' '$W/o.txt' | grep -q 'EnableBackupsBucket=false' && ! grep -q 'BackupsS3BucketName' '$W/o.txt'"
check "plan deshabilitado: sin 'backups:' en el estado ni '+ bucket de backups'" bash -c "! grep -qE '^  backups:|\\+ bucket de backups' '$W/o.txt'"
check "plan deshabilitado: ninguna llamada AWS menciona backups (mismas llamadas que antes)" bash -c "! grep -qi backups '$MOCK_LOG'"
check "plan deshabilitado: el comando conserva los 3 parametros internos" bash -c "grep -q 'ClusterName=demo-x InternalS3BucketName=demo-x-internal-111111111111 InternalS3BucketUser=demo-x-s3 EnableBackupsBucket=false' '$W/o.txt'"
: > "$MOCK_LOG"; printf 'demo-x\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"; EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1)
run_s "$W/o.txt" s3-requisites.sh apply
check "apply deshabilitado: deploy con los 3 parametros de siempre + EnableBackupsBucket=false (sin nombres de backups)" bash -c "l=\$(grep 'cloudformation deploy' '$MOCK_LOG'); grep -q 'EnableBackupsBucket=false' <<<\"\$l\" && grep -q 'InternalS3BucketUser=demo-x-s3' <<<\"\$l\" && ! grep -qi 'BackupsS3Bucket' <<<\"\$l\""
check "apply deshabilitado: el texto de confirmacion no menciona recursos de backups" bash -c "! grep -qi 'bucket de backups' '$W/o.txt'"
STDIN_FILE=""
# stack con backups pero ENABLE=false: apply aborta (quitaria usuario/clave/secreto)
: > "$MOCK_LOG"; printf 'demo-x\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"; EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BACKUPS_OUT=1 MOCK_BACKUPS_BUCKET=1 MOCK_BACKUPS_USER=1 MOCK_BACKUPS_SECRET=si)
if run_s "$W/o.txt" s3-requisites.sh apply; then bad "apply con ENABLE=false sobre stack con backups debe abortar"; else ok "apply con ENABLE=false sobre un stack que ya tiene backups aborta"; fi
check "ENABLE=false con backups en el stack: explica que los QUITARIA y no llama a deploy" bash -c "grep -q 'QUITARIA' '$W/o.txt' && ! grep -q 'cloudformation deploy' '$MOCK_LOG'"
STDIN_FILE=""
# env deshabilitado: no escribe BACKUPS_* aunque el stack tenga los outputs
D="$(newdir b-off-env)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_BACKUPS_OUT=1)
check "env deshabilitado termina bien" run_s "$W/o.txt" s3-requisites.sh env
check "env deshabilitado: el .env NO tiene BACKUPS_* y no se lee el secreto de backups" bash -c "! grep -q BACKUPS '$D/.env' && ! grep -q 'secret:demo-x-backups' '$MOCK_LOG' && grep -q '^export S3_BUCKET_ACCESS_KEY=' '$D/.env'"
check "env deshabilitado: salida igual que antes (sin mencionar backups)" bash -c "! grep -qi backups '$W/o.txt'"
D="$(newdir b-off-st)"; EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si); run_s "$W/o.txt" s3-requisites.sh status
check "status deshabilitado sin backups en el stack: sin lineas de backups" bash -c "! grep -qiE 'backups:|BACKUPS_S3' '$W/o.txt'"

echo "== 14d) s3-requisites.sh habilitado: plan y apply"
D="$(newdir b-on)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si)
check "plan habilitado (stack existente sin backups) termina bien" run_s "$W/o.txt" s3-requisites.sh plan
check "plan habilitado: HABILITADO, bucket/usuario por defecto y estado de backups (no/no/no)" bash -c "grep -q 'HABILITADO' '$W/o.txt' && grep -q 'backups: bucket $BKB=no  usuario $BKU=no existe  secreto=no  (en el stack: no)' '$W/o.txt'"
check "plan habilitado: comando de apply con los 3 parametros de backups" bash -c "grep -q 'EnableBackupsBucket=true BackupsS3BucketName=$BKB BackupsS3BucketUser=$BKU' '$W/o.txt'"
check "plan habilitado sobre stack existente: ACTUALIZACION que solo AÑADE, con los 3 recursos nuevos" bash -c "grep -q 'ACTUALIZACION que solo AÑADE' '$W/o.txt' && grep -q '+ bucket de backups $BKB' '$W/o.txt' && grep -q '+ usuario IAM $BKU' '$W/o.txt' && grep -q '+ secreto de Secrets Manager $BKU' '$W/o.txt'"
check "plan habilitado: sin conflictos y siguiente paso con backups-info" bash -c "grep -q 'sin conflictos de nombres' '$W/o.txt' && grep -q 'backups-info' '$W/o.txt'"
check "plan habilitado: ninguna operacion de escritura" bash -c "! grep -E '$WRITE_RE' '$MOCK_LOG'"
check "plan habilitado: solo lecturas conocidas" bash -c "! grep -vE '^(sts get-caller-identity|cloudformation (describe-stacks|validate-template)|s3api head-bucket|iam get-user|secretsmanager describe-secret) ' '$MOCK_LOG'"
check "plan habilitado: no crea .env" bash -c "[ ! -e '$D/.env' ]"
# plan sin stack: se crea todo
D="$(newdir b-on0)"; EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=0); run_s "$W/o.txt" s3-requisites.sh plan
check "plan habilitado sin stack: 'ademas se crearan el bucket ... (Retain)'" bash -c "grep -q 'ademas se crearan el bucket $BKB' '$W/o.txt'"
# plan con stack que ya tiene backups
D="$(newdir b-on-has)"; EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si MOCK_BACKUPS_OUT=1 MOCK_BACKUPS_BUCKET=1 MOCK_BACKUPS_USER=1 MOCK_BACKUPS_SECRET=si)
run_s "$W/o.txt" s3-requisites.sh plan
check "plan con backups ya en el stack: 'apply no cambia nada de ellos' y sin conflictos" bash -c "grep -q 'apply no cambia nada de ellos' '$W/o.txt' && grep -q 'sin conflictos de nombres' '$W/o.txt' && grep -q '(en el stack: si)' '$W/o.txt'"
# conflictos: recursos homonimos que NO son del stack => apply aborta sin deploy
printf 'demo-x\n' > "$W/in.txt"
for cf in "MOCK_BACKUPS_BUCKET=1|bucket de backups $BKB ya existe" "MOCK_BACKUPS_USER=1|usuario IAM $BKU ya existe" "MOCK_BACKUPS_SECRET=si|ya existe un secreto llamado $BKU" "MOCK_BACKUPS_SECRET=borrandose|programado para borrado"; do
  var="${cf%%|*}"; want="${cf##*|}"; D="$(newdir b-cf)"; : > "$MOCK_LOG"; STDIN_FILE="$W/in.txt"
  EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si "$var")
  if run_s "$W/o.txt" s3-requisites.sh apply; then bad "conflicto $var: apply debe abortar"; else ok "conflicto $var: apply aborta"; fi
  check "conflicto $var: mensaje '$want' y sin deploy" bash -c "grep -q '$want' '$W/o.txt' && ! grep -q 'cloudformation deploy' '$MOCK_LOG'"
  EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si "$var"); run_s "$W/o.txt" s3-requisites.sh plan
  check "conflicto $var: plan lo senala (KO) sin escribir" bash -c "grep -q 'KO' '$W/o.txt' && grep -q '$want' '$W/o.txt' && ! grep -E '$WRITE_RE' '$MOCK_LOG'"
done
STDIN_FILE=""
# nombres distintos a los del stack => reemplazo => aborta
D="$(newdir b-rename)"; : > "$MOCK_LOG"; STDIN_FILE="$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true BACKUPS_BUCKET_NAME=otro-backups-1 KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si MOCK_BACKUPS_OUT=1 MOCK_BACKUPS_BUCKET=1 MOCK_BACKUPS_USER=1 MOCK_BACKUPS_SECRET=si)
if run_s "$W/o.txt" s3-requisites.sh apply; then bad "cambiar el nombre del bucket de backups sobre un stack que ya lo tiene debe abortar"; else ok "apply con otro BACKUPS_BUCKET_NAME que el del stack aborta"; fi
check "rename: avisa de REEMPLAZARIA y no llama a deploy" bash -c "grep -q 'REEMPLAZARIA' '$W/o.txt' && ! grep -q 'cloudformation deploy' '$MOCK_LOG'"
STDIN_FILE=""
# apply habilitado: confirmacion interactiva con los recursos nuevos y deploy con parametros
D="$(newdir b-apply)"; : > "$MOCK_LOG"; printf 'otro\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si)
if run_s "$W/o.txt" s3-requisites.sh apply; then bad "apply habilitado con confirmacion erronea"; else ok "apply habilitado con confirmacion erronea aborta"; fi
check "apply habilitado: el texto de confirmacion lista los recursos NUEVOS y dice que solo añade" bash -c "grep -q 'solo AÑADE recursos' '$W/o.txt' && grep -q '+ bucket de backups $BKB' '$W/o.txt' && grep -q '+ usuario IAM $BKU' '$W/o.txt' && grep -q '+ secreto de Secrets Manager $BKU' '$W/o.txt'"
check "apply habilitado con confirmacion erronea: sin deploy" bash -c "! grep -q 'cloudformation deploy' '$MOCK_LOG'"
: > "$MOCK_LOG"; printf 'demo-x\n' > "$W/in.txt"; run_s "$W/o.txt" s3-requisites.sh apply
check "apply habilitado confirmado: deploy con EnableBackupsBucket=true y nombres de backups, mas los internos" bash -c "l=\$(grep 'cloudformation deploy' '$MOCK_LOG'); grep -q 'EnableBackupsBucket=true' <<<\"\$l\" && grep -q 'BackupsS3BucketName=$BKB' <<<\"\$l\" && grep -q 'BackupsS3BucketUser=$BKU' <<<\"\$l\" && grep -q 'InternalS3BucketName=demo-x-internal-111111111111' <<<\"\$l\" && grep -q 'CAPABILITY_NAMED_IAM' <<<\"\$l\""
STDIN_FILE=""

echo "== 14e) env, status y backups-info con backups habilitados"
BCK_RE='AKIAMOCKBACKUP0000|FAKE/backups\+KEY0000'
D="$(newdir b-env)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=1 MOCK_BUCKET=1 MOCK_BACKUPS_OUT=1)
check "env habilitado termina bien" run_s "$W/o.txt" s3-requisites.sh env
run_s "$W/o2.txt" s3-requisites.sh env
check "env habilitado: .env 600 y las 4 variables BACKUPS_S3_BUCKET_* una sola vez" bash -c "[ \$(stat -c %a '$D/.env') = 600 ] && for n in ACCESS_KEY SECRET_KEY NAME REGION; do [ \$(grep -c \"^export BACKUPS_S3_BUCKET_\$n=\" '$D/.env') = 1 ] || exit 1; done"
check "env habilitado: valores correctos al hacer source (y las S3_BUCKET_* internas siguen)" bash -c "env -i bash -c 'source \"$D/.env\"; [ \"\$BACKUPS_S3_BUCKET_ACCESS_KEY\" = AKIAMOCKBACKUP0000 ] && [ \"\$BACKUPS_S3_BUCKET_SECRET_KEY\" = \"FAKE/backups+KEY0000\" ] && [ \"\$BACKUPS_S3_BUCKET_NAME\" = $BKB ] && [ \"\$BACKUPS_S3_BUCKET_REGION\" = eu-west-1 ] && [ \"\$S3_BUCKET_ACCESS_KEY\" = AKIAMOCKFAKE0000 ]'"
check "env habilitado: no imprime ningun valor (ni claves de backups ni nombre del bucket de .env)" bash -c "! grep -qE '$BCK_RE|AKIAMOCKFAKE0000' '$W/o.txt' '$W/o2.txt'"
check "env habilitado: solo lecturas AWS" bash -c "! grep -E '$WRITE_RE' '$MOCK_LOG'"
check "env habilitado: documenta que apps-layer no las usa" has "$W/o.txt" "apps-layer no las usa"
printf 'export KEEP=1\nexport BACKUPS_S3_BUCKET_ACCESS_KEY=old\n' > "$D/.env"; run_s "$W/o.txt" s3-requisites.sh env
check "env habilitado sustituye la clave vieja de backups y conserva el resto" bash -c "grep -q KEEP=1 '$D/.env' && [ \$(grep -c BACKUPS_S3_BUCKET_ACCESS_KEY '$D/.env') = 1 ] && ! grep -q '=old' '$D/.env'"
# habilitado pero el stack aun no tiene los outputs: avisa de que falta apply
D="$(newdir b-env-no)"; EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=1 MOCK_BUCKET=1)
check "env habilitado sin outputs de backups en el stack: termina bien (aviso)" run_s "$W/o.txt" s3-requisites.sh env
check "env habilitado sin outputs: avisa de que falta un apply y no escribe BACKUPS_*; las internas si" bash -c "grep -q 'falta el output BackupsS3SecretArn' '$W/o.txt' && grep -q 'apply' '$W/o.txt' && ! grep -q BACKUPS '$D/.env' && grep -q '^export S3_BUCKET_ACCESS_KEY=' '$D/.env'"
# status
D="$(newdir b-st)"; printf 'export BACKUPS_S3_BUCKET_NAME=x\n' > "$D/.env"; chmod 600 "$D/.env"
EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si MOCK_BACKUPS_OUT=1 MOCK_BACKUPS_BUCKET=1 MOCK_BACKUPS_USER=1 MOCK_BACKUPS_SECRET=si)
check "status habilitado" run_s "$W/o.txt" s3-requisites.sh status
check "status habilitado: estado de backups, outputs BackupsS3* y solo nombres de variables del .env" bash -c "grep -q 'backups: bucket $BKB=si' '$W/o.txt' && grep -q 'output BackupsS3BucketName = $BKB' '$W/o.txt' && grep -q 'output BackupsS3SecretArn = ' '$W/o.txt' && grep -q 'BACKUPS_S3_BUCKET_NAME presente' '$W/o.txt' && grep -q 'BACKUPS_S3_BUCKET_ACCESS_KEY ausente' '$W/o.txt' && ! grep -qE '$BCK_RE' '$W/o.txt'"
# backups-info
: > "$MOCK_LOG"; check "backups-info termina bien" run_s "$W/o.txt" s3-requisites.sh backups-info
check "backups-info: bucket, region, usuario, ARN del secreto y claves de keos-fleet" bash -c "grep -q 'Bucket ........... $BKB' '$W/o.txt' && grep -q 'Region ........... eu-west-1' '$W/o.txt' && grep -q 'Usuario IAM ...... $BKU' '$W/o.txt' && grep -q 'Secreto (ARN) .... arn:aws:secretsmanager:eu-west-1:111111111111:secret:demo-x-backups-XyZ123' '$W/o.txt' && grep -q 'backups.s3BucketName' '$W/o.txt' && grep -q 'backups.s3BucketRegion' '$W/o.txt' && grep -q 'BACKUPS_S3_BUNDLE' '$W/o.txt'"
check "backups-info: imprime el comando get-secret-value pero NO lo ejecuta" bash -c "grep -q 'aws secretsmanager get-secret-value --secret-id arn:aws:secretsmanager:eu-west-1:111111111111:secret:demo-x-backups-XyZ123 --region eu-west-1 --profile cloud-provisioner' '$W/o.txt' && ! grep -q 'secretsmanager get-secret-value' '$MOCK_LOG'"
check "backups-info: solo lectura (sin escrituras) y sin secretos en la salida" bash -c "! grep -E '$WRITE_RE' '$MOCK_LOG' && ! grep -qE '$BCK_RE|AKIAMOCKFAKE0000' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D" ENABLE_BACKUPS_BUCKET=true MOCK_STACK=1 MOCK_BUCKET=1)
if run_s "$W/o.txt" s3-requisites.sh backups-info; then bad "backups-info habilitado sin outputs debe fallar"; else ok "backups-info habilitado sin outputs en el stack falla"; fi
check "backups-info sin outputs: pide plan/apply" has "$W/o.txt" "ejecuta s3-requisites.sh plan y apply"
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1)
if run_s "$W/o.txt" s3-requisites.sh backups-info; then bad "backups-info deshabilitado sin outputs debe fallar"; else ok "backups-info deshabilitado sin backups en el stack falla"; fi
check "backups-info deshabilitado: explica ENABLE_BACKUPS_BUCKET=false" has "$W/o.txt" "ENABLE_BACKUPS_BUCKET=false"
EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_BACKUPS_OUT=1)
check "backups-info deshabilitado pero con backups en el stack: informa igualmente" run_s "$W/o.txt" s3-requisites.sh backups-info
if run_s "$W/o.txt" s3-requisites.sh plan --delete-backups; then bad "--delete-backups con plan debe abortar"; else ok "--delete-backups solo se admite con delete"; fi
if run_s "$W/o.txt" s3-requisites.sh delete --otra; then bad "argumento desconocido en delete"; else ok "delete con argumento desconocido aborta"; fi

echo "== 14f) delete: el bucket de backups se conserva salvo --delete-backups"
BDEL_ENV=(KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si MOCK_BACKUPS_OUT=1 MOCK_BACKUPS_BUCKET=1 MOCK_BACKUPS_USER=1 MOCK_BACKUPS_SECRET=si MOCK_VERSIONS=1 MOCK_VERSIONS_BACKUPS=1)
BENVF='export S3_BUCKET_ACCESS_KEY=x\nexport S3_BUCKET_SECRET_KEY=y\nexport BACKUPS_S3_BUCKET_ACCESS_KEY=bx\nexport BACKUPS_S3_BUCKET_SECRET_KEY=by\nexport BACKUPS_S3_BUCKET_NAME=bn\nexport BACKUPS_S3_BUCKET_REGION=br\nexport KEEP=1\n'
# por defecto: no toca el bucket de backups
D="$(newdir b-del1)"; printf "$BENVF" > "$D/.env"; rm -f "$W/versions_done" "$W/versions_done_backups"; : > "$MOCK_LOG"; printf 'demo-x\n111111111111\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" "${BDEL_ENV[@]}")
check "delete sin --delete-backups termina bien (solo cluster y cuenta, sin tercera confirmacion)" run_s "$W/o.txt" s3-requisites.sh delete
check "delete sin --delete-backups: NO vacia ni borra el bucket de backups" bash -c "! grep -E '(delete-objects|delete-bucket|list-object-versions|list-multipart-uploads|abort-multipart-upload) .*--bucket $BKB' '$MOCK_LOG'"
check "delete sin --delete-backups: si borra el bucket interno y el stack" bash -c "grep -q 's3api delete-bucket .*--bucket demo-x-internal-111111111111' '$MOCK_LOG' && grep -q 'cloudformation delete-stack' '$MOCK_LOG'"
check "delete sin --delete-backups: informa de que se conserva y avisa del usuario/clave/secreto del stack" bash -c "grep -q 'NO se toca: se CONSERVA' '$W/o.txt' && grep -q 'delete --delete-backups' '$W/o.txt' && grep -q 'al borrar el stack se borran su usuario IAM $BKU' '$W/o.txt' && grep -q 'se ha CONSERVADO' '$W/o.txt'"
check "delete sin --delete-backups: no libera el secreto de backups (sin delete-secret de backups)" bash -c "! grep -E 'delete-secret .*$BKU' '$MOCK_LOG'"
check ".env: quita las claves internas y las claves de backups (invalidas sin stack) pero conserva NAME/REGION de backups y el resto" bash -c "! grep -qE 'S3_BUCKET_(ACCESS|SECRET)_KEY' '$D/.env' && grep -q BACKUPS_S3_BUCKET_NAME '$D/.env' && grep -q BACKUPS_S3_BUCKET_REGION '$D/.env' && grep -q KEEP=1 '$D/.env'"
# --delete-backups sin tty
D="$(newdir b-del2)"; : > "$MOCK_LOG"; STDIN_FILE=""; EXTRA=(APPS_LAYER_DIR="$D" MOCK_STACK=1 MOCK_BUCKET=1 MOCK_BACKUPS_OUT=1 MOCK_BACKUPS_BUCKET=1)
if run_s "$W/o.txt" s3-requisites.sh delete --delete-backups; then bad "delete --delete-backups sin tty"; else ok "delete --delete-backups sin tty aborta"; fi
check "delete --delete-backups sin tty: sin borrados" bash -c "! grep -E 'delete-|abort-' '$MOCK_LOG'"
# --delete-backups con la 3ª confirmacion mal escrita: aborta sin tocar NADA (ni siquiera el bucket interno)
D="$(newdir b-del3)"; : > "$MOCK_LOG"; rm -f "$W/versions_done" "$W/versions_done_backups"; printf 'demo-x\n111111111111\nnombre-incorrecto\n' > "$W/in.txt"; STDIN_FILE="$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" "${BDEL_ENV[@]}")
if run_s "$W/o.txt" s3-requisites.sh delete --delete-backups; then bad "3a confirmacion erronea"; else ok "delete --delete-backups con la confirmacion EXTRA erronea aborta"; fi
check "confirmacion EXTRA erronea: no se borra ni vacia nada" bash -c "! grep -E 'delete-|abort-' '$MOCK_LOG'"
check "se avisa de la confirmacion EXTRA con el nombre del bucket de backups" has "$W/o.txt" "confirmacion EXTRA) escribir el nombre del bucket de backups"
printf 'demo-x\n111111111111\ndemo-x\n' > "$W/in.txt"
if run_s "$W/o.txt" s3-requisites.sh delete --delete-backups; then bad "la 3a confirmacion no acepta el nombre del cluster"; else ok "la confirmacion EXTRA no acepta otra cosa que el nombre del bucket de backups"; fi
# --delete-backups correcto
D="$(newdir b-del4)"; printf "$BENVF" > "$D/.env"; : > "$MOCK_LOG"; rm -f "$W/versions_done" "$W/versions_done_backups"; printf "demo-x\n111111111111\n$BKB\n" > "$W/in.txt"; EXTRA=(APPS_LAYER_DIR="$D" "${BDEL_ENV[@]}")
check "delete --delete-backups con las 3 confirmaciones correctas termina bien" run_s "$W/o.txt" s3-requisites.sh delete --delete-backups
check "delete --delete-backups: vacia (versiones y delete markers) y borra el bucket de backups ademas del interno" bash -c "grep -q 'delete-objects .*--bucket $BKB' '$MOCK_LOG' && grep -q 's3api delete-bucket .*--bucket $BKB' '$MOCK_LOG' && grep -q 's3api delete-bucket .*--bucket demo-x-internal-111111111111' '$MOCK_LOG'"
check "delete --delete-backups: orden vaciar backups -> borrar stack -> borrar bucket de backups" bash -c "a=\$(grep -n 'delete-objects .*--bucket $BKB' '$MOCK_LOG' | head -1 | cut -d: -f1); b=\$(grep -n 'cloudformation delete-stack' '$MOCK_LOG' | head -1 | cut -d: -f1); c=\$(grep -n 's3api delete-bucket .*--bucket $BKB' '$MOCK_LOG' | head -1 | cut -d: -f1); [ \$a -lt \$b ] && [ \$b -lt \$c ]"
check "delete --delete-backups: avisa de irreversible y limpia BACKUPS_* del .env (conserva el resto)" bash -c "grep -q 'bucket de BACKUPS $BKB con TODAS sus versiones' '$W/o.txt' && ! grep -q 'BACKUPS_S3' '$D/.env' && grep -q KEEP=1 '$D/.env'"
# pertenencia: bucket de backups de otro cluster (sin stack, etiqueta distinta) => no se toca
D="$(newdir b-del5)"; : > "$MOCK_LOG"; printf "demo-x\n111111111111\n$BKB\n" > "$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=0 MOCK_BACKUPS_BUCKET=1 MOCK_BACKUPS_CLUSTER=otro-cluster)
if run_s "$W/o.txt" s3-requisites.sh delete --delete-backups; then bad "bucket de backups de otro cluster"; else ok "delete --delete-backups de un bucket de backups que no es del cluster aborta"; fi
check "bucket de backups ajeno: sin borrados y explica la pertenencia" bash -c "! grep -E 'delete-|abort-' '$MOCK_LOG' && grep -q 'no es de este cluster' '$W/o.txt'"
# huerfano (stack ya borrado, bucket Retain con la etiqueta del cluster): se puede borrar con --delete-backups
D="$(newdir b-del6)"; : > "$MOCK_LOG"; rm -f "$W/versions_done_backups"; printf "demo-x\n111111111111\n$BKB\n" > "$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=0 MOCK_BACKUPS_BUCKET=1 MOCK_VERSIONS_BACKUPS=1)
check "delete --delete-backups de un bucket de backups huerfano con etiqueta del cluster" run_s "$W/o.txt" s3-requisites.sh delete --delete-backups
check "huerfano: borra el bucket de backups y no hay delete-stack" bash -c "grep -q 's3api delete-bucket .*--bucket $BKB' '$MOCK_LOG' && ! grep -q 'cloudformation delete-stack' '$MOCK_LOG'"
# huerfano sin --delete-backups: nada que borrar de lo interno y no toca el bucket
D="$(newdir b-del7)"; : > "$MOCK_LOG"; printf "demo-x\n111111111111\n" > "$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=0 MOCK_BACKUPS_BUCKET=1)
run_s "$W/o.txt" s3-requisites.sh delete
check "huerfano sin --delete-backups: no borra el bucket de backups" bash -c "! grep -E 'delete-bucket|delete-objects' '$MOCK_LOG'"
# delete sin backups (caso de siempre): la salida no menciona backups
D="$(newdir b-del8)"; : > "$MOCK_LOG"; rm -f "$W/versions_done"; printf 'demo-x\n111111111111\n' > "$W/in.txt"
EXTRA=(APPS_LAYER_DIR="$D" KIT_TEST_ALLOW_NOTTY=1 MOCK_STACK=1 MOCK_BUCKET=1 MOCK_USER=1 MOCK_SECRET=si MOCK_VERSIONS=1)
check "delete sin backups en ningun sitio termina bien" run_s "$W/o.txt" s3-requisites.sh delete
check "delete sin backups: la salida no menciona backups (igual que antes)" bash -c "! grep -qi backups '$W/o.txt'"
STDIN_FILE=""

echo "== 14g) las claves de backups no salen en ninguna salida; el render conserva el .env de backups; README"
check "ninguna salida de los scripts contiene claves de backups ficticias" bash -c "! grep -qE '$BCK_RE' '$LOGF'"
D="$(newdir b-render)"; printf 'export BACKUPS_S3_BUCKET_ACCESS_KEY=bk1\nexport BACKUPS_S3_BUCKET_SECRET_KEY=bk2\nexport BACKUPS_S3_BUCKET_NAME=bk3\nexport BACKUPS_S3_BUCKET_REGION=bk4\n' > "$D/.env"; chmod 600 "$D/.env"
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh
check "render conserva las variables BACKUPS_S3_BUCKET_* del .env (1 linea cada una)" bash -c "for n in ACCESS_KEY SECRET_KEY NAME REGION; do [ \$(grep -c \"^export BACKUPS_S3_BUCKET_\$n=\" '$D/.env') = 1 ] || exit 1; done"
check "README: seccion 'Bucket de backups opcional' con ENABLE_BACKUPS_BUCKET, --delete-backups, backups-info y backups.s3BucketName" bash -c "grep -q '^## Bucket de backups opcional' '$KIT/README.md' && grep -q 'ENABLE_BACKUPS_BUCKET=true' '$KIT/README.md' && grep -q -- '--delete-backups' '$KIT/README.md' && grep -q 'backups-info' '$KIT/README.md' && grep -q 'backups.s3BucketName' '$KIT/README.md' && grep -q 's3BucketRegion' '$KIT/README.md'"
check "README: no contiene claves de backups ficticias ni valores AKIA" bash -c "! grep -qE '$BCK_RE|AKIA[A-Z0-9]{12}' '$KIT/README.md'"

echo "== 15) ENVIRONMENT_SIZE=CUSTOM: overlay de recursos (templates/sizes-custom.env), perfil x hosts, y S/PIT sin cambios"
OVL="$KIT/templates/sizes-custom.env"
# apps con variables de recursos que consume cada plantilla (lista cerrada del kit) y que deben llevar TODAS en el YAML
CUSTOM_CHECK='def req: {"postgres":["CPU_REQUESTS","CPU_LIMITS","MEMORY_REQUESTS","MEMORY_LIMITS","SHARED_BUFFERS","MAINTENANCE_WORK_MEM"],
  "discovery":["CPU_REQUESTS","CPU_LIMITS","MEMORY_REQUESTS"],"intelligence":["CPU_REQUESTS","CPU_LIMITS","MEMORY_REQUESTS"],"rocket-catalog-standalone":["CPU_REQUESTS","CPU_LIMITS","MEMORY_REQUESTS"],
  "rocket":["CPU_REQUESTS","CPU_LIMITS","MEMORY_REQUESTS","DEBUG_CPU_REQUESTS","DEBUG_CPU_LIMITS","DEBUG_MEMORY_REQUESTS","CATALOG_CPU_REQUESTS","CATALOG_CPU_LIMITS","CATALOG_MEMORY_REQUESTS",
  "VALIDATOR_CPU_REQUESTS","VALIDATOR_CPU_LIMITS","VALIDATOR_MEMORY_REQUESTS","EXTERNAL_SERVICES_CPU_REQUESTS","EXTERNAL_SERVICES_CPU_LIMITS","EXTERNAL_SERVICES_MEMORY_REQUESTS"],
  "virtualizer":[],"pit":[]};
  [.[0].tenants[].apps[] | (.parallel[]? // .) | select(has("name"))] | all(. as $a | (req[$a.name] // ["CPU_REQUESTS","CPU_LIMITS","MEMORY_REQUESTS","MEMORY_LIMITS"]) | all(. as $v | ($a.env // {})[$v] != null))'
for prof in full minimal; do for hosts in false true; do
  D="$(newdir "c-$prof-$hosts")"; EXTRA=(APPS_LAYER_DIR="$D" KEOS_PROFILE="$prof" USE_TENANT_HOSTS="$hosts" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM)
  label="CUSTOM perfil=$prof hosts=$hosts"
  if run_s "$W/o.txt" render-apps-layer.sh; then ok "render $label"; else bad "render $label"; sed 's/^/      /' "$W/o.txt"; continue; fi
  R="$D/demo-x.yaml"; T="$D/demo-x-dev.yaml"
  RJ="$(yq . "$R" | jq -s .)"; TJ="$(yq . "$T" | jq -s .)"
  check "$label: ENVIRONMENT_SIZE CUSTOM en los dos YAML" bash -c "grep -q 'ENVIRONMENT_SIZE: \"CUSTOM\"' '$R' && grep -q 'ENVIRONMENT_SIZE: \"CUSTOM\"' '$T'"
  check "$label: cada app del root lleva todas las variables que consume su plantilla" jq -e "$CUSTOM_CHECK" <<<"$RJ"
  check "$label: cada app del tenant lleva todas las variables que consume su plantilla" jq -e "$CUSTOM_CHECK" <<<"$TJ"
  check "$label: sin \${ residuales (salvo placeholders CCT)" bash -c "! sed -E 's/\\\$\{(tenantId|external_domain)\}//g' '$R' '$T' | grep -F '\${'"
  check "$label: sin app hdfs/connector-dfs-hdfs" jq -e '[.. | objects | select(has("name")) | .name] | (index("hdfs")==null and index("connector-dfs-hdfs")==null)' <<<"$TJ"
  check "$label: salida avisa del overlay usado" has "$W/o.txt" "ENVIRONMENT_SIZE=CUSTOM: recursos inyectados desde $OVL"
  check "$label: tenant 600 (token) y root 644" bash -c "[ \$(stat -c %a '$T') = 600 ] && [ \$(stat -c %a '$R') = 644 ]"
  check "$label: el token sigue inyectado una sola vez y no sale en la salida" bash -c "[ \$(grep -cF '$FAKE' '$T') = 1 ] && ! grep -F '$FAKE' '$W/o.txt'"
  check "$label: el valor de las variables de recursos va entre comillas (texto)" jq -e '.[0].tenants[0].apps[0].parallel[0].env | (.CPU_REQUESTS|type) == "string"' <<<"$RJ"
  check "$label: .env igual que sin CUSTOM (el overlay no toca el .env)" bash -c "diff <(sed -E 's#$W/(c|r)-[a-z]+-[a-z]+#DIR#g' '$D/.env') <(sed -E 's#$W/(c|r)-[a-z]+-[a-z]+#DIR#g' '$W/r-$prof-$hosts/.env')"
done; done
D="$W/c-full-false"; RJ="$(yq . "$D/demo-x.yaml" | jq -s .)"; TJ="$(yq . "$D/demo-x-dev.yaml" | jq -s .)"
AE='[.[0].tenants[].apps[] | (.parallel[]? // .) | select(.name == $a)][0].env'
check "quirk governance-map cruzado: MEMORY_REQUESTS=1024 y MEMORY_LIMITS=512 (request real 512, limite real 1024)" jq -e --arg a governance-map "$AE | .MEMORY_REQUESTS==\"1024\" and .MEMORY_LIMITS==\"512\"" <<<"$RJ"
check "quirk discovery/intelligence/rocket/rocket-catalog-standalone: sin MEMORY_LIMITS (la plantilla no lo consume)" jq -e '[.[0].tenants[].apps[] | (.parallel[]? // .) | select(.name|IN("discovery","intelligence","rocket","rocket-catalog-standalone")) | .env | has("MEMORY_LIMITS")] | (length == 4 and all(. == false))' <<<"$TJ"
check "rocket lleva las 12 variables de workers (DEBUG_/CATALOG_/VALIDATOR_/EXTERNAL_SERVICES_)" jq -e --arg a rocket "$AE | [keys[] | select(test(\"^(DEBUG|CATALOG|VALIDATOR|EXTERNAL_SERVICES)_(CPU|MEMORY)_\"))] | length == 12" <<<"$TJ"
check "postgres con unidad (4096M) y SHARED_BUFFERS/MAINTENANCE_WORK_MEM" jq -e --arg a postgres "$AE | .MEMORY_REQUESTS==\"4096M\" and .SHARED_BUFFERS==\"512MB\" and .MAINTENANCE_WORK_MEM==\"128MB\"" <<<"$TJ"
check "virtualizer y pit sin variables de recursos (su plantilla no las consume)" jq -e '[.[0].tenants[].apps[] | (.parallel[]? // .) | select(.name|IN("virtualizer","pit")) | .env | has("CPU_REQUESTS")] | (length == 2 and all(. == false))' <<<"$TJ"
check "las dos instancias de connector-rdbms-postgres-internal llevan recursos" jq -e '[.[0].tenants[].apps[] | (.parallel[]? // .) | select(.name=="connector-rdbms-postgres-internal") | .env.CPU_REQUESTS] | length == 2 and all(. != null)' <<<"$TJ"
check "el env previo de cada app se conserva (INIT_PATH de connector-s3)" jq -e --arg a connector-s3 "$AE | .INIT_PATH==\"/demo-x-internal-111111111111\" and .CPU_REQUESTS==\"0.1\"" <<<"$TJ"
check "el env previo de opensearch1 se conserva" jq -e --arg a opensearch "$AE | .APP_NAME==\"opensearch1\" and .MEMORY_LIMITS==\"2048M\"" <<<"$TJ"
check "el overlay no asigna valores de cliente (hosts, grupos, datanode, dominios) ni lleva token (los comentarios que los citan como excluidos no cuentan)" bash -c "! grep -vE '^[[:space:]]*#' '$OVL' | grep -qiE 'igualdad|DATANODE|HAPROXY|ADMIN_GROUP|TYPES_TO_BE_DISCOVERED|SWAGGER|DOMAINS_ENABLED|MONITORING_ENABLED|TOKEN'"
check "el overlay solo tiene secciones [app] y VARIABLE=valor sin comillas" bash -c "! grep -vE '^\\s*(#.*)?\$|^\\[[a-z0-9-]+\\]\$|^[A-Z][A-Z0-9_]*=[A-Za-z0-9._+-]+\$' '$OVL'"
# S y PIT: sin cambios (no se lee el overlay, no se inyecta nada, solo difiere la linea ENVIRONMENT_SIZE)
for sz in S PIT; do
  D="$(newdir "c-$sz")"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=$sz CUSTOM_SIZES_FILE=/no/existe/sizes.env)
  if run_s "$W/o.txt" render-apps-layer.sh; then ok "ENVIRONMENT_SIZE=$sz no lee CUSTOM_SIZES_FILE (aunque no exista)"; else bad "ENVIRONMENT_SIZE=$sz con CUSTOM_SIZES_FILE inexistente"; fi
  check "$sz: sin variables de recursos inyectadas ni comentario CUSTOM ni aviso del overlay" bash -c "! grep -qE 'CPU_REQUESTS|MEMORY_LIMITS|SHARED_BUFFERS|ENVIRONMENT_SIZE=CUSTOM' '$D/demo-x.yaml' '$D/demo-x-dev.yaml' '$W/o.txt'"
done
check "S vs PIT: los YAML del tenant solo difieren en la linea ENVIRONMENT_SIZE (y en las rutas del directorio)" bash -c "[ \$(diff <(sed -E 's#$W/c-(S|PIT)#DIR#g' '$W/c-S/demo-x-dev.yaml') <(sed -E 's#$W/c-(S|PIT)#DIR#g' '$W/c-PIT/demo-x-dev.yaml') | grep -c '^[<>]') = 2 ]"
check "S: root y tenant identicos a los de r-full-false (mismo render que la matriz de la seccion 1)" bash -c "for f in demo-x.yaml demo-x-dev.yaml; do diff <(sed -E 's#$W/(c-S|r-full-false)#DIR#g' \"$W/c-S/\$f\") <(sed -E 's#$W/(c-S|r-full-false)#DIR#g' \"$W/r-full-false/\$f\") || exit 1; done"

echo "== 15b) CUSTOM: salvaguarda (falla con app y variable) y overlay propio (CUSTOM_SIZES_FILE)"
# ov OUT AWK_PROGRAM: copia del overlay del kit filtrada con awk
ov() { awk "$2" "$OVL" > "$1"; }
negtest() {  # negtest ETIQUETA OVERLAY PATRON_EN_SALIDA...
  local lbl="$1" f="$2"; shift 2
  local D; D="$(newdir "neg-$(echo "$lbl" | tr -c 'a-z0-9\n' _)")"
  EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM CUSTOM_SIZES_FILE="$f")
  if run_s "$W/o.txt" render-apps-layer.sh; then bad "$lbl: debia abortar"; return; fi
  ok "$lbl: aborta"
  local pat; for pat in "$@"; do check "$lbl: el mensaje contiene '$pat'" has "$W/o.txt" "$pat"; done
  check "$lbl: no escribe ningun YAML" bash -c "[ ! -e '$D/demo-x.yaml' ] && [ ! -e '$D/demo-x-dev.yaml' ]"
}
ov "$W/ov-nopg.env" '/^\[postgres\]$/ {s=1} s && /^MEMORY_LIMITS=/ {s=0; next} {print}'
negtest "falta MEMORY_LIMITS de postgres" "$W/ov-nopg.env" "app postgres: falta MEMORY_LIMITS" "faltan variables de recursos" "$W/ov-nopg.env"
ov "$W/ov-norocket.env" '/^\[rocket\]$/ {s=1} s && /^DEBUG_MEMORY_REQUESTS=/ {next} {print}'
negtest "falta DEBUG_MEMORY_REQUESTS de rocket (worker)" "$W/ov-norocket.env" "app rocket: falta DEBUG_MEMORY_REQUESTS"
ov "$W/ov-noapp.env" '/^\[governance-ui\]$/ {s=1; next} s && /^\[/ {s=0} s {next} {print}'
negtest "falta toda la seccion de governance-ui (root)" "$W/ov-noapp.env" "app governance-ui: falta CPU_REQUESTS" "app governance-ui: falta MEMORY_LIMITS" "demo-x.yaml"
ov "$W/ov-novar-tenant.env" '/^\[pgbouncer\]$/ {s=1} s && /^CPU_LIMITS=/ {s=0; next} {print}'
negtest "falta CPU_LIMITS de pgbouncer (tenant)" "$W/ov-novar-tenant.env" "app pgbouncer: falta CPU_LIMITS" "demo-x-dev.yaml"
{ cat "$OVL"; } | sed 's/^\[discovery\]$/[discovery]\nMEMORY_LIMITS=2048/' > "$W/ov-discmem.env"
negtest "MEMORY_LIMITS en discovery (la plantilla no la consume)" "$W/ov-discmem.env" "'discovery' no consume MEMORY_LIMITS"
{ cat "$OVL"; printf '[nginx-raro]\nCPU_REQUESTS=1\n'; } > "$W/ov-unkapp.env"
negtest "app desconocida en el overlay" "$W/ov-unkapp.env" "'nginx-raro' no esta en la lista del kit"
sed 's/^CPU_LIMITS=2$/CPU_LIMITS="2"/' "$OVL" > "$W/ov-quotes.env"
negtest "valor con comillas" "$W/ov-quotes.env" "linea no valida" "sin comillas"
{ cat "$OVL"; printf '[postgres]\nCPU_LIMITS=9\n'; } > "$W/ov-dupsec.env"
negtest "seccion repetida" "$W/ov-dupsec.env" "seccion [postgres] repetida"
sed '0,/^CPU_LIMITS=2$/ s//CPU_LIMITS=2\nCPU_LIMITS=3/' "$OVL" > "$W/ov-dupvar.env"
negtest "variable repetida en la misma seccion" "$W/ov-dupvar.env" "CPU_LIMITS repetida"
sed 's/^CPU_LIMITS=2$/CPU_LIMITS=/' "$OVL" > "$W/ov-empty.env"
negtest "valor vacio" "$W/ov-empty.env" "linea no valida"
D="$(newdir neg-rel)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM CUSTOM_SIZES_FILE=sizes.env)
if run_s "$W/o.txt" render-apps-layer.sh; then bad "CUSTOM_SIZES_FILE relativo debe abortar"; else ok "CUSTOM_SIZES_FILE relativo aborta"; fi
check "CUSTOM_SIZES_FILE relativo: mensaje claro" has "$W/o.txt" "ruta absoluta"
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM CUSTOM_SIZES_FILE="$W/no-existe.env")
if run_s "$W/o.txt" render-apps-layer.sh; then bad "CUSTOM_SIZES_FILE inexistente debe abortar"; else ok "CUSTOM_SIZES_FILE inexistente aborta"; fi
check "CUSTOM_SIZES_FILE inexistente: mensaje claro" has "$W/o.txt" "no se puede leer el overlay"
# el --dry-run de un overlay incompleto tambien aborta y no escribe
EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM CUSTOM_SIZES_FILE="$W/ov-nopg.env")
if run_s "$W/o.txt" render-apps-layer.sh --dry-run; then bad "dry-run con overlay incompleto"; else ok "dry-run con overlay incompleto aborta"; fi
# overlay propio completo: un valor cambiado se refleja (y solo en esa app)
sed 's/^CPU_LIMITS=2$/CPU_LIMITS=3/' "$OVL" > "$W/ov-mine.env"
D="$(newdir c-mine)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM CUSTOM_SIZES_FILE="$W/ov-mine.env")
check "overlay propio (CUSTOM_SIZES_FILE) renderiza" run_s "$W/o.txt" render-apps-layer.sh
check "overlay propio: el valor editado llega al YAML y la salida cita el fichero" bash -c "grep -q \"CPU_LIMITS: '3'\" '$D/demo-x-dev.yaml' && grep -qF 'desde $W/ov-mine.env' '$W/o.txt'"
# overlay con comentario y lineas en blanco extra, y secciones de apps que el perfil no despliega (minimal sin se-*): valido
D="$(newdir c-min-extra)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM KEOS_PROFILE=minimal ENABLE_GENAI=false)
check "CUSTOM minimal + genai=false: las secciones de apps no desplegadas se aceptan" run_s "$W/o.txt" render-apps-layer.sh
check "CUSTOM minimal + genai=false: sin se-searcher, genai-* ni pit en los YAML" bash -c "! grep -qE 'name: (se-searcher|genai-|pit|datamarket-agent)' '$D/demo-x.yaml' '$D/demo-x-dev.yaml'"
# check-apps-layer.sh con CUSTOM: ok si el YAML esta completo, KO si se le quita una variable a mano
D="$(newdir c-check)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE" ENVIRONMENT_SIZE=CUSTOM); run_s "$W/o.txt" render-apps-layer.sh
run_s "$W/o.txt" check-apps-layer.sh --no-aws --no-cluster
check "check CUSTOM: marca ok los dos YAML completos" bash -c "grep -q 'CUSTOM: demo-x.yaml lleva las variables' '$W/o.txt' && grep -q 'CUSTOM: demo-x-dev.yaml lleva las variables' '$W/o.txt'"
python3 -I - "$D/demo-x-dev.yaml" <<'PYEOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace("        SHARED_BUFFERS: '512MB'\n","",1)
open(p,'w').write(s)
PYEOF
run_s "$W/o.txt" check-apps-layer.sh --no-aws --no-cluster; rc=$?
check "check CUSTOM: KO si a una app le falta una variable (nombra app y variable)" bash -c "[ $rc -ne 0 ] && grep -q 'app postgres sin la variable de recursos SHARED_BUFFERS' '$W/o.txt'"
# S/PIT: check no hace la comprobacion CUSTOM
D="$(newdir c-check-s)"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE"); run_s "$W/o.txt" render-apps-layer.sh; run_s "$W/o.txt" check-apps-layer.sh --no-aws --no-cluster
check "check con S: no menciona CUSTOM" bash -c "! grep -q 'CUSTOM' '$W/o.txt'"
EXTRA=(APPS_LAYER_DIR="$D" ENVIRONMENT_SIZE=XL); if run_s "$W/o.txt" render-apps-layer.sh; then bad "XL"; else ok "ENVIRONMENT_SIZE=XL sigue abortando"; fi
check "mensaje de XL lista S, PIT y CUSTOM" bash -c "grep -q 'solo S, PIT o CUSTOM' '$W/o.txt'"
check "lib.sh: lista cerrada de apps de custom_required_vars cubre todas las apps de los dos perfiles de plantilla (sin app desconocida en el render completo)" bash -c "! grep -q 'no esta en la lista cerrada' '$W/o.txt'"

echo "== 16) backups-env.sh (OPCIONAL): backups.env sin comillas, modo 600, sin secretos, sin tocar AWS/cluster"
D="$(newdir bk-1)"; : > "$MOCK_LOG"; EXTRA=(APPS_LAYER_DIR="$D" LLM_TOKEN="$FAKE")
check "backups-env: exit 0" run_s "$W/o.txt" backups-env.sh
B="$D/backups.env"
check "backups.env: modo 600" test "$(stat -c %a "$B")" = 600
check "backups.env: 4 lineas exactas (cuenta, region, bucket y rol de Velero por defecto)" bash -c "[ \"\$(cat '$B')\" = \"\$(printf 'AWS_ACCOUNT_ID=111111111111\nAWS_REGION=eu-west-1\nAWS_BUCKET_NAME=demo-x-velero-111111111111\nAWS_IAM_ROLE_NAME=demo-x-velero')\" ]"
check "backups.env: sin comillas ni comentarios ni export" bash -c "! grep -qE \"['\\\"#]|export\" '$B'"
check "backups-env: directorio efimero 700" test "$(stat -c %a "$D")" = 700
check "backups-env: no llama a aws, kubectl ni docker (solo escribe un fichero)" bash -c "[ ! -s '$MOCK_LOG' ]"
check "backups-env: avisa de que es opcional y no ejecuta nada" bash -c "grep -q 'OPCIONAL' '$W/o.txt' && grep -q 'Nada de esto se ha ejecutado' '$W/o.txt' && grep -q 'enviroment-ready --backups backups.env' '$W/o.txt'"
check "backups-env: avisa de reporters (functional-monitoring:0.3.1, ECR 717279725338, parche de la GlobalNetworkPolicy, --reporter lo pisa)" bash -c "grep -q 'enviroment-ready --reporter backups.env' '$W/o.txt' && grep -q 'functional-monitoring:0.3.1' '$W/o.txt' && grep -q '717279725338' '$W/o.txt' && grep -qF 'kubernetes.io/metadata.name ==' '$W/o.txt' && grep -qF 'globalnetworkpolicies.crd.projectcalico.org allow-all-traffic-from-keos-reports' '$W/o.txt' && grep -q 'PISA' '$W/o.txt'"
check "backups-env: avisa del override keos-backup-velero.yaml (BSL Unavailable) y de keos backup schedule" bash -c "grep -q 'keos-backup-velero.yaml' '$W/o.txt' && grep -q 'ENABLE_BACKUP_VELERO' '$W/o.txt' && grep -q 'keos backup schedule vault idp' '$W/o.txt'"
check "backups-env: el token no sale ni se escribe" bash -c "! grep -F '$FAKE' '$W/o.txt' '$B'"
run_s "$W/o.txt" backups-env.sh
check "backups-env idempotente: 'sin cambios' y sin .bak" bash -c "grep -q 'sin cambios' '$W/o.txt' && [ ! -e '$B.bak' ]"
EXTRA=(APPS_LAYER_DIR="$D" VELERO_BUCKET=otro-bucket-velero VELERO_ROLE=role_otro-velero SC_POSTGRES=keos); run_s "$W/o.txt" backups-env.sh
check "backups-env con otros valores: reescribe con copia .bak (600) y añade SC_POSTGRES" bash -c "grep -q '^AWS_BUCKET_NAME=otro-bucket-velero\$' '$B' && grep -q '^AWS_IAM_ROLE_NAME=role_otro-velero\$' '$B' && grep -q '^SC_POSTGRES=keos\$' '$B' && [ \$(stat -c %a '$B.bak') = 600 ] && grep -q 'demo-x-velero-111111111111' '$B.bak' && [ \$(stat -c %a '$B') = 600 ]"
D2="$(newdir bk-2)"; EXTRA=(APPS_LAYER_DIR="$D2"); run_s "$W/o.txt" backups-env.sh --dry-run
check "backups-env --dry-run: muestra el contenido y no escribe nada" bash -c "grep -q 'AWS_BUCKET_NAME=demo-x-velero-111111111111' '$W/o.txt' && [ -z \"\$(ls -A '$D2')\" ]"
EXTRA=(APPS_LAYER_DIR="$D2" VELERO_ROLE=arn:aws:iam::111111111111:role/x); if run_s "$W/o.txt" backups-env.sh; then bad "VELERO_ROLE con ARN debe abortar"; else ok "VELERO_ROLE con un ARN (no un nombre) aborta"; fi
EXTRA=(APPS_LAYER_DIR="$D2" VELERO_BUCKET=BUCKET_MAL); if run_s "$W/o.txt" backups-env.sh; then bad "bucket invalido"; else ok "VELERO_BUCKET invalido aborta"; fi
check "backups-env aborto: no deja backups.env" test ! -e "$D2/backups.env"
D3="$W/bk-open"; rm -rf "$D3"; mkdir "$D3"; chmod 755 "$D3"; EXTRA=(APPS_LAYER_DIR="$D3")
if run_s "$W/o.txt" backups-env.sh; then bad "directorio 755"; else ok "backups-env aborta si APPS_LAYER_DIR es accesible por otros"; fi
check "backups-env: sin backups.env en el directorio inseguro" test ! -e "$D3/backups.env"
check "ninguna salida (CUSTOM y backups) contiene el token ficticio" bash -c "! grep -F '$FAKE' '$LOGF'"
check "backups-env.sh -h funciona" bash -c "env -i PATH=\"$PATH\" bash '$S/backups-env.sh' -h | grep -q 'backups.env'"

echo "== 17) README/INFORME del kit documentan CUSTOM, backups.env y los gotchas de CCT"
check "README: CUSTOM, sizes-custom.env, CUSTOM_SIZES_FILE y que sizes/ pisa el env en S/PIT" bash -c "grep -q 'ENVIRONMENT_SIZE=CUSTOM' '$KIT/README.md' && grep -q 'sizes-custom.env' '$KIT/README.md' && grep -q 'CUSTOM_SIZES_FILE' '$KIT/README.md' && grep -qi 'pisa' '$KIT/README.md'"
check "README: quirks (MEMORY_LIMITS ignorado, governance-map cruzado, unidades)" bash -c "grep -q 'MEMORY_LIMITS' '$KIT/README.md' && grep -q 'cruzad' '$KIT/README.md' && grep -q '4096M' '$KIT/README.md'"
check "README: bug de CCT 15.1 (SecretsBundle intelligence) y tecnica PUT /v2/upgrade" bash -c "grep -q 'secretsbundles.secrets.stratio.com intelligence' '$KIT/README.md' && grep -q 'PUT /v2/upgrade' '$KIT/README.md' && grep -q 'interpolate=false' '$KIT/README.md' && grep -q 'trap' '$KIT/README.md'"
check "README: cct-ajustes-cliente.sh y keos-cluster-snapshot.sh no se adoptan" bash -c "grep -q 'cct-ajustes-cliente.sh' '$KIT/README.md' && grep -q 'keos-cluster-snapshot.sh' '$KIT/README.md'"
check "README: backups-env.sh, enviroment-ready --backups y --reporter con sus avisos" bash -c "grep -q 'backups-env.sh' '$KIT/README.md' && grep -q 'enviroment-ready --backups' '$KIT/README.md' && grep -q 'enviroment-ready --reporter' '$KIT/README.md' && grep -q 'functional-monitoring' '$KIT/README.md'"
check "INFORME: SHA de la PR actualizado a 2d36d7d (HEAD) y sin f36fe83 como HEAD actual" bash -c "grep -q '2d36d7d' '$KIT/docs/INFORME.md' && ! grep -q 'HEAD \`f36fe83\`' '$KIT/docs/INFORME.md'"
check "kit.env.example documenta CUSTOM y CUSTOM_SIZES_FILE" bash -c "grep -q 'CUSTOM_SIZES_FILE' '$KIT/kit.env.example' && grep -q 'CUSTOM' '$KIT/kit.env.example'"
check "README/INFORME/kit.env.example/overlay sin el token ficticio" bash -c "! grep -rlF '$FAKE' '$KIT/README.md' '$KIT/docs/INFORME.md' '$KIT/kit.env.example' '$OVL'"

echo
echo "Resultado: $PASS ok, $FAIL fallos"
[[ $FAIL -eq 0 ]]

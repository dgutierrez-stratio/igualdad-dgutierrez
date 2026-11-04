#!/usr/bin/env bash
# run-offline-tests.sh — pruebas OFFLINE de la skill con datos ficticios (cuenta 111111111111, clúster demo-x) y un
# `aws`/`kubectl`/`docker` FALSOS en el PATH (tests/mock/bin). No toca AWS ni el clúster real.
# Usage: tests/run-offline-tests.sh [directorio-temporal]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SK="$(cd "$HERE/.." && pwd)"; S="$SK/scripts"
T="${1:-$(mktemp -d)}"; mkdir -p "$T"; T="$(cd "$T" && pwd)"
export PATH="$HERE/mock/bin:$PATH" MOCK_DATA="$HERE/mock/data" AWS_PAGER=""
FAIL=0; N=0
pass() { N=$((N+1)); echo "PASS  $*"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "FAIL  $*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
# operaciones AWS de solo lectura
RO='^(describe|list|get|head|batch-get|update-kubeconfig)'
writes_in_log() {  # imprime las llamadas que NO son de lectura (aws), y las de kubectl/docker que no son lectura
  grep -E '^[a-z0-9]+ [a-z0-9-]+ ::' "$1" | grep -vE '^(kubectl|docker|cloud-provisioner) ' | grep -vE '^configure ' | awk -v re="$RO" '$2 !~ re {print $1" "$2}' || true
  grep -E '^kubectl ::' "$1" | grep -vE ' (get|config|version|api-resources) ' || true
  grep -E '^docker ::' "$1" | grep -vE ' ::  ?(ps|info|inspect|image|version)' || true
  grep -E '^cloud-provisioner ::' "$1" | grep -v ' version' || true
}

echo "== 0. sintaxis =="
for f in "$S"/*.sh "$HERE"/run-offline-tests.sh; do check "bash -n $(basename "$f")" bash -n "$f"; done
command -v shellcheck >/dev/null && { for f in "$S"/*.sh; do check "shellcheck $(basename "$f")" shellcheck -S error "$f"; done; } || echo "SKIP  shellcheck no instalado"

echo "== 1. init + render de plantillas con datos ficticios =="
cd "$T" && rm -rf clusters
export MOCK_LOG="$T/mock.log"; : > "$MOCK_LOG"
"$S/init-cluster.sh" --account 111111111111 --name demo-x --no-detect --admin-profile igualdad --set CLOUD_PROVISIONER_BIN="$HERE/mock/bin/cloud-provisioner" >/dev/null && pass "init-cluster.sh" || fail "init-cluster.sh"
D="$T/clusters/demo-x"
"$S/init-cluster.sh" --account 12345 --name demo-x --no-detect --dir "$T/bad" >/dev/null 2>&1 && fail "init acepta cuenta inválida" || pass "init rechaza cuenta inválida"
"$S/init-cluster.sh" --account 111111111111 --name 'Demo_X' --no-detect --dir "$T/bad" >/dev/null 2>&1 && fail "init acepta nombre inválido" || pass "init rechaza nombre inválido"
cat > "$D/demo-x.json" <<'J'
{"vpc_id":"vpc-0123456789abcdef0","azs":[
{"az":"eu-west-1a","public_subnet":"subnet-aaa1","private_subnet":"subnet-bbb1","pods_subnet":null,"nat_gateway":"nat-1"},
{"az":"eu-west-1b","public_subnet":"subnet-aaa2","private_subnet":"subnet-bbb2","pods_subnet":null,"nat_gateway":"nat-1"},
{"az":"eu-west-1c","public_subnet":"subnet-aaa3","private_subnet":"subnet-bbb3","pods_subnet":null,"nat_gateway":"nat-1"}]}
J
AWS_ACCESS_KEY=AKIAFAKEFAKEFAKE0000 AWS_SECRET_KEY=fakesecretfakesecret "$S/render-cluster.sh" --dir "$D" >/dev/null && pass "render-cluster.sh" || fail "render-cluster.sh"
EFS_ID=fs-0abc "$S/render-keos.sh" --dir "$D" >/dev/null && pass "render-keos.sh" || fail "render-keos.sh"
for f in cluster.yaml keos.yaml override_vars/demo-x.yaml; do
  [[ "$(grep -c '\${' "$D/$f")" -eq 0 ]] && pass "sin \${ en $f" || fail "quedan \${ en $f"
  yq '.' "$D/$f" >/dev/null 2>&1 && pass "yq parsea $f" || fail "yq no parsea $f"
done
[[ "$(stat -c %a "$D/cluster.yaml")" == 600 ]] && pass "cluster.yaml chmod 600" || fail "cluster.yaml chmod"
grep -q 'demo-x.desa.int' "$D/cluster.yaml" && grep -q 'arn:aws:iam::111111111111:policy/ecr-pull' "$D/cluster.yaml" && pass "valores derivados en cluster.yaml" || fail "valores derivados"
# plantilla rota => aborta
mkdir -p "$D/templates"; printf 'x: ${NO_EXISTE}\n' > "$D/templates/keos.yaml.tpl"
EFS_ID=fs-0abc "$S/render-keos.sh" --dir "$D" >/dev/null 2>&1 && fail "render no aborta con \${ sin resolver" || pass "render aborta si queda \${ sin resolver"
rm -rf "$D/templates"

echo "== 2. teardown DRY-RUN (por defecto) =="
: > "$MOCK_LOG"
out="$("$S/teardown.sh" --dir "$D" 2>&1)"; rc=$?
echo "$out" > "$T/dryrun.out"
[[ $rc -eq 0 ]] && pass "dry-run termina con rc=0" || fail "dry-run rc=$rc (ver $T/dryrun.out)"
grep -q 'NADA borrado' <<<"$out" && pass "dry-run declara que no borra nada" || fail "falta el resumen de dry-run"
n="$(grep -c '^\[DRY-RUN\]' <<<"$out")"; [[ "$n" -gt 10 ]] && pass "dry-run lista $n operaciones planificadas" || fail "dry-run lista pocas operaciones ($n)"
w="$(writes_in_log "$MOCK_LOG")"; [[ -z "$w" ]] && pass "(a) ninguna operación de escritura/borrado invocada en dry-run ($(wc -l < "$MOCK_LOG") llamadas registradas)" || { fail "(a) escrituras en dry-run: $w"; }
for k in 'efs delete' 'route53 delete' 'iam delete' 'ec2 delete' 's3api delete' 'eks delete' 'cloudformation delete'; do
  grep -q "^$k" "$MOCK_LOG" && fail "dry-run llamó a $k" || true; done
grep -q '^kubectl :: .* delete' "$MOCK_LOG" && fail "dry-run: kubectl delete" || pass "dry-run: ningún kubectl delete"
grep -q 'ya no existe\|BUG' <<<"$out" && fail "mensaje inesperado en dry-run" || true
# pide --purge-account-shared para la fase 9
"$S/teardown.sh" --dir "$D" --phase 9 >/dev/null 2>&1 && fail "fase 9 sin --purge-account-shared" || pass "fase 9 exige --purge-account-shared"
: > "$MOCK_LOG"; MOCK_CALLER_ARN="arn:aws:sts::111111111111:assumed-role/OrganizationAccountAccessRole/s" "$S/teardown.sh" --dir "$D" --purge-account-shared --phase 9 --profile igualdad > "$T/p9.out" 2>&1; rc=$?
[[ -z "$(writes_in_log "$MOCK_LOG")" ]] && pass "dry-run fase 9: sin escrituras (rc=$rc)" || fail "fase 9 dry-run escribió"

echo "== 3. (b) guarda: el llamador es un recurso a borrar / protegido =="
: > "$MOCK_LOG"
out="$(MOCK_CALLER_ARN="arn:aws:sts::111111111111:assumed-role/demo-x-velero/sesion" "$S/teardown.sh" --dir "$D" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'GUARDA' <<<"$out" && pass "(b) aborta si el ARN del llamador coincide con un recurso a borrar" || fail "(b) la guarda no abortó (rc=$rc)"
[[ -z "$(writes_in_log "$MOCK_LOG")" ]] && pass "(b) sin escrituras tras abortar" || fail "(b) escrituras tras abortar"
cp "$D/cluster.env" "$T/cluster.env.bak"; echo 'export VELERO_ROLE=OrganizationAccountAccessRole' >> "$D/cluster.env"
out="$("$S/teardown.sh" --dir "$D" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'GUARDA.*PROTEGIDO' <<<"$out" && pass "(b) aborta si un recurso a borrar es OrganizationAccountAccessRole" || fail "(b) denylist no abortó (rc=$rc)"
cp "$T/cluster.env.bak" "$D/cluster.env"
out="$(MOCK_CALLER_ARN="arn:aws:iam::111111111111:user/cloud-provisioner" "$S/teardown.sh" --dir "$D" --purge-account-shared --phase 9 --profile cloud-provisioner 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'GUARDA\|no puede ejecutarse como el usuario' <<<"$out" && pass "(b) fase 9 como el propio usuario cloud-provisioner aborta" || fail "(b) fase 9 como cloud-provisioner no abortó (rc=$rc)"

echo "== 4. (c) cuenta incorrecta =="
: > "$MOCK_LOG"
out="$(MOCK_ACCOUNT=999999999999 "$S/teardown.sh" --dir "$D" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'cuenta incorrecta' <<<"$out" && pass "(c) aborta con cuenta incorrecta" || fail "(c) no abortó (rc=$rc)"
[[ "$(grep -vc '^sts get-caller-identity\|^configure' "$MOCK_LOG")" -eq 0 ]] && pass "(c) solo se llamó a sts get-caller-identity" || fail "(c) hubo más llamadas: $(cat "$MOCK_LOG" | head -3)"
out="$(MOCK_ACCOUNT=999999999999 "$S/create-test-vpc.sh" --delete --name demo-x --expect-account 111111111111 --profile igualdad --region eu-west-1 --apply 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'wrong account' <<<"$out" && pass "(c) create-test-vpc.sh --delete aborta con cuenta incorrecta" || fail "(c) VPC delete no abortó"

echo "== 5. teardown --apply con mocks: orden de borrado =="
: > "$MOCK_LOG"; touch "$D/cluster.yaml" "$D/secrets.yml"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\ns\ns\ns\ns\ns\n' | MOCK_KIND_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 "$S/teardown.sh" --dir "$D" --apply --phase 1,2,3,4,5,6,7 2>&1)"; rc=$?
echo "$out" > "$T/apply.out"
[[ $rc -ne 0 && $rc -ne 2 ]] && fail "apply abortó rc=$rc (ver $T/apply.out)" || pass "apply mock rc=$rc (2 = la verificación detecta lo que el mock no elimina de verdad)"
seq_of() { grep -nE "$1" "$MOCK_LOG" | head -1 | cut -d: -f1; }
order_ok=1; prev=0
for pat in '^kubectl :: .*delete svc' '^kubectl :: .*delete pvc' '^kubectl :: .*scale deployment keoscluster' '^docker :: exec .*clusterctl' '^docker :: exec .*delete cl --all' '^efs delete-mount-target' '^efs delete-file-system' '^route53 change-resource-record-sets' '^route53 delete-hosted-zone' '^s3api delete-objects' '^s3api delete-bucket' '^iam detach-role-policy' '^iam delete-role ' '^iam delete-policy ' '^ec2 delete-nat-gateway' '^ec2 release-address' '^ec2 delete-subnet' '^ec2 delete-vpc'; do
  l="$(seq_of "$pat")"; if [[ -z "$l" ]]; then echo "      falta: $pat"; order_ok=0; continue; fi
  [[ "$l" -ge "$prev" ]] || { echo "      desordenado: $pat (línea $l < $prev)"; order_ok=0; }; prev="$l"
done
[[ $order_ok -eq 1 ]] && pass "orden: LB/PVC -> pausa operator -> move -> delete cl -> EFS -> Route53 -> S3 -> IAM -> red -> VPC" || fail "orden de borrado incorrecto"
grep -q 'delete-role --role-name OrganizationAccountAccessRole\|delete-user' "$MOCK_LOG" && fail "se intentó borrar un recurso protegido" || pass "no se borró ningún rol/usuario protegido (ni usuario IAM sin --purge-account-shared)"
grep -q 'eipalloc-foreign' "$MOCK_LOG" && ! grep -q 'release-address.*eipalloc-foreign' "$MOCK_LOG" && pass "no se liberó la EIP ajena (otro Name)" || { grep -q 'release-address.*eipalloc-foreign' "$MOCK_LOG" && fail "se liberó una EIP ajena" || pass "EIP ajena intacta"; }
grep -q 'ZPUB' "$MOCK_LOG" && grep -q 'delete-hosted-zone.*ZPUB' "$MOCK_LOG" && pass "zonas Route53 borradas por id" || fail "zona pública no borrada"
grep -q 'change-resource-record-sets' "$MOCK_LOG" && ! grep 'change-resource-record-sets' "$MOCK_LOG" | grep -q 'SOA' && pass "registros vaciados (NS/SOA del apex preservados en el batch)" || true
# confirmación incorrecta no borra nada
: > "$MOCK_LOG"; out="$(printf 'otro\n111111111111\n' | TEARDOWN_ALLOW_NONTTY=1 "$S/teardown.sh" --dir "$D" --apply --phase 3 2>&1)"; rc=$?
[[ $rc -ne 0 && -z "$(writes_in_log "$MOCK_LOG")" ]] && pass "confirmación incorrecta del nombre: aborta sin borrar" || fail "confirmación incorrecta no abortó"
: > "$MOCK_LOG"; out="$(printf 'demo-x\n222222222222\n' | TEARDOWN_ALLOW_NONTTY=1 "$S/teardown.sh" --dir "$D" --apply --phase 3 2>&1)"; rc=$?
[[ $rc -ne 0 && -z "$(writes_in_log "$MOCK_LOG")" ]] && pass "confirmación incorrecta de la cuenta: aborta sin borrar" || fail "confirmación de cuenta incorrecta no abortó"
: > "$MOCK_LOG"; out="$("$S/teardown.sh" --dir "$D" --apply --phase 3 </dev/null 2>&1)"; rc=$?
[[ $rc -ne 0 && -z "$(writes_in_log "$MOCK_LOG")" ]] && pass "--apply sin terminal interactiva: aborta sin borrar" || fail "apply sin tty no abortó"

echo "== 6. provision.sh en dry-run =="
: > "$MOCK_LOG"
for st in ecr-policy zones external-dns velero efs; do "$S/provision.sh" $st --dir "$D" >/dev/null 2>&1 && pass "provision.sh $st (dry-run)" || fail "provision.sh $st (dry-run)"; done
[[ -z "$(writes_in_log "$MOCK_LOG" | grep -v '^configure')" ]] && pass "provision.sh dry-run: sin escrituras en AWS" || fail "provision.sh dry-run escribió: $(writes_in_log "$MOCK_LOG")"
echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["elasticfilesystem:Describe*"],"Resource":"*"}]}' > "$D/.work/efs-csi-policy.json"
: > "$MOCK_LOG"
"$S/provision.sh" efs-csi --dir "$D" --apply >/dev/null 2>&1 && fail "efs-csi --apply sin --ack-shared-node-role" || pass "efs-csi exige --ack-shared-node-role para aplicar"
[[ -z "$(writes_in_log "$MOCK_LOG" | grep -v '^configure')" ]] && pass "efs-csi sin ack: no escribió nada" || fail "efs-csi escribió sin ack"

echo "== 7. apps-layer.sh (envoltorio del 2-apps-layer-kit; kit FALSO que registra argumentos y entorno) =="
KS="$T/stubkit"; rm -rf "$KS"; mkdir -p "$KS/scripts"; : > "$KS/scripts/lib.sh"
for n in s3-requisites render-apps-layer import-llm-token fetch-universe check-apps-layer launch-apps-layer backups-env; do
  cat > "$KS/scripts/$n.sh" <<EOS
#!/usr/bin/env bash
echo "kitstub :: $n \$*" >> "\$MOCK_LOG"
echo "STUB $n args=[\$*] CLUSTER_ENV_FILE=\$CLUSTER_ENV_FILE KEOS_WORKSPACE_DIR=\$KEOS_WORKSPACE_DIR APPS_LAYER_DIR=\$APPS_LAYER_DIR KIT_AWS_PROFILE=\$KIT_AWS_PROFILE UNIVERSE_BRANCH=\${UNIVERSE_BRANCH:-} NOTTY=\${KIT_TEST_ALLOW_NOTTY:-} BK=\${ENABLE_BACKUPS_BUCKET:-} BKN=\${BACKUPS_BUCKET_NAME:-} BKU=\${BACKUPS_USER_NAME:-} SIZE=\${ENVIRONMENT_SIZE:-} CSF=\${CUSTOM_SIZES_FILE:-}"
exit 0
EOS
  chmod +x "$KS/scripts/$n.sh"
done
AL="$S/apps-layer.sh"; EXPECT_AL="$T/apps-layer-demo-x"
al() { TMPDIR="$T" "$AL" --dir "$D" --kit "$KS" "$@"; }
: > "$MOCK_LOG"
check "apps-layer.sh -h" "$AL" -h
out="$(al env 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "kit=$KS" <<<"$out" && grep -q "workspace keos (/workspace)=$D" <<<"$out" && grep -q "directorio efímero (/apps-layer)=$EXPECT_AL" <<<"$out" && grep -q 'rama-lst=branch-15.1' <<<"$out" && pass "apps-layer.sh env: kit, workspace=<dir>, dir efímero en TMPDIR y rama branch-15.1" || fail "apps-layer.sh env"
[[ "$(APPS_LAYER_KIT="$KS" bash -c "source '$S/lib.sh'; find_apps_layer_kit '' '$D'")" == "$KS" ]] && pass "find_apps_layer_kit respeta APPS_LAYER_KIT" || fail "find_apps_layer_kit APPS_LAYER_KIT"
bash -c "source '$S/lib.sh'; SKILL_DIR=/no/existe; APPS_LAYER_KIT=; find_apps_layer_kit /no/existe '$T/vacio'" >/dev/null 2>&1 && fail "find_apps_layer_kit encontró un kit inexistente" || pass "find_apps_layer_kit devuelve 1 si no hay kit"
out="$(al s3 plan 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "STUB s3-requisites args=\[plan\] CLUSTER_ENV_FILE=$D/cluster.env KEOS_WORKSPACE_DIR=$D APPS_LAYER_DIR=$EXPECT_AL KIT_AWS_PROFILE=cloud-provisioner UNIVERSE_BRANCH=branch-15.1" <<<"$out" && pass "s3 plan delega con CLUSTER_ENV_FILE=<dir>/cluster.env, workspace=<dir>, dir efímero y perfil cloud-provisioner" || { fail "s3 plan delegado"; echo "$out" | sed 's/^/      /'; }
out="$(APPS_LAYER_DIR=/stratio/e/igualdad/apps-layer al s3 status 2>&1)"
grep -q 'se IGNORA' <<<"$out" && grep -q "APPS_LAYER_DIR=$EXPECT_AL " <<<"$out" && ! grep '^STUB' <<<"$out" | grep -q 'APPS_LAYER_DIR=/stratio/e/igualdad/apps-layer ' && pass "APPS_LAYER_DIR exportada (ruta vieja) se ignora avisando: el kit recibe la ruta efímera esperada" || fail "APPS_LAYER_DIR del entorno no se ignoró"
out="$(APPS_LAYER_DIR=/stratio/e/igualdad/apps-layer al --apps-layer-dir /tmp/otra-ruta s3 status 2>&1)"
grep '^STUB' <<<"$out" | grep -q 'APPS_LAYER_DIR=/tmp/otra-ruta ' && ! grep -q 'se IGNORA' <<<"$out" && pass "--apps-layer-dir explícito se respeta" || fail "--apps-layer-dir"
: > "$MOCK_LOG"; out="$(al s3 apply 2>&1)"
grep -q '^kitstub :: s3-requisites plan' "$MOCK_LOG" && ! grep -q 's3-requisites apply' "$MOCK_LOG" && grep -q 'DRY-RUN' <<<"$out" && pass "s3 apply sin --apply: solo muestra el plan (dry-run)" || fail "s3 apply sin --apply ejecutó apply"
: > "$MOCK_LOG"; al s3 apply --apply >/dev/null 2>&1; grep -q '^kitstub :: s3-requisites apply' "$MOCK_LOG" && pass "s3 apply --apply delega en el kit (que pide terminal y confirmación)" || fail "s3 apply --apply"
: > "$MOCK_LOG"; out="$(al s3 delete 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'teardown.sh' <<<"$out" && ! grep -q '^kitstub' "$MOCK_LOG" && pass "s3 delete se rechaza (lo hace teardown.sh fase A)" || fail "s3 delete no rechazado"
: > "$MOCK_LOG"; al render >/dev/null 2>&1; grep -q '^kitstub :: render-apps-layer --dry-run' "$MOCK_LOG" && pass "render es dry-run por defecto" || fail "render no es dry-run"
: > "$MOCK_LOG"; al render --apply --no-aws-creds >/dev/null 2>&1; grep -q '^kitstub :: render-apps-layer --no-aws-creds$' "$MOCK_LOG" && pass "render --apply escribe (sin --dry-run) y pasa el resto de opciones" || fail "render --apply: $(cat "$MOCK_LOG")"
for sub in "token /x/y.yaml:import-llm-token:/x/y.yaml" "fetch:fetch-universe:" "check --no-aws:check-apps-layer:--no-aws" "launch:launch-apps-layer:" "launch --skip-fetch:launch-apps-layer:--skip-fetch" "s3 env:s3-requisites:env"; do
  cmd="${sub%%:*}"; rest="${sub#*:}"; kn="${rest%%:*}"; ka="${rest#*:}"; : > "$MOCK_LOG"
  al $cmd >/dev/null 2>&1; grep -q "^kitstub :: $kn $ka\$" "$MOCK_LOG" && pass "apps-layer.sh $cmd -> $kn.sh $ka" || fail "apps-layer.sh $cmd: $(cat "$MOCK_LOG")"
done
for f in --run --force; do : > "$MOCK_LOG"; al launch $f >/dev/null 2>&1 && fail "launch $f aceptado" || { [[ ! -s "$MOCK_LOG" ]] && pass "launch $f rechazado: la skill nunca ejecuta docker run" || fail "launch $f llegó al kit"; }; done
al nope >/dev/null 2>&1 && fail "subcomando desconocido aceptado" || pass "subcomando desconocido rechazado"
# paso 14h: backups-env delega en el kit (solo escribe backups.env; el wrapper no ejecuta enviroment-ready, docker, kubectl ni aws)
: > "$MOCK_LOG"; out="$(al backups-env --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "^kitstub :: backups-env --dry-run$" "$MOCK_LOG" && grep -q "STUB backups-env args=\[--dry-run\] CLUSTER_ENV_FILE=$D/cluster.env KEOS_WORKSPACE_DIR=$D APPS_LAYER_DIR=$EXPECT_AL KIT_AWS_PROFILE=cloud-provisioner" <<<"$out" && pass "backups-env --dry-run delega en backups-env.sh del kit con cluster.env, workspace y directorio efímero" || { fail "backups-env --dry-run: $(cat "$MOCK_LOG")"; }
: > "$MOCK_LOG"; al backups-env >/dev/null 2>&1; grep -q '^kitstub :: backups-env $' "$MOCK_LOG" && ! grep -qE '^(aws|kubectl|docker|gh|enviroment-ready) ' "$MOCK_LOG" && pass "backups-env sin argumentos delega y el wrapper no lanza aws/kubectl/docker" || fail "backups-env sin args: $(cat "$MOCK_LOG")"
out="$(APPS_LAYER_DIR=/stratio/e/igualdad/apps-layer al backups-env --dry-run 2>&1)"
grep -q 'se IGNORA' <<<"$out" && grep -q "APPS_LAYER_DIR=$EXPECT_AL " <<<"$out" && pass "backups-env respeta la regla de APPS_LAYER_DIR (exportada, se ignora avisando)" || fail "backups-env con APPS_LAYER_DIR exportada"
grep -q 'backups-env' <<<"$("$AL" -h 2>&1)" && grep -q 'ENVIRONMENT_SIZE acepta S|PIT|CUSTOM' <<<"$("$AL" -h 2>&1)" && ! grep -q '^set -uo' <<<"$("$AL" -h 2>&1)" && pass "apps-layer.sh -h documenta backups-env y CUSTOM sin volcar código" || fail "apps-layer.sh -h"
# ENVIRONMENT_SIZE=CUSTOM: el wrapper no lo bloquea y y CUSTOM_SIZES_FILE llegan intactos al kit
DC="$T/dcustom"; rm -rf "$DC"; mkdir -p "$DC"; cp "$D/cluster.env" "$DC/cluster.env"; printf 'export ENVIRONMENT_SIZE=CUSTOM\nexport CUSTOM_SIZES_FILE=/ruta/abs/mis-sizes.env\n' >> "$DC/cluster.env"
out="$(TMPDIR="$T" "$AL" --dir "$DC" --kit "$KS" env 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'size=CUSTOM' <<<"$out" && grep -q 'overlay de recursos=/ruta/abs/mis-sizes.env' <<<"$out" && pass "env con ENVIRONMENT_SIZE=CUSTOM: lo acepta e informa del overlay (CUSTOM_SIZES_FILE)" || { fail "env con CUSTOM"; echo "$out" | sed 's/^/      /'; }
: > "$MOCK_LOG"; out="$(TMPDIR="$T" "$AL" --dir "$DC" --kit "$KS" render 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'STUB render-apps-layer args=\[--dry-run\].* SIZE=CUSTOM CSF=/ruta/abs/mis-sizes.env' <<<"$out" && pass "render con CUSTOM: el kit recibe ENVIRONMENT_SIZE=CUSTOM y CUSTOM_SIZES_FILE" || { fail "render con CUSTOM"; echo "$out" | sed 's/^/      /'; }

echo "== 7b. apps-layer.sh prereqs / plan (solo lectura, mocks) =="
: > "$MOCK_LOG"; out="$(al prereqs 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'RESULTADO: OK' <<<"$out" && pass "prereqs OK: tenant keos Active, cct-orchestrator Running, NLB, gh autenticado" || { fail "prereqs rc=$rc"; echo "$out" | sed 's/^/      /'; }
grep -q 'gh lee Stratio/kubernetes-universe universe-images.lst@branch-15.1' <<<"$out" && pass "prereqs comprueba el acceso de gh a Stratio/kubernetes-universe@branch-15.1" || fail "prereqs no comprueba gh api"
w="$(writes_in_log "$MOCK_LOG")"; [[ -z "$w" ]] && pass "prereqs: ninguna escritura en AWS/kubectl/docker" || fail "prereqs escribió: $w"
out="$(MOCK_GH_NOAUTH=1 al prereqs 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'gh auth login' <<<"$out" && grep -q 'PARAR' <<<"$out" && pass "prereqs: gh sin autenticar => KO con mensaje claro (parar)" || fail "prereqs con gh sin auth rc=$rc"
out="$(MOCK_GH_FAIL=1 al prereqs 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no puede leer universe-images.lst' <<<"$out" && pass "prereqs: gh sin acceso al repo => KO" || fail "prereqs con gh api roto rc=$rc"
out="$(MOCK_TENANT_STATE=Pending al prereqs 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'keos install no ha terminado' <<<"$out" && pass "prereqs: tenant keos no Active => KO" || fail "prereqs con tenant Pending rc=$rc"
out="$(MOCK_ACCOUNT=999999999999 al prereqs 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'sts:' <<<"$out" && pass "prereqs: cuenta incorrecta => KO" || fail "prereqs con cuenta incorrecta"
: > "$MOCK_LOG"; out="$(al plan 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'STUB s3-requisites args=\[plan\]' <<<"$out" && grep -q 'STUB render-apps-layer args=\[--dry-run\]' <<<"$out" && pass "plan: prereqs + s3-requisites plan + render --dry-run" || { fail "plan rc=$rc"; echo "$out" | sed 's/^/      /' | tail -8; }
w="$(writes_in_log "$MOCK_LOG")"; [[ -z "$w" ]] && pass "plan: sin escrituras" || fail "plan escribió: $w"

echo "== 8. teardown fase A (apps-layer): contenedores, directorio efímero, requisitos S3 =="
mkal() { rm -rf "$EXPECT_AL"; mkdir -m 700 "$EXPECT_AL"; echo "export X=1" > "$EXPECT_AL/.env"; mkdir -m 700 "$EXPECT_AL/aws"; echo k > "$EXPECT_AL/kube-config"; }
td() { TMPDIR="$T" APPS_LAYER_KIT="$KS" "$S/teardown.sh" --dir "$D" "$@"; }
mkal; : > "$MOCK_LOG"; out="$(MOCK_APPS_UP=1 MOCK_APPS_OTHER=1 td --phase A 2>&1)"; rc=$?
echo "$out" > "$T/faseA.out"
[[ $rc -eq 0 ]] && pass "fase A dry-run: rc=0" || { fail "fase A dry-run rc=$rc (ver $T/faseA.out)"; }
grep -q '\[DRY-RUN\] pararía y borraría el contenedor apps-layer-demo-x' <<<"$out" && grep -q '\[DRY-RUN\] pararía y borraría el contenedor keos-installer_demo-x' <<<"$out" && pass "fase A dry-run: planifica los dos contenedores por nombre exacto" || fail "fase A: contenedores"
grep -q "\[DRY-RUN\] borraría de forma segura (shred + rm -rf) $EXPECT_AL" <<<"$out" && [[ -f "$EXPECT_AL/.env" ]] && pass "fase A dry-run: planifica el directorio efímero y no lo toca" || fail "fase A: directorio efímero"
grep -q 'lanzados a mano que NO se tocan' <<<"$out" && grep -q 'adoring_raman' <<<"$out" && pass "fase A: avisa de contenedores apps-layer lanzados a mano (no se tocan)" || fail "fase A: contenedor ajeno"
grep -q 'se CONSERVAN' <<<"$out" && grep -q 'delete-s3-requisites' <<<"$out" && pass "fase A: bucket/stack S3 se conservan por defecto (Retain) e indica el flag" || fail "fase A: S3 por defecto"
[[ -z "$(writes_in_log "$MOCK_LOG")" ]] && ! grep -qE '^docker :: (stop|rm)' "$MOCK_LOG" && ! grep -q '^kitstub' "$MOCK_LOG" && pass "fase A dry-run: ninguna escritura, docker stop/rm ni kit invocado" || fail "fase A dry-run escribió: $(writes_in_log "$MOCK_LOG")"
out="$(td 2>&1)"; l1="$(grep -n 'Fase A' <<<"$out" | head -1 | cut -d: -f1)"; l2="$(grep -n 'Fase 1 ' <<<"$out" | head -1 | cut -d: -f1)"; l9="$(grep -n 'Fase 2 ' <<<"$out" | head -1 | cut -d: -f1)"
[[ -n "$l1" && -n "$l2" && "$l1" -lt "$l2" && "$l2" -lt "$l9" ]] && pass "el dry-run por defecto incluye la fase A ANTES de las fases del clúster (1, 2...)" || fail "orden fase A ($l1,$l2,$l9)"
: > "$MOCK_LOG"; out="$(MOCK_APPS_UP=1 td --phase A --delete-s3-requisites 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[DRY-RUN\] ejecutaría 2-apps-layer-kit/scripts/s3-requisites.sh delete' <<<"$out" && ! grep -q '^kitstub' "$MOCK_LOG" && pass "fase A --delete-s3-requisites en dry-run: solo planifica (no invoca al kit)" || fail "delete-s3 dry-run rc=$rc"
[[ -z "$(writes_in_log "$MOCK_LOG")" ]] && pass "delete-s3 dry-run: sin escrituras" || fail "delete-s3 dry-run escribió"
td --phase 1 --delete-s3-requisites >/dev/null 2>&1 && fail "--delete-s3-requisites sin fase A" || pass "--delete-s3-requisites exige la fase A"
out="$(MOCK_CALLER_ARN="arn:aws:iam::111111111111:user/demo-x-s3" td --phase A --delete-s3-requisites 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'GUARDA' <<<"$out" && pass "guarda: si el llamador es el usuario IAM S3 a borrar, aborta" || fail "guarda del usuario S3 (rc=$rc)"
out="$(MOCK_REQ_OTHER=1 td --phase A 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no es de este clúster' <<<"$out" && pass "pertenencia: un stack de otro clúster aborta" || fail "stack ajeno no abortó (rc=$rc)"
out="$(MOCK_NO_REQUISITES=1 td --phase A 2>&1)"; grep -q 'stack demo-x-requisites=no' <<<"$out" && pass "sin stack: lo dice (bucket/usuario según AWS)" || fail "sin stack"
out="$(MOCK_APPS_UP=1 MOCK_APPS_IMG=docker.io/library/nginx:1 td --phase A 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no parece de apps-layer-automation' <<<"$out" && pass "un contenedor apps-layer-<C> con otra imagen aborta (no se borra)" || fail "imagen ajena no abortó (rc=$rc)"
out="$(APPS_LAYER_DIR=/tmp/otra-cosa td --phase A 2>&1)"; grep -q 'no se llama apps-layer-demo-x: NO se borra' <<<"$out" && pass "APPS_LAYER_DIR exportada con otro nombre: no se borra" || fail "APPS_LAYER_DIR ajena"
mkdir -p "$D/apps-layer"; out="$(td --phase A 2>&1)"; rmdir "$D/apps-layer"
grep -q 'ubicación ANTIGUA' <<<"$out" && pass "avisa de la ubicación antigua <dir>/apps-layer (no la toca)" || fail "ubicación antigua"
# apply: sin flag, contenedores + directorio, bucket intacto
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\n' | MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 td --apply --phase A 2>&1)"; rc=$?
echo "$out" > "$T/faseA-apply.out"
[[ $rc -eq 0 || $rc -eq 2 ]] && pass "fase A --apply (mock) rc=$rc (2 = el mock no elimina de verdad los contenedores)" || fail "fase A apply rc=$rc (ver $T/faseA-apply.out)"
a="$(grep -nE '^docker :: stop -t 30 apps-layer-demo-x' "$MOCK_LOG" | head -1 | cut -d: -f1)"; b="$(grep -nE '^docker :: stop -t 30 keos-installer_demo-x' "$MOCK_LOG" | head -1 | cut -d: -f1)"
[[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] && pass "apply: para primero apps-layer-<C> y luego keos-installer_<C>" || fail "orden de parada ($a,$b)"
grep -qE '^docker :: rm -f (apps-layer-demo-x|keos-installer_demo-x)' "$MOCK_LOG" && ! grep -E '^docker :: (stop|rm)' "$MOCK_LOG" | grep -vqE 'apps-layer-demo-x|keos-installer_demo-x' && pass "apply: solo se tocan los dos contenedores por nombre exacto" || fail "docker stop/rm fuera de lo esperado: $(grep -E '^docker :: (stop|rm)' "$MOCK_LOG")"
[[ ! -e "$EXPECT_AL" ]] && pass "apply: directorio efímero borrado" || fail "apply: sigue existiendo $EXPECT_AL"
! grep -q '^kitstub' "$MOCK_LOG" && ! grep -qE '^(s3api (delete-bucket|delete-objects)|cloudformation delete-stack|iam delete-user)' "$MOCK_LOG" && pass "apply sin --delete-s3-requisites: no se toca stack, bucket ni usuario S3" || fail "apply sin flag tocó S3"
# apply: con flag y confirmación del bucket
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\ndemo-x-internal-111111111111\n' | MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 td --apply --phase A --delete-s3-requisites 2>&1)"; rc=$?
grep -q '^kitstub :: s3-requisites delete' "$MOCK_LOG" && grep -q 'NOTTY=1' <<<"$out" && pass "apply + --delete-s3-requisites + bucket tecleado: invoca s3-requisites.sh delete del kit" || fail "no invocó delete (rc=$rc)"
grep -q "STUB s3-requisites args=\[delete\] CLUSTER_ENV_FILE=$D/cluster.env KEOS_WORKSPACE_DIR=$D APPS_LAYER_DIR=$EXPECT_AL KIT_AWS_PROFILE=cloud-provisioner" <<<"$out" && pass "el kit recibe cluster.env, workspace, dir efímero esperado y el perfil" || fail "entorno del kit en delete"
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\notro-bucket\n' | MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 td --apply --phase A --delete-s3-requisites 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^kitstub' "$MOCK_LOG" && pass "bucket mal tecleado: aborta sin llamar al kit" || fail "bucket mal tecleado no abortó (rc=$rc)"
# directorio efímero como enlace simbólico: no se sigue
rm -rf "$EXPECT_AL" "$T/real-al"; mkdir -m 700 "$T/real-al"; echo precioso > "$T/real-al/dato"; ln -s "$T/real-al" "$EXPECT_AL"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\n' | TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 td --apply --phase A 2>&1)"
[[ -f "$T/real-al/dato" ]] && grep -q 'enlace simbólico' <<<"$out" && pass "directorio efímero que es un enlace simbólico: no se sigue ni se borra" || fail "enlace simbólico seguido"
rm -f "$EXPECT_AL"
# fase 8: lo que apps-layer deja en el workspace aparece en los grupos
touch "$D/admin.key" "$D/demo-x-dev-tenant.yaml"; out="$(td --phase 8 2>&1)"
grep -q 'admin.key' <<<"$out" && grep -q 'demo-x-dev-tenant.yaml' <<<"$out" && [[ -f "$D/admin.key" ]] && pass "fase 8 lista admin.key y los YAML de tenant de apps-layer (sin --delete-local no borra)" || fail "fase 8 no lista lo de apps-layer"
rm -f "$D/admin.key" "$D/demo-x-dev-tenant.yaml"
mkdir -p "$D/override_charts_values"; out="$(td --phase 8 2>&1)"; grep -q 'grupo A.*override_charts_values' <<<"$out" && [[ -d "$D/override_charts_values" ]] && pass "fase 8 lista override_charts_values/ en el grupo A (sin --delete-local no borra nada)" || fail "fase 8 sin override_charts_values"
rmdir "$D/override_charts_values"

echo "== 9. bucket de backups OPCIONAL (migración a GitOps): apps-layer.sh y teardown fase A =="
BKB=demo-x-backups-111111111111; BKU=demo-x-backups; BKENV=(MOCK_BACKUPS_BUCKET=1 MOCK_BACKUPS_USER=1 MOCK_BACKUPS_SECRET=1 MOCK_BACKUPS_OUT=1)
# 9a) envoltorio
: > "$MOCK_LOG"; out="$(al s3 backups-info 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'STUB s3-requisites args=\[backups-info\] CLUSTER_ENV_FILE=' <<<"$out" && grep -q '^kitstub :: s3-requisites backups-info$' "$MOCK_LOG" && pass "s3 backups-info delega en el kit (solo lectura)" || fail "s3 backups-info"
grep -q 'BK= BKN= BKU=' <<<"$out" && pass "sin variables de backups en el shell: no se reenvía nada (el kit usa cluster.env/kit.env/defectos: desactivado)" || fail "no debería reenviar ENABLE_BACKUPS_BUCKET"
out="$(ENABLE_BACKUPS_BUCKET=true BACKUPS_BUCKET_NAME=otro-backups-9 BACKUPS_USER_NAME=otro-bk al s3 plan 2>&1)"
grep -q 'BK=true BKN=otro-backups-9 BKU=otro-bk' <<<"$out" && pass "ENABLE_BACKUPS_BUCKET/BACKUPS_BUCKET_NAME/BACKUPS_USER_NAME exportadas en el shell se pasan al kit" || fail "reenvío de variables de backups: $out"
cp "$D/cluster.env" "$T/cluster.env.bk"; printf 'export ENABLE_BACKUPS_BUCKET=true\n' >> "$D/cluster.env"
out="$(ENABLE_BACKUPS_BUCKET=false al s3 plan 2>&1)"
grep -q 'BK=false' <<<"$out" && pass "una variable exportada en el shell gana a cluster.env (el kit respeta ese orden)" || fail "prioridad del entorno"
out="$(al env 2>&1)"; grep -q 'bucket de backups (opcional, GitOps)=enabled:true bucket=demo-x-backups-111111111111 usuario=demo-x-backups' <<<"$out" && pass "env muestra el estado de backups desde cluster.env (y nombres por defecto)" || fail "env de backups: $out"
cp "$T/cluster.env.bk" "$D/cluster.env"
out="$(al env 2>&1)"; grep -q 'enabled:false' <<<"$out" && pass "env: backups desactivado por defecto" || fail "env sin backups"
out="$(al s3 apply 2>&1)"; grep -q 'ENABLE_BACKUPS_BUCKET=true' <<<"$out" && grep -q 'DRY-RUN' <<<"$out" && pass "s3 apply sin --apply sigue siendo dry-run y menciona el bucket de backups" || fail "dry-run s3 apply"
out="$(al s3 delete 2>&1)"; grep -q -- '--delete-backups' <<<"$out" && pass "s3 delete se rechaza y remite a teardown (--delete-backups)" || fail "mensaje de s3 delete"
al s3 nope >/dev/null 2>&1 && fail "s3 desconocido aceptado" || pass "s3 desconocido rechazado"
check "templates/cluster.env.example documenta ENABLE_BACKUPS_BUCKET=false, BACKUPS_BUCKET_NAME y BACKUPS_USER_NAME" bash -c "grep -q 'ENABLE_BACKUPS_BUCKET=false' '$SK/templates/cluster.env.example' && grep -q 'BACKUPS_BUCKET_NAME=\${CLUSTER_NAME}-backups-\${AWS_ACCOUNT_ID}' '$SK/templates/cluster.env.example' && grep -q 'BACKUPS_USER_NAME=\${CLUSTER_NAME}-backups' '$SK/templates/cluster.env.example'"
check "cluster.env.example sigue sin definir backups por defecto (todo comentado)" bash -c "! grep -E '^export (ENABLE_BACKUPS_BUCKET|BACKUPS_)' '$SK/templates/cluster.env.example'"
# 9b) teardown fase A sin backups: igual que antes
mkal; : > "$MOCK_LOG"; out="$(td --phase A 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! grep -qi 'backups' <<<"$out" && pass "fase A sin recursos de backups: la salida no los menciona (igual que antes)" || fail "fase A sin backups menciona backups (rc=$rc)"
# 9c) con recursos de backups: se informan y se conservan
mkal; : > "$MOCK_LOG"; out="$(env "${BKENV[@]}" bash -c "TMPDIR='$T' APPS_LAYER_KIT='$KS' '$S/teardown.sh' --dir '$D' --phase A" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "bucket de BACKUPS (opcional, plataforma Stratio/GitOps): en el stack=si bucket $BKB=existe usuario IAM $BKU=existe secreto=existe" <<<"$out" && pass "fase A: informa del bucket/usuario/secreto de backups" || { fail "fase A con backups (rc=$rc)"; echo "$out" | grep -i backups | sed 's/^/      /'; }
grep -q "el bucket de backups $BKB, su usuario $BKU y su secreto se CONSERVAN también" <<<"$out" && grep -q -- '--delete-s3-requisites --delete-backups' <<<"$out" && pass "fase A: los CONSERVA por defecto e indica cómo borrarlos" || fail "fase A: no dice que se conservan"
grep -q "bucket de backups $BKB (Retain) conservado a propósito" <<<"$out" && pass "verificación: el bucket de backups figura como conservado a propósito (no como KO)" || fail "verificación de backups"
[[ -z "$(writes_in_log "$MOCK_LOG")" ]] && ! grep -q '^kitstub' "$MOCK_LOG" && pass "fase A con backups en dry-run: sin escrituras ni kit" || fail "dry-run con backups escribió"
# --delete-s3-requisites sin --delete-backups: se conserva el bucket (aviso del usuario/clave/secreto del stack)
out="$(env "${BKENV[@]}" bash -c "TMPDIR='$T' APPS_LAYER_KIT='$KS' '$S/teardown.sh' --dir '$D' --phase A --delete-s3-requisites" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "el bucket de backups $BKB se CONSERVA (sin --delete-backups); ojo: si el stack lo tiene" <<<"$out" && grep -q '\[DRY-RUN\] ejecutaría 2-apps-layer-kit/scripts/s3-requisites.sh delete' <<<"$out" && ! grep -q 'con --delete-backups' <<<"$out" && pass "dry-run --delete-s3-requisites: conserva el bucket de backups y no planifica borrarlo" || fail "dry-run delete-s3 sin --delete-backups (rc=$rc)"
# con --delete-backups
out="$(env "${BKENV[@]}" bash -c "TMPDIR='$T' APPS_LAYER_KIT='$KS' '$S/teardown.sh' --dir '$D' --phase A --delete-s3-requisites --delete-backups" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "se borrará TAMBIÉN el bucket de BACKUPS $BKB" <<<"$out" && grep -q "\[DRY-RUN\] con --delete-backups ('s3-requisites.sh delete --delete-backups'): vaciar y borrar también el bucket de BACKUPS $BKB" <<<"$out" && pass "dry-run --delete-s3-requisites --delete-backups: planifica el borrado del bucket de backups con confirmación extra" || fail "dry-run con --delete-backups (rc=$rc)"
out="$(env "${BKENV[@]}" bash -c "TMPDIR='$T' APPS_LAYER_KIT='$KS' '$S/teardown.sh' --dir '$D' --phase A --delete-s3-requisites --delete-backups" 2>&1)"
grep -q "KO  bucket de backups $BKB" <<<"$out" && pass "verificación (dry-run): con --delete-backups el bucket aún existe => KO esperado" || fail "verificación con --delete-backups"
td --phase A --delete-backups >/dev/null 2>&1 && fail "--delete-backups sin --delete-s3-requisites aceptado" || pass "--delete-backups exige --delete-s3-requisites"
out="$(td --phase A --delete-backups 2>&1)"; grep -q 'solo se admite junto a --delete-s3-requisites' <<<"$out" && pass "--delete-backups solo: mensaje claro" || fail "mensaje de --delete-backups solo"
out="$(env "${BKENV[@]}" bash -c "TMPDIR='$T' APPS_LAYER_KIT='$KS' '$S/teardown.sh' --dir '$D' --phase 1 --delete-backups --delete-s3-requisites" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'pertenece a la fase A' <<<"$out" && pass "--delete-backups sin la fase A: rechazado" || fail "delete-backups sin fase A"
# guardas de identidades protegidas
for pu in cloud-provisioner igualdad; do
  out="$(BACKUPS_USER_NAME=$pu td --phase A --delete-s3-requisites 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && grep -q 'PROTEGIDA' <<<"$out" && pass "guarda: BACKUPS_USER_NAME=$pu aborta (identidad protegida)" || fail "guarda BACKUPS_USER_NAME=$pu (rc=$rc)"
done
out="$(CP_PROFILE=x BACKUPS_USER_NAME=demo-x-s3 td --phase A 2>&1)"; [[ $? -eq 0 ]] && pass "BACKUPS_USER_NAME protegido solo importa al borrar (--delete-s3-requisites); en dry-run informativo no aborta" || fail "guarda sin flag"
# 9d) apply: el kit recibe delete sin o con --delete-backups
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\ndemo-x-internal-111111111111\n' | env "${BKENV[@]}" MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 TMPDIR="$T" APPS_LAYER_KIT="$KS" "$S/teardown.sh" --dir "$D" --apply --phase A --delete-s3-requisites 2>&1)"; rc=$?
grep -q '^kitstub :: s3-requisites delete$' "$MOCK_LOG" && pass "apply --delete-s3-requisites (sin --delete-backups): el kit recibe 'delete' a secas (conserva el bucket de backups)" || fail "kit sin --delete-backups: $(cat "$MOCK_LOG" | grep kitstub)"
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\ndemo-x-internal-111111111111\n%s\n' "$BKB" | env "${BKENV[@]}" MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 TMPDIR="$T" APPS_LAYER_KIT="$KS" "$S/teardown.sh" --dir "$D" --apply --phase A --delete-s3-requisites --delete-backups 2>&1)"; rc=$?
grep -q '^kitstub :: s3-requisites delete --delete-backups$' "$MOCK_LOG" && pass "apply con ambos flags + nombre del bucket de backups tecleado: el kit recibe 'delete --delete-backups'" || fail "kit con --delete-backups (rc=$rc): $(grep kitstub "$MOCK_LOG")"
grep -q 'ATENCIÓN EXTRA' <<<"$out" && pass "apply con --delete-backups: aviso EXTRA de copias de seguridad irreversibles" || fail "falta el aviso EXTRA"
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\ndemo-x-internal-111111111111\nnombre-malo\n' | env "${BKENV[@]}" MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 TMPDIR="$T" APPS_LAYER_KIT="$KS" "$S/teardown.sh" --dir "$D" --apply --phase A --delete-s3-requisites --delete-backups 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^kitstub' "$MOCK_LOG" && pass "nombre del bucket de backups mal tecleado: aborta sin llamar al kit" || fail "confirmación extra no abortó (rc=$rc)"
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\ndemo-x-internal-111111111111\ndemo-x-internal-111111111111\n' | env "${BKENV[@]}" MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 TMPDIR="$T" APPS_LAYER_KIT="$KS" "$S/teardown.sh" --dir "$D" --apply --phase A --delete-s3-requisites --delete-backups 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^kitstub' "$MOCK_LOG" && pass "teclear el bucket interno en la confirmación del de backups no vale" || fail "confirmación extra aceptó el bucket interno"
# --delete-backups sin bucket de backups existente: el kit recibe 'delete' a secas y no hay confirmación extra
mkal; : > "$MOCK_LOG"
out="$(printf 'demo-x\n111111111111\ns\ns\ns\ndemo-x-internal-111111111111\n' | MOCK_APPS_UP=1 TEARDOWN_ALLOW_NONTTY=1 TEARDOWN_NO_WAIT=1 TMPDIR="$T" APPS_LAYER_KIT="$KS" "$S/teardown.sh" --dir "$D" --apply --phase A --delete-s3-requisites --delete-backups 2>&1)"; rc=$?
grep -q '^kitstub :: s3-requisites delete$' "$MOCK_LOG" && grep -q 'nada extra que borrar' <<<"$out" && pass "--delete-backups sin recursos de backups: nada extra, sin confirmación extra" || fail "--delete-backups sin recursos (rc=$rc)"
check "teardown.md/SKILL.md/PLAN.md/steps.md/gotchas.md/resources-by-step.md/open-risks.md documentan el bucket de backups y --delete-backups" bash -c "cd '$SK' && grep -q -- '--delete-backups' references/teardown.md && grep -q 'backups-info' SKILL.md && grep -q 'ENABLE_BACKUPS_BUCKET' PLAN.md references/steps.md references/gotchas.md references/resources-by-step.md references/open-risks.md SKILL.md"
rm -rf "$EXPECT_AL"

echo "== 10. paso 13b y flags opcionales: helm_repository, authenticator, keos.yaml/override_vars condicionales, render-postinstall =="
AWS_REPO="$(cd "$SK/../../.." && pwd)/1-aws-cluster"
mk13() {  # mk13 NOMBRE [CLAVE=VALOR ...]: dir de prueba nuevo (cluster.env de init-cluster + VPC ficticia) bajo $T/p13
  local d="$T/p13/$1"; shift; rm -rf "$d"; mkdir -p "$T/p13"
  "$S/init-cluster.sh" --account 111111111111 --name demo-x --no-detect --admin-profile igualdad --dir "$d" --set CLOUD_PROVISIONER_BIN="$HERE/mock/bin/cloud-provisioner" >/dev/null 2>&1 || return 1
  local kv; for kv in "$@"; do "$S/init-cluster.sh" --dir "$d" --set "$kv" >/dev/null 2>&1; done
  cp "$D/demo-x.json" "$d/demo-x.json"; echo "$d"
}
rk() { EFS_ID=fs-0abc "$S/render-keos.sh" --dir "$1" >/dev/null 2>&1; }
# (a) cluster.yaml: helm_repository.url con KEOS_HELM_PATH (default helm-15.1) y authenticator: true
P1="$(mk13 off)"
AWS_ACCESS_KEY=AKIAFAKEFAKEFAKE0000 AWS_SECRET_KEY=fakesecretfakesecret "$S/render-cluster.sh" --dir "$P1" >/dev/null 2>&1 && pass "(a) render-cluster.sh con los flags nuevos sin definir" || fail "(a) render-cluster.sh"
[[ "$(yq -r 'select(.kind=="KeosCluster")|.spec.helm_repository.url' "$P1/cluster.yaml" | head -1)" == "oci://717279725338.dkr.ecr.eu-west-1.amazonaws.com/helm" ]] && pass "(a) cluster.yaml: helm_repository.url termina en /helm" || fail "(a) helm_repository.url"
[[ "$(yq -r 'select(.kind=="KeosCluster")|.spec.control_plane.aws.logging.authenticator' "$P1/cluster.yaml" | head -1)" == true ]] && pass "(a) cluster.yaml: logging.authenticator: true" || fail "(a) authenticator"
[[ "$(grep -c '\${' "$P1/cluster.yaml")" -eq 0 ]] && pass "(a) cluster.yaml sin \${ residual" || fail "(a) \${ residual en cluster.yaml"
sed -i '/^export CP_HELM_PATH=/d' "$P1/cluster.env"
AWS_ACCESS_KEY=AKIAFAKEFAKEFAKE0000 AWS_SECRET_KEY=fakesecretfakesecret "$S/render-cluster.sh" --dir "$P1" >/dev/null 2>&1 && grep -q '/helm$' "$P1/cluster.yaml" && pass "(a) sin CP_HELM_PATH en cluster.env: default helm" || fail "(a) default de CP_HELM_PATH"
P2="$(mk13 helm99 CP_HELM_PATH=helm-99)"
AWS_ACCESS_KEY=AKIAFAKEFAKEFAKE0000 AWS_SECRET_KEY=fakesecretfakesecret "$S/render-cluster.sh" --dir "$P2" >/dev/null 2>&1 && grep -q 'oci://.*/helm-99$' "$P2/cluster.yaml" && pass "(a) CP_HELM_PATH=helm-99 llega a cluster.yaml" || fail "(a) CP_HELM_PATH personalizado"
# (b) flags apagados: keos.yaml (29 líneas) y override_vars (22) como antes, sin claves nuevas ni override_charts_values
P3="$(mk13 off2)"; rk "$P3" && pass "(b) render-keos.sh con flags por defecto" || fail "(b) render-keos.sh"
[[ "$(yq -r '.keos|keys|join(",")' "$P3/keos.yaml")" == "cluster_id,domain,external_domain,flavour,k8s_installation,storage" ]] && ! grep -Eq '^  backup:|^    storage_class:|clamav|falco|opensearch_output' "$P3/keos.yaml" && [[ "$(wc -l < "$P3/keos.yaml")" -eq 29 ]] && pass "(b) keos.yaml sin backup/security (29 líneas, como antes)" || fail "(b) keos.yaml con claves nuevas"
! grep -q 'velero_enable_snapshot_volumes' "$P3/override_vars/demo-x.yaml" && [[ "$(wc -l < "$P3/override_vars/demo-x.yaml")" -eq 22 ]] && pass "(b) override_vars sin velero_enable_snapshot_volumes (22 líneas, como antes)" || fail "(b) override_vars con claves nuevas"
[[ ! -e "$P3/override_charts_values" ]] && pass "(b) sin override_charts_values con ENABLE_BACKUP_VELERO=false" || fail "(b) override_charts_values creado sin flag"
P4="$(mk13 bad ENABLE_FALCO=quizas)"; EFS_ID=fs-0abc "$S/render-keos.sh" --dir "$P4" >/dev/null 2>&1 && fail "(b) acepta ENABLE_FALCO inválido" || pass "(b) rechaza un flag con valor distinto de true/false"
# (b2) flags exportados en el entorno de la shell NO activan nada: solo cuenta lo escrito en cluster.env
P3E="$(mk13 envflags)"; ENABLE_FALCO=true KEOS_ENABLE_CLAMAV=true ENABLE_BACKUP_VELERO=true ENABLE_MONITORING=true EFS_ID=fs-0abc "$S/render-keos.sh" --dir "$P3E" >/dev/null 2>&1 \
  && ! grep -Eq '^  backup:|^  security:|clamav|falco' "$P3E/keos.yaml" && [[ ! -e "$P3E/override_charts_values" ]] && ! grep -q velero_enable_snapshot_volumes "$P3E/override_vars/demo-x.yaml" \
  && cmp -s "$P3E/keos.yaml" "$P3/keos.yaml" && pass "(b2) flags exportados en el entorno: render-keos.sh los ignora (keos.yaml sin backup/security, sin override_charts_values)" || fail "(b2) un flag del entorno activó algo en render-keos.sh"
out="$(ENABLE_FALCO=true ENABLE_MONITORING=true ENABLE_BACKUP_VELERO=true ENABLE_CENTRAL_LOGGING=true ENABLE_BACKUP_SCHEDULE=true "$S/render-postinstall.sh" --dir "$P3E" 2>&1)"
grep -q 'AVISO: ningún bloque opcional' <<<"$out" && ! grep -qE '^(keos|sed|kubectl) ' <<<"$out" && pass "(b2) flags exportados en el entorno: render-postinstall.sh los ignora (solo el AVISO, ningún comando)" || fail "(b2) render-postinstall.sh activó un flag del entorno"
# (c) ENABLE_BACKUP_VELERO=true
P5="$(mk13 vel ENABLE_BACKUP_VELERO=true)"; rk "$P5" && pass "(c) render-keos.sh con ENABLE_BACKUP_VELERO=true" || fail "(c) render-keos.sh"
[[ "$(yq -r '.keos.backup.storage_class' "$P5/keos.yaml")" == efs-demo-x ]] && pass "(c) keos.yaml: keos.backup.storage_class=efs-demo-x" || fail "(c) storage_class"
grep -q '^velero_enable_snapshot_volumes: true$' "$P5/override_vars/demo-x.yaml" && pass "(c) override_vars: velero_enable_snapshot_volumes: true" || fail "(c) velero_enable_snapshot_volumes"
[[ "$(yq -r '.credentials.useSecret' "$P5/override_charts_values/keos-backup-velero.yaml")" == false ]] && pass "(c) override_charts_values/keos-backup-velero.yaml con useSecret: false" || fail "(c) keos-backup-velero.yaml"
! yq -r '.keos|keys[]' "$P5/keos.yaml" | grep -qx security && pass "(c) sin security si no hay clamav/falco" || fail "(c) security inesperado"
cp "$P5/override_charts_values/keos-backup-velero.yaml" "$T/vel.bk"; rk "$P5" && cmp -s "$T/vel.bk" "$P5/override_charts_values/keos-backup-velero.yaml" && ! ls "$P5/override_charts_values/" | grep -q '\.bak' && pass "(c) idempotente: no reescribe ni crea .bak" || fail "(c) no idempotente"
printf -- '---\nother: 1\n' > "$P5/override_charts_values/keos-backup-velero.yaml"; rk "$P5" && ls "$P5/override_charts_values/" | grep -q 'keos-backup-velero.yaml.bak' && grep -q 'useSecret: false' "$P5/override_charts_values/keos-backup-velero.yaml" && pass "(c) un fichero previo distinto se conserva como .bak antes de escribir" || fail "(c) no conserva el fichero previo"
# (d) falco y clamav
P6="$(mk13 fal ENABLE_FALCO=true)"; rk "$P6" && [[ "$(yq -r '.keos.security.falco.enabled' "$P6/keos.yaml")" == false ]] && pass "(d) ENABLE_FALCO=true: keos.yaml lleva falco.enabled: false" || fail "(d) falco.enabled"
! grep -q 'clamav' "$P6/keos.yaml" && pass "(d) sin clamav si KEOS_ENABLE_CLAMAV no está activo" || fail "(d) clamav inesperado"
P7="$(mk13 clam KEOS_ENABLE_CLAMAV=true)"; rk "$P7" && [[ "$(yq -r '.keos.security.clamav.enabled' "$P7/keos.yaml")" == true ]] && ! grep -q falco "$P7/keos.yaml" && pass "(d) KEOS_ENABLE_CLAMAV=true: security.clamav.enabled: true (sin falco)" || fail "(d) clamav"
P8="$(mk13 all ENABLE_BACKUP_VELERO=true KEOS_ENABLE_CLAMAV=true ENABLE_FALCO=true ENABLE_MONITORING=true ENABLE_CENTRAL_LOGGING=true ENABLE_BACKUP_SCHEDULE=true)"; rk "$P8" \
  && [[ "$(grep -c '\${' "$P8/keos.yaml" "$P8/override_vars/demo-x.yaml" | grep -vc ':0$')" -eq 0 ]] && [[ "$(yq -r '.keos.security.falco.enabled' "$P8/keos.yaml")" == false ]] && pass "(d) todos los flags: YAML válido, sin \${ y falco.enabled: false" || fail "(d) todos los flags"
# (e) render-postinstall.sh
pi() { "$S/render-postinstall.sh" --dir "$1" 2>&1; }
out="$(pi "$P3")"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'AVISO' <<<"$out" && grep -q 'ENABLE_MONITORING' <<<"$out" && grep -q 'ENABLE_FALCO' <<<"$out" && grep -q 'ENABLE_BACKUP_SCHEDULE' <<<"$out" && ! grep -qE '^(keos|sed|kubectl) ' <<<"$out" && pass "(e) render-postinstall sin flags: rc=0, AVISO con las opciones y ningún comando" || fail "(e) postinstall sin flags"
out="$(pi "$P8")"; rc=$?
ok=1; for pat in '^keos monitoring$' '^kubectl -n keos-metrics get cm \$CM' 'patch --patch-file|--patch-file /dev/stdin' '^keos backup velero$' '^kubectl -n keos-backup get bsl aws' '^keos backup schedule vault idp$' '^keos central-logging$' "^sed -i '/\^    falco:/" '^kubectl -n keos-ops patch keos keos --type merge' '^keos falco$'; do grep -Eq -- "$pat" <<<"$out" || { ok=0; echo "      falta: $pat"; }; done
[[ $rc -eq 0 && $ok -eq 1 ]] && pass "(e) render-postinstall con todos los flags: imprime los comandos esperados" || fail "(e) postinstall con flags"
ord="$(grep -nE '^(keos monitoring|keos backup velero|keos backup schedule vault idp|keos central-logging|keos falco)$' <<<"$out" | cut -d: -f2 | tr '\n' ',')"
[[ "$ord" == "keos monitoring,keos backup velero,keos backup schedule vault idp,keos central-logging,keos falco," ]] && pass "(e) orden: monitoring, velero, schedule, central-logging, falco" || fail "(e) orden: $ord"
! grep -qiE 'password|secret|token|AKIA|access_key|LLM' <<<"$out" && ! grep -qiE 'password|secret|token|AKIA|access_key|LLM' <<<"$(pi "$P3")" && pass "(e) la salida no contiene palabras de secretos" || fail "(e) la salida menciona secretos"
out="$(pi "$P5")"; grep -q '^keos backup velero$' <<<"$out" && ! grep -q '^keos monitoring$' <<<"$out" && ! grep -q 'keos falco' <<<"$out" && ! grep -q 'AVISO: falta' <<<"$out" && pass "(e) solo ENABLE_BACKUP_VELERO: solo el bloque de velero (override_charts_values presente, sin aviso)" || fail "(e) bloque de velero aislado"
P9="$(mk13 mon ENABLE_MONITORING=true)"; out="$(pi "$P9")"; grep -q '^keos monitoring$' <<<"$out" && grep -q 'PLT-5162' <<<"$out" && pass "(e) pushgateway activo (plantilla): el parche PLT-5162 acompaña a keos monitoring" || fail "(e) parche pushgateway"
mkdir -p "$P9/override_vars"; sed 's/^prometheus_pushgateway_enabled:.*/prometheus_pushgateway_enabled: false/' "$P3/override_vars/demo-x.yaml" > "$P9/override_vars/demo-x.yaml"
out="$(pi "$P9")"; grep -q '^keos monitoring$' <<<"$out" && ! grep -q 'kubectl -n keos-metrics' <<<"$out" && grep -q 'omitido' <<<"$out" && pass "(e) pushgateway desactivado en override_vars: sin parche" || fail "(e) parche con pushgateway desactivado"
P10="$(mk13 vsin ENABLE_BACKUP_VELERO=true ENABLE_BACKUP_SCHEDULE=true ENABLE_FALCO=true)"; out="$(pi "$P10")"
grep -q 'AVISO: falta .*keos-backup-velero.yaml' <<<"$out" && grep -q 'AVISO: falco envía' <<<"$out" && pass "(e) avisa si falta keos-backup-velero.yaml y si falco va sin central logging" || fail "(e) avisos de dependencias"
out="$(ENABLE_FALCO=quizas "$S/render-postinstall.sh" --dir "$(mk13 badf ENABLE_FALCO=quizas)" 2>&1)"; rc=$?; [[ $rc -ne 0 ]] && pass "(e) valor inválido de un flag: error" || fail "(e) acepta flag inválido"
# ENABLE_FALCO=true con keos.yaml sin bloque falco (renderizado antes de activar el flag): AVISO de re-renderizar antes de `keos install`
P11="$(mk13 falstale ENABLE_FALCO=true)"; cp "$P3/keos.yaml" "$P11/keos.yaml"; out="$(pi "$P11")"
grep -q 'AVISO: .*keos.yaml NO contiene el bloque keos.security.falco' <<<"$out" && grep -q 'ANTES de `keos install`' <<<"$out" && grep -q '^keos falco$' <<<"$out" && pass "(e) falco con keos.yaml sin bloque falco: AVISO de re-renderizar antes de keos install" || fail "(e) sin aviso de keos.yaml sin falco"
out="$(pi "$P6")"; ! grep -q 'NO contiene el bloque keos.security.falco' <<<"$out" && grep -q '^keos falco$' <<<"$out" && pass "(e) falco con keos.yaml que sí lleva el bloque: sin aviso" || fail "(e) aviso espurio de falco con keos.yaml correcto"
out="$(pi "$P10")"; ! grep -q 'NO contiene el bloque keos.security.falco' <<<"$out" && pass "(e) falco sin keos.yaml: sin aviso (no hay fichero que comprobar)" || fail "(e) aviso de falco sin keos.yaml"
snap="$(find "$P9" -type f -printf '%p %s %T@\n' | sort)"; pi "$P9" >/dev/null; [[ "$snap" == "$(find "$P9" -type f -printf '%p %s %T@\n' | sort)" && ! -e "$P9/override_charts_values" ]] && pass "(e) render-postinstall no escribe ficheros" || fail "(e) render-postinstall escribió ficheros"
# espejo en 1-aws-cluster: mismos comandos que la skill
if [[ -d "$AWS_REPO" ]]; then
  PA="$(mk13 mir ENABLE_BACKUP_VELERO=true ENABLE_MONITORING=true ENABLE_CENTRAL_LOGGING=true ENABLE_BACKUP_SCHEDULE=true ENABLE_FALCO=true)"; rk "$PA"
  diff <("$S/render-postinstall.sh" --dir "$PA") <(WORKSPACE_DIR="$PA" "$AWS_REPO/render-postinstall.sh" "$PA/cluster.env") >/dev/null && pass "1-aws-cluster/render-postinstall.sh imprime lo mismo que el de la skill" || fail "1-aws-cluster/render-postinstall.sh difiere del de la skill"
  mkdir -p "$T/p13/awsws"; EFS_ID=fs-0abc WORKSPACE_DIR="$T/p13/awsws" "$AWS_REPO/render-keos.sh" "$PA/cluster.env" >/dev/null 2>&1 && cmp -s "$T/p13/awsws/keos.yaml" "$PA/keos.yaml" && cmp -s "$T/p13/awsws/override_charts_values/keos-backup-velero.yaml" "$PA/override_charts_values/keos-backup-velero.yaml" && pass "1-aws-cluster/render-keos.sh genera el mismo keos.yaml y keos-backup-velero.yaml que la skill" || fail "1-aws-cluster/render-keos.sh difiere"
  mkdir -p "$T/p13/awsws0"; EFS_ID=fs-0abc WORKSPACE_DIR="$T/p13/awsws0" "$AWS_REPO/render-keos.sh" "$P3/cluster.env" >/dev/null 2>&1 && cmp -s "$T/p13/awsws0/keos.yaml" "$P3/keos.yaml" && [[ ! -e "$T/p13/awsws0/override_charts_values" ]] && pass "1-aws-cluster/render-keos.sh con flags apagados = keos.yaml de la skill y sin override_charts_values" || fail "1-aws-cluster/render-keos.sh con flags apagados difiere"
  mkdir -p "$T/p13/awsws1"; ENABLE_FALCO=true KEOS_ENABLE_CLAMAV=true ENABLE_BACKUP_VELERO=true EFS_ID=fs-0abc WORKSPACE_DIR="$T/p13/awsws1" "$AWS_REPO/render-keos.sh" "$P3/cluster.env" >/dev/null 2>&1 && cmp -s "$T/p13/awsws1/keos.yaml" "$P3/keos.yaml" && [[ ! -e "$T/p13/awsws1/override_charts_values" ]] && pass "1-aws-cluster/render-keos.sh ignora los flags exportados en el entorno" || fail "1-aws-cluster/render-keos.sh activó un flag del entorno"
  out="$(ENABLE_FALCO=true ENABLE_MONITORING=true WORKSPACE_DIR="$T/p13/awsws1" "$AWS_REPO/render-postinstall.sh" "$P3/cluster.env" 2>&1)"; grep -q 'AVISO: ningún bloque opcional' <<<"$out" && pass "1-aws-cluster/render-postinstall.sh ignora los flags exportados en el entorno" || fail "1-aws-cluster/render-postinstall.sh activó un flag del entorno"
  PF="$(mk13 awsfal ENABLE_FALCO=true)"; mkdir -p "$T/p13/awsws2"; cp "$P3/keos.yaml" "$T/p13/awsws2/keos.yaml"; out="$(WORKSPACE_DIR="$T/p13/awsws2" "$AWS_REPO/render-postinstall.sh" "$PF/cluster.env" 2>&1)"
  grep -q 'NO contiene el bloque keos.security.falco' <<<"$out" && pass "1-aws-cluster/render-postinstall.sh avisa si keos.yaml no lleva el bloque falco" || fail "1-aws-cluster/render-postinstall.sh sin aviso de falco"
  for f in cluster.yaml.tpl keos.yaml.tpl; do cmp -s "$AWS_REPO/$f" "$SK/templates/$f" && pass "plantilla $f idéntica en 1-aws-cluster y la skill" || fail "plantilla $f difiere"; done
  diff <(grep -E '^#?export (ENABLE_BACKUP_VELERO|KEOS_ENABLE_CLAMAV|ENABLE_MONITORING|ENABLE_CENTRAL_LOGGING|ENABLE_FALCO|ENABLE_BACKUP_SCHEDULE)=' "$AWS_REPO/cluster.env.example") <(grep -E '^#?export (ENABLE_BACKUP_VELERO|KEOS_ENABLE_CLAMAV|ENABLE_MONITORING|ENABLE_CENTRAL_LOGGING|ENABLE_FALCO|ENABLE_BACKUP_SCHEDULE)=' "$SK/templates/cluster.env.example") >/dev/null && pass "ambos cluster.env.example declaran los mismos flags opcionales (false por defecto)" || fail "cluster.env.example difieren en los flags"
fi
for v in ENABLE_BACKUP_VELERO KEOS_ENABLE_CLAMAV ENABLE_MONITORING ENABLE_CENTRAL_LOGGING ENABLE_FALCO ENABLE_BACKUP_SCHEDULE; do grep -q "^#export $v=false" "$SK/templates/cluster.env.example" || fail "cluster.env.example no documenta $v=false"; done; pass "templates/cluster.env.example documenta los 6 flags con false"
# (f) sintaxis de los scripts nuevos
for f in "$S/render-postinstall.sh" "$AWS_REPO/render-postinstall.sh" "$AWS_REPO/render-keos.sh" "$AWS_REPO/render-cluster.sh"; do [[ -f "$f" ]] && check "(f) bash -n ${f#"$SK/../../../"}" bash -n "$f"; done

echo "== 11. progress.sh: lista markdown de progreso (solo escribe .work/progress) =="
PR="$S/progress.sh"; PD="$T/prog/demo-x"; mkdir -p "$PD"; printf 'export CLUSTER_NAME=demo-x\nexport AWS_ACCOUNT_ID=111111111111\n' > "$PD/cluster.env"
out="$("$PR" --dir "$PD" 2>&1)"
grep -q '^## Progreso de la instalación · demo-x (cuenta 111111111111)' <<<"$out" && pass "progress: cabecera con clúster y cuenta" || fail "progress: cabecera"
[[ "$(grep -c '^- \[ \] ' <<<"$out")" == 19 ]] && grep -q 'Siguiente: 0 ·' <<<"$out" && pass "progress: 19 pasos pendientes y siguiente = 0" || fail "progress: estado inicial"
[[ ! -e "$PD/.work/progress" ]] && pass "progress show no escribe estado" || fail "progress show escribió estado"
"$PR" --dir "$PD" done 0 >/dev/null; out="$("$PR" --dir "$PD" doing 1 2>&1)"
grep -q '^- \[x\] 0 ·' <<<"$out" && grep -q '^- \[ \] 👉 1 · .* — en curso' <<<"$out" && grep -q '1 de 17 pasos hechos\*\* · Ahora: 1 ·' <<<"$out" && pass "progress: done tica, doing marca 👉 y el pie lo refleja" || fail "progress: done/doing"
out="$("$PR" --dir "$PD" fail 1 2>&1)"; grep -q '^- \[ \] ❌ 1 ·' <<<"$out" && grep -q '(falló)' <<<"$out" && pass "progress: fail marca ❌" || fail "progress: fail"
out="$("$PR" --dir "$PD" skip 13b 2>&1)"; grep -q '^- \[x\] 13b · .* — omitido' <<<"$out" && pass "progress: skip de paso opcional" || fail "progress: skip opcional"
"$PR" --dir "$PD" skip 5 >/dev/null 2>&1 && fail "progress: acepta omitir un paso obligatorio" || pass "progress: rechaza omitir un paso obligatorio"
"$PR" --dir "$PD" done 99 >/dev/null 2>&1 && fail "progress: acepta ID desconocido" || pass "progress: rechaza ID desconocido"
[[ "$(stat -c %a "$PD/.work/progress")" == 600 ]] && pass "progress: .work/progress modo 600" || fail "progress: modo del estado"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 14f 14g; do "$PR" --dir "$PD" done "$i" >/dev/null; done
out="$("$PR" --dir "$PD" 2>&1)"; grep -q '17 de 17 pasos hechos\*\* · Instalación completa' <<<"$out" && pass "progress: 17 de 17 = instalación completa (opcionales no cuentan)" || fail "progress: instalación completa"
out="$("$PR" --dir "$PD" reset 2>&1)"; grep -q '0 de 17 pasos hechos' <<<"$out" && pass "progress reset" || fail "progress reset"

echo; echo "RESULTADO: $((N-FAIL))/$N pruebas OK, $FAIL fallos. Directorio temporal: $T"
[[ $FAIL -eq 0 ]]

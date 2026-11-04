#!/usr/bin/env bash
# run-offline-tests.sh — pruebas OFFLINE de legacy-eks-uninstall (cuenta 111111111111, clúster demo-x). `aws` y `python` FALSOS en el PATH
# (tests/mock/bin): no tocan AWS ni el toolkit real. Usage: tests/run-offline-tests.sh [directorio-temporal]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SK="$(cd "$HERE/.." && pwd)"; S="$SK/scripts"; FX="$HERE/fixtures"
T="${1:-$(mktemp -d)}"; mkdir -p "$T"; T="$(cd "$T" && pwd)"
export PATH="$HERE/mock/bin:$PATH" MOCK_FIXTURES="$FX" AWS_PAGER=""
export MARKETPLACE_PYTHON="$HERE/mock/bin/python" FINDER_PY="$HERE/mock/bin/finder.py" REMOVER_PY="$HERE/mock/bin/remover.py" SKIP_HANDLER_CHECK=1
FAIL=0; N=0
pass() { N=$((N+1)); echo "PASS  $*"; }
fail() { N=$((N+1)); FAIL=$((FAIL+1)); echo "FAIL  $*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
touch "$FINDER_PY" "$REMOVER_PY"; trap 'rm -f "$FINDER_PY" "$REMOVER_PY"' EXIT

echo "== 0. sintaxis =="
for f in "$S"/*.sh "$HERE"/run-offline-tests.sh; do check "bash -n $(basename "$f")" bash -n "$f"; done
command -v shellcheck >/dev/null && { for f in "$S"/*.sh; do check "shellcheck $(basename "$f")" shellcheck -S error "$f"; done; } || echo "SKIP  shellcheck no instalado"

echo "== 1. filtro puro (filter-resources.sh) =="
F="$S/filter-resources.sh"; CL="$T/clean.json"; RP="$T/report.json"
"$F" "$FX/finder-full.json" "$FX/context.json" "$CL" "$RP" >/dev/null && pass "filtro termina bien" || fail "filtro falla"
inclean() { jq -e --arg t "$1" --arg i "$2" '(.[$t]//[])|index($i)!=null' "$CL" >/dev/null; }
for x in "vpcs vpc-0f717d5c98b8ddb9b" "subnets subnet-066202e0d96b8cac2" "route_tables rtb-0c88fa6c255789fb7" "ec2_security_groups sg-05a093ea0e7bb85a5" "athena_workgroups primary" "kms_keys 479952cb-bca7-4ead-827a-abebaff570e2" "iam_roles AWSServiceRoleForAutoScaling" "iam_roles AWSServiceRoleForAmazonEKSNodegroup"; do
  set -- $x; inclean "$1" "$2" && fail "PROTEGIDO en el plan: $1 $2" || pass "protegido fuera del plan: $1 $2"; done
inclean vpcs vpc-0f7b98399966cea8c && pass "VPC del clúster en el plan" || fail "VPC del clúster ausente"
inclean eks_clusters demo-x && pass "EKS del clúster en el plan" || fail "EKS ausente"
inclean iam_users cloud-provisioner && pass "usuario cloud-provisioner (compartido) en el plan" || fail "cloud-provisioner ausente"
for x in "s3_buckets bucket-de-otro-equipo" "iam_roles rol-de-otro-proyecto" "secrets_manager_secrets secreto-ajeno"; do set -- $x; inclean "$1" "$2" && fail "AJENO en el plan: $1 $2" || pass "ajeno excluido: $1 $2"; done
[[ "$(jq '[.[]|length]|add' "$CL")" -eq 127 ]] && pass "127 recursos a borrar (igual que la ejecución real)" || fail "recuento a borrar: $(jq '[.[]|length]|add' "$CL")"
[[ "$(jq '.counts.protected' "$RP")" -eq 13 && "$(jq '.counts.unowned' "$RP")" -eq 3 ]] && pass "13 protegidos y 3 ajenos informados" || fail "recuentos protegidos/ajenos"
"$F" "$FX/finder-full.json" "$FX/context.json" "$T/c2.json" "$T/r2.json" --include-unowned >/dev/null; jq -e '.s3_buckets|index("bucket-de-otro-equipo")!=null' "$T/c2.json" >/dev/null && pass "--include-unowned incluye los ajenos" || fail "--include-unowned"
jq -e '.vpcs|index("vpc-0f717d5c98b8ddb9b")==null' "$T/c2.json" >/dev/null && pass "--include-unowned NO incluye protegidos" || fail "--include-unowned incluye la VPC por defecto"
jq '.keep_shared=true' "$FX/context.json" > "$T/ctx-keep.json"; "$F" "$FX/finder-full.json" "$T/ctx-keep.json" "$T/c3.json" "$T/r3.json" >/dev/null
jq -e '((.iam_users//[])|index("cloud-provisioner")==null) and ((.cloudformation_stacks//[])|index("cluster-api-provider-aws-sigs-k8s-io")==null)' "$T/c3.json" >/dev/null && pass "keep_shared conserva usuario y pila CAPA" || fail "keep_shared no conserva lo compartido"
jq '.dedicated_account=false' "$FX/context.json" > "$T/ctx-ded.json"; "$F" "$FX/finder-full.json" "$T/ctx-ded.json" "$T/c4.json" "$T/r4.json" >/dev/null
jq -e '(.ec2_volumes//[])|length==0' "$T/c4.json" >/dev/null && pass "cuenta NO dedicada: volúmenes opacos excluidos" || fail "cuenta no dedicada: volúmenes incluidos"
jq '.caller_name="demo-x-s3"' "$FX/context.json" > "$T/ctx-caller.json"; "$F" "$FX/finder-full.json" "$T/ctx-caller.json" "$T/c5.json" "$T/r5.json" >/dev/null
jq -e '(.iam_users//[])|index("demo-x-s3")==null' "$T/c5.json" >/dev/null && pass "la identidad del llamador nunca se borra" || fail "el llamador entró en el plan"
jq '.default_vpc.vpc="vpc-DEFAULTX" | .default_vpc.members+=["eni-0c9aab0432b85aaf9"]' "$FX/context.json" > "$T/ctx-dm.json"; "$F" "$FX/finder-full.json" "$T/ctx-dm.json" "$T/c6.json" "$T/r6.json" >/dev/null
jq -e '(.ec2_network_interfaces//[])|index("eni-0c9aab0432b85aaf9")==null' "$T/c6.json" >/dev/null && pass "miembro de la VPC por defecto (ENI) protegido" || fail "ENI de la VPC por defecto en el plan"
echo '{"a":1}' | "$F" /dev/stdin "$FX/context.json" "$T/x.json" "$T/y.json" >/dev/null 2>&1 && fail "acepta JSON que no es del finder" || pass "rechaza JSON mal formado"
echo '{}' > "$T/ctx-bad.json"; "$F" "$FX/finder-full.json" "$T/ctx-bad.json" "$T/x.json" "$T/y.json" >/dev/null 2>&1 && fail "acepta contexto incompleto" || pass "rechaza contexto incompleto"

echo "== 2. flujo completo con aws/python falsos =="
W="$T/work"; mkdir -p "$W/clusters/demo-x"; cd "$W"
cat > clusters/demo-x/cluster.env <<'E'
export CLUSTER_NAME=demo-x
export AWS_ACCOUNT_ID=111111111111
export AWS_REGION=eu-west-1
export ADMIN_PROFILE=igualdad
export CP_PROFILE=cloud-provisioner-111111111111
export EXTERNAL_DOMAIN=demo-x.desa.int
export KEOS_INSTALLER_IMAGE=qa.int.stratio.com/stratio/keos-installer:1.4.2
E
D="$W/clusters/demo-x"; export MOCK_LOG="$T/mock.log" MOCK_STATE="$T/state"; mkdir -p "$MOCK_STATE"; : > "$MOCK_LOG"
out="$("$S/uninstall.sh" identify 2>&1)"; grep -q 'CANDIDATO.*cluster=demo-x.*account=111111111111' <<<"$out" && pass "identify lista el clúster instalado" || fail "identify sin candidato: $out"
out="$("$S/uninstall.sh" identify --dir "$D" 2>&1)"; grep -q 'IDENTIFICADO cluster=demo-x account=111111111111.*eks=ACTIVE' <<<"$out" && pass "identify valida cuenta y EKS" || fail "identify --dir: $out"
[[ -f "$D/uninstall/identity.json" ]] && pass "identity.json guardado (VPC y OIDC)" || fail "falta identity.json"
"$S/uninstall.sh" apply --dir "$D" --confirm-cluster demo-x --confirm-account 111111111111 >/dev/null 2>&1 && fail "apply sin plan previo" || pass "apply exige plan previo"
"$S/uninstall.sh" plan --dir "$D" > "$T/plan.out" 2>&1 && pass "plan termina bien" || { fail "plan falla"; tail -5 "$T/plan.out"; }
grep -q 'PROTEGIDOS: 13' "$T/plan.out" && grep -q 'AJENOS excluidos: 3' "$T/plan.out" && pass "plan informa protegidos y ajenos" || fail "resumen del plan"
[[ -f "$D/uninstall/plan.sha256" && -f "$D/uninstall/planned.lst" ]] && pass "plan fijado (sha256 + lista)" || fail "plan sin fijar"
[[ -f "$D/uninstall/baseline/oaar-role.json" ]] && pass "foto previa del acceso guardada" || fail "falta baseline"
[[ ! -s "$MOCK_STATE/deleted.lst" ]] && pass "plan no borra nada" || fail "plan borró recursos"
"$S/uninstall.sh" apply --dir "$D" --confirm-cluster otro --confirm-account 111111111111 >/dev/null 2>&1 && fail "apply acepta clúster distinto" || pass "apply rechaza --confirm-cluster erróneo"
"$S/uninstall.sh" apply --dir "$D" --confirm-cluster demo-x --confirm-account 222222222222 >/dev/null 2>&1 && fail "apply acepta cuenta distinta" || pass "apply rechaza --confirm-account erróneo"
cp "$D/uninstall/clean.json" "$T/clean.bak"; jq '.s3_buckets+=["bucket-de-otro-equipo"]' "$T/clean.bak" > "$D/uninstall/clean.json"
"$S/uninstall.sh" apply --dir "$D" --confirm-cluster demo-x --confirm-account 111111111111 >/dev/null 2>&1 && fail "apply acepta clean.json manipulado" || pass "apply detecta clean.json distinto del plan revisado"
cp "$T/clean.bak" "$D/uninstall/clean.json"
: > "$MOCK_STATE/remover-received.lst"
"$S/uninstall.sh" apply --dir "$D" --confirm-cluster demo-x --confirm-account 111111111111 --wait 0 > "$T/apply.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "apply termina con rc=0 y verify OK" || { fail "apply rc=$rc"; tail -15 "$T/apply.out"; }
grep -q 'Pasada 1/4' "$T/apply.out" && grep -q 'Pasada 2/4' "$T/apply.out" && pass "hizo 2 pasadas (la 1ª falla en el EKS, la 2ª termina)" || fail "número de pasadas"
grep -q 'no queda ningún recurso del clúster demo-x' "$T/apply.out" && pass "verify: cuenta limpia" || fail "verify no declara limpia"
grep -q 'acceso intacto' "$T/apply.out" && pass "verify: acceso a la cuenta intacto" || fail "verify no comprueba el acceso"
bad=0; for p in vpc-0f717d5c98b8ddb9b subnet-066202e0d96b8cac2 AWSServiceRoleForAutoScaling kms_keys,479952cb bucket-de-otro-equipo rol-de-otro-proyecto secreto-ajeno OrganizationAccountAccessRole athena_workgroups,primary; do grep -q "$p" "$MOCK_STATE/remover-received.lst" && { bad=1; echo "   el remover recibió $p"; }; done
[[ $bad -eq 0 ]] && pass "el remover NUNCA recibió un recurso protegido ni ajeno" || fail "el remover recibió algo protegido"
w="$(grep -E '^aws ' "$MOCK_LOG" | grep -v '^aws --version' | sed -E 's/^aws --profile [^ ]+ --region [^ ]+ //' | awk '{print $2}' | grep -vE '^(describe|list|get)' | sort -u)"
[[ -z "$w" ]] && pass "la skill solo hizo llamadas AWS de lectura ($(grep -c '^aws ' "$MOCK_LOG") llamadas)" || fail "llamadas AWS no de lectura: $w"
grep -qE 'kubectl|helm' "$MOCK_LOG" && fail "la skill tocó el clúster" || pass "no tocó el clúster"

echo "== 3. no progreso, instance profiles huérfanas y herramienta ausente =="
rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE"; : > "$MOCK_LOG"; rm -rf "$D/uninstall"; export MOCK_LEFTOVER_PROFILE=eks-leftover-1234 MOCK_LEFTOVER_STICKY=1
"$S/uninstall.sh" plan --dir "$D" >/dev/null 2>&1
# una instance profile que aparece DESPUÉS de la foto previa (no estaba antes): simulamos la foto previa vacía
echo '[]' > "$D/uninstall/baseline/instance-profiles-before.json"
"$S/uninstall.sh" apply --dir "$D" --confirm-cluster demo-x --confirm-account 111111111111 --wait 0 > "$T/apply2.out" 2>&1; rc=$?
[[ $rc -eq 2 ]] && grep -q 'eks-leftover-1234' "$T/apply2.out" && pass "verify detecta instance profile huérfana (rc=2)" || fail "instance profile huérfana no detectada (rc=$rc)"
unset MOCK_LEFTOVER_PROFILE MOCK_LEFTOVER_STICKY
SKIP_HANDLER_CHECK="" REMOVER_PY="$HERE/mock/bin/remover.py" "$S/uninstall.sh" plan --dir "$D" >/dev/null 2>&1 && fail "plan sin handlers de PLT-5240" || pass "plan aborta si el remover no tiene los handlers de PLT-5240"
cp "$D/cluster.env" "$T/env.bak"; sed -i 's/ADMIN_PROFILE=igualdad/ADMIN_PROFILE=cloud-provisioner-111111111111/' "$D/cluster.env"
"$S/uninstall.sh" identify --dir "$D" >/dev/null 2>&1 && fail "acepta el perfil cloud-provisioner" || pass "rechaza ejecutar con el perfil cloud-provisioner (se borra)"
cp "$T/env.bak" "$D/cluster.env"

echo "== 3b. protegidos extra desde cluster.env =="
rm -rf "$MOCK_STATE" "$D/uninstall"; mkdir -p "$MOCK_STATE"; : > "$MOCK_LOG"
echo 'export UNINSTALL_PROTECTED_IDS="bucket-de-otro-equipo demo-x-velero-111111111111"' >> "$D/cluster.env"; echo 'export UNINSTALL_PROTECTED_NAMES="demo-x-external-dns"' >> "$D/cluster.env"
"$S/uninstall.sh" plan --dir "$D" >/dev/null 2>&1
jq -e '(.s3_buckets//[])|index("demo-x-velero-111111111111")==null' "$D/uninstall/clean.json" >/dev/null && pass "UNINSTALL_PROTECTED_IDS protege un bucket del clúster" || fail "PROTECTED_IDS ignorado"
jq -e '(.iam_roles//[])|index("demo-x-external-dns")==null' "$D/uninstall/clean.json" >/dev/null && pass "UNINSTALL_PROTECTED_NAMES protege un rol del clúster" || fail "PROTECTED_NAMES ignorado"
cp "$T/env.bak" "$D/cluster.env"; rm -rf "$MOCK_STATE" "$D/uninstall"; mkdir -p "$MOCK_STATE"

echo "== 4. EKS ya borrado =="
touch "$MOCK_STATE/eks_gone"; rm -f "$D/uninstall/identity.json"
out="$("$S/uninstall.sh" identify --dir "$D" 2>&1)"; grep -q 'eks=NO_EXISTE' <<<"$out" && pass "identify con el EKS ya borrado: eks=NO_EXISTE (no lo da por existente)" || fail "identify con EKS borrado: $out"
[[ ! -f "$D/uninstall/identity.json" ]] && pass "no se escribe identity.json sin EKS" || fail "identity.json escrito sin EKS"

echo "== 5. fase LOCAL (docker, directorio efímero y ficheros) =="
rm -rf "$MOCK_STATE" "$D/uninstall"; mkdir -p "$MOCK_STATE"; : > "$MOCK_LOG"
# workspace ficticio: raíz = $W (repo git), clúster = $D
cd "$W" && git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p "$W/.claude" "$W/docs"; echo skill > "$W/.claude/s.md"; echo doc > "$W/docs/d.md"; echo "gen: raiz" > "$W/keos.yaml"; echo readme > "$W/README.md"; echo KEEP=1 > "$W/cluster.env"
git add -A && git commit -qm base
cd "$D"; mkdir -p logs templates pki .config .kube apps/a backup/objects backup/manifests override_vars requirements/lib .work "$T/eph"
echo s > secrets.yml; echo c > cluster.yaml; echo k > kubeconfig-demo-x; echo k > admin.key; echo c > admin.cert; echo ca > pki/ca.key; chmod 000 pki/ca.key
echo y > keos.yaml; echo y > override_vars/o.yaml; echo j > apps/a/x.json; echo m > backup/manifests/m.yaml; echo S > backup/objects/Secret_x_kubeconfig.yaml; echo v > demo-x.json
echo big > requirements/lib/big.bin; echo w > .work/w; echo L > logs/l.log; echo T > templates/t.tpl; echo notas > notes.txt; echo r > .config/rootowned
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR/apps-layer-demo-x"; echo "S3_KEY=xx" > "$TMPDIR/apps-layer-demo-x/.env"
printf '%s\n' "a1|demo-x-control-plane|cloud-provisioner:0.9.8|running|/var/run/docker.sock" "a2|keos-installer_demo-x|qa.int.stratio.com/stratio/keos-installer:1.4.2|exited|$D" \
  "a3|epic_swanson|qa.int.stratio.com/stratio/keos-installer:1.4.2|exited|$D,/var/run/docker.sock" "a4|otro_trabajo|qa.int.stratio.com/stratio/keos-installer:1.4.3|exited|/home/x/otro" \
  "a5|demo-x-control-plane2|nginx:latest|running|$D" > "$MOCK_STATE/containers.tsv"
LP="$S/uninstall.sh local-plan --dir $D --root $W"; LA="$S/uninstall.sh local-apply --dir $D --root $W --confirm-cluster demo-x --confirm-account 111111111111 --backup-dir $T/bk"
$S/uninstall.sh local-plan --dir "$D" >/dev/null 2>&1 && fail "local-plan con el EKS aún vivo" || pass "local-plan se niega si el EKS sigue existiendo"
"$S/uninstall.sh" plan --dir "$D" >/dev/null 2>&1; "$S/uninstall.sh" apply --dir "$D" --confirm-cluster demo-x --confirm-account 111111111111 --wait 0 >/dev/null 2>&1
$S/uninstall.sh local-apply --dir "$D" --confirm-cluster demo-x --confirm-account 111111111111 >/dev/null 2>&1 && fail "local-apply sin plan" || pass "local-apply exige local-plan previo"
out="$($LP 2>&1)"; rc=$?; echo "$out" > "$T/localplan.out"
[[ $rc -eq 0 ]] && pass "local-plan termina bien (AWS limpio)" || { fail "local-plan rc=$rc"; tail -8 "$T/localplan.out"; }
for n in demo-x-control-plane keos-installer_demo-x epic_swanson; do grep -q "$n" <<<"$out" && pass "plan lista el contenedor $n" || fail "plan no lista $n"; done
grep -q 'otro_trabajo' <<<"$out" && fail "plan incluye un contenedor ajeno" || pass "plan ignora el contenedor ajeno (otro_trabajo)"
grep -q 'demo-x-control-plane2' <<<"$out" && fail "plan incluye contenedor con imagen no esperada" || pass "plan ignora imágenes no esperadas (nginx)"
for f in secrets.yml cluster.yaml kubeconfig-demo-x admin.key pki apps backup requirements demo-x.json keos.yaml; do grep -q "$D/$f" <<<"$out" && pass "plan lista $f" || fail "plan no lista $f"; done
grep -q "$W/keos.yaml" <<<"$out" && pass "con --root lista también keos.yaml de la raíz" || fail "no lista keos.yaml de la raíz"
grep -q "$W/README.md\|\.claude\|$W/docs" <<<"$out" && fail "plan toca README/.claude/docs de la raíz" || pass "README, .claude y docs de la raíz NO están en el plan"
grep -q 'no reconocidos' <<<"$out" && grep -q 'notes.txt' <<<"$out" && pass "notes.txt se informa como no reconocido (se conserva)" || fail "no reconocido no informado"
grep -qE '/etc/hosts' <<<"$out" && pass "informa de lo que queda fuera (hosts/aws/git)" || fail "falta el apartado fuera de alcance"
[[ -z "$(grep -E '^docker (rm|run)' "$MOCK_LOG")" && -f "$D/secrets.yml" ]] && pass "local-plan no borra ni ejecuta nada" || fail "local-plan modificó algo"
$S/uninstall.sh local-apply --dir "$D" --root "$W" --confirm-cluster otro --confirm-account 111111111111 >/dev/null 2>&1 && fail "local-apply acepta clúster erróneo" || pass "local-apply rechaza --confirm-cluster erróneo"
touch "$D/override_charts_values"; $LA >/dev/null 2>&1 && fail "local-apply acepta elementos nuevos" || pass "local-apply aborta si aparecen elementos no revisados"
rm -f "$D/override_charts_values"
echo "cambio" >> "$W/keos.yaml"; $LP >/dev/null 2>&1 && fail "acepta fichero versionado con cambios" || pass "rechaza borrar un fichero versionado con cambios sin commit"
(cd "$W" && git checkout -q keos.yaml); $LP >/dev/null 2>&1
$LA > "$T/localapply.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "local-apply termina con rc=0" || { fail "local-apply rc=$rc"; tail -12 "$T/localapply.out"; }
BK="$(ls "$T"/bk/demo-x-workspace-*.tar.gz 2>/dev/null | head -1)"
[[ -n "$BK" && "$(stat -c %a "$BK")" == 600 ]] && pass "backup creado con permisos 600" || fail "backup ausente o permisos"
lst="$(tar -tzf "$BK" 2>/dev/null)"
grep -q 'secrets.yml' <<<"$lst" && grep -q 'kubeconfig-demo-x' <<<"$lst" && grep -q 'Secret_x_kubeconfig' <<<"$lst" && pass "el backup contiene secretos y Secret del backup" || fail "backup sin secretos"
grep -q 'requirements/lib/big.bin' <<<"$lst" && fail "el backup incluye requirements/" || pass "el backup excluye requirements/ y .work/"
grep -q 'pki/ca.key' <<<"$lst" && pass "el backup incluye ficheros ilegibles (vía contenedor auxiliar)" || fail "backup sin pki/ca.key (ilegible)"
for f in secrets.yml cluster.yaml kubeconfig-demo-x admin.key pki apps backup requirements demo-x.json keos.yaml .config .work; do [[ -e "$D/$f" ]] && fail "no se borró $f" || pass "borrado $f"; done
[[ ! -e "$W/keos.yaml" ]] && pass "borrado keos.yaml de la raíz" || fail "keos.yaml de la raíz sigue"
for f in cluster.env logs/l.log templates/t.tpl notes.txt uninstall; do [[ -e "$D/$f" ]] && pass "se conserva $f" || fail "se borró $f"; done
for f in README.md .claude/s.md docs/d.md cluster.env; do [[ -e "$W/$f" ]] && pass "raíz: se conserva $f" || fail "raíz: se borró $f"; done
[[ ! -d "$TMPDIR/apps-layer-demo-x" ]] && pass "directorio efímero de apps-layer destruido" || fail "sigue /tmp/apps-layer-demo-x"
rest="$(cut -d'|' -f2 "$MOCK_STATE/containers.tsv")"
grep -q 'otro_trabajo' <<<"$rest" && grep -q 'demo-x-control-plane2' <<<"$rest" && ! grep -qE '^(demo-x-control-plane|keos-installer_demo-x|epic_swanson)$' <<<"$rest" && pass "se borraron los 3 contenedores del clúster y NO los ajenos" || fail "contenedores restantes: $rest"
grep -q 'docker run .*rm -rf' "$MOCK_LOG" && pass "el .config de root se borró con el contenedor auxiliar" || fail "no se usó el contenedor auxiliar para rm"
# sin imagen auxiliar: lo que no se pueda borrar se imprime como sudo (la skill no usa sudo)
mkdir -p "$D/.config"; echo r > "$D/.config/rootowned"; MOCK_NO_IMAGE=1 $LP >/dev/null 2>&1
MOCK_NO_IMAGE=1 "$S/uninstall.sh" local-apply --dir "$D" --root "$W" --confirm-cluster demo-x --confirm-account 111111111111 --no-backup > "$T/nosudo.out" 2>&1; rc=$?
[[ $rc -eq 2 ]] && grep -q 'sudo rm -rf' "$T/nosudo.out" && pass "sin contenedor auxiliar imprime 'sudo rm -rf' y sale con rc=2" || fail "caso sin sudo (rc=$rc)"
[[ -z "$(grep -nE '(^|[;&|(]|\$\()[[:space:]]*sudo[[:space:]]' "$S"/*.sh | grep -vE 'echo|printf|warn|info|komsg|okmsg|#')" ]] && pass "la skill no invoca sudo (solo lo imprime)" || fail "la skill invoca sudo"
unset TMPDIR; cd "$W"

echo; echo "== $((N-FAIL))/$N pruebas OK =="; [[ $FAIL -eq 0 ]]

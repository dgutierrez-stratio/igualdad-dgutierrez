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

echo; echo "== $((N-FAIL))/$N pruebas OK =="; [[ $FAIL -eq 0 ]]

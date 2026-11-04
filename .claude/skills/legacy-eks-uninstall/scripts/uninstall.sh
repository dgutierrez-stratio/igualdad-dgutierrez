#!/usr/bin/env bash
# uninstall.sh — desinstala un clúster legacy EKS instalado con la skill legacy-eks-cluster y deja la cuenta AWS limpia,
# usando el finder y el remover de aws-marketplace-toolkit (PR #51 / PLT-5240 mergeada) con un filtro de recursos protegidos.
#
# Usage:
#   uninstall.sh identify [--dir DIR]                 # qué clúster es el instalado: lista candidatos; con --dir valida cuenta/EKS
#   uninstall.sh plan  --dir DIR [--keep-shared] [--include-unowned]
#                                                     # finder -> filtro -> remover --dry-run. NO borra nada. Deja el plan revisable
#   uninstall.sh apply --dir DIR --confirm-cluster NOMBRE --confirm-account CUENTA [--max-passes 4] [--pass-timeout 1200] [--wait 90] [--accept-new]
#                                                     # ejecuta el plan en pasadas (finder -> filtro -> remover) hasta dejar la cuenta limpia; termina con verify
#   uninstall.sh verify --dir DIR                     # solo lectura: ¿queda algo del clúster? ¿sigue intacto el acceso a la cuenta?
#
# Qué NO hace: no toca el clúster (ni kubectl ni helm), no crea ni modifica nada en AWS (los borrados los hace SOLO el remover; `awsx` aquí
# bloquea cualquier operación que no sea de lectura), no toca ~/.aws, /etc/hosts, git ni el workspace local.
# Ficheros (sin secretos) en <DIR>/uninstall/: identity.json context.json finder-full.json clean.json report.json planned.lst plan.sha256 baseline/ logs/
# Variables: MARKETPLACE_TOOLKIT FINDER_PY REMOVER_PY MARKETPLACE_PYTHON; SKIP_HANDLER_CHECK=1 (solo pruebas/bajo tu responsabilidad);
# UNINSTALL_PROTECTED_IDS / UNINSTALL_PROTECTED_NAMES (en cluster.env, separados por espacios): ids/nombres IAM extra que NUNCA se borran.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
FILTER="$LIB_DIR/filter-resources.sh"

cmd="${1:-}"; [[ -n "$cmd" ]] || { sed -n '2,15p' "$0"; exit 2; }; shift || true
DIR=""; KEEP_SHARED=false; INCLUDE_UNOWNED=false; CONF_CLUSTER=""; CONF_ACCOUNT=""; MAX_PASSES=4; PASS_TIMEOUT=1200; WAIT=90; ACCEPT_NEW=false
while [[ $# -gt 0 ]]; do case "$1" in
  --dir) DIR="$2"; shift 2 ;; --keep-shared) KEEP_SHARED=true; shift ;; --include-unowned) INCLUDE_UNOWNED=true; shift ;;
  --confirm-cluster) CONF_CLUSTER="$2"; shift 2 ;; --confirm-account) CONF_ACCOUNT="$2"; shift 2 ;;
  --max-passes) MAX_PASSES="$2"; shift 2 ;; --pass-timeout) PASS_TIMEOUT="$2"; shift 2 ;; --wait) WAIT="$2"; shift 2 ;; --accept-new) ACCEPT_NEW=true; shift ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;; esac; done
need_tools jq

# ---------------------------------------------------------------------------------------------------------------------
# Candidatos: clusters/*/cluster.env (los que deja la skill de instalación) o el directorio dado
# ---------------------------------------------------------------------------------------------------------------------
env_field() { ( set +u; source "$1/cluster.env" 2>/dev/null; echo "${!2:-}" ); }
list_candidates() {
  local f d n=0
  for f in ./clusters/*/cluster.env ./cluster.env; do
    [[ -f "$f" ]] || continue; d="$(cd "$(dirname "$f")" && pwd)"
    printf 'CANDIDATO dir=%s cluster=%s account=%s region=%s admin_profile=%s\n' "$d" "$(env_field "$d" CLUSTER_NAME)" "$(env_field "$d" AWS_ACCOUNT_ID)" "$(env_field "$d" AWS_REGION)" "$(env_field "$d" ADMIN_PROFILE)"
    n=$((n+1))
  done
  return 0
}

setup_dir() {  # carga cluster.env y el perfil de ADMINISTRACIÓN (nunca el usuario cloud-provisioner: se va a borrar)
  DIR="$(resolve_dir "$DIR")"
  load_env "$DIR" CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION ADMIN_PROFILE
  C="$CLUSTER_NAME"; ACCT="$AWS_ACCOUNT_ID"; REGION="$AWS_REGION"; PROFILE="$ADMIN_PROFILE"
  [[ "$PROFILE" != "${CP_PROFILE:-__nada__}" && "$PROFILE" != cloud-provisioner* ]] || die "ADMIN_PROFILE=$PROFILE es el del usuario cloud-provisioner, que esta skill borra: usa un perfil de administración (p. ej. el que asume OrganizationAccountAccessRole)"
  set_aws "$PROFILE" "$REGION"
  U="$DIR/uninstall"; mkdir -p "$U/logs" "$U/baseline"; chmod 700 "$U"
  local id; id="$(awsx sts get-caller-identity --output json 2>/dev/null)" || die "sts get-caller-identity falló con el perfil $PROFILE (¿credenciales caducadas?)"
  CALLER_ACCT="$(jq -r .Account <<<"$id")"; CALLER_ARN="$(jq -r .Arn <<<"$id")"
  [[ "$CALLER_ACCT" == "$ACCT" ]] || die "cuenta incorrecta: el perfil $PROFILE opera en $CALLER_ACCT y el clúster $C es de $ACCT. Abortado sin tocar nada."
  if   [[ "$CALLER_ARN" =~ :assumed-role/([^/]+)/ ]]; then CALLER_NAME="${BASH_REMATCH[1]}"
  elif [[ "$CALLER_ARN" =~ :user/(.+)$ ]];            then CALLER_NAME="${BASH_REMATCH[1]##*/}"
  else CALLER_NAME=""; fi
  [[ "$CALLER_NAME" != "cloud-provisioner" ]] || die "el llamador es el usuario cloud-provisioner (se borra en esta desinstalación): usa el perfil de administración"
}

# ---------------------------------------------------------------------------------------------------------------------
# Identidad del clúster (se guarda mientras el EKS existe: tras borrarlo ya no se puede consultar)
# ---------------------------------------------------------------------------------------------------------------------
eks_json() { awsx eks describe-cluster --name "$C" --output json 2>/dev/null || true; }
# OJO: `jq -e` sobre una entrada vacía sale con 0 (no llega a evaluar nada), así que hay que exigir antes que haya salida.
has_cluster() { [[ -n "$1" ]] && jq -e '(.cluster|type)=="object"' <<<"$1" >/dev/null 2>&1; }
save_identity() {
  local j; j="$(eks_json)"; has_cluster "$j" || return 0
  local vpc oidc; vpc="$(jq -r '.cluster.resourcesVpcConfig.vpcId // ""' <<<"$j")"; oidc="$(jq -r '.cluster.identity.oidc.issuer // "" | sub("^.*/id/";"")' <<<"$j")"
  local old="{}"; [[ -f "$U/identity.json" ]] && old="$(cat "$U/identity.json")"
  jq -n --argjson o "$old" --arg v "$vpc" --arg i "$oidc" --arg c "$C" '$o + {cluster:$c} + (if $v!="" and ($o.cluster_vpc//"")=="" then {cluster_vpc:$v} else {} end) + (if $i!="" and ($o.oidc_issuer_id//"")=="" then {oidc_issuer_id:$i} else {} end)' > "$U/identity.json"
  chmod 600 "$U/identity.json"
}

do_identify() {
  if [[ -z "$DIR" ]]; then
    local out; out="$(list_candidates)"; [[ -n "$out" ]] || die "no hay clústeres instalados aquí (./clusters/*/cluster.env): indica --dir"
    echo "$out"
    if [[ "$(wc -l <<<"$out")" -gt 1 ]]; then echo "HAY VARIOS: pregunta a la persona usuaria cuál y vuelve a lanzar con --dir <dir>"; else echo "Un solo candidato: confírmalo con la persona usuaria y vuelve a lanzar con --dir <dir> para validar cuenta y EKS"; fi
    return 0
  fi
  setup_dir
  local j st vpc; j="$(eks_json)"
  if has_cluster "$j"; then
    st="$(jq -r .cluster.status <<<"$j")"; vpc="$(jq -r '.cluster.resourcesVpcConfig.vpcId' <<<"$j")"
    local tag; tag="$(jq -r --arg c "$C" '.cluster.tags["kubernetes.io/cluster/"+$c] // .cluster.tags["sigs.k8s.io/cluster-api-provider-aws/cluster/"+$c] // ""' <<<"$j")"
    [[ -n "$tag" ]] || die "el EKS $C existe pero NO lleva los tags de pertenencia: no es el clúster de $DIR. Abortado."
    save_identity
    echo "IDENTIFICADO cluster=$C account=$ACCT region=$REGION profile=$PROFILE eks=$st vpc=$vpc llamador=$CALLER_NAME dir=$DIR"
  else
    warn "el EKS $C no existe en $ACCT/$REGION (¿ya borrado, o desinstalación a medias?). Sigue siendo válido si quedan recursos."
    echo "IDENTIFICADO cluster=$C account=$ACCT region=$REGION profile=$PROFILE eks=NO_EXISTE llamador=$CALLER_NAME dir=$DIR"
  fi
}

# ---------------------------------------------------------------------------------------------------------------------
# Contexto para el filtro (todo lectura)
# ---------------------------------------------------------------------------------------------------------------------
collect_context() {
  save_identity
  local ident="{}"; [[ -f "$U/identity.json" ]] && ident="$(cat "$U/identity.json")"
  local cvpc oidc; cvpc="$(jq -r '.cluster_vpc // ""' <<<"$ident")"; oidc="$(jq -r '.oidc_issuer_id // ""' <<<"$ident")"
  if [[ -z "$cvpc" && -f "$DIR/$C.json" ]]; then cvpc="$(jq -r '.vpc_id // ""' "$DIR/$C.json" 2>/dev/null || true)"; fi
  # VPC por defecto (unívoca o abortar) y sus dependientes
  local dv; dv="$(awsx ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[].VpcId' --output text)"
  local dmem="[]"
  if [[ "$dv" =~ ^vpc-[0-9a-f]+$ ]]; then
    dmem="$( { awsx ec2 describe-subnets --filters Name=vpc-id,Values="$dv" --query 'Subnets[].SubnetId' --output text
               awsx ec2 describe-route-tables --filters Name=vpc-id,Values="$dv" --query 'RouteTables[].RouteTableId' --output text
               awsx ec2 describe-security-groups --filters Name=vpc-id,Values="$dv" --query 'SecurityGroups[].GroupId' --output text
               awsx ec2 describe-network-interfaces --filters Name=vpc-id,Values="$dv" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
             } | tr '\t ' '\n\n' | grep . | jq -R . | jq -s . )"
  elif [[ -n "$dv" ]]; then die "hay varias VPC por defecto ($dv): no es normal, revisa a mano"
  else dv="__sin_vpc_por_defecto__"; warn "la cuenta no tiene VPC por defecto"; fi
  # claves KMS gestionadas por AWS
  local kms="[]" k
  for k in $(awsx kms list-keys --query 'Keys[].KeyId' --output text 2>/dev/null || true); do
    [[ "$(awsx kms describe-key --key-id "$k" --query 'KeyMetadata.KeyManager' --output text 2>/dev/null || echo ?)" == "AWS" ]] && kms="$(jq -c --arg k "$k" '. + [$k]' <<<"$kms")"
  done
  # miembros de la VPC del clúster (si aún existe)
  local cmem="[]"
  if [[ -n "$cvpc" && "$(awsx ec2 describe-vpcs --vpc-ids "$cvpc" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)" == 1 ]]; then
    cmem="$( { awsx ec2 describe-subnets --filters Name=vpc-id,Values="$cvpc" --query 'Subnets[].SubnetId' --output text
               awsx ec2 describe-route-tables --filters Name=vpc-id,Values="$cvpc" --query 'RouteTables[].RouteTableId' --output text
               awsx ec2 describe-security-groups --filters Name=vpc-id,Values="$cvpc" --query 'SecurityGroups[].GroupId' --output text
               awsx ec2 describe-network-interfaces --filters Name=vpc-id,Values="$cvpc" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
               awsx ec2 describe-nat-gateways --filter Name=vpc-id,Values="$cvpc" --query 'NatGateways[].NatGatewayId' --output text
               awsx ec2 describe-instances --filters Name=vpc-id,Values="$cvpc" --query 'Reservations[].Instances[].InstanceId' --output text
             } | tr '\t ' '\n\n' | grep . | jq -R . | jq -s . )"
  fi
  # zonas Route53 (id -> nombre)
  local zones; zones="$(awsx route53 list-hosted-zones --query 'HostedZones[].[Id,Name]' --output json | jq -c 'map({key:.[0],value:.[1]})|from_entries')"
  # cuenta dedicada: solo este EKS en todas las regiones habilitadas y ninguna VPC no-por-defecto ajena en la región
  local dedicated=true foreign_eks="" r
  for r in $(awsx ec2 describe-regions --query 'Regions[].RegionName' --output text); do
    for n in $(awsr "$r" eks list-clusters --query 'clusters' --output text 2>/dev/null || true); do [[ "$n" == "$C" && "$r" == "$REGION" ]] || foreign_eks+="$r/$n "; done
  done
  [[ -z "$foreign_eks" ]] || { dedicated=false; warn "hay otros EKS en la cuenta: $foreign_eks"; }
  local nd; nd="$(awsx ec2 describe-vpcs --filters Name=isDefault,Values=false --query 'Vpcs[].VpcId' --output text | tr '\t' '\n' | grep -vx "${cvpc:-__nada__}" || true)"
  [[ -z "$nd" ]] || { dedicated=false; warn "hay VPC no por defecto ajenas al clúster: $(echo $nd)"; }
  jq -n --arg c "$C" --arg a "$ACCT" --arg r "$REGION" --arg d "${EXTERNAL_DOMAIN:-}" --arg ca "$CALLER_ARN" --arg cn "${CALLER_NAME:-}" \
        --arg dv "$dv" --argjson dm "$dmem" --argjson kms "$kms" --arg cv "$cvpc" --argjson cm "$cmem" --arg oidc "$oidc" --argjson zones "$zones" \
        --argjson ded "$dedicated" --argjson keep "$KEEP_SHARED" --arg ecr "${ECR_POLICY_NAME:-ecr-pull-through-cache-machinepool}" \
        --arg pids "${UNINSTALL_PROTECTED_IDS:-}" --arg pnames "${UNINSTALL_PROTECTED_NAMES:-}" \
    '{cluster:$c,account:$a,region:$r,domain:$d,caller_arn:$ca,caller_name:$cn,default_vpc:{vpc:$dv,members:$dm},kms_aws_managed:$kms,
      cluster_vpc:$cv,cluster_vpc_members:$cm,oidc_issuer_id:$oidc,zones:$zones,dedicated_account:$ded,keep_shared:$keep,
      ecr_policy_name:$ecr,cp_user:"cloud-provisioner",protected_ids:($pids|split(" ")|map(select(.!=""))),protected_names:($pnames|split(" ")|map(select(.!="")))}' > "$U/context.json"
  chmod 600 "$U/context.json"
}

run_finder() {  # run_finder SALIDA.json
  local out="$1"; rm -f "$out"
  "$MARKETPLACE_PYTHON" -I "$FINDER_PY" --profile "$PROFILE" --region "$REGION" --output-file "$out" >> "$U/logs/finder.log" 2>&1 || die "el finder falló (ver $U/logs/finder.log)"
  [[ -f "$out" ]] || echo '{}' > "$out"   # el finder no escribe fichero si no encuentra nada
  chmod 600 "$out"
}

filter_now() {  # filter_now FULL CLEAN REPORT
  local args=(); [[ "$INCLUDE_UNOWNED" == true ]] && args+=(--include-unowned)
  "$FILTER" "$1" "$U/context.json" "$2" "$3" "${args[@]}"
}
items_of() { jq -r 'to_entries[]|.key as $t|.value[]|"\($t),\(.)"' "$1" | sort; }

take_baseline() {  # una sola vez: foto del acceso a la cuenta
  [[ -f "$U/baseline/oaar-role.json" ]] && return 0
  awsx iam get-role --role-name OrganizationAccountAccessRole --output json | jq -S '{trust:.Role.AssumeRolePolicyDocument, arn:.Role.Arn}' > "$U/baseline/oaar-role.json"
  awsx iam list-attached-role-policies --role-name OrganizationAccountAccessRole --output json | jq -S '[.AttachedPolicies[].PolicyArn]' > "$U/baseline/oaar-policies.json"
  awsx iam list-roles --query 'Roles[].RoleName' --output json | jq -S . > "$U/baseline/roles-before.json"
  awsx iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output json | jq -S . > "$U/baseline/instance-profiles-before.json"
  info "foto previa del acceso guardada en $U/baseline/"
}

summary() {  # summary REPORT CLEAN
  echo; echo "== Resumen del plan para el clúster $C (cuenta $ACCT, $REGION) =="
  jq -r '"a borrar: \(.counts.owned // 0) del clúster + \(.counts.shared // 0) compartidos de la cuenta | PROTEGIDOS: \(.counts.protected // 0) | AJENOS excluidos: \(.counts.unowned // 0)"' "$1"
  echo "-- a borrar, por tipo:"; jq -r 'to_entries[]|"   \(.value|length)\t\(.key)"' "$2" | sort -rn
  echo "-- PROTEGIDOS (no se tocan):"; jq -r '.protected[]|"   \(.type)  \(.id)  [\(.reason)]"' "$1"
  if [[ "$(jq '.unowned|length' "$1")" -gt 0 ]]; then echo "-- AJENOS (sin relación con el clúster; excluidos salvo --include-unowned):"; jq -r '.unowned[]|"   \(.type)  \(.id)  [\(.reason)]"' "$1"; fi
  jq -r '.shared[]|"   \(.type)  \(.id)"' "$1" | sed '1i -- compartidos de la cuenta que SÍ se borran (usa --keep-shared para conservarlos):'
}

do_plan() {
  setup_dir; resolve_toolkit; [[ -n "${SKIP_HANDLER_CHECK:-}" ]] || check_remover_handlers
  take_baseline; collect_context
  info "buscando recursos (finder)..."; run_finder "$U/finder-full.json"
  filter_now "$U/finder-full.json" "$U/clean.json" "$U/report.json" >/dev/null
  summary "$U/report.json" "$U/clean.json"
  local n; n="$(jq '[.[]|length]|add // 0' "$U/clean.json")"
  if [[ "$n" -eq 0 ]]; then echo; echo "Nada que borrar: la cuenta ya está limpia para este clúster."; rm -f "$U/plan.sha256" "$U/planned.lst"; return 0; fi
  info "dry-run del remover..."
  local dr; dr="$("$MARKETPLACE_PYTHON" -I "$REMOVER_PY" "$U/clean.json" --profile "$PROFILE" --region "$REGION" --dry-run --less-verbose 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tr '\r' '\n')"; echo "$dr" > "$U/logs/remover-dry-run.log"
  grep -q 'No deletion method' <<<"$dr" && die "el remover no tiene handler para algún tipo del plan (ver $U/logs/remover-dry-run.log): actualiza el toolkit"
  grep -qE '\[ERROR\]' <<<"$dr" && die "el dry-run del remover dio errores (ver $U/logs/remover-dry-run.log)"
  sha256sum "$U/clean.json" | cut -d' ' -f1 > "$U/plan.sha256"; items_of "$U/clean.json" > "$U/planned.lst"
  echo; echo "Dry-run OK ($(grep -c 'Would delete' <<<"$dr") operaciones). Plan fijado (sha256 $(cut -c1-12 "$U/plan.sha256"))."
  echo "SIGUIENTE: confirmar con la persona usuaria y lanzar:  uninstall.sh apply --dir $DIR --confirm-cluster $C --confirm-account $ACCT"
}

# ---------------------------------------------------------------------------------------------------------------------
do_apply() {
  setup_dir; resolve_toolkit; [[ -n "${SKIP_HANDLER_CHECK:-}" ]] || check_remover_handlers
  [[ "$CONF_CLUSTER" == "$C" ]]   || die "--confirm-cluster debe ser exactamente '$C' (el clúster identificado y confirmado)"
  [[ "$CONF_ACCOUNT" == "$ACCT" ]] || die "--confirm-account debe ser exactamente '$ACCT'"
  [[ -f "$U/plan.sha256" && -f "$U/planned.lst" && -f "$U/clean.json" ]] || die "no hay plan: ejecuta primero 'uninstall.sh plan --dir $DIR' y revísalo"
  [[ "$(sha256sum "$U/clean.json" | cut -d' ' -f1)" == "$(cat "$U/plan.sha256")" ]] || die "clean.json ha cambiado desde el plan revisado: vuelve a ejecutar 'plan'"
  [[ "$MAX_PASSES" =~ ^[1-9][0-9]*$ && "$PASS_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--max-passes/--pass-timeout deben ser enteros > 0"
  local prev="" pass rc items
  for ((pass=1; pass<=MAX_PASSES; pass++)); do
    if [[ $pass -gt 1 ]]; then
      collect_context; run_finder "$U/finder-full.json"; filter_now "$U/finder-full.json" "$U/clean.json" "$U/report.json" >/dev/null
    fi
    if [[ "$(jq '[.[]|length]|add // 0' "$U/clean.json")" -eq 0 ]]; then echo "Pasada $pass: no queda nada que borrar."; break; fi
    items="$(items_of "$U/clean.json")"
    if [[ $pass -gt 1 ]]; then
      local fresh; fresh="$(comm -13 "$U/planned.lst" <(echo "$items") || true)"
      if [[ -n "$fresh" && "$ACCEPT_NEW" != true ]]; then die "han aparecido recursos que NO estaban en el plan revisado (no se borran):"$'\n'"$fresh"$'\n'"Revisa y relanza 'plan' (o usa --accept-new bajo tu responsabilidad)."; fi
      if [[ "$items" == "$prev" ]]; then warn "la pasada $pass tiene los mismos recursos que la anterior: sin progreso. Parada."; break; fi
    fi
    prev="$items"
    echo; echo "=== Pasada $pass/$MAX_PASSES: $(wc -l <<<"$items") recursos (límite ${PASS_TIMEOUT}s) ==="
    set +e
    timeout "$PASS_TIMEOUT" "$MARKETPLACE_PYTHON" -I "$REMOVER_PY" "$U/clean.json" --profile "$PROFILE" --region "$REGION" > "$U/logs/remover-pass$pass.log" 2>&1
    rc=$?; set -e
    sed 's/\x1b\[[0-9;]*m//g' "$U/logs/remover-pass$pass.log" | tr '\r' '\n' | grep -E '^20.* \[ERROR\]|Failed to delete|^[a-z0-9_]+,' | cut -c1-200 | sort -u | head -15 || true
    case $rc in 0) okmsg "pasada $pass: remover rc=0" ;; 124) warn "pasada $pass: el remover superó ${PASS_TIMEOUT}s y se cortó (probable reintento sin límite: ver $U/logs/remover-pass$pass.log)" ;; *) warn "pasada $pass: remover rc=$rc (se reintenta en la siguiente pasada)" ;; esac
    [[ $pass -lt $MAX_PASSES ]] && { info "esperando ${WAIT}s a que AWS libere dependencias..."; sleep "$WAIT"; }
  done
  do_verify
}

# ---------------------------------------------------------------------------------------------------------------------
do_verify() {
  setup_dir; resolve_toolkit; collect_context
  run_finder "$U/finder-after.json"; filter_now "$U/finder-after.json" "$U/clean-after.json" "$U/report-after.json" >/dev/null
  local left; left="$(jq '[.[]|length]|add // 0' "$U/clean-after.json")" rc=0
  echo; echo "== Verificación =="
  if [[ "$left" -eq 0 ]]; then okmsg "no queda ningún recurso del clúster $C ni compartido de su instalación"; else komsg "quedan $left recursos:"; jq -r 'to_entries[]|.key as $t|.value[]|"   \($t)  \(.)"' "$U/clean-after.json"; rc=2; fi
  echo "-- protegidos que siguen ahí (esperado): $(jq '.counts.protected // 0' "$U/report-after.json")"
  [[ "$(jq '.unowned|length' "$U/report-after.json")" -eq 0 ]] || { echo "-- ajenos NO borrados:"; jq -r '.unowned[]|"   \(.type)  \(.id)"' "$U/report-after.json"; }
  # acceso a la cuenta
  if [[ -f "$U/baseline/oaar-role.json" ]]; then
    local now_role now_pol
    now_role="$(awsx iam get-role --role-name OrganizationAccountAccessRole --output json | jq -S '{trust:.Role.AssumeRolePolicyDocument, arn:.Role.Arn}')"
    now_pol="$(awsx iam list-attached-role-policies --role-name OrganizationAccountAccessRole --output json | jq -S '[.AttachedPolicies[].PolicyArn]')"
    if [[ "$now_role" == "$(cat "$U/baseline/oaar-role.json")" && "$now_pol" == "$(cat "$U/baseline/oaar-policies.json")" ]]; then okmsg "acceso intacto: OrganizationAccountAccessRole conserva su confianza y sus políticas (llamador: $CALLER_NAME)"; else komsg "OrganizationAccountAccessRole HA CAMBIADO respecto a la foto previa"; rc=2; fi
  else warn "no hay foto previa del acceso (baseline): solo se comprueba que el rol existe"; awsx iam get-role --role-name OrganizationAccountAccessRole >/dev/null && okmsg "OrganizationAccountAccessRole existe"; fi
  [[ "$(awsx sts get-caller-identity --query Account --output text)" == "$ACCT" ]] && okmsg "sts: sigues operando en $ACCT"
  # residuos que el finder no lista
  local ip; ip="$(awsx iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output json | jq -r --slurpfile b "$U/baseline/instance-profiles-before.json" '. - ($b[0]//[]) | .[]' 2>/dev/null || true)"
  [[ -z "$ip" ]] && okmsg "sin instance profiles huérfanas" || { komsg "instance profiles que no estaban antes (el finder no las lista; borrar a mano si son del clúster):"; echo "$ip" | sed 's/^/   /'; rc=2; }
  echo; echo "Fuera de AWS (esta skill no lo toca): perfil local cloud-provisioner en ~/.aws (clave ya borrada), línea de /etc/hosts, estado GitOps en git, directorio $DIR y contenedores keos-installer/apps-layer locales."
  return $rc
}

case "$cmd" in
  identify) do_identify ;; plan) do_plan ;; apply) do_apply ;; verify) do_verify ;;
  *) die "subcomando desconocido: $cmd (identify|plan|apply|verify)" ;;
esac

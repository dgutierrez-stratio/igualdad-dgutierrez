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
#   uninstall.sh local-plan  --dir DIR [--root DIR]   # LOCAL, no borra: contenedores docker, directorio efímero de apps-layer y ficheros generados
#   uninstall.sh local-apply --dir DIR [--root DIR] --confirm-cluster N --confirm-account A [--backup-dir D] [--no-backup] [--accept-partial-backup]
#                                                     # hace BACKUP (.tar.gz 600) y borra lo del plan local. Exige que AWS ya esté limpio
#
# Qué NO hace: no toca el clúster (ni kubectl ni helm) ni escribe en AWS (los borrados de AWS los hace SOLO el remover; `awsx` aquí bloquea
# cualquier operación que no sea de lectura). La fase local solo toca contenedores docker del clúster, /tmp/apps-layer-<C> y los ficheros
# generados listados; NUNCA ~/.aws, /etc/hosts (no usa sudo: imprime el comando), git, cluster.env ni logs/.
# Ficheros (sin secretos) en <DIR>/uninstall/: identity.json context.json finder-full.json clean.json report.json planned.lst plan.sha256 baseline/ logs/
# Variables: MARKETPLACE_TOOLKIT FINDER_PY REMOVER_PY MARKETPLACE_PYTHON; SKIP_HANDLER_CHECK=1 (solo pruebas/bajo tu responsabilidad);
# UNINSTALL_PROTECTED_IDS / UNINSTALL_PROTECTED_NAMES (en cluster.env, separados por espacios): ids/nombres IAM extra que NUNCA se borran.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
FILTER="$LIB_DIR/filter-resources.sh"

cmd="${1:-}"; [[ -n "$cmd" ]] || { sed -n '2,22p' "$0"; exit 2; }; shift || true
DIR=""; KEEP_SHARED=false; INCLUDE_UNOWNED=false; CONF_CLUSTER=""; CONF_ACCOUNT=""; MAX_PASSES=4; PASS_TIMEOUT=1200; WAIT=90; ACCEPT_NEW=false
ROOT=""; BACKUP_DIR="${UNINSTALL_BACKUP_DIR:-$HOME/backups}"; NO_BACKUP=false; ACCEPT_PARTIAL=false
while [[ $# -gt 0 ]]; do case "$1" in
  --dir) DIR="$2"; shift 2 ;; --keep-shared) KEEP_SHARED=true; shift ;; --include-unowned) INCLUDE_UNOWNED=true; shift ;;
  --confirm-cluster) CONF_CLUSTER="$2"; shift 2 ;; --confirm-account) CONF_ACCOUNT="$2"; shift 2 ;;
  --max-passes) MAX_PASSES="$2"; shift 2 ;; --pass-timeout) PASS_TIMEOUT="$2"; shift 2 ;; --wait) WAIT="$2"; shift 2 ;; --accept-new) ACCEPT_NEW=true; shift ;;
  --root) ROOT="$2"; shift 2 ;; --backup-dir) BACKUP_DIR="$2"; shift 2 ;; --no-backup) NO_BACKUP=true; shift ;; --accept-partial-backup) ACCEPT_PARTIAL=true; shift ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;; esac; done
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

# ---------------------------------------------------------------------------------------------------------------------
# FASE LOCAL: contenedores docker, directorio efímero de apps-layer y ficheros generados del workspace
# ---------------------------------------------------------------------------------------------------------------------
# Patrones relativos al directorio del clúster (y, con --root, a la raíz del workspace). SECRETO = se hace backup y se destruye con shred;
# GENERADO = regenerable (se incluye en el backup salvo requirements/ y .work/, que pesan y se rehacen). Se CONSERVAN siempre: cluster.env, logs/, templates/, uninstall/.
SECRET_PATTERNS=(secrets.yml cluster.yaml 'kubeconfig-*' admin.key admin.cert pki .kube .config .keos_bash_history)
GEN_PATTERNS=(keos.yaml keos.yaml.cloud-provisioner override_vars override_charts_values apps backup 'data_psql.*.yaml' ldap_user.template '*-tenant.yaml' '*_group.json' '*-users_role.json' estado .work requirements)
NOBACKUP_PATTERNS=(requirements .work)
KEEP_NAMES=(cluster.env logs templates uninstall)
EXPECTED_IMG_RE='(cloud-provisioner|keos-installer|apps-layer-automation)'

dk() {  # docker; en planes solo lectura
  local v="${1:-}"
  if [[ "${LOCAL_MODE:-plan}" != apply && ! "$v" =~ ^(ps|inspect|info|version|image|images)$ ]]; then die "BUG: docker '$v' en un plan (solo lectura)"; fi
  docker "$@"
}
list_matches() {  # list_matches BASE KIND(secret|gen) -> rutas relativas existentes
  local base="$1" kind="$2" pat f; local -a pats
  if [[ "$kind" == secret ]]; then pats=("${SECRET_PATTERNS[@]}"); else pats=("${GEN_PATTERNS[@]}" "$C.json"); fi
  ( cd "$base" && shopt -s nullglob dotglob && for pat in "${pats[@]}"; do for f in $pat; do if [[ -e "$f" || -L "$f" ]]; then echo "$f"; fi; done; done | sort -u )
}
is_kept() { local n="$1" k; for k in "${KEEP_NAMES[@]}"; do [[ "$n" == "$k" ]] && return 0; done; return 1; }
owner_of() { stat -c '%U' "$1" 2>/dev/null || echo "?"; }

local_docker_candidates() {  # -> líneas "ID|nombre|imagen|estado|motivo"
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || { warn "docker no responde: no se pueden revisar los contenedores"; return 0; }
  local id name img st mounts why
  for id in $(dk ps -a --format '{{.ID}}'); do
    name="$(dk inspect -f '{{.Name}}' "$id" | sed 's#^/##')"; img="$(dk inspect -f '{{.Config.Image}}' "$id")"
    [[ "$img" =~ $EXPECTED_IMG_RE ]] || continue
    st="$(dk inspect -f '{{.State.Status}}' "$id")"; mounts="$(dk inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$id")"; why=""
    case "$name" in "${C}-control-plane") why="kind retenido de cloud-provisioner" ;; "keos-installer_${C}") why="contenedor de apps-layer" ;; "apps-layer-${C}") why="contenedor de apps-layer" ;; esac
    if [[ -z "$why" ]]; then
      local m; while IFS= read -r m; do [[ -n "$m" ]] || continue
        if [[ "$m" == "$DIR" || "$m" == "${ROOT:-__nada__}" || "$m" == "${TMPDIR:-/tmp}/apps-layer-$C" ]]; then why="monta el workspace del clúster ($m)"; break; fi
      done <<<"$mounts"
    fi
    if [[ -n "$why" ]]; then echo "$id|$name|$img|$st|$why"; fi
  done
}

cluster_gone_check() {  # la fase local solo corre si AWS ya está limpio (si no, se perderían kubeconfig/secretos aún necesarios)
  local j; j="$(eks_json)"; has_cluster "$j" && die "el EKS $C sigue existiendo: ejecuta antes 'apply' (borrado en AWS). La fase local destruye kubeconfig y secretos que aún harían falta."
  local left; [[ -f "$U/clean-after.json" ]] && left="$(jq '[.[]|length]|add // 0' "$U/clean-after.json")" || left=""
  [[ "$left" == "0" ]] || die "no consta una verificación limpia (falta $U/clean-after.json o tiene recursos): ejecuta 'uninstall.sh verify --dir $DIR' y que salga OK antes de limpiar lo local"
  local vpc; vpc="$(jq -r '.cluster_vpc // ""' "$U/identity.json" 2>/dev/null || true)"
  if [[ -n "$vpc" && "$(awsx ec2 describe-vpcs --vpc-ids "$vpc" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)" != 0 ]]; then die "la VPC $vpc del clúster aún existe en AWS"; fi
  [[ "$(awsx route53 list-hosted-zones --query "length(HostedZones[?contains(Name, '${EXTERNAL_DOMAIN:-__nada__}')])" --output text)" == 0 ]] || die "aún hay zonas Route53 de ${EXTERNAL_DOMAIN}"
}

local_collect() {  # rellena L_ITEMS (tipo|ruta-absoluta|grupo|dueño|tamaño), L_KEPT, L_UNKNOWN y L_DOCKER
  L_ITEMS=(); L_KEPT=(); L_UNKNOWN=(); L_DOCKER=()
  local base rel kind abs
  local -a bases=("$DIR"); [[ -n "$ROOT" ]] && bases+=("$ROOT")
  for base in "${bases[@]}"; do
    for kind in secret gen; do
      while IFS= read -r rel; do [[ -n "$rel" ]] || continue; is_kept "$rel" && continue; abs="$base/$rel"
      # los Secret_* del backup de objetos van como SECRETO (shred) aunque backup/ sea "generado"
        L_ITEMS+=("$kind|$abs|$(owner_of "$abs")|$(du -sh "$abs" 2>/dev/null | cut -f1 || true)")
      done < <(list_matches "$base" "$kind")
    done
    L_KEPT+=("$base: $(cd "$base" && shopt -s nullglob dotglob && for f in cluster.env logs templates uninstall; do if [[ -e $f ]]; then printf '%s ' "$f"; fi; done)")
  done
  while IFS= read -r l; do [[ -n "$l" ]] && L_DOCKER+=("$l"); done < <(local_docker_candidates)
  # la raíz del workspace: si es un repo git, los ficheros versionados que se van a borrar deben estar limpios y subidos
  if [[ -n "$ROOT" && -d "$ROOT/.git" ]]; then
    local it p
    for it in "${L_ITEMS[@]}"; do p="${it#*|}"; p="${p%%|*}"; [[ "$p" == "$ROOT"/* ]] || continue
      git -C "$ROOT" ls-files --error-unmatch -- "${p#"$ROOT"/}" >/dev/null 2>&1 || git -C "$ROOT" ls-files -- "${p#"$ROOT"/}" | grep -q . || continue
      git -C "$ROOT" diff --quiet -- "${p#"$ROOT"/}" && git -C "$ROOT" diff --cached --quiet -- "${p#"$ROOT"/}" || die "${p#"$ROOT"/} está versionado y tiene cambios sin commit: haz commit/push antes de borrarlo"
    done
  fi
}

do_local_plan() {
  setup_dir; LOCAL_MODE=plan; [[ -z "$ROOT" ]] || ROOT="$(cd "$ROOT" && pwd)"
  cluster_gone_check; local_collect
  echo; echo "== Plan LOCAL para $C (no borra nada) =="
  echo "-- contenedores docker del clúster (se borran con docker rm -f):"
  local d id name img st why
  if [[ ${#L_DOCKER[@]} -eq 0 ]]; then echo "   (ninguno)"; else for d in "${L_DOCKER[@]}"; do IFS='|' read -r id name img st why <<<"$d"; printf '   %s  %s  [%s]  %s\n' "$id" "$name" "$st" "$why"; done; fi
  local eph="${TMPDIR:-/tmp}/apps-layer-$C"
  echo "-- directorio efímero de apps-layer: $([[ -d "$eph" ]] && echo "$eph (se destruye con shred)" || echo '(no existe)')"
  echo "-- ficheros (secret = backup + shred; gen = regenerable, va al backup salvo requirements/ y .work/):"
  local it k p o sz
  if [[ ${#L_ITEMS[@]} -eq 0 ]]; then echo "   (ninguno)"; else for it in "${L_ITEMS[@]}"; do IFS='|' read -r k p o sz <<<"$it"; printf '   %-6s %-8s %6s  %s\n' "$k" "$o" "$sz" "$p"; done; fi
  echo "-- se CONSERVAN: ${L_KEPT[*]:-}"
  local f unk=""
  for f in $(cd "$DIR" && shopt -s nullglob dotglob && printf '%s\n' *); do
    is_kept "$f" && continue; printf '%s\n' "${L_ITEMS[@]:-}" | grep -qF "|$DIR/$f|" || unk+="   $DIR/$f"$'\n'
  done
  [[ -z "$unk" ]] || { echo "-- no reconocidos (se CONSERVAN, revísalos tú):"; printf '%s' "$unk"; }
  local ro=0; for it in "${L_ITEMS[@]:-}"; do [[ -n "$it" ]] || continue; IFS='|' read -r k p o sz <<<"$it"; [[ "$o" == root ]] && ro=1; done
  [[ $ro -eq 0 ]] || echo "-- hay ficheros de root: se leerán/borrarán con un contenedor auxiliar (imagen ${KEOS_INSTALLER_IMAGE:-keos-installer}); sin él habría que usar sudo"
  [[ "$NO_BACKUP" == true ]] && warn "--no-backup: NO se hará copia de seguridad" || echo "-- backup: $BACKUP_DIR/${C}-workspace-<fecha>.tar.gz (600; sin requirements/ ni .work/)"
  { printf '%s\n' "${L_ITEMS[@]:-}" | cut -d'|' -f1,2; printf '%s\n' "${L_DOCKER[@]:-}" | cut -d'|' -f2 | sed 's/^/docker|/'; } | { grep -v '^$' || true; } | sort > "$U/local-planned.lst"
  echo; echo "SIGUIENTE: confirmar con la persona usuaria y lanzar: uninstall.sh local-apply --dir $DIR${ROOT:+ --root $ROOT} --confirm-cluster $C --confirm-account $ACCT"
  print_outside
}

print_outside() {
  echo; echo "== Fuera del alcance de esta skill (no usa sudo ni toca ~/.aws, /etc/hosts o git) =="
  if grep -q "${EXTERNAL_DOMAIN:-__nada__}" /etc/hosts 2>/dev/null; then echo "  /etc/hosts tiene entradas de $EXTERNAL_DOMAIN. Para quitarlas:   sudo sed -i '/${EXTERNAL_DOMAIN//./\\.}/d' /etc/hosts"; else echo "  /etc/hosts: sin entradas de $EXTERNAL_DOMAIN"; fi
  echo "  ~/.aws: el perfil '${CP_PROFILE:-cloud-provisioner}' tiene una clave que ya no existe; el paso 1 de la instalación lo regenera (no hace falta tocarlo)."
  echo "  Git: el estado GitOps del clúster (clusters/$C en flux-stratio/keos-fleet) y el repo de este workspace no se tocan."
}

rm_path() {  # rm_path RUTA [secret] -> borra; si falla por permisos usa el contenedor auxiliar (root) y, si no, lo anota en NEED_SUDO
  local p="$1" kind="${2:-gen}" parent name img
  [[ -e "$p" || -L "$p" ]] || return 0
  [[ "$p" != "/" && "$p" != "$HOME" && "$p" == /* && ${#p} -gt 8 ]] || die "ruta no segura: $p"
  if [[ "$kind" == secret || -d "$p" ]]; then
    find "$p" -type f \( -name 'Secret_*' -o -name '*.key' -o -name 'secrets.yml' -o -name 'kubeconfig*' -o -name 'ca.password' -o -name 'cluster.yaml' \) -writable -exec shred -u {} + 2>/dev/null || true
  fi
  [[ "$kind" == secret && -f "$p" && -w "$p" ]] && { shred -u "$p" 2>/dev/null || rm -f "$p"; }
  [[ -e "$p" || -L "$p" ]] && { chmod -R u+rwX "$p" 2>/dev/null || true; rm -rf "$p" 2>/dev/null || true; }
  if [[ -e "$p" || -L "$p" ]]; then
    img="${KEOS_INSTALLER_IMAGE:-}"; parent="$(dirname "$p")"; name="$(basename "$p")"
    if [[ -n "$img" ]] && dk image inspect "$img" >/dev/null 2>&1 && dk run --rm -v "$parent":/w --entrypoint sh "$img" -c 'rm -rf -- "/w/$1"' sh "$name" >/dev/null 2>&1; then :; fi
  fi
  if [[ -e "$p" || -L "$p" ]]; then NEED_SUDO+=("$p"); komsg "no se pudo borrar $p"; else okmsg "borrado $p"; fi
}

make_backup() {  # -> ARCHIVE (entradas relativas a /: restaurar con `tar -xzf FICHERO -C /`)
  local ts; ts="$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  ARCHIVE="$BACKUP_DIR/${C}-workspace-$ts.tar.gz"
  local it k p o sz nb pat unreadable=0 rootown=0 img="${KEOS_INSTALLER_IMAGE:-}" helper=false
  [[ -n "$img" ]] && dk image inspect "$img" >/dev/null 2>&1 && helper=true
  local -a args=() rels=()
  for it in "${L_ITEMS[@]:-}"; do [[ -n "$it" ]] || continue; IFS='|' read -r k p o sz <<<"$it"; nb=false
    for pat in "${NOBACKUP_PATTERNS[@]}"; do [[ "$(basename "$p")" == "$pat" ]] && nb=true; done; $nb && continue
    args+=("$p"); rels+=("${p#/}"); [[ "$o" == root ]] && rootown=1
    [[ -n "$(find "$p" ! -readable -print -quit 2>/dev/null)" ]] && unreadable=1
  done
  [[ ${#args[@]} -gt 0 ]] || { info "nada que archivar"; ARCHIVE=""; return 0; }
  if [[ $unreadable -eq 1 ]]; then
    if $helper; then
      # un contenedor (root, mismas rutas montadas en solo lectura) lee todo y deja el .tar.gz a nombre del usuario con permisos 600
      local -a mounts=(); local seen=" " bdir
      for p in "${args[@]}"; do bdir="$(dirname "$p")"; [[ "$seen" == *" $bdir "* ]] || { seen+="$bdir "; mounts+=(-v "$bdir:$bdir:ro"); }; done
      dk run --rm "${mounts[@]}" -v "$BACKUP_DIR":/out --entrypoint sh "$img" -c 'a="$1"; ug="$2"; shift 2; tar -czf "/out/$a" -C / "$@" 2>/dev/null; rc=$?; chown "$ug" "/out/$a"; chmod 600 "/out/$a"; exit $rc' sh "$(basename "$ARCHIVE")" "$(id -u):$(id -g)" "${rels[@]}" >/dev/null 2>&1 || true
      [[ -s "$ARCHIVE" ]] || die "el backup con el contenedor auxiliar falló: no se borra nada"
    else
      [[ "$ACCEPT_PARTIAL" == true ]] || die "hay ficheros que este usuario no puede leer y no hay imagen auxiliar local ($img): descárgala, o usa --accept-partial-backup (copia parcial) o --no-backup"
      warn "backup PARCIAL: faltarán los ficheros ilegibles"
    fi
  fi
  if [[ ! -s "$ARCHIVE" ]]; then
    tar -czf "$ARCHIVE" --ignore-failed-read -C / "${rels[@]}" 2>/dev/null || true; chmod 600 "$ARCHIVE" 2>/dev/null || true
  fi
  [[ -s "$ARCHIVE" ]] || die "no se pudo crear el backup $ARCHIVE: no se borra nada"
  local n; n="$(tar -tzf "$ARCHIVE" 2>/dev/null | wc -l)"; [[ "$n" -gt 0 ]] || die "el backup $ARCHIVE está vacío o corrupto: no se borra nada"
  okmsg "backup: $ARCHIVE ($n entradas, $(du -h "$ARCHIVE" | cut -f1), sha256 $(sha256sum "$ARCHIVE" | cut -c1-12)…, permisos $(stat -c %a "$ARCHIVE"))"
}

do_local_apply() {
  setup_dir; LOCAL_MODE=apply; [[ -z "$ROOT" ]] || ROOT="$(cd "$ROOT" && pwd)"
  [[ "$CONF_CLUSTER" == "$C" ]]    || die "--confirm-cluster debe ser exactamente '$C'"
  [[ "$CONF_ACCOUNT" == "$ACCT" ]] || die "--confirm-account debe ser exactamente '$ACCT'"
  [[ -f "$U/local-planned.lst" ]] || die "no hay plan local: ejecuta antes 'uninstall.sh local-plan --dir $DIR'"
  cluster_gone_check; local_collect
  local now; now="$( { printf '%s\n' "${L_ITEMS[@]:-}" | cut -d'|' -f1,2; printf '%s\n' "${L_DOCKER[@]:-}" | cut -d'|' -f2 | sed 's/^/docker|/'; } | { grep -v '^$' || true; } | sort )"
  local fresh; fresh="$(comm -13 "$U/local-planned.lst" <(echo "$now") || true)"
  [[ -z "$fresh" ]] || die "han aparecido elementos que NO estaban en el plan local revisado (no se borra nada):"$'\n'"$fresh"$'\n'"Revisa y relanza 'local-plan'."
  NEED_SUDO=(); ARCHIVE=""
  if [[ "$NO_BACKUP" == true ]]; then warn "sin backup (--no-backup)"; else make_backup; fi
  local d id name img st why
  for d in "${L_DOCKER[@]:-}"; do [[ -n "$d" ]] || continue; IFS='|' read -r id name img st why <<<"$d"
    if dk rm -f "$id" >/dev/null 2>&1; then okmsg "contenedor $name ($id) borrado"; else komsg "no se pudo borrar el contenedor $name ($id)"; fi
  done
  local eph="${TMPDIR:-/tmp}/apps-layer-$C"
  if [[ -d "$eph" && ! -L "$eph" && "$(owner_of "$eph")" == "$(id -un)" ]]; then find "$eph" -type f -exec shred -u {} + 2>/dev/null || true; rm_path "$eph" secret
  elif [[ -e "$eph" ]]; then warn "$eph existe pero no es un directorio propio normal: no se toca"; fi
  local it k p o sz
  for it in "${L_ITEMS[@]:-}"; do [[ -n "$it" ]] || continue; IFS='|' read -r k p o sz <<<"$it"; rm_path "$p" "$k"; done
  echo; echo "== Resultado local =="
  [[ -z "$ARCHIVE" ]] || echo "backup: $ARCHIVE"
  if [[ ${#NEED_SUDO[@]} -gt 0 ]]; then komsg "quedan ${#NEED_SUDO[@]} rutas que requieren sudo (la skill no lo usa):"; printf '   sudo rm -rf %q\n' "${NEED_SUDO[@]}"; return 2; fi
  okmsg "workspace local limpio: se conservan cluster.env, logs/, templates/ y uninstall/"
  print_outside
}

case "$cmd" in
  identify) do_identify ;; plan) do_plan ;; apply) do_apply ;; verify) do_verify ;; local-plan) do_local_plan ;; local-apply) do_local_apply ;;
  *) die "subcomando desconocido: $cmd (identify|plan|apply|verify|local-plan|local-apply)" ;;
esac

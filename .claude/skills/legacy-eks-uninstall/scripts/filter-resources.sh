#!/usr/bin/env bash
# filter-resources.sh — decide qué entradas del JSON del finder se pueden borrar. PURO (solo jq): no llama a AWS; todo lo que
# necesita viene en el fichero de contexto (lo genera `uninstall.sh context`). Así se prueba sin cuenta.
#
# Usage: filter-resources.sh FULL.json CONTEXT.json CLEAN.json REPORT.json [--include-unowned]
#
# Cada (tipo, id) se clasifica, por este orden, en:
#   protected  NUNCA se borra: VPC por defecto y sus dependientes, claves KMS gestionadas por AWS, workgroup `primary`, roles de
#              servicio/SSO, OrganizationAccountAccessRole, la identidad del llamador, y lo que el contexto añada (protected_ids/names).
#   shared     recursos de CUENTA que creó la instalación (pila CAPA, roles/policies *.cluster-api-provider-aws.sigs.k8s.io, policy ECR,
#              usuario cloud-provisioner). Se borran salvo keep_shared=true (entonces pasan a protected).
#   owned      pertenecen al clúster: nombre con el del clúster, VPC del clúster y sus miembros, zonas del dominio, OIDC del clúster; y,
#              si la cuenta es "dedicada" (un solo EKS y ninguna VPC ajena), los tipos opacos (volúmenes, NLB, EFS, ASG...).
#   unowned    todo lo demás: se EXCLUYE y se informa (solo se borra con --include-unowned).
# CLEAN.json = owned + shared (+ unowned con --include-unowned), mismo formato que el finder. REPORT.json = detalle por entrada.
set -euo pipefail
[[ $# -ge 4 ]] || { sed -n '2,17p' "$0"; exit 2; }
FULL="$1"; CTX="$2"; CLEAN="$3"; REPORT="$4"; shift 4
INCLUDE_UNOWNED=false
while [[ $# -gt 0 ]]; do case "$1" in --include-unowned) INCLUDE_UNOWNED=true; shift ;; *) echo "opción desconocida: $1" >&2; exit 2 ;; esac; done
command -v jq >/dev/null || { echo "falta jq" >&2; exit 1; }
jq -e 'type=="object"' "$FULL" >/dev/null || { echo "$FULL no es un objeto JSON del finder" >&2; exit 1; }
jq -e '.cluster and .account and (.default_vpc.vpc|type=="string")' "$CTX" >/dev/null || { echo "contexto incompleto (cluster/account/default_vpc.vpc)" >&2; exit 1; }

jq -n --slurpfile full "$FULL" --slurpfile ctx "$CTX" --argjson inc "$INCLUDE_UNOWNED" '
$ctx[0] as $x | ($x.cluster|ascii_downcase) as $c |
def inset($arr): . as $i | (($arr // []) | index($i)) != null;
def tail_name: sub("^.*[/:]"; "");
def capa_re: "\\.cluster-api-provider-aws\\.sigs\\.k8s\\.io$";
def named: ["iam_roles","iam_users","iam_policies","s3_buckets","secrets_manager_secrets","cloudformation_stacks","cloudwatch_log_groups","eks_clusters","ssm_parameters","ecr_repositories","ecrpublic_repositories","ec2_key_pairs","sns_topics","sqs_queues","lambda_functions","dynamodb_tables"];
def opaque: ["ec2_volumes","eips","albs_nlbs","target_groups","autoscaling_groups","efs","ec2_instances","ec2_network_interfaces","nat_gateways","ec2_security_groups","subnets","route_tables","vpcs"];

def classify($t; $id):
  ($id|tostring) as $i | ($i|tail_name) as $n |
  if   ($i|inset($x.protected_ids))                                                   then {k:"protected", r:"identificador protegido por contexto"}
  elif ($i == $x.default_vpc.vpc or ($i|inset($x.default_vpc.members)))              then {k:"protected", r:"VPC por defecto de la cuenta"}
  elif ($t=="kms_keys" and ($i|inset($x.kms_aws_managed)))                            then {k:"protected", r:"clave KMS gestionada por AWS"}
  elif ($t=="athena_workgroups" and $i=="primary")                                    then {k:"protected", r:"workgroup Athena por defecto"}
  elif ($t=="iam_roles" and ($i|test("^(AWSServiceRole|AWSReservedSSO_|OrganizationAccountAccessRole$)"))) then {k:"protected", r:"rol de servicio/SSO/acceso a la cuenta"}
  elif ($t=="iam_roles" and ($i == ($x.caller_name // "__none__") or ($i|inset($x.protected_names)))) then {k:"protected", r:"rol del llamador o protegido por contexto"}
  elif ($t=="iam_users" and ($i == ($x.caller_name // "__none__") or ($i|inset($x.protected_names)))) then {k:"protected", r:"usuario del llamador o protegido por contexto"}
  elif ($t=="cloudformation_stacks" and $i == "cluster-api-provider-aws-sigs-k8s-io")  then (if $x.keep_shared then {k:"protected", r:"compartido (keep_shared)"} else {k:"shared", r:"pila CAPA de la cuenta"} end)
  elif (($t=="iam_roles" or $t=="iam_policies") and ($n|test(capa_re)))               then (if $x.keep_shared then {k:"protected", r:"compartido (keep_shared)"} else {k:"shared", r:"rol/policy CAPA de la cuenta"} end)
  elif ($t=="iam_policies" and $n == ($x.ecr_policy_name // "ecr-pull-through-cache-machinepool")) then (if $x.keep_shared then {k:"protected", r:"compartido (keep_shared)"} else {k:"shared", r:"policy ECR de la instalación"} end)
  elif ($t=="iam_users" and $i == ($x.cp_user // "cloud-provisioner"))               then (if $x.keep_shared then {k:"protected", r:"compartido (keep_shared)"} else {k:"shared", r:"usuario IAM cloud-provisioner"} end)
  elif ($t=="eks_clusters")                                                           then (if ($i|ascii_downcase)==$c then {k:"owned", r:"EKS del clúster"} else {k:"unowned", r:"otro EKS"} end)
  elif ($t=="vpcs")                                                                   then (if $i == $x.cluster_vpc then {k:"owned", r:"VPC del clúster"} else {k:"unowned", r:"VPC no identificada como del clúster"} end)
  elif ($t=="iam_identity_providers")                                                 then (if ($x.oidc_issuer_id // "") != "" and ($i|contains($x.oidc_issuer_id)) then {k:"owned", r:"OIDC del EKS del clúster"} else {k:"unowned", r:"proveedor OIDC no identificado como del clúster"} end)
  elif ($t=="route53_hosted_zones")                                                   then (if (($x.zones // {})[$i] // "") as $zn | ($zn != "" and ($zn|ascii_downcase|rtrimstr(".")|endswith(($x.domain // "__none__")|ascii_downcase))) then {k:"owned", r:"zona del dominio del clúster"} else {k:"unowned", r:"zona de otro dominio"} end)
  elif ($i|inset($x.cluster_vpc_members))                                             then {k:"owned", r:"dentro de la VPC del clúster"}
  elif ($t|IN(named[]))                                                               then (if ($i|ascii_downcase|contains($c)) then {k:"owned", r:"nombre del clúster"} else {k:"unowned", r:"nombre sin relación con el clúster"} end)
  elif ($t|IN(opaque[]))                                                              then (if $x.dedicated_account then {k:"owned", r:"cuenta dedicada a este clúster"} else {k:"unowned", r:"id opaco y cuenta no dedicada"} end)
  else {k:"unowned", r:"tipo no previsto"} end;

[ $full[0] | to_entries[] | .key as $t | .value[] | (classify($t; .)) as $cl | {type:$t, id:(.|tostring), kind:$cl.k, reason:$cl.r} ] as $rows |
{
  clean: ( [ $rows[] | select(.kind=="owned" or .kind=="shared" or ($inc and .kind=="unowned")) ]
           | group_by(.type) | map({key:.[0].type, value:[.[].id]}) | from_entries ),
  report: {
    cluster: $x.cluster, account: $x.account, include_unowned: $inc, keep_shared: ($x.keep_shared // false),
    counts: ($rows | group_by(.kind) | map({key:.[0].kind, value:length}) | from_entries),
    protected: [ $rows[] | select(.kind=="protected") | {type,id,reason} ],
    unowned:   [ $rows[] | select(.kind=="unowned")   | {type,id,reason} ],
    shared:    [ $rows[] | select(.kind=="shared")    | {type,id,reason} ],
    owned:     [ $rows[] | select(.kind=="owned")     | {type,id} ]
  }
}' > "${CLEAN}.tmp.$$"

jq '.clean' "${CLEAN}.tmp.$$" > "$CLEAN"
jq '.report' "${CLEAN}.tmp.$$" > "$REPORT"
rm -f "${CLEAN}.tmp.$$"
chmod 600 "$CLEAN" "$REPORT"

# Aserción final (defensa en profundidad): nada protegido puede haber entrado en CLEAN.
bad="$(jq -n --slurpfile c "$CLEAN" --slurpfile r "$REPORT" '[ $r[0].protected[] | select(. as $p | (($c[0][$p.type] // []) | index($p.id)) != null) ] | length')"
[[ "$bad" == 0 ]] || { echo "BUG: $bad recursos protegidos han llegado a CLEAN.json" >&2; rm -f "$CLEAN"; exit 3; }
echo "owned=$(jq '.counts.owned // 0' "$REPORT") shared=$(jq '.counts.shared // 0' "$REPORT") protected=$(jq '.counts.protected // 0' "$REPORT") unowned=$(jq '.counts.unowned // 0' "$REPORT") -> a borrar: $(jq '[.[]|length]|add // 0' "$CLEAN")"

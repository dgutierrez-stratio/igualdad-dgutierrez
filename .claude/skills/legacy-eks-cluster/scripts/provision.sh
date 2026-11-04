#!/usr/bin/env bash
# provision.sh — pasos de la skill que CREAN recursos en AWS (1, 2, 8, 9, 10, 11). DRY-RUN POR DEFECTO.
#
# Usage: provision.sh <paso> [--dir DIR] [--apply] [--ack-shared-node-role] [--new-key]
#
# Pasos:
#   iam-user     (1)  usuario IAM `cloud-provisioner` + AdministratorAccess + access key guardada en el perfil $CP_PROFILE
#                     (sin imprimirla). Perfil: $ADMIN_PROFILE. Cuenta compartida: no se crea 2ª key sin --new-key.
#   ecr-policy   (2)  policy $ECR_POLICY_NAME (pull through cache de ECR). Una vez por cuenta.
#   zones        (8)  zonas Route53 pública + privada de $EXTERNAL_DOMAIN (cloud-provisioner NO las crea). Solo la que falte.
#   external-dns (9)  rol IRSA ${CLUSTER_NAME}-external-dns + policy
#   velero       (10) bucket $VELERO_BUCKET + rol IRSA $VELERO_ROLE + policy ${CLUSTER_NAME}-velero
#   efs          (11) EFS cifrado + mount targets (SG del clúster) + política del FS (solo TLS y vía mount target)
#   efs-csi      (11) policy ${CLUSTER_NAME}-efs-csi adjunta al rol de nodos de CUENTA
#                     eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io: exige --ack-shared-node-role para aplicar
#   status            lista (solo lectura) qué existe de todo lo anterior
#
# Todo lo que crea lleva tags keos.stratio.com/owner=<cluster> y managed-by=legacy-eks-cluster (las zonas, el bucket, los
# roles y policies, el EFS) para que el teardown pueda demostrar pertenencia. Idempotente: lo que ya existe se salta.
# Ficheros temporales (JSON de políticas) en <dir>/.work/. Log en <dir>/logs/provision-<fecha>.log (sin secretos).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

STEP="${1:-}"; [[ -n "$STEP" && "$STEP" != -* ]] || { sed -n '2,24p' "$0"; exit 1; }; shift
DIR=""; APPLY=0; ACK=0; NEWKEY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;; --apply) APPLY=1; shift ;; --ack-shared-node-role) ACK=1; shift ;; --new-key) NEWKEY=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;;
  esac
done
DIR="$(resolve_dir "$DIR")"; need_tools aws jq
load_env "$DIR" CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION CP_PROFILE ADMIN_PROFILE EXTERNAL_DOMAIN ECR_POLICY_NAME ECR_POLICY_ARN VELERO_BUCKET VELERO_ROLE
WORK="$DIR/.work"; mkdir -p "$WORK" "$DIR/logs"
LOG="$DIR/logs/provision-$(date +%Y%m%d).log"
MODE="DRY-RUN"; [[ $APPLY -eq 1 ]] && MODE="APPLY"
TAGS_KV=("Key=keos.stratio.com/owner,Value=${CLUSTER_NAME}" "Key=managed-by,Value=legacy-eks-cluster")
TAGS_IAM=(--tags "${TAGS_KV[@]}")

logl() { echo "$(date -u +%FT%TZ) [$STEP] $*" >> "$LOG"; }
# run <descripción> <args de aws...>: solo ejecuta con --apply
run() { local d="$1"; shift; logl "$MODE: $d"; if [[ $APPLY -eq 1 ]]; then echo "[APPLY]   $d"; awsx "$@" >/dev/null; else echo "[DRY-RUN] haría: $d"; fi; }

# Perfil: CP si ya funciona y es de la cuenta; si no, el de administración (aviso).
use_cp_or_admin() {
  set_aws "$CP_PROFILE" "$AWS_REGION"
  if ! assert_account_soft; then
    warn "el perfil $CP_PROFILE aún no es utilizable: se usa $ADMIN_PROFILE"
    set_aws "$ADMIN_PROFILE" "$AWS_REGION"; assert_account "$AWS_ACCOUNT_ID"
  fi
}
assert_account_soft() { local a; a="$(awsx sts get-caller-identity --output json 2>/dev/null | jq -r .Account 2>/dev/null || true)"; [[ "$a" == "$AWS_ACCOUNT_ID" ]]; }
cp_profile() { set_aws "$CP_PROFILE" "$AWS_REGION"; assert_account "$AWS_ACCOUNT_ID"; }

role_exists()   { awsx iam get-role --role-name "$1" >/dev/null 2>&1; }
policy_exists() { awsx iam get-policy --policy-arn "$1" >/dev/null 2>&1; }

echo "== provision.sh $STEP [$MODE] cluster=$CLUSTER_NAME cuenta=$AWS_ACCOUNT_ID región=$AWS_REGION =="
[[ $APPLY -eq 1 ]] || echo "(dry-run: no se crea nada; añade --apply para ejecutar)"

case "$STEP" in
# ------------------------------------------------------------------------------------------------------------
iam-user)
  set_aws "$ADMIN_PROFILE" "$AWS_REGION"; assert_account "$AWS_ACCOUNT_ID"
  U=cloud-provisioner
  if awsx iam get-user --user-name "$U" >/dev/null 2>&1; then
    echo "el usuario IAM $U ya existe"
    keys="$(awsx iam list-access-keys --user-name "$U" --output json | jq -r '[.AccessKeyMetadata[]|.AccessKeyId+":"+.Status]|join(" ")')"
    echo "access keys existentes (solo ids): ${keys:-ninguna}"
    local_ak="$("${AWS_GET_BIN:-aws}" configure get aws_access_key_id --profile "$CP_PROFILE" 2>/dev/null || true)"
    if [[ -n "$local_ak" ]]; then
      echo "el perfil local $CP_PROFILE ya tiene una access key configurada (no se toca)"; exit 0
    fi
    [[ $NEWKEY -eq 1 ]] || die "el usuario existe pero el perfil local $CP_PROFILE no tiene claves. NO se crea otra key sin --new-key (máximo 2 por usuario; la otra puede estar en uso por otro entorno). Revisa con la persona usuaria."
    n_keys="$(jq -rn --arg k "$keys" '$k|split(" ")|map(select(length>0))|length')"
    [[ "$n_keys" -lt 2 ]] || die "el usuario ya tiene 2 access keys (máximo): borra una a mano antes"
  else
    run "create-user $U" iam create-user --user-name "$U" "${TAGS_IAM[@]}"
    run "attach-user-policy $U AdministratorAccess" iam attach-user-policy --user-name "$U" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  fi
  if [[ $APPLY -eq 1 ]]; then
    AK=""; SK=""
    read -r AK SK < <(awsx iam create-access-key --user-name "$U" --output json | jq -r '.AccessKey|[.AccessKeyId,.SecretAccessKey]|@tsv')
    [[ -n "$AK" && -n "$SK" ]] || die "no se pudo crear la access key"
    aws configure set aws_access_key_id "$AK" --profile "$CP_PROFILE"
    aws configure set aws_secret_access_key "$SK" --profile "$CP_PROFILE"
    aws configure set region "$AWS_REGION" --profile "$CP_PROFILE"
    unset AK SK
    logl "access key creada y guardada en el perfil $CP_PROFILE (no se registra)"
    echo "access key guardada en el perfil local $CP_PROFILE (no se muestra). Esperando propagación de IAM..."
    for i in $(seq 1 18); do set_aws "$CP_PROFILE" "$AWS_REGION"; if assert_account_soft; then echo "ok  sts OK con $CP_PROFILE"; break; fi; sleep 5; [[ $i -lt 18 ]] || die "sts sigue fallando con $CP_PROFILE tras 90 s"; done
  else echo "[DRY-RUN] haría: create-access-key $U y guardarla en el perfil $CP_PROFILE sin imprimirla"; fi
  ;;
# ------------------------------------------------------------------------------------------------------------
ecr-policy)
  use_cp_or_admin
  if policy_exists "$ECR_POLICY_ARN"; then echo "la policy $ECR_POLICY_ARN ya existe: nada que hacer"
  else
    DOC='{"Version":"2012-10-17","Statement":[{"Action":["ecr:BatchImportUpstreamImage","ecr:CreateRepository"],"Effect":"Allow","Resource":["*"]}]}'
    run "create-policy $ECR_POLICY_NAME (ecr:BatchImportUpstreamImage, ecr:CreateRepository)" iam create-policy --policy-name "$ECR_POLICY_NAME" --policy-document "$DOC" "${TAGS_IAM[@]}"
  fi
  ;;
# ------------------------------------------------------------------------------------------------------------
zones)
  cp_profile; derive_vars
  echo "VPC=$VPC_ID  zonas actuales: pública='${PUBLIC_ZONE_ID:-}' privada='${PRIVATE_ZONE_ID:-}'"
  [[ "$(wc -w <<<"$PUBLIC_ZONE_ID")" -le 1 && "$(wc -w <<<"$PRIVATE_ZONE_ID")" -le 1 ]] || die "hay más de una zona pública o privada de $EXTERNAL_DOMAIN: ambiguo, revisar a mano"
  mkzone() {  # mkzone public|private
    local kind="$1" ref="${CLUSTER_NAME}-${1}-$(date +%s)" zid
    if [[ "$kind" == private ]]; then
      run "create-hosted-zone $EXTERNAL_DOMAIN (privada, VPC $VPC_ID)" route53 create-hosted-zone --name "$EXTERNAL_DOMAIN" --caller-reference "$ref" --vpc VPCRegion="$AWS_REGION",VPCId="$VPC_ID"
    else
      run "create-hosted-zone $EXTERNAL_DOMAIN (pública)" route53 create-hosted-zone --name "$EXTERNAL_DOMAIN" --caller-reference "$ref"
    fi
  }
  [[ -n "$PUBLIC_ZONE_ID" ]]  || mkzone public
  [[ -n "$PRIVATE_ZONE_ID" ]] || mkzone private
  if [[ $APPLY -eq 1 ]]; then
    derive_vars
    for z in $PUBLIC_ZONE_ID $PRIVATE_ZONE_ID; do
      awsx route53 change-tags-for-resource --resource-type hostedzone --resource-id "$z" \
        --add-tags "Key=keos.stratio.com/owner,Value=${CLUSTER_NAME}" "Key=managed-by,Value=legacy-eks-cluster" >/dev/null
    done
    echo "pública=$PUBLIC_ZONE_ID privada=$PRIVATE_ZONE_ID"
    awsx route53 get-hosted-zone --id "$PRIVATE_ZONE_ID" --output json | jq -e --arg v "$VPC_ID" '[.VPCs[].VPCId]|index($v)' >/dev/null && okmsg "la zona privada tiene la VPC del clúster" || komsg "la zona privada NO tiene la VPC del clúster"
  fi
  echo "(la delegación NS de la zona pública en el dominio padre queda fuera de alcance)"
  ;;
# ------------------------------------------------------------------------------------------------------------
external-dns)
  cp_profile; derive_vars
  [[ -n "$PUBLIC_ZONE_ID" && -n "$PRIVATE_ZONE_ID" ]] || die "faltan las zonas Route53 (provision.sh zones)"
  R="${CLUSTER_NAME}-external-dns"; PARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${R}"
  jq -n --arg a "$AWS_ACCOUNT_ID" --arg i "$OIDC_ISSUER" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Federated:("arn:aws:iam::"+$a+":oidc-provider/"+$i)},Action:"sts:AssumeRoleWithWebIdentity",Condition:{StringEquals:{($i+":sub"):"system:serviceaccount:kube-system:external-dns",($i+":aud"):"sts.amazonaws.com"}}}]}' > "$WORK/external-dns-trust.json"
  jq -n --arg p "arn:aws:route53:::hostedzone/$PUBLIC_ZONE_ID" --arg q "arn:aws:route53:::hostedzone/$PRIVATE_ZONE_ID" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["route53:ChangeResourceRecordSets"],Resource:[$p,$q]},{Effect:"Allow",Action:["route53:ListHostedZones","route53:ListResourceRecordSets","route53:ListTagsForResource"],Resource:["*"]}]}' > "$WORK/external-dns-policy.json"
  role_exists "$R" && echo "el rol $R ya existe" || run "create-role $R (IRSA kube-system/external-dns)" iam create-role --role-name "$R" --assume-role-policy-document "file://$WORK/external-dns-trust.json" "${TAGS_IAM[@]}"
  policy_exists "$PARN" && echo "la policy $PARN ya existe" || run "create-policy $R (route53 solo de las 2 zonas)" iam create-policy --policy-name "$R" --policy-document "file://$WORK/external-dns-policy.json" "${TAGS_IAM[@]}"
  run "attach-role-policy $R <- $PARN" iam attach-role-policy --role-name "$R" --policy-arn "$PARN"
  ;;
# ------------------------------------------------------------------------------------------------------------
velero)
  cp_profile; derive_vars
  PARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-velero"
  out="$(awsx s3api head-bucket --bucket "$VELERO_BUCKET" 2>&1)" && ex=1 || ex=0
  if [[ $ex -eq 1 ]]; then echo "el bucket $VELERO_BUCKET ya existe y es accesible"
  elif grep -q 403 <<<"$out"; then die "el bucket $VELERO_BUCKET pertenece a otra cuenta (nombre global): cambia VELERO_BUCKET en cluster.env"
  else
    if [[ "$AWS_REGION" == us-east-1 ]]; then run "create-bucket $VELERO_BUCKET" s3api create-bucket --bucket "$VELERO_BUCKET" --region "$AWS_REGION"
    else run "create-bucket $VELERO_BUCKET" s3api create-bucket --bucket "$VELERO_BUCKET" --region "$AWS_REGION" --create-bucket-configuration "LocationConstraint=$AWS_REGION"; fi
  fi
  run "put-bucket-tagging $VELERO_BUCKET (owner)" s3api put-bucket-tagging --bucket "$VELERO_BUCKET" --tagging "TagSet=[{Key=keos.stratio.com/owner,Value=${CLUSTER_NAME}},{Key=managed-by,Value=legacy-eks-cluster}]"
  jq -n --arg a "$AWS_ACCOUNT_ID" --arg i "$OIDC_ISSUER" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Federated:("arn:aws:iam::"+$a+":oidc-provider/"+$i)},Action:"sts:AssumeRoleWithWebIdentity",Condition:{StringEquals:{($i+":sub"):"system:serviceaccount:keos-backup:velero-server",($i+":aud"):"sts.amazonaws.com"}}}]}' > "$WORK/velero-trust.json"
  jq -n --arg b "$VELERO_BUCKET" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["ec2:DescribeVolumes","ec2:DescribeSnapshots","ec2:CreateTags","ec2:CreateVolume","ec2:CreateSnapshot","ec2:DeleteSnapshot"],Resource:"*"},{Effect:"Allow",Action:["s3:GetObject","s3:DeleteObject","s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],Resource:["arn:aws:s3:::"+$b+"/*"]},{Effect:"Allow",Action:["s3:ListBucket"],Resource:["arn:aws:s3:::"+$b]}]}' > "$WORK/velero-policy.json"
  role_exists "$VELERO_ROLE" && echo "el rol $VELERO_ROLE ya existe" || run "create-role $VELERO_ROLE (IRSA keos-backup/velero-server)" iam create-role --role-name "$VELERO_ROLE" --assume-role-policy-document "file://$WORK/velero-trust.json" "${TAGS_IAM[@]}"
  policy_exists "$PARN" && echo "la policy $PARN ya existe" || run "create-policy ${CLUSTER_NAME}-velero" iam create-policy --policy-name "${CLUSTER_NAME}-velero" --policy-document "file://$WORK/velero-policy.json" "${TAGS_IAM[@]}"
  run "attach-role-policy $VELERO_ROLE <- $PARN" iam attach-role-policy --role-name "$VELERO_ROLE" --policy-arn "$PARN"
  ;;
# ------------------------------------------------------------------------------------------------------------
efs)
  cp_profile; derive_vars
  FSJ="$(awsx efs describe-file-systems --creation-token "$CLUSTER_NAME" --output json)"
  EFS_ID="$(jq -r '.FileSystems[0].FileSystemId // ""' <<<"$FSJ")"
  if [[ -n "$EFS_ID" ]]; then echo "el EFS $EFS_ID ya existe (creation-token $CLUSTER_NAME)"
  else
    run "create-file-system (cifrado, creation-token $CLUSTER_NAME)" efs create-file-system --creation-token "$CLUSTER_NAME" --encrypted \
      --tags "Key=Name,Value=$CLUSTER_NAME" "Key=keos.stratio.com/owner,Value=$CLUSTER_NAME" "Key=managed-by,Value=legacy-eks-cluster"
    if [[ $APPLY -eq 1 ]]; then
      EFS_ID="$(awsx efs describe-file-systems --creation-token "$CLUSTER_NAME" --output json | jq -r '.FileSystems[0].FileSystemId')"
      for i in $(seq 1 60); do [[ "$(awsx efs describe-file-systems --file-system-id "$EFS_ID" --output json | jq -r '.FileSystems[0].LifeCycleState')" == available ]] && break; sleep 5; done
    fi
  fi
  if [[ -z "$EFS_ID" ]]; then echo "[DRY-RUN] (los mount targets y la política se calcularán cuando exista el EFS)"; exit 0; fi
  have="$(awsx efs describe-mount-targets --file-system-id "$EFS_ID" --output json | jq -r '[.MountTargets[].SubnetId]|join(" ")')"
  for s in $SUBNET_IDS; do
    if [[ " $have " == *" $s "* ]]; then echo "mount target en $s ya existe"
    else run "create-mount-target $EFS_ID en $s (SG $CLUSTER_SG)" efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$s" --security-groups "$CLUSTER_SG"; fi
  done
  jq -n --arg r "arn:aws:elasticfilesystem:${AWS_REGION}:${AWS_ACCOUNT_ID}:file-system/${EFS_ID}" '{Version:"2012-10-17",Statement:[{Sid:"AccessThroughMountTarget",Effect:"Allow",Principal:{AWS:"*"},Action:["elasticfilesystem:ClientRootAccess","elasticfilesystem:ClientWrite","elasticfilesystem:ClientMount"],Resource:$r,Condition:{Bool:{"aws:SecureTransport":"true","elasticfilesystem:AccessedViaMountTarget":"true"}}}]}' > "$WORK/efs-fs-policy.json"
  run "put-file-system-policy $EFS_ID (solo vía mount target y con TLS)" efs put-file-system-policy --file-system-id "$EFS_ID" --policy "file://$WORK/efs-fs-policy.json"
  if [[ $APPLY -eq 1 ]]; then echo "EFS_ID=$EFS_ID (los mount targets tardan 1-2 min en estar available)"; fi
  ;;
# ------------------------------------------------------------------------------------------------------------
efs-csi)
  cp_profile
  NODE_ROLE=eks-nodegroup.cluster-api-provider-aws.sigs.k8s.io; PARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-efs-csi"
  : "${EFS_CSI_POLICY_URL:?falta EFS_CSI_POLICY_URL en cluster.env}"
  echo "ATENCIÓN: $NODE_ROLE es un rol DE CUENTA compartido por todos los clústeres que cree cloud-provisioner aquí;"
  echo "          todos los pods de los nodos heredarían los permisos de EFS de la policy."
  if [[ -f "$WORK/efs-csi-policy.json" ]]; then echo "usando $WORK/efs-csi-policy.json existente (bórralo para volver a descargar)"
  else curl -fsSL -o "$WORK/efs-csi-policy.json" "$EFS_CSI_POLICY_URL" || die "no se pudo descargar $EFS_CSI_POLICY_URL"; fi
  jq -e '.Statement' "$WORK/efs-csi-policy.json" >/dev/null || die "la policy descargada no es un documento IAM válido"
  echo "sha256: $(sha256sum "$WORK/efs-csi-policy.json" | cut -d' ' -f1)   origen: $EFS_CSI_POLICY_URL (sin versión fija: REVISAR)"
  jq -r '.Statement[] | [.Effect, (.Action|if type=="array" then join(",") else . end)] | @tsv' "$WORK/efs-csi-policy.json"
  if [[ $APPLY -eq 1 && $ACK -ne 1 ]]; then die "añade --ack-shared-node-role cuando la persona usuaria haya dado su OK explícito a modificar el rol de nodos de cuenta"; fi
  policy_exists "$PARN" && echo "la policy $PARN ya existe" || run "create-policy ${CLUSTER_NAME}-efs-csi" iam create-policy --policy-name "${CLUSTER_NAME}-efs-csi" --policy-document "file://$WORK/efs-csi-policy.json" "${TAGS_IAM[@]}"
  run "attach-role-policy $NODE_ROLE <- $PARN (ROL DE CUENTA COMPARTIDO)" iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn "$PARN"
  ;;
# ------------------------------------------------------------------------------------------------------------
status)
  cp_profile
  echo "-- IAM"; for r in "${CLUSTER_NAME}-external-dns" "$VELERO_ROLE"; do role_exists "$r" && echo "rol $r: existe" || echo "rol $r: no"; done
  for p in "$ECR_POLICY_ARN" "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-external-dns" "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-velero" "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-efs-csi"; do policy_exists "$p" && echo "policy $p: existe" || echo "policy $p: no"; done
  echo "-- EFS: $(awsx efs describe-file-systems --creation-token "$CLUSTER_NAME" --output json | jq -r '.FileSystems[0].FileSystemId // "no"')"
  echo "-- bucket $VELERO_BUCKET: $(awsx s3api head-bucket --bucket "$VELERO_BUCKET" >/dev/null 2>&1 && echo existe || echo no)"
  echo "-- zonas de $EXTERNAL_DOMAIN: $(awsx route53 list-hosted-zones --output json | jq -r --arg n "${EXTERNAL_DOMAIN}." '[.HostedZones[]|select(.Name==$n)|.Id+(if .Config.PrivateZone then "(privada)" else "(pública)" end)]|join(" ")')"
  ;;
*) die "paso desconocido: $STEP (iam-user|ecr-policy|zones|external-dns|velero|efs|efs-csi|status)" ;;
esac

#!/usr/bin/env bash
# s3-requisites.sh - requisitos AWS del modo S3 de apps-layer: stack CloudFormation minimo propio
#   (bucket interno + usuario IAM + access key + secreto en Secrets Manager) y, OPCIONAL (ENABLE_BACKUPS_BUCKET=true, por
#   defecto false), el bucket de backups de la plataforma Stratio (+ usuario IAM + access key + secreto) para migrar a GitOps.
#
# Usage: s3-requisites.sh [plan|apply|status|env|backups-info|delete] [--delete-backups] [-h]
#   plan    (por defecto) solo lectura: muestra variables, estado actual y lo que haria apply. No escribe nada.
#   apply   cloudformation deploy del stack ${STACK_NAME}. Exige terminal interactiva y escribir el nombre del cluster.
#   status  solo lectura: estado del stack, bucket, usuario, secreto y nombres presentes en ${APPS_LAYER_DIR}/.env.
#   env     anade S3_BUCKET_ACCESS_KEY, S3_BUCKET_SECRET_KEY y AWS_REGION a ${APPS_LAYER_DIR}/.env leyendo el
#           secreto de Secrets Manager SIN imprimirlo (chmod 600, idempotente: sustituye lineas, no duplica).
#   delete  vacia el bucket (objetos, versiones, delete markers, multipart), borra el stack y el bucket (que tiene
#           DeletionPolicy Retain) y limpia las claves del .env. Pide escribir el nombre del cluster y la cuenta.
#           El bucket de BACKUPS NO se toca (se conserva; si el stack lo tiene, su usuario IAM/clave/secreto SI se van con el stack).
#           Solo con --delete-backups tambien lo vacia (versiones y delete markers) y lo borra, tras una confirmacion EXTRA
#           tecleando el nombre de ese bucket.
#   backups-info  solo lectura y SIN secretos: bucket, region, usuario IAM, ARN del secreto y el comando
#           `aws secretsmanager get-secret-value` (no se ejecuta) para obtener las claves; es lo que necesita keos-fleet
#           (backups.s3BucketName/s3BucketRegion y BACKUPS_S3_BUNDLE).
# Bucket de backups (ENABLE_BACKUPS_BUCKET, BACKUPS_BUCKET_NAME, BACKUPS_USER_NAME): activarlo sobre un stack existente es una
# ACTUALIZACION que solo AÑADE recursos. `env` escribe BACKUPS_S3_BUCKET_{ACCESS_KEY,SECRET_KEY,NAME,REGION} en el .env solo si esta
# habilitado (apps-layer-automation no las usa: son para hacer `source` al migrar a GitOps).
#
# Perfil AWS: KIT_AWS_PROFILE (por defecto cloud-provisioner), region AWS_REGION; la cuenta se verifica con sts.
# Los secretos nunca se imprimen ni van en la linea de comandos.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
{ set +x; } 2>/dev/null

CMD="plan"
case "${1:-}" in
  plan|apply|status|env|backups-info|delete) CMD="$1"; shift ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  "") ;;
  *) die "subcomando desconocido: $1 (plan|apply|status|env|backups-info|delete)" ;;
esac
DELETE_BACKUPS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-backups) [[ "$CMD" == delete ]] || die "--delete-backups solo se admite con el subcomando delete"; DELETE_BACKUPS=1; shift ;;
    *) die "argumentos sobrantes: $*" ;;
  esac
done

need_tools jq
load_kit_env
pick_aws_bin
TPL="$KIT_DIR/templates/requisites-s3.cfn.yaml"
ENV_FILE="$APPS_LAYER_DIR/.env"
[[ -f "$TPL" ]] || die "no existe la plantilla $TPL"
[[ "$CMD" == apply || "$CMD" == env || "$CMD" == delete ]] || export KIT_READONLY=1
BK=0; [[ "$ENABLE_BACKUPS_BUCKET" != true ]] || BK=1   # bucket de backups habilitado

# ---- estado (solo lectura) ----------------------------------------------------------------------------------
STACK_EXISTS=0; STACK_STATUS=""; STACK_JSON=""
BUCKET_STATE="no"        # no | si | ajeno (403: existe pero no es accesible)
USER_EXISTS=0; SECRET_STATE="no"   # no | si | borrandose
# bucket de backups (solo se consulta si esta habilitado, si el stack ya lo tiene o con delete: sin habilitar, mismas llamadas que antes)
BACKUPS_READ=0; B_BUCKET_STATE="no"; B_USER_EXISTS=0; B_SECRET_STATE="no"

read_state() {
  if STACK_JSON="$(awsr cloudformation describe-stacks --stack-name "$STACK_NAME" --output json 2>/dev/null)"; then
    STACK_EXISTS=1; STACK_STATUS="$(jq -r '.Stacks[0].StackStatus // "?"' <<<"$STACK_JSON")"
  else STACK_EXISTS=0; STACK_STATUS=""; STACK_JSON=""; fi
  local out rc=0
  out="$(awsr s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then BUCKET_STATE="si"
  elif grep -qiE '404|not found|NoSuchBucket' <<<"$out"; then BUCKET_STATE="no"
  else BUCKET_STATE="ajeno"; fi
  if awsr iam get-user --user-name "$S3_USER_NAME" --output json >/dev/null 2>&1; then USER_EXISTS=1; else USER_EXISTS=0; fi
  local sj
  if sj="$(awsr secretsmanager describe-secret --secret-id "$S3_USER_NAME" --output json 2>/dev/null)"; then
    if jq -e '.DeletedDate' <<<"$sj" >/dev/null 2>&1; then SECRET_STATE="borrandose"; else SECRET_STATE="si"; fi
  else SECRET_STATE="no"; fi
  read_backups_state
}

stack_output() {  # stack_output CLAVE -> valor (vacio si no existe)
  [[ -n "$STACK_JSON" ]] || return 0
  jq -r --arg k "$1" '(.Stacks[0].Outputs // [])[] | select(.OutputKey==$k) | .OutputValue' <<<"$STACK_JSON"
}

# El stack ya tiene el bucket de backups (output BackupsS3BucketName)
stack_has_backups() { [[ -n "$(stack_output BackupsS3BucketName)" ]]; }

read_backups_state() {
  if [[ $BK == 1 ]] || stack_has_backups || [[ "$CMD" == delete ]]; then BACKUPS_READ=1; else BACKUPS_READ=0; return 0; fi
  local out rc=0 sj
  out="$(awsr s3api head-bucket --bucket "$BACKUPS_BUCKET_NAME" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then B_BUCKET_STATE="si"
  elif grep -qiE '404|not found|NoSuchBucket' <<<"$out"; then B_BUCKET_STATE="no"
  else B_BUCKET_STATE="ajeno"; fi
  if awsr iam get-user --user-name "$BACKUPS_USER_NAME" --output json >/dev/null 2>&1; then B_USER_EXISTS=1; else B_USER_EXISTS=0; fi
  if sj="$(awsr secretsmanager describe-secret --secret-id "$BACKUPS_USER_NAME" --output json 2>/dev/null)"; then
    if jq -e '.DeletedDate' <<<"$sj" >/dev/null 2>&1; then B_SECRET_STATE="borrandose"; else B_SECRET_STATE="si"; fi
  else B_SECRET_STATE="no"; fi
}

show_vars() {
  cat <<EOF
Cluster ........ $CLUSTER_NAME   (cuenta esperada $AWS_ACCOUNT_ID, region $AWS_REGION, perfil $KIT_AWS_PROFILE)
Stack .......... $STACK_NAME
Bucket ......... $S3_BUCKET_NAME
Usuario IAM .... $S3_USER_NAME   (el secreto de Secrets Manager se llama igual)
Plantilla ...... $TPL
.env destino ... $ENV_FILE
EOF
  if [[ $BK == 1 ]]; then
    echo "Backups ........ HABILITADO (ENABLE_BACKUPS_BUCKET=true): bucket $BACKUPS_BUCKET_NAME, usuario IAM $BACKUPS_USER_NAME (el secreto se llama igual)"
  elif [[ "$CMD" == plan ]]; then echo "Backups ........ no habilitado (ENABLE_BACKUPS_BUCKET=false)"; fi   # solo plan: el resto de salidas sin habilitar son las de antes
}

show_state() {
  echo "Estado actual:"
  echo "  stack:   ${STACK_STATUS:-no existe}"
  echo "  bucket:  $BUCKET_STATE"
  echo "  usuario: $([[ $USER_EXISTS == 1 ]] && echo existe || echo no existe)"
  echo "  secreto: $SECRET_STATE"
  # sin habilitar y sin nada de backups en la cuenta/stack no se imprime nada (salida igual que antes)
  if [[ $BACKUPS_READ == 1 ]] && { [[ $BK == 1 ]] || stack_has_backups || [[ "$B_BUCKET_STATE" != no || $B_USER_EXISTS == 1 || "$B_SECRET_STATE" != no ]]; }; then
    echo "  backups: bucket $BACKUPS_BUCKET_NAME=$B_BUCKET_STATE  usuario $BACKUPS_USER_NAME=$([[ $B_USER_EXISTS == 1 ]] && echo existe || echo "no existe")  secreto=$B_SECRET_STATE  (en el stack: $(stack_has_backups && echo si || echo no))"
  fi
}

# conflictos que impiden un apply seguro; imprime los problemas y devuelve 1 si hay alguno
check_conflicts() {
  local bad=0
  if [[ $STACK_EXISTS == 0 ]]; then
    if [[ "$BUCKET_STATE" != no ]]; then
      komsg "el bucket $S3_BUCKET_NAME ya existe (o pertenece a otra cuenta) y no lo gestiona el stack: elige otro S3_BUCKET_NAME"; bad=1; fi
    if [[ $USER_EXISTS == 1 ]]; then
      komsg "el usuario IAM $S3_USER_NAME ya existe y no lo gestiona el stack: elige otro S3_USER_NAME"; bad=1; fi
    if [[ "$SECRET_STATE" == si ]]; then
      komsg "ya existe un secreto llamado $S3_USER_NAME: elige otro S3_USER_NAME"; bad=1; fi
  fi
  if [[ "$SECRET_STATE" == borrandose ]]; then
    komsg "el secreto $S3_USER_NAME esta programado para borrado (CloudFormation lo borra con ventana de recuperacion) y su nombre sigue reservado."
    echo "    Liberarlo (irreversible):  aws secretsmanager delete-secret --secret-id $S3_USER_NAME --force-delete-without-recovery --profile $KIT_AWS_PROFILE --region $AWS_REGION"
    bad=1
  fi
  if [[ $BK == 1 ]]; then
    if ! stack_has_backups; then
      # backups aun no gestionados por el stack: cualquier recurso homonimo es ajeno y aborta
      if [[ "$B_BUCKET_STATE" != no ]]; then
        komsg "el bucket de backups $BACKUPS_BUCKET_NAME ya existe (o pertenece a otra cuenta) y no lo gestiona el stack: elige otro BACKUPS_BUCKET_NAME"; bad=1; fi
      if [[ $B_USER_EXISTS == 1 ]]; then
        komsg "el usuario IAM $BACKUPS_USER_NAME ya existe y no lo gestiona el stack: elige otro BACKUPS_USER_NAME"; bad=1; fi
      if [[ "$B_SECRET_STATE" == si ]]; then
        komsg "ya existe un secreto llamado $BACKUPS_USER_NAME: elige otro BACKUPS_USER_NAME"; bad=1; fi
    elif [[ "$(stack_output BackupsS3BucketName)" != "$BACKUPS_BUCKET_NAME" || "$(stack_output BackupsS3BucketUser)" != "$BACKUPS_USER_NAME" ]]; then
      # ya los gestiona el stack: cambiar el nombre implicaria reemplazo (usuario/secreto nuevos, bucket Retain huerfano)
      komsg "el stack ya tiene backups con otro bucket/usuario ($(stack_output BackupsS3BucketName) / $(stack_output BackupsS3BucketUser)): cambiar el nombre REEMPLAZARIA recursos. Restaura BACKUPS_BUCKET_NAME/BACKUPS_USER_NAME o gestiona el cambio a mano"; bad=1
    fi
    if [[ "$B_SECRET_STATE" == borrandose ]]; then
      komsg "el secreto $BACKUPS_USER_NAME esta programado para borrado (ventana de recuperacion) y su nombre sigue reservado."
      echo "    Liberarlo (irreversible):  aws secretsmanager delete-secret --secret-id $BACKUPS_USER_NAME --force-delete-without-recovery --profile $KIT_AWS_PROFILE --region $AWS_REGION"
      bad=1
    fi
  elif stack_has_backups; then
    komsg "el stack ya tiene el bucket de backups y ENABLE_BACKUPS_BUCKET=false lo QUITARIA del stack (borraria el usuario IAM, su clave y el secreto; el bucket Retain quedaria huerfano). Pon ENABLE_BACKUPS_BUCKET=true"; bad=1
  fi
  case "$STACK_STATUS" in
    ""|CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) ;;
    *) komsg "el stack esta en estado $STACK_STATUS: resuelvelo antes de aplicar"; bad=1 ;;
  esac
  return $bad
}

print_apply_cmd() {
  cat <<EOF
Comando que ejecutaria apply:
  aws cloudformation deploy --stack-name $STACK_NAME --template-file $TPL \\
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --tags cluster=$CLUSTER_NAME \\
    --parameter-overrides ClusterName=$CLUSTER_NAME InternalS3BucketName=$S3_BUCKET_NAME InternalS3BucketUser=$S3_USER_NAME $(backups_params)
EOF
}

# parametros de backups de cloudformation deploy (EnableBackupsBucket=false: no crea nada y no toca los recursos existentes)
backups_params() {
  if [[ $BK == 1 ]]; then echo "EnableBackupsBucket=true BackupsS3BucketName=$BACKUPS_BUCKET_NAME BackupsS3BucketUser=$BACKUPS_USER_NAME"
  else echo "EnableBackupsBucket=false"; fi
}

# ---- subcomandos --------------------------------------------------------------------------------------------
do_plan() {
  assert_account
  show_vars; echo; read_state; show_state; echo
  if awsr cloudformation validate-template --template-body "file://$TPL" --output json >/dev/null 2>&1; then
    okmsg "la plantilla es valida (validate-template)"
  else wnmsg "validate-template no pudo validar la plantilla (permisos o sintaxis)"; fi
  if check_conflicts; then okmsg "sin conflictos de nombres"; fi
  echo; print_apply_cmd
  echo; echo "Crea: bucket versionado y cifrado (Retain), usuario IAM con s3:* solo sobre ese bucket, access key y secreto."
  describe_backups_effect
  if [[ $BK == 1 ]]; then echo "Siguiente: s3-requisites.sh apply, luego s3-requisites.sh env y s3-requisites.sh backups-info     (plan no ha escrito nada)"
  else echo "Siguiente: s3-requisites.sh apply   y luego   s3-requisites.sh env     (plan no ha escrito nada)"; fi
}

# que hara apply con el bucket de backups (solo se menciona si esta habilitado o el stack ya lo tiene)
describe_backups_effect() {
  if [[ $BK == 1 ]]; then
    if [[ $STACK_EXISTS == 1 ]] && stack_has_backups; then
      echo "Backups: ya estan en el stack (bucket $BACKUPS_BUCKET_NAME, usuario $BACKUPS_USER_NAME): apply no cambia nada de ellos."
    elif [[ $STACK_EXISTS == 1 ]]; then
      echo "Backups: el stack existe, asi que apply es una ACTUALIZACION que solo AÑADE recursos (nada existente se reemplaza ni se borra):"
      echo "  + bucket de backups $BACKUPS_BUCKET_NAME (versionado, cifrado AES256, acceso publico bloqueado, Retain)"
      echo "  + usuario IAM $BACKUPS_USER_NAME (s3:* solo sobre ese bucket) con su access key"
      echo "  + secreto de Secrets Manager $BACKUPS_USER_NAME (ACCESS_KEY/SECRET_KEY)"
    else
      echo "Backups: ademas se crearan el bucket $BACKUPS_BUCKET_NAME (Retain), el usuario IAM $BACKUPS_USER_NAME, su access key y el secreto $BACKUPS_USER_NAME."
    fi
  fi
}

do_apply() {
  require_tty
  assert_account
  show_vars; echo; read_state; show_state; echo
  check_conflicts || die "hay conflictos (arriba): nada que aplicar"
  print_apply_cmd; echo
  echo "Esto CREARA/ACTUALIZARA recursos en la cuenta $AWS_ACCOUNT_ID (usuario IAM con access key incluido)."
  describe_backups_effect
  confirm_typed "$CLUSTER_NAME" "Escribe el nombre del cluster ($CLUSTER_NAME) para continuar:" || die "confirmacion incorrecta: abortado sin tocar nada"
  awsw cloudformation deploy --stack-name "$STACK_NAME" --template-file "$TPL" \
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --tags "cluster=$CLUSTER_NAME" \
    --parameter-overrides "ClusterName=$CLUSTER_NAME" "InternalS3BucketName=$S3_BUCKET_NAME" "InternalS3BucketUser=$S3_USER_NAME" $(backups_params)
  read_state
  echo "Stack: ${STACK_STATUS:-?}"
  [[ "$STACK_STATUS" == CREATE_COMPLETE || "$STACK_STATUS" == UPDATE_COMPLETE ]] || die "el stack no quedo en estado completo (${STACK_STATUS:-?})"
  jq -r '(.Stacks[0].Outputs // [])[] | "  output \(.OutputKey) = \(.OutputValue)"' <<<"$STACK_JSON"
  echo "Siguiente: s3-requisites.sh env   (escribe las claves en $ENV_FILE sin imprimirlas)"
  [[ $BK != 1 ]] || echo "Backups: s3-requisites.sh env tambien escribe BACKUPS_S3_BUCKET_*; s3-requisites.sh backups-info imprime los datos para GitOps (sin secretos)"
}

do_status() {
  assert_account
  show_vars; echo; read_state; show_state
  if [[ $STACK_EXISTS == 1 ]]; then jq -r '(.Stacks[0].Outputs // [])[] | "  output \(.OutputKey) = \(.OutputValue)"' <<<"$STACK_JSON"; fi
  echo ".env ($ENV_FILE), solo nombres:"
  local n
  for n in S3_BUCKET_ACCESS_KEY S3_BUCKET_SECRET_KEY AWS_REGION; do
    if env_has_var "$ENV_FILE" "$n"; then okmsg "$n presente"; else komsg "$n ausente o vacio"; fi
  done
  if [[ $BK == 1 ]]; then
    for n in BACKUPS_S3_BUCKET_ACCESS_KEY BACKUPS_S3_BUCKET_SECRET_KEY BACKUPS_S3_BUCKET_NAME BACKUPS_S3_BUCKET_REGION; do
      if env_has_var "$ENV_FILE" "$n"; then okmsg "$n presente"; else wnmsg "$n ausente o vacio (s3-requisites.sh env)"; fi
    done
  fi
}

do_env() {
  assert_account
  ensure_private_dir "$APPS_LAYER_DIR"   # aborta antes de leer el secreto si el directorio no es seguro
  read_state
  [[ $STACK_EXISTS == 1 ]] || die "el stack $STACK_NAME no existe: ejecuta primero apply"
  [[ "$STACK_STATUS" == CREATE_COMPLETE || "$STACK_STATUS" == UPDATE_COMPLETE ]] || die "stack en estado $STACK_STATUS"
  local arn sj ss ak sk
  arn="$(stack_output S3StratioAppsSecretArn)"
  [[ -n "$arn" ]] || die "el stack no tiene el output S3StratioAppsSecretArn"
  sj="$(awsr secretsmanager get-secret-value --secret-id "$arn" --output json)" || die "no se pudo leer el secreto $arn"
  ss="$(jq -r '.SecretString // empty' <<<"$sj")"; unset sj
  ak="$(jq -r '.ACCESS_KEY // empty' <<<"$ss")"; sk="$(jq -r '.SECRET_KEY // empty' <<<"$ss")"; unset ss
  [[ -n "$ak" && -n "$sk" ]] || die "el secreto no contiene ACCESS_KEY/SECRET_KEY"
  ensure_private_dir "$APPS_LAYER_DIR"
  [[ -f "$ENV_FILE" ]] || ( umask 077; : > "$ENV_FILE" )
  chmod 600 "$ENV_FILE"
  emit_export S3_BUCKET_ACCESS_KEY "$ak" | env_replace "$ENV_FILE" S3_BUCKET_ACCESS_KEY
  emit_export S3_BUCKET_SECRET_KEY "$sk" | env_replace "$ENV_FILE" S3_BUCKET_SECRET_KEY
  unset ak sk
  printf 'export AWS_REGION=%s\n' "$AWS_REGION" | env_replace "$ENV_FILE" AWS_REGION
  okmsg "S3_BUCKET_ACCESS_KEY, S3_BUCKET_SECRET_KEY y AWS_REGION escritas en $ENV_FILE (modo 600; valores no mostrados)"
  if [[ $BK == 1 ]]; then env_backups; fi
  echo "Recuerda: las claves no estan en el YAML; en un contenedor ya arrancado ejecuta  source /apps-layer/.env"
}

# Variables de backups en el .env (solo con ENABLE_BACKUPS_BUCKET=true y si el stack ya tiene el output). apps-layer-automation NO las usa:
# son para hacer `source` al migrar a GitOps (keos-fleet backups.s3BucketName/s3BucketRegion y BACKUPS_S3_BUNDLE). Nunca se imprimen valores.
env_backups() {
  local arn sj ss ak sk
  arn="$(stack_output BackupsS3SecretArn)"
  if [[ -z "$arn" ]]; then
    wnmsg "ENABLE_BACKUPS_BUCKET=true pero el stack $STACK_NAME aun no tiene el bucket de backups (falta el output BackupsS3SecretArn): ejecuta s3-requisites.sh apply y luego env. No se escribe BACKUPS_S3_BUCKET_* en $ENV_FILE."
    return 0
  fi
  sj="$(awsr secretsmanager get-secret-value --secret-id "$arn" --output json)" || die "no se pudo leer el secreto de backups $arn"
  ss="$(jq -r '.SecretString // empty' <<<"$sj")"; unset sj
  ak="$(jq -r '.ACCESS_KEY // empty' <<<"$ss")"; sk="$(jq -r '.SECRET_KEY // empty' <<<"$ss")"; unset ss
  [[ -n "$ak" && -n "$sk" ]] || die "el secreto de backups no contiene ACCESS_KEY/SECRET_KEY"
  emit_export BACKUPS_S3_BUCKET_ACCESS_KEY "$ak" | env_replace "$ENV_FILE" BACKUPS_S3_BUCKET_ACCESS_KEY
  emit_export BACKUPS_S3_BUCKET_SECRET_KEY "$sk" | env_replace "$ENV_FILE" BACKUPS_S3_BUCKET_SECRET_KEY
  unset ak sk
  emit_export BACKUPS_S3_BUCKET_NAME "$(stack_output BackupsS3BucketName)" | env_replace "$ENV_FILE" BACKUPS_S3_BUCKET_NAME
  emit_export BACKUPS_S3_BUCKET_REGION "$AWS_REGION" | env_replace "$ENV_FILE" BACKUPS_S3_BUCKET_REGION
  okmsg "BACKUPS_S3_BUCKET_ACCESS_KEY, _SECRET_KEY, _NAME y _REGION escritas en $ENV_FILE (modo 600; valores no mostrados; apps-layer no las usa: para 'source' al migrar a GitOps)"
}

do_backups_info() {
  assert_account
  read_state
  local b u arn
  if [[ $STACK_EXISTS == 0 ]] || ! stack_has_backups; then
    if [[ $BK == 1 ]]; then komsg "ENABLE_BACKUPS_BUCKET=true pero el stack $STACK_NAME aun no tiene el bucket de backups: ejecuta s3-requisites.sh plan y apply"
    else komsg "bucket de backups no habilitado (ENABLE_BACKUPS_BUCKET=false) y el stack $STACK_NAME no lo tiene: activalo en kit.env y ejecuta s3-requisites.sh plan/apply"; fi
    return 1
  fi
  b="$(stack_output BackupsS3BucketName)"; u="$(stack_output BackupsS3BucketUser)"; arn="$(stack_output BackupsS3SecretArn)"
  cat <<EOF
Bucket de backups (datos para el consumidor GitOps; sin secretos)
  Stack ............ $STACK_NAME ($STACK_STATUS)
  Bucket ........... $b     (keos-fleet: backups.s3BucketName)
  Region ........... $AWS_REGION     (keos-fleet: backups.s3BucketRegion)
  Usuario IAM ...... $u
  Secreto (ARN) .... $arn
Para obtener las claves (NO se ejecuta aqui; imprime el secreto, hazlo tu y no lo pegues en ningun sitio):
  aws secretsmanager get-secret-value --secret-id $arn --region $AWS_REGION --profile $KIT_AWS_PROFILE --query SecretString --output text
Formato del secreto: {"ACCESS_KEY":"...","SECRET_KEY":"..."}. Alternativa sin imprimirlas: s3-requisites.sh env (las deja en $ENV_FILE) y  source $ENV_FILE
Para keos-fleet, BACKUPS_S3_BUNDLE es el base64 de:
  passwords:
    - name: backup
      data:
        user: <ACCESS_KEY>
        pass: <SECRET_KEY>
EOF
}

empty_bucket() {  # empty_bucket BUCKET
  local bkt="$1" j objs n f
  while :; do
    j="$(awsr s3api list-object-versions --bucket "$bkt" --max-items 1000 --output json)"
    objs="$(jq -c '[(.Versions // [])[], (.DeleteMarkers // [])[]] | map({Key, VersionId})' <<<"$j")"
    n="$(jq 'length' <<<"$objs")"
    [[ "$n" -gt 0 ]] || break
    f="$(umask 077; mktemp "${TMPDIR:-/tmp}/s3del.XXXXXX")"
    jq -c '{Objects: ., Quiet: true}' <<<"$objs" > "$f"
    awsw s3api delete-objects --bucket "$bkt" --delete "file://$f" >/dev/null || { rm -f "$f"; die "fallo al borrar objetos"; }
    rm -f "$f"; echo "  borradas $n versiones/delete markers"
  done
  j="$(awsr s3api list-multipart-uploads --bucket "$bkt" --output json 2>/dev/null || echo '{}')"
  while IFS=$'\t' read -r key uid; do
    [[ -n "$key" ]] || continue
    awsw s3api abort-multipart-upload --bucket "$bkt" --key "$key" --upload-id "$uid" >/dev/null
    echo "  abortada subida multiparte"
  done < <(jq -r '(.Uploads // [])[] | [.Key, .UploadId] | @tsv' <<<"$j")
}

do_delete() {
  require_tty
  assert_account
  show_vars; echo; read_state; show_state; echo
  if [[ $STACK_EXISTS == 0 && "$BUCKET_STATE" == no && $USER_EXISTS == 0 && "$SECRET_STATE" == no \
        && "$B_BUCKET_STATE" == no && $B_USER_EXISTS == 0 && "$B_SECRET_STATE" == no ]]; then
    info "no queda nada que borrar"; env_remove "$ENV_FILE" S3_BUCKET_ACCESS_KEY; env_remove "$ENV_FILE" S3_BUCKET_SECRET_KEY
    [[ $DELETE_BACKUPS == 0 ]] || { env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_ACCESS_KEY; env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_SECRET_KEY; env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_NAME; env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_REGION; }
    return 0
  fi
  [[ "$BUCKET_STATE" != ajeno ]] || die "el bucket $S3_BUCKET_NAME existe pero no es accesible con este perfil (no es nuestro): no se toca"
  # pertenencia del bucket: lo declara el stack o lleva la etiqueta cluster=<CLUSTER_NAME>
  if [[ "$BUCKET_STATE" == si ]]; then
    local own=0 tj
    if [[ $STACK_EXISTS == 1 && "$(stack_output InternalS3BucketName)" == "$S3_BUCKET_NAME" ]]; then own=1; fi
    if [[ $own == 0 ]]; then
      tj="$(awsr s3api get-bucket-tagging --bucket "$S3_BUCKET_NAME" --output json 2>/dev/null || echo '{}')"
      if jq -e --arg c "$CLUSTER_NAME" '(.TagSet // [])[] | select(.Key=="cluster" and .Value==$c)' <<<"$tj" >/dev/null; then own=1; fi
    fi
    [[ $own == 1 ]] || die "el bucket $S3_BUCKET_NAME no es de este cluster (ni lo declara el stack ni lleva la etiqueta cluster=$CLUSTER_NAME): abortado"
  fi
  # bucket de backups: pertenencia (solo si se pide borrarlo) y que pasa con el por defecto
  local B_IN_STACK=0 B_DEL=0
  stack_has_backups && B_IN_STACK=1
  if [[ "$B_BUCKET_STATE" == si && $DELETE_BACKUPS == 1 ]]; then
    local bown=0 btj
    if [[ $STACK_EXISTS == 1 && "$(stack_output BackupsS3BucketName)" == "$BACKUPS_BUCKET_NAME" ]]; then bown=1; fi
    if [[ $bown == 0 ]]; then
      btj="$(awsr s3api get-bucket-tagging --bucket "$BACKUPS_BUCKET_NAME" --output json 2>/dev/null || echo '{}')"
      if jq -e --arg c "$CLUSTER_NAME" '(.TagSet // [])[] | select(.Key=="cluster" and .Value==$c)' <<<"$btj" >/dev/null; then bown=1; fi
    fi
    [[ $bown == 1 ]] || die "el bucket de backups $BACKUPS_BUCKET_NAME no es de este cluster (ni lo declara el stack ni lleva la etiqueta cluster=$CLUSTER_NAME): abortado sin tocar nada"
    B_DEL=1
  elif [[ "$B_BUCKET_STATE" == ajeno && $DELETE_BACKUPS == 1 ]]; then
    die "el bucket de backups $BACKUPS_BUCKET_NAME existe pero no es accesible con este perfil (no es nuestro): no se toca"
  fi
  cat <<EOF
Se BORRARA de forma IRREVERSIBLE en la cuenta $AWS_ACCOUNT_ID:
  - todos los objetos, versiones y delete markers del bucket $S3_BUCKET_NAME y el propio bucket
  - el stack $STACK_NAME (usuario IAM $S3_USER_NAME, su access key y el secreto de Secrets Manager)
  - las lineas S3_BUCKET_ACCESS_KEY/S3_BUCKET_SECRET_KEY de $ENV_FILE
Las apps de apps-layer que usen ese bucket dejaran de funcionar.
EOF
  if [[ $B_DEL == 1 ]]; then
    cat <<EOF

--delete-backups: ademas se BORRARA de forma IRREVERSIBLE el bucket de BACKUPS $BACKUPS_BUCKET_NAME con TODAS sus versiones y delete markers
(copias de seguridad de la plataforma: no hay forma de recuperarlas), el usuario IAM $BACKUPS_USER_NAME, su access key y su secreto, y las
lineas BACKUPS_S3_BUCKET_* de $ENV_FILE.
Se te pedira ADEMAS (confirmacion EXTRA) escribir el nombre del bucket de backups.
EOF
  else
    if [[ "$B_BUCKET_STATE" == si ]]; then
      echo
      echo "El bucket de BACKUPS $BACKUPS_BUCKET_NAME NO se toca: se CONSERVA con todos sus datos (Retain). Para borrarlo: delete --delete-backups."
    fi
    if [[ $B_IN_STACK == 1 ]]; then
      echo "AVISO: el stack tiene los recursos de backups: al borrar el stack se borran su usuario IAM $BACKUPS_USER_NAME, su access key y su secreto (el bucket y sus datos quedan, sin credenciales ni gestion del stack)."
    fi
    [[ $DELETE_BACKUPS == 0 ]] || info "--delete-backups: no hay bucket de backups $BACKUPS_BUCKET_NAME que borrar"
  fi
  confirm_typed "$CLUSTER_NAME" "Escribe el nombre del cluster ($CLUSTER_NAME):" || die "confirmacion incorrecta: abortado sin tocar nada"
  confirm_typed "$AWS_ACCOUNT_ID" "Escribe el numero de cuenta ($AWS_ACCOUNT_ID):" || die "confirmacion incorrecta: abortado sin tocar nada"
  if [[ $B_DEL == 1 ]]; then
    confirm_typed "$BACKUPS_BUCKET_NAME" "CONFIRMACION EXTRA: escribe el nombre del bucket de BACKUPS ($BACKUPS_BUCKET_NAME) para borrarlo con todos sus datos:" || die "confirmacion incorrecta: abortado sin tocar nada"
  fi

  if [[ "$BUCKET_STATE" == si ]]; then echo "Vaciando bucket..."; empty_bucket "$S3_BUCKET_NAME"; fi
  if [[ $B_DEL == 1 ]]; then echo "Vaciando bucket de backups $BACKUPS_BUCKET_NAME..."; empty_bucket "$BACKUPS_BUCKET_NAME"; fi
  if [[ $STACK_EXISTS == 1 ]]; then
    echo "Borrando stack $STACK_NAME..."
    awsw cloudformation delete-stack --stack-name "$STACK_NAME"
    awsw cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" || die "el borrado del stack no termino correctamente: revisalo en la consola"
  fi
  if [[ "$BUCKET_STATE" == si ]]; then
    echo "Borrando bucket (Retain en el stack)..."
    awsw s3api delete-bucket --bucket "$S3_BUCKET_NAME"
  fi
  if [[ $B_DEL == 1 ]]; then
    echo "Borrando bucket de backups $BACKUPS_BUCKET_NAME (Retain en el stack)..."
    awsw s3api delete-bucket --bucket "$BACKUPS_BUCKET_NAME"
  fi
  # CloudFormation deja el secreto en ventana de recuperacion y su nombre reservado: lo liberamos para poder relanzar
  local sj
  if sj="$(awsr secretsmanager describe-secret --secret-id "$S3_USER_NAME" --output json 2>/dev/null)" && jq -e '.DeletedDate' <<<"$sj" >/dev/null 2>&1; then
    echo "Liberando el nombre del secreto $S3_USER_NAME (borrado sin recuperacion)..."
    awsw secretsmanager delete-secret --secret-id "$S3_USER_NAME" --force-delete-without-recovery >/dev/null
  fi
  if [[ $B_DEL == 1 ]] && sj="$(awsr secretsmanager describe-secret --secret-id "$BACKUPS_USER_NAME" --output json 2>/dev/null)" && jq -e '.DeletedDate' <<<"$sj" >/dev/null 2>&1; then
    echo "Liberando el nombre del secreto de backups $BACKUPS_USER_NAME (borrado sin recuperacion)..."
    awsw secretsmanager delete-secret --secret-id "$BACKUPS_USER_NAME" --force-delete-without-recovery >/dev/null
  fi
  env_remove "$ENV_FILE" S3_BUCKET_ACCESS_KEY; env_remove "$ENV_FILE" S3_BUCKET_SECRET_KEY
  # las claves de backups dejan de ser validas si el stack se borra (su access key iba en el stack)
  if [[ $B_IN_STACK == 1 ]]; then env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_ACCESS_KEY; env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_SECRET_KEY; fi
  if [[ $B_DEL == 1 ]]; then
    env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_ACCESS_KEY; env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_SECRET_KEY
    env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_NAME; env_remove "$ENV_FILE" BACKUPS_S3_BUCKET_REGION
    okmsg "borrado completado (stack, buckets interno y de backups, usuarios, secretos y claves del .env)"
  else
    okmsg "borrado completado (stack, bucket, usuario, secreto y claves del .env)"
    [[ "$B_BUCKET_STATE" != si ]] || wnmsg "el bucket de backups $BACKUPS_BUCKET_NAME se ha CONSERVADO (borrarlo: delete --delete-backups)"
  fi
}

case "$CMD" in
  plan) do_plan ;; apply) do_apply ;; status) do_status ;; env) do_env ;; backups-info) do_backups_info ;; delete) do_delete ;;
esac

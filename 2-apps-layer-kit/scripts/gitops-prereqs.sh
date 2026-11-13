#!/usr/bin/env bash
# gitops-prereqs.sh - prerrequisitos de AWS de la MIGRACION a GitOps (`flux keos cluster migrate`). ACTIVADO por defecto (ENABLE_LOKI_BUCKET=true; con false el paso se omite). Nada se crea hasta `apply`.
#
# LOKI NO ES LEGACY: el keos-installer 1.4.2 no lo despliega. Lo despliega GitOps (keos-fleet: components.loki enabled, installationType s3-eks)
# y espera, ya creados, el bucket <cluster>-loki y el rol IRSA loki-<cluster> (SA system:serviceaccount:keos-observability:loki) con la politica
# inline `loki-s3` (Stratio/keos-fleet#220, migracion-legacy-gitops.md §4.4). Sin ellos Loki no arranca tras migrar. Este script los crea de antemano.
# Hoy cubre SOLO Loki. alloy y tempo quedan DESACTIVADOS por defecto (components.alloy/tempo enabled:false) y no tienen paso de prerrequisitos. Otros prerrequisitos (KMS+rol de kustomize-controller, rol IRSA del driver
# de EFS) NO se crean aqui: ver 1-aws-cluster/GUIA-INSTALACION-LEGACY.md ("Prerrequisitos de la migracion a GitOps").
#
# Usage: gitops-prereqs.sh [plan|apply|status|info] [-h]
#   plan    (por defecto) solo lectura: variables, estado de cada recurso y lo que haria apply. No escribe nada.
#   apply   CREA lo que falte (bucket, rol IRSA, politica inline). Exige terminal interactiva y escribir el nombre del cluster. Solo CREA y es idempotente:
#           lo que ya existe se ADOPTA tal cual (no se modifica, ni se etiqueta, ni se reescribe); si difiere de lo esperado, lo AVISA y no lo toca.
#           Nunca borra. Si el rol existe pero le falta la politica inline, NO se anade (seria modificar un rol ajeno): se avisa.
#   status  solo lectura: como plan pero termina con rc=1 si falta algo o hay divergencias.
#   info    solo lectura y SIN secretos (no hay ninguno: IRSA): lo que necesita keos-fleet (components.loki.* y ARN del rol).
# El borrado NO esta aqui: lo cubre legacy-eks-uninstall (el nombre lleva el del cluster) y teardown.sh no lo toca (nunca borra buckets de datos a ciegas).
#
# Perfil AWS: KIT_AWS_PROFILE (por defecto cloud-provisioner), region AWS_REGION; la cuenta se verifica con sts. Necesita el clúster EKS vivo para leer su OIDC.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
{ set +x; } 2>/dev/null

CMD="plan"
case "${1:-}" in
  plan|apply|status|info) CMD="$1"; shift ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  "") ;;
  *) die "subcomando desconocido: $1 (plan|apply|status|info)" ;;
esac
[[ $# -eq 0 ]] || die "argumentos sobrantes: $*"

need_tools jq
load_kit_env
pick_aws_bin
[[ "$ENABLE_LOKI_BUCKET" == true ]] || die "ENABLE_LOKI_BUCKET=false (desactivado a proposito en cluster.env/kit.env/entorno): el paso se omite. Quita esa linea o pon ENABLE_LOKI_BUCKET=true para usarlo"
[[ "$CMD" == apply ]] || export KIT_READONLY=1
LOKI_SA="system:serviceaccount:keos-observability:loki"
LOKI_POLICY="loki-s3"

OIDC_ISSUER=""        # host/ruta del emisor OIDC del EKS, sin https://
OIDC_ARN=""
BUCKET_STATE="no"     # no | si | ajeno
ROLE_STATE="no"       # no | si
POLICY_STATE="no"     # no | si
DIVERGE=()

read_oidc() {
  local url
  url="$(awsr eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
  [[ -n "$url" && "$url" != None ]] || die "no se pudo leer el emisor OIDC del EKS $CLUSTER_NAME (¿existe el clúster?): sin el no se puede crear el rol IRSA"
  OIDC_ISSUER="${url#https://}"
  OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"
  awsr iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" --output json >/dev/null 2>&1 \
    || die "no existe el proveedor OIDC de IAM $OIDC_ARN: el rol IRSA no seria asumible"
}

read_state() {
  local out rc=0 rj
  out="$(awsr s3api head-bucket --bucket "$LOKI_BUCKET_NAME" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then BUCKET_STATE="si"
  elif grep -qiE '404|not found|NoSuchBucket' <<<"$out"; then BUCKET_STATE="no"
  else BUCKET_STATE="ajeno"; fi
  DIVERGE=()
  if rj="$(awsr iam get-role --role-name "$LOKI_ROLE_NAME" --output json 2>/dev/null)"; then
    ROLE_STATE="si"
    # la confianza debe permitir el SA de Loki desde el OIDC de ESTE clúster
    jq -e --arg a "$OIDC_ARN" --arg sa "$LOKI_SA" --arg iss "$OIDC_ISSUER" '
      [.Role.AssumeRolePolicyDocument.Statement[]? | select(.Effect=="Allow" and .Action=="sts:AssumeRoleWithWebIdentity"
        and ((.Principal.Federated // "")==$a) and ((.Condition.StringEquals[$iss+":sub"] // "")==$sa))] | length > 0' <<<"$rj" >/dev/null \
      || DIVERGE+=("la confianza del rol $LOKI_ROLE_NAME no es la esperada (OIDC de este clúster y sub $LOKI_SA)")
  else ROLE_STATE="no"; fi
  if [[ $ROLE_STATE == si ]] && rj="$(awsr iam get-role-policy --role-name "$LOKI_ROLE_NAME" --policy-name "$LOKI_POLICY" --output json 2>/dev/null)"; then
    POLICY_STATE="si"
    jq -e --arg b "$LOKI_BUCKET_NAME" '[.PolicyDocument.Statement[]? | (.Resource | if type=="array" then .[] else . end)] | any(. == "arn:aws:s3:::"+$b+"/*")' <<<"$rj" >/dev/null \
      || DIVERGE+=("la politica $LOKI_POLICY del rol no apunta al bucket $LOKI_BUCKET_NAME")
  else POLICY_STATE="no"; fi
}

show_vars() {
  cat <<EOF
Cluster ........ $CLUSTER_NAME   (cuenta esperada $AWS_ACCOUNT_ID, region $AWS_REGION, perfil $KIT_AWS_PROFILE)
Loki bucket .... $LOKI_BUCKET_NAME
Loki rol IRSA .. $LOKI_ROLE_NAME   (SA $LOKI_SA, politica inline $LOKI_POLICY)
OIDC ........... $OIDC_ISSUER
EOF
}

show_state() {
  echo "Estado actual:"
  echo "  bucket:  $BUCKET_STATE"
  echo "  rol:     $([[ $ROLE_STATE == si ]] && echo existe || echo "no existe")"
  echo "  politica: $([[ $POLICY_STATE == si ]] && echo existe || echo "no existe") ($LOKI_POLICY)"
  local d; for d in "${DIVERGE[@]:-}"; do [[ -z "$d" ]] || wnmsg "DIVERGENCIA (no se modifica): $d"; done
}

# conflictos que impiden un apply seguro
check_conflicts() {
  local bad=0
  if [[ "$BUCKET_STATE" == ajeno ]]; then komsg "el bucket $LOKI_BUCKET_NAME existe pero no es accesible con este perfil (de otra cuenta): elige otro LOKI_BUCKET_NAME"; bad=1; fi
  if [[ $ROLE_STATE == si && $POLICY_STATE == no ]]; then
    komsg "el rol $LOKI_ROLE_NAME existe pero SIN la politica inline $LOKI_POLICY: no se anade (seria modificar un rol existente). Revisalo a mano"; bad=1; fi
  return $bad
}

do_plan() {
  assert_account; read_oidc; show_vars; echo; read_state; show_state; echo
  if check_conflicts; then okmsg "sin conflictos"; fi
  echo; echo "Lo que haria apply (solo CREA; nunca modifica ni borra):"
  if [[ "$BUCKET_STATE" == no ]]; then echo "  + bucket $LOKI_BUCKET_NAME (cifrado AES256, acceso publico bloqueado, etiqueta cluster=$CLUSTER_NAME)"
  else echo "  = bucket $LOKI_BUCKET_NAME ya existe: se ADOPTA tal cual (no se modifica)"; fi
  if [[ $ROLE_STATE == no ]]; then echo "  + rol IAM $LOKI_ROLE_NAME (confianza IRSA para $LOKI_SA) con la politica inline $LOKI_POLICY (Get/Put/DeleteObject y ListBucket solo sobre el bucket)"
  else echo "  = rol $LOKI_ROLE_NAME ya existe: se ADOPTA tal cual (no se modifica)"; fi
  echo; echo "Siguiente: gitops-prereqs.sh apply (si falta algo) y gitops-prereqs.sh info     (plan no ha escrito nada)"
}

tmp_json() {  # tmp_json CONTENIDO -> ruta de un fichero temporal 600 (sin secretos: confianza/politicas)
  local f; f="$(umask 077; mktemp "${TMPDIR:-/tmp}/gitops-prereqs.XXXXXX")"; printf '%s\n' "$1" > "$f"; echo "$f"
}

do_apply() {
  require_tty; assert_account; read_oidc; show_vars; echo; read_state; show_state; echo
  check_conflicts || die "hay conflictos (arriba): nada que aplicar"
  if [[ "$BUCKET_STATE" == si && $ROLE_STATE == si ]]; then
    okmsg "bucket y rol (con su politica) ya existen: nada que crear; se adoptan sin modificarlos"
    do_info_text; return 0
  fi
  echo "Esto CREARA recursos en la cuenta $AWS_ACCOUNT_ID (solo crea; lo existente no se toca):"
  [[ "$BUCKET_STATE" != no ]] || echo "  + bucket $LOKI_BUCKET_NAME"
  [[ $ROLE_STATE == si ]] || echo "  + rol $LOKI_ROLE_NAME con politica inline $LOKI_POLICY"
  confirm_typed "$CLUSTER_NAME" "Escribe el nombre del cluster ($CLUSTER_NAME) para continuar:" || die "confirmacion incorrecta: abortado sin tocar nada"
  local f
  if [[ "$BUCKET_STATE" == no ]]; then
    if [[ "$AWS_REGION" == us-east-1 ]]; then awsw s3api create-bucket --bucket "$LOKI_BUCKET_NAME" >/dev/null
    else awsw s3api create-bucket --bucket "$LOKI_BUCKET_NAME" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null; fi
    awsw s3api put-public-access-block --bucket "$LOKI_BUCKET_NAME" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    f="$(tmp_json '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}')"
    awsw s3api put-bucket-encryption --bucket "$LOKI_BUCKET_NAME" --server-side-encryption-configuration "file://$f"; rm -f "$f"
    awsw s3api put-bucket-tagging --bucket "$LOKI_BUCKET_NAME" --tagging "TagSet=[{Key=cluster,Value=$CLUSTER_NAME},{Key=purpose,Value=loki-gitops}]"
    okmsg "bucket $LOKI_BUCKET_NAME creado"
  fi
  if [[ $ROLE_STATE == no ]]; then
    f="$(tmp_json "$(jq -n --arg a "$OIDC_ARN" --arg iss "$OIDC_ISSUER" --arg sa "$LOKI_SA" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Federated:$a},Action:"sts:AssumeRoleWithWebIdentity",Condition:{StringEquals:{($iss+":sub"):$sa,($iss+":aud"):"sts.amazonaws.com"}}}]}')")"
    awsw iam create-role --role-name "$LOKI_ROLE_NAME" --assume-role-policy-document "file://$f" \
      --tags "Key=cluster,Value=$CLUSTER_NAME" "Key=purpose,Value=loki-gitops" >/dev/null; rm -f "$f"
    f="$(tmp_json "$(jq -n --arg b "$LOKI_BUCKET_NAME" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["s3:GetObject","s3:PutObject","s3:DeleteObject"],Resource:["arn:aws:s3:::"+$b+"/*"]},{Effect:"Allow",Action:["s3:ListBucket"],Resource:["arn:aws:s3:::"+$b]}]}')")"
    awsw iam put-role-policy --role-name "$LOKI_ROLE_NAME" --policy-name "$LOKI_POLICY" --policy-document "file://$f"; rm -f "$f"
    okmsg "rol $LOKI_ROLE_NAME creado con la politica $LOKI_POLICY"
  fi
  read_state
  [[ "$BUCKET_STATE" == si && $ROLE_STATE == si && $POLICY_STATE == si ]] || die "tras apply falta algo (bucket=$BUCKET_STATE rol=$ROLE_STATE politica=$POLICY_STATE)"
  do_info_text
}

do_status() {
  assert_account; read_oidc; show_vars; echo; read_state; show_state
  if [[ "$BUCKET_STATE" == si && $ROLE_STATE == si && $POLICY_STATE == si && ${#DIVERGE[@]} -eq 0 ]]; then okmsg "Loki: bucket, rol y politica presentes"; return 0; fi
  komsg "Loki: falta algo o hay divergencias (gitops-prereqs.sh plan)"; return 1
}

do_info_text() {
  cat <<EOF

Datos para el consumidor GitOps (sin secretos; IRSA no usa claves)
  Bucket ........... $LOKI_BUCKET_NAME     (keos-fleet: components.loki.config.s3.bucketName)
  Region ........... $AWS_REGION     (keos-fleet: components.loki.config.s3.region)
  Rol IRSA ......... arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LOKI_ROLE_NAME}     (el overlay s3-eks lo deduce del nombre loki-<cluster>)
  ServiceAccount ... keos-observability/loki
Override del RSIP (components.loki; flux-keos no deriva aun installationType en EKS, hay que fijarlo):
  components:
    loki:
      enabled: true
      config:
        installationType: s3-eks
        s3:
          bucketName: $LOKI_BUCKET_NAME
          region: $AWS_REGION
    alloy:
      enabled: false
    tempo:
      enabled: false
Recuerda: Loki es de GitOps, no del legacy. alloy y tempo van DESACTIVADOS por defecto en igualdad (sin prerrequisitos); activarlos es una decision aparte.
EOF
}

do_info() {
  assert_account; read_oidc; read_state
  if [[ "$BUCKET_STATE" != si || $ROLE_STATE != si || $POLICY_STATE != si ]]; then
    komsg "faltan recursos de Loki (bucket=$BUCKET_STATE rol=$ROLE_STATE politica=$POLICY_STATE): ejecuta gitops-prereqs.sh plan y apply"; return 1
  fi
  do_info_text
}

case "$CMD" in plan) do_plan ;; apply) do_apply ;; status) do_status ;; info) do_info ;; esac

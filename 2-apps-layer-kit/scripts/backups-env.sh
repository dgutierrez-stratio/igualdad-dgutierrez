#!/usr/bin/env bash
# backups-env.sh - OPCIONAL. Genera ${APPS_LAYER_DIR}/backups.env, el fichero que lee `enviroment-ready --backups` (y, aunque no lo use, exige `--reporter`)
# dentro del contenedor de apps-layer-automation (guia de la PR Stratio/keos-fleet#220, secciones 7.5 y 7.6). NO ejecuta enviroment-ready, ni docker, ni kubectl, ni aws:
# solo escribe el fichero e imprime los pasos opcionales y sus avisos para que los lances tu.
#
# Usage: backups-env.sh [--dry-run] [-h]
#   --dry-run   muestra el contenido que escribiria y no escribe nada
#
# Contenido (4 lineas, SIN comillas y sin comentarios: el script de apps-layer exporta cada valor tal cual y las comillas acabarian dentro del ARN del rol):
#   AWS_ACCOUNT_ID=<cuenta>  AWS_REGION=<region>  AWS_BUCKET_NAME=<VELERO_BUCKET>  AWS_IAM_ROLE_NAME=<VELERO_ROLE>   (+ SC_POSTGRES=<StorageClass> si lo defines)
# Es el bucket y el rol IRSA de VELERO de keos install (cluster.env: VELERO_BUCKET / VELERO_ROLE; defaults ${CLUSTER_NAME}-velero-${AWS_ACCOUNT_ID} y
# ${CLUSTER_NAME}-velero), NO el bucket de backups de ENABLE_BACKUPS_BUCKET (ese es otro: usuario IAM con claves estaticas para la migracion a GitOps). Ningun secreto:
# modo 600 igualmente, en el directorio efimero (700) ${APPS_LAYER_DIR}, con copia .bak si ya existia y era distinto.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
{ set +x; } 2>/dev/null

DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done

load_kit_env
[[ "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "AWS_REGION '$AWS_REGION' no valida"
[[ "$VELERO_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "VELERO_BUCKET '$VELERO_BUCKET' no es un nombre de bucket valido (3-63, minusculas)"
[[ "$VELERO_ROLE" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] || die "VELERO_ROLE '$VELERO_ROLE' no es un nombre de rol IAM valido (es el NOMBRE, no el ARN)"
[[ -z "$SC_POSTGRES" || "$SC_POSTGRES" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "SC_POSTGRES '$SC_POSTGRES' no es un nombre de StorageClass valido"

BODY="$(printf 'AWS_ACCOUNT_ID=%s\nAWS_REGION=%s\nAWS_BUCKET_NAME=%s\nAWS_IAM_ROLE_NAME=%s\n' "$AWS_ACCOUNT_ID" "$AWS_REGION" "$VELERO_BUCKET" "$VELERO_ROLE"
  [[ -z "$SC_POSTGRES" ]] || printf 'SC_POSTGRES=%s\n' "$SC_POSTGRES")"
DEST="$APPS_LAYER_DIR/backups.env"

if [[ "$DRY" == 1 ]]; then
  echo "--dry-run: se escribiria $DEST (modo 600) con:"; printf '%s\n' "$BODY" | sed 's/^/  /'
else
  ensure_private_dir "$APPS_LAYER_DIR"
  tmp="$(umask 077; mktemp "$DEST.XXXXXX")"
  printf '%s\n' "$BODY" > "$tmp"; chmod 600 "$tmp"
  if [[ -f "$DEST" ]] && cmp -s "$tmp" "$DEST"; then
    rm -f "$tmp"; chmod 600 "$DEST"; echo "sin cambios: $DEST"
  else
    if [[ -f "$DEST" ]]; then
      bak="$DEST.bak"; [[ ! -e "$bak" ]] || bak="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
      cp -p "$DEST" "$bak"; chmod 600 "$bak"; echo "copia de seguridad: $bak"
    fi
    mv "$tmp" "$DEST"; chmod 600 "$DEST"; echo "generado: $DEST (modo 600; sin comillas)"
  fi
  printf '%s\n' "$BODY" | sed 's/^/  /'
fi

cat <<EOF

OPCIONAL (paso 14h de la skill). Nada de esto se ha ejecutado; lo lanzas tu, DENTRO del contenedor de apps-layer (launch-apps-layer.sh --run), cuando keos install y las apps ya esten:
  cd /apps-layer && enviroment-ready --backups backups.env
AVISOS antes de lanzarlo:
  - Actua sobre el cluster: 'keos backup create idp vault' (volumenes en keos-backup; con keos.backup.storage_class, o la StorageClass por defecto si no existe), escribe
    override_vars/velero.yaml en el workspace si no existe y RELANZA 'keos backup velero'; para cada PgCluster (postgreskeos, y los del tenant) crea un PVC <pg>-backup-pvc de 40Gi y un
    PgBackup diario a las 01:00 si no existen. Solo lanza un backup puntual de IdP y vault.
  - Para que la BackupStorageLocation 'aws' quede Available con IRSA hace falta el override keos-backup-velero.yaml (credentials.useSecret: false): lo genera render-keos.sh con
    ENABLE_BACKUP_VELERO=true en cluster.env. Sin el, la BSL puede quedar Unavailable. Comprueba despues: kubectl -n keos-backup get bsl aws
  - Para backups diarios de IdP y vault (00:00 y 00:05, 7 dias, sin control-plane): 'keos backup schedule vault idp' desde la shell de keos-installer (paso 13b de la skill).
  - Los valores salen de VELERO_BUCKET/VELERO_ROLE; comprueba que existen: aws s3api head-bucket --bucket $VELERO_BUCKET ; aws iam get-role --role-name $VELERO_ROLE (no se han ejecutado).
REPORTERS (aun mas opcional; guia 7.6): 'enviroment-ready --reporter backups.env' (reutiliza este fichero) crea el namespace keos-reports, la GlobalNetworkPolicy
  allow-all-traffic-from-keos-reports y tres HelmReleases (postgresql-statistics-report, keos-versions-reporter, functional-monitoring). Avisos conocidos de la guia:
  - functional-monitoring: el chart mas alto del ECR helm-15.1 es el 0.3.1 y la imagen stratio/functional-monitoring:0.3.1 puede no estar en tu ECR (ImagePullBackOff); el universo 15.1
    espera la 0.3.2, cuyo chart no esta en el ECR. Hay que subir la imagen a mano desde qa.int.stratio.com/stratio/functional-monitoring:0.3.1 (ECR 717279725338 en la PR).
  - El hook post-install de functional-monitoring (Job functional-monitoring-report) falla con i/o timeout hacia thanos-query.keos-metrics:9090 porque la GlobalNetworkPolicy se crea con un
    selector 'name == keos-reports' y el namespace no lleva esa etiqueta. Parche (desde el host):
      kubectl patch globalnetworkpolicies.crd.projectcalico.org allow-all-traffic-from-keos-reports --type json -p '[{"op":"replace","path":"/spec/ingress/0/source/namespaceSelector","value":"kubernetes.io/metadata.name == '"'"'keos-reports'"'"'"}]'
    Un nuevo 'enviroment-ready --reporter' vuelve a aplicar la plantilla y lo PISA: repite el parche.
EOF

#!/usr/bin/env bash
# render-postinstall.sh — paso 13b (OPCIONAL): imprime por stdout los comandos a ejecutar DENTRO del contenedor keos-installer
# tras `keos install`, según los flags de cluster.env. NO ejecuta nada, no escribe ficheros y no toca secretos. Termina siempre con 0.
#
# Usage: render-postinstall.sh [--dir DIR]
#
# Flags (todos false por defecto): ENABLE_MONITORING, ENABLE_BACKUP_VELERO, ENABLE_BACKUP_SCHEDULE, ENABLE_CENTRAL_LOGGING, ENABLE_FALCO
# (KEOS_ENABLE_CLAMAV no genera comandos: lo despliega `keos install`). Orden de salida: monitoring (+ parche pushgateway PLT-5162),
# backup velero (+ bsl), backup schedule, central-logging, falco. Si no hay ningún flag activo imprime un AVISO con las opciones.
# Entradas opcionales de solo lectura: <dir>/override_vars/<cluster>.yaml (prometheus_pushgateway_enabled),
# <dir>/override_charts_values/keos-backup-velero.yaml (avisa si falta con ENABLE_BACKUP_VELERO=true) y
# <dir>/keos.yaml (con ENABLE_FALCO=true avisa si no lleva el bloque keos.security.falco: hay que re-renderizarlo antes de `keos install`).
# Los flags se leen solo de cluster.env: el entorno heredado de la shell se ignora.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
DIR=""; while [[ $# -gt 0 ]]; do case "$1" in --dir) DIR="$2"; shift 2 ;; -h|--help) sed -n '2,14p' "$0"; exit 0 ;; *) die "opción desconocida: $1" ;; esac; done
DIR="$(resolve_dir "$DIR")"
# Los flags opcionales se leen SOLO de cluster.env: se ignora lo heredado del entorno de la shell (así `ENABLE_FALCO=true render-...` no activa nada
# y la skill siempre pregunta antes de activar un opcional). Se activan con init-cluster.sh --dir D --set ENABLE_X=true.
unset ENABLE_BACKUP_VELERO KEOS_ENABLE_CLAMAV ENABLE_FALCO ENABLE_MONITORING ENABLE_CENTRAL_LOGGING ENABLE_BACKUP_SCHEDULE
load_env "$DIR" CLUSTER_NAME
OVF="$DIR/override_vars/${CLUSTER_NAME}.yaml"; OCV="$DIR/override_charts_values/keos-backup-velero.yaml"

# --- Flags (todos false por defecto) ---
flag() { local v="${!1:-false}"; [[ "$v" == true || "$v" == false ]] || die "$1 debe ser true o false (valor: $v)"; echo "$v"; }
MON="$(flag ENABLE_MONITORING)"; VEL="$(flag ENABLE_BACKUP_VELERO)"; SCH="$(flag ENABLE_BACKUP_SCHEDULE)"
LOG="$(flag ENABLE_CENTRAL_LOGGING)"; FAL="$(flag ENABLE_FALCO)"

# El parche del pushgateway solo aplica si la monitorización incluye pushgateway: override_vars (renderizado) lo activa con
# prometheus_pushgateway_enabled: true; la plantilla lo lleva a true siempre, así que sin fichero se asume true.
PG=true
if [[ -f "$OVF" ]] && ! grep -Eq '^prometheus_pushgateway_enabled:[[:space:]]*true' "$OVF"; then PG=false; fi

if [[ "$MON$VEL$SCH$LOG$FAL" != *true* ]]; then
  cat <<'EOF'
# AVISO: ningún bloque opcional post-install está activado: tras `keos install` NO se desplegará monitorización, Velero, backups programados,
# central logging ni falco (el clúster del cliente sí los tiene). Opciones disponibles (todas false por defecto, en cluster.env):
#   ENABLE_MONITORING=true       keos monitoring (+ parche PLT-5162 del pushgateway)
#   ENABLE_BACKUP_VELERO=true    keos backup velero (+ keos.backup.storage_class, velero_enable_snapshot_volumes y keos-backup-velero.yaml)
#   ENABLE_BACKUP_SCHEDULE=true  keos backup schedule vault idp (requiere Velero)
#   ENABLE_CENTRAL_LOGGING=true  keos central-logging (fluentd + OpenSearch)
#   ENABLE_FALCO=true            falco con salida a OpenSearch (requiere central logging)
#   KEOS_ENABLE_CLAMAV=true      ClamAV (lo despliega `keos install`; no genera comandos aquí)
# Cómo activarlas: `export ENABLE_X=true` en cluster.env (o init-cluster.sh --dir <dir> --set ENABLE_X=true). ENABLE_BACKUP_VELERO,
# ENABLE_FALCO y KEOS_ENABLE_CLAMAV cambian keos.yaml/override_vars: decídelo ANTES de `keos install` y vuelve a ejecutar render-keos.sh.
# Después, vuelve a ejecutar este script para obtener los comandos.
EOF
  exit 0
fi

echo "# === Paso 13b: post-install de keos (OPCIONAL) — clúster $CLUSTER_NAME ==="
echo "# Ejecutar DENTRO del contenedor keos-installer (la shell que se abre al arrancarlo), DESPUÉS de \`keos install\`, en este orden."
echo "# Este script solo imprime: no ejecuta nada. Bloques activados por cluster.env."

if [[ "$MON" == true ]]; then
  cat <<'EOF'

# --- keos monitoring: Prometheus, Alertmanager, Grafana y Thanos query + exporters activados en override_vars ---
keos monitoring
EOF
  if [[ "$PG" == true ]]; then
    cat <<'EOF'

# Parche PLT-5162: tras `keos monitoring` la HelmRelease pushgateway de keos-metrics queda con "ValuesError ... yaml: line 119"
# (liveness/readiness con dos espacios de más en el ConfigMap; un override no lo evita). Se corrige el ConfigMap y el helm-controller
# reintenta solo. SE PIERDE si se vuelve a lanzar `keos monitoring`: repetir este parche.
CM=00-pushgateway-helm-chart-default-values
kubectl -n keos-metrics get cm $CM -o jsonpath='{.data.values\.yaml}' \
  | sed -E '/^(liveness|readiness):/,/^$/ s/^    /  /' \
  | jq -Rs '{data: {"values.yaml": .}}' \
  | kubectl -n keos-metrics patch cm $CM --type merge --patch-file /dev/stdin
kubectl -n keos-metrics get hr pushgateway   # Ready True
EOF
  else
    echo
    echo "# (parche PLT-5162 omitido: prometheus_pushgateway_enabled no está activo en $OVF)"
  fi
fi

if [[ "$VEL" == true ]]; then
  [[ -f "$OCV" ]] || echo "
# AVISO: falta $OCV: ejecuta render-keos.sh con ENABLE_BACKUP_VELERO=true antes (sin él la BackupStorageLocation queda Unavailable con IRSA)"
  cat <<'EOF'

# --- Velero con el bucket y el rol IRSA de override_vars (variables velero_*) ---
keos backup velero
kubectl -n keos-backup get bsl aws   # debe estar Available
EOF
fi

if [[ "$SCH" == true ]]; then
  [[ "$VEL" == true ]] || echo "
# AVISO: los backups programados necesitan Velero: activa ENABLE_BACKUP_VELERO o ejecuta antes \`keos backup velero\`"
  cat <<'EOF'

# --- Backups programados de IdP (00:00) y vault (00:05), 7 días de retención, sin control-plane (no aplica en EKS) ---
keos backup schedule vault idp
EOF
fi

if [[ "$LOG" == true ]]; then
  cat <<'EOF'

# --- Central logging (keos-logs: fluentd y OpenSearch) ---
keos central-logging
EOF
fi

if [[ "$FAL" == true ]]; then
  if [[ -f "$DIR/keos.yaml" ]] && ! grep -q '^    falco:' "$DIR/keos.yaml"; then echo "
# AVISO: $DIR/keos.yaml NO contiene el bloque keos.security.falco: re-renderiza keos.yaml con ENABLE_FALCO=true (render-keos.sh) ANTES de \`keos install\`;
# si no, el sed de activación de más abajo no hará nada y \`keos falco\` fallará"; fi
  [[ "$LOG" == true ]] || echo "
# AVISO: falco envía a OpenSearch (security.falco.opensearch_output): necesita central logging (ENABLE_CENTRAL_LOGGING o \`keos central-logging\` ya lanzado)"
  cat <<'EOF'

# --- Falco con salida a OpenSearch. keos.yaml se instaló con falco.enabled: false (el precheck de `keos install` falla con true);
# `keos falco` exige true en keos.yaml Y que coincida con el CR keos de keos-ops, así que se cambia en los dos sitios ---
sed -i '/^    falco:/,/enabled:/ s/enabled: false.*/enabled: true/' /workspace/keos.yaml
kubectl -n keos-ops patch keos keos --type merge -p '{"spec":{"keos":{"security":{"falco":{"enabled":true}}}}}'
keos falco
EOF
fi
exit 0

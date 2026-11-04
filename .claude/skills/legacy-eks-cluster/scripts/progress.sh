#!/usr/bin/env bash
# progress.sh — lista markdown de progreso de la instalación (una línea por paso, con casilla), para pegarla en la respuesta tras cada paso.
# Solo escribe <dir>/.work/progress (estado de cada paso, sin secretos); no toca AWS ni el clúster.
#
# Usage: progress.sh [--dir DIR] [show | doing ID | done ID | fail ID | skip ID | reset]
#   show (defecto)  imprime la lista con el estado actual
#   doing ID        marca el paso como EN CURSO (👉)         done ID   lo marca hecho ([x])
#   fail ID         lo marca como fallido (❌)                skip ID   lo marca omitido (solo pasos opcionales: 13b, 14h)
#   reset           vuelve todo a pendiente
# IDs: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 13b 14 14f 14g 14h  (13b y 14h son opcionales). Cada subcomando que cambia el estado imprime después la lista.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Paso (ID) y nombre corto en lenguaje llano. "lo lanzas tú" = lo ejecuta la persona usuaria; "opcional" = no obligatorio.
STEPS=(
  "0|Preparar y comprobar herramientas y cuenta"
  "1|Usuario IAM de cloud-provisioner"
  "2|Política y acceso al ECR"
  "3|Red (VPC y subredes)"
  "4|Descriptor del clúster (cluster.yaml)"
  "5|Crear el clúster EKS (lo lanzas tú, ~30 min)"
  "6|Comprobar que el clúster está sano"
  "7|Variables derivadas del clúster"
  "8|DNS (zonas Route53)"
  "9|Permisos de external-dns"
  "10|Velero (bucket y permisos)"
  "11|Almacenamiento compartido (EFS)"
  "12|Configurar keos (keos.yaml y overrides)"
  "13|Instalar keos (lo lanzas tú)"
  "13b|Opciones tras keos install (opcional)"
  "14|Preparar apps-layer (S3, universo, render, check)"
  "14f|Instalar las apps (lo lanzas tú)"
  "14g|Comprobar las apps"
  "14h|Backups y reporters de las apps (opcional)"
)
OPTIONAL=" 13b 14h "

DIR=""; CMD="show"; ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    show|reset) CMD="$1"; shift ;;
    doing|done|fail|skip) CMD="$1"; ID="${2:-}"; [[ -n "$ID" ]] || die "$1 necesita un ID de paso"; shift 2 ;;
    *) die "opción desconocida: $1" ;;
  esac
done
DIR="$(resolve_dir "$DIR")"
load_env "$DIR" CLUSTER_NAME
STATE="$DIR/.work/progress"

valid_id() { local s; for s in "${STEPS[@]}"; do [[ "${s%%|*}" == "$1" ]] && return 0; done; return 1; }
state_of() {  # state_of ID -> pending|doing|done|fail|skip
  local v=""; [[ -f "$STATE" ]] && v="$(awk -v id="$1" '$1==id {v=$2} END{print v}' "$STATE")"
  echo "${v:-pending}"
}
set_state() {  # set_state ID ESTADO (reescribe el fichero sin la entrada previa del ID)
  mkdir -p "$DIR/.work"
  { [[ -f "$STATE" ]] && awk -v id="$1" '$1!=id' "$STATE"; echo "$1 $2"; } > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"
}

case "$CMD" in
  reset) rm -f "$STATE" ;;
  doing|done|fail|skip)
    valid_id "$ID" || die "ID de paso desconocido: $ID (válidos: $(printf '%s ' "${STEPS[@]%%|*}"))"
    [[ "$CMD" != skip || "$OPTIONAL" == *" $ID "* ]] || die "solo se pueden omitir los pasos opcionales (13b, 14h), no el $ID"
    set_state "$ID" "$CMD" ;;
esac

total=0; hechos=0; actual=""; siguiente=""
echo "## Progreso de la instalación · ${CLUSTER_NAME}${AWS_ACCOUNT_ID:+ (cuenta $AWS_ACCOUNT_ID)}"
echo
for s in "${STEPS[@]}"; do
  id="${s%%|*}"; name="${s#*|}"; st="$(state_of "$id")"
  [[ "$OPTIONAL" == *" $id "* ]] || total=$((total+1))
  case "$st" in
    done)  echo "- [x] $id · $name"; [[ "$OPTIONAL" == *" $id "* ]] || hechos=$((hechos+1)) ;;
    skip)  echo "- [x] $id · $name — omitido" ;;
    doing) echo "- [ ] 👉 $id · $name — en curso"; [[ -n "$actual" ]] || actual="$id · $name" ;;
    fail)  echo "- [ ] ❌ $id · $name — falló, hay que revisarlo"; [[ -n "$actual" ]] || actual="$id · $name (falló)" ;;
    *)     echo "- [ ] $id · $name"; [[ -n "$siguiente" || "$OPTIONAL" == *" $id "* ]] || siguiente="$id · $name" ;;
  esac
done
echo
if [[ -n "$actual" ]]; then echo "**$hechos de $total pasos hechos** · Ahora: $actual"
elif [[ -n "$siguiente" ]]; then echo "**$hechos de $total pasos hechos** · Siguiente: $siguiente"
else echo "**$hechos de $total pasos hechos** · Instalación completa"; fi

#!/usr/bin/env bash
# fetch-universe.sh - descarga SIEMPRE fresco el zip del universo de descriptores Y universe-images.lst a ${APPS_LAYER_DIR}
# (para montarlos en el contenedor apps-layer encima de los embebidos en la imagen). launch-apps-layer.sh lo invoca antes de cada lanzamiento.
#
# Usage: fetch-universe.sh [-h]
#   URL:    http://qa.int.stratio.com/repository/paas/kubernetes-universe/descriptors/kubernetes-universe-descriptors-${UNIVERSE_VERSION}.zip
#           (override: UNIVERSE_ZIP_URL). Requiere VPN/acceso a qa.int.stratio.com.
#   Destino: ${APPS_LAYER_DIR}/kubernetes-universe-descriptors-${UNIVERSE_VERSION}.zip
#   lst:    `gh api -H 'Accept: application/vnd.github.raw' repos/Stratio/kubernetes-universe/contents/universe-images.lst?ref=${UNIVERSE_BRANCH}`
#           (UNIVERSE_BRANCH por defecto branch-<major>.<minor> de UNIVERSE_VERSION, p. ej. branch-15.1). Exige `gh` autenticado con
#           acceso a Stratio/kubernetes-universe (si no, para con un mensaje claro). Destino: ${APPS_LAYER_DIR}/${UNIVERSE_VERSION}-universe-images.lst
#           Motivo: connectors-management y intelligence leen de ahi las versiones de connectors-loader y analytic-environment.
# Descarga con curl -fSL a un temporal del mismo directorio, valida (tamano > 0 y `unzip -t`) y lo mueve de forma atomica.
# El lst se valida no vacio y con connectors-loader; mv atomico. No reutiliza nunca una copia previa: si la descarga o la validacion fallan, aborta (la copia anterior no se usa).
# Imprime tamano y sha256 (no son secretos). El directorio debe ser privado (700, del usuario actual).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

case "${1:-}" in -h|--help) sed -n '2,17p' "$0"; exit 0 ;; "") ;; *) die "opcion desconocida: $1" ;; esac
load_kit_env
fetch_universe_assets

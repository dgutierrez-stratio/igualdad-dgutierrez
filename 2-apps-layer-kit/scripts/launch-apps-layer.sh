#!/usr/bin/env bash
# launch-apps-layer.sh - construye el comando `docker run` del contenedor apps-layer-automation.
#
# Usage: launch-apps-layer.sh [--run] [--force] [--skip-fetch] [-h]
#   (sin opciones)  DESCARGA SIEMPRE fresco el zip del universo y universe-images.lst (fetch-universe.sh; exige gh autenticado) e IMPRIME el comando por stdout (los
#                   avisos van por stderr); no ejecuta docker.
#   --skip-fetch    no descarga: exige que ${APPS_LAYER_DIR}/kubernetes-universe-descriptors-${UNIVERSE_VERSION}.zip (valido, unzip -t) y
#                   ${UNIVERSE_VERSION}-universe-images.lst (con connectors-loader) existan; avisa si tiene mas de 24 h. Solo para cuando acabas de descargarlo a mano.
#   --run           ejecuta el comando (docker run interactivo). Aborta si ya hay un contenedor apps-layer
#                   en marcha o uno con el mismo nombre (el entrypoint hace `docker rm -f keos-installer_<cluster>`,
#                   lo que rompe el apps-installer de ese otro contenedor), salvo --force.
#
# Resuelve la IP del NLB de ingress para --add-host admin.<EXTERNAL_DOMAIN> (el dominio no resuelve desde la
# estacion). Se puede fijar con NLB_IP; si no se resuelve se omite --add-host y se avisa.
# Monta: APPS_LAYER_DIR -> /apps-layer, KEOS_WORKSPACE_DIR -> /workspace (y tambien en su misma ruta del host), docker.sock, APPS_LAYER_DIR/aws -> /root/.aws (ro) y el
# zip del universo descargado -> /apps-layer-automation/universe/kubernetes-universe-descriptors-<version>.zip y universe-images.lst
# (gh api, rama branch-<major>.<minor>) -> /apps-layer-automation/universe/<version>-universe-images.lst:ro, ambos sobre los de la imagen.
# Imagen: APPS_LAYER_IMAGE; con APPS_LAYER_IMAGE_DIGEST=sha256:... se fija por digest (repo:tag@sha256:...).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RUN=0; FORCE=0; SKIP_FETCH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --skip-fetch) SKIP_FETCH=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "opcion desconocida: $1" ;;
  esac
done

load_kit_env
NAME="apps-layer-${CLUSTER_NAME}"
ROOT_YAML="$(root_yaml_name)"; TENANT_YAML="$(tenant_yaml_name)"

# imagen (opcionalmente fijada por digest)
IMAGE="$APPS_LAYER_IMAGE"
if [[ -n "$APPS_LAYER_IMAGE_DIGEST" ]]; then
  [[ "$APPS_LAYER_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "APPS_LAYER_IMAGE_DIGEST debe tener la forma sha256:<64 hex>"
  IMAGE="${APPS_LAYER_IMAGE%@*}@${APPS_LAYER_IMAGE_DIGEST}"
fi

# --- comprobaciones previas (avisos; solo --run las convierte en error) -------------------------------------
problems=()
if [[ -d "$APPS_LAYER_DIR" ]]; then
  why="$(verify_private_dir "$APPS_LAYER_DIR")" || problems+=("directorio de ejecucion no seguro: $why")
else
  problems+=("no existe $APPS_LAYER_DIR (efimero: ejecuta scripts/render-apps-layer.sh para regenerarlo)")
fi
for f in .env kube-config "$ROOT_YAML" "$TENANT_YAML"; do
  [[ -f "$APPS_LAYER_DIR/$f" ]] || problems+=("falta $APPS_LAYER_DIR/$f")
done
[[ -d "$APPS_LAYER_DIR/aws" ]] || problems+=("falta $APPS_LAYER_DIR/aws (se monta como /root/.aws para 'aws eks get-token'; docker lo crearia como root)")
[[ -d "$KEOS_WORKSPACE_DIR" ]] || problems+=("no existe KEOS_WORKSPACE_DIR=$KEOS_WORKSPACE_DIR")
for p in "${problems[@]}"; do warn "$p"; done
if [[ "$RUN" == 1 && ${#problems[@]} -gt 0 ]]; then die "no se lanza: resuelve los avisos anteriores"; fi

# --- zip del universo: SIEMPRE fresco (nunca se reutiliza una copia previa) -------------------------------------
ZIP_NAME="$(universe_zip_name)"; ZIP="$APPS_LAYER_DIR/$ZIP_NAME"
LST_NAME="$(universe_lst_name)"; LST="$APPS_LAYER_DIR/$LST_NAME"
if [[ -d "$APPS_LAYER_DIR" ]] && verify_private_dir "$APPS_LAYER_DIR" >/dev/null; then
  if [[ "$SKIP_FETCH" == 1 ]]; then
    why="$(validate_universe_zip "$ZIP")" || die "--skip-fetch: zip del universo no utilizable: $why (ejecuta scripts/fetch-universe.sh)"
    why="$(validate_universe_lst "$LST")" || die "--skip-fetch: universe-images.lst no utilizable: $why (ejecuta scripts/fetch-universe.sh)"
    for f in "$ZIP" "$LST"; do
      if [[ -n "$(find "$f" -mmin +1440 2>/dev/null)" ]]; then warn "$(basename "$f") tiene mas de 24 h: no es fresco. Quita --skip-fetch o ejecuta scripts/fetch-universe.sh"; fi
    done
    info "universo (sin refrescar, --skip-fetch): $ZIP ($(stat -c %s "$ZIP") bytes, sha256 $(sha256sum "$ZIP" | cut -d' ' -f1)); $LST"
  else
    fetch_universe_assets >&2
  fi
else
  warn "no se descargan el zip del universo ni universe-images.lst: $APPS_LAYER_DIR no existe o no es seguro (arriba). Se descargara al relanzar launch."
fi

# --- IP del NLB para --add-host -----------------------------------------------------------------------------
HOST_FQDN="admin.${EXTERNAL_DOMAIN}"
NLB_IP_RESOLVED="$NLB_IP"
if [[ -z "$NLB_IP_RESOLVED" ]]; then
  KC=""
  for c in "$KUBECONFIG_SRC" "$APPS_LAYER_DIR/kube-config"; do [[ -f "$c" ]] && { KC="$c"; break; }; done
  if [[ -n "$KC" ]] && command -v kubectl >/dev/null 2>&1; then
    nlb_host="$(AWS_PROFILE="$KIT_AWS_PROFILE" AWS_PAGER="" kubectl --kubeconfig "$KC" -n "$NLB_NAMESPACE" get svc "$NLB_SERVICE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "$nlb_host" ]]; then
      if [[ "$nlb_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then NLB_IP_RESOLVED="$nlb_host"
      else NLB_IP_RESOLVED="$(getent hosts "$nlb_host" 2>/dev/null | awk 'NR==1{print $1}' || true)"; fi
    fi
  fi
fi
ARGS=(docker run -it --rm --name "$NAME"
  -v "$APPS_LAYER_DIR:/apps-layer"
  -v "$KEOS_WORKSPACE_DIR:/workspace"
  -v /var/run/docker.sock:/var/run/docker.sock
  -v "$APPS_LAYER_DIR/aws:/root/.aws:ro"
  -v "$ZIP:$UNIVERSE_ZIP_MOUNT_DIR/$ZIP_NAME"
  -v "$LST:$UNIVERSE_ZIP_MOUNT_DIR/$LST_NAME:ro")
# Desde apps-layer-automation 15.1-0.1.0-M1/M2 (ffecfe8f), enviroment-ready (--reporter) crea directorios temporales en ${KEOS_WORKSPACE_DIR} vistos desde DENTRO del
# contenedor y los traduce a /workspace para keos-installer: el workspace debe estar tambien montado en su misma ruta del host (quickstart upstream, sin DinD).
# Sin esto el mktemp falla. Con imagenes anteriores no hace nada. (Si KEOS_WORKSPACE_DIR fuese /workspace, el montaje ya existe y no se duplica.)
[[ "$KEOS_WORKSPACE_DIR" == /workspace ]] || ARGS+=(-v "$KEOS_WORKSPACE_DIR:$KEOS_WORKSPACE_DIR")
if [[ -n "$NLB_IP_RESOLVED" ]]; then
  [[ "$NLB_IP_RESOLVED" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "IP de NLB no valida: $NLB_IP_RESOLVED"
  ARGS+=(--add-host "${HOST_FQDN}:${NLB_IP_RESOLVED}")
else
  warn "no se pudo resolver la IP del NLB ($NLB_NAMESPACE/$NLB_SERVICE): se omite --add-host. Fija NLB_IP=<ip> o anadelo a mano: --add-host ${HOST_FQDN}:<ip>"
  [[ "$RUN" == 0 ]] || die "con --run hace falta resolver el NLB (o NLB_IP): el acceso a ${HOST_FQDN} falla si no resuelve por DNS"
fi
ARGS+=(--net host --cgroupns host "$IMAGE")

# --- salida ------------------------------------------------------------------------------------------------
print_cmd() {  # una opcion con su valor por linea: -v X, --name X, --add-host X, --net host ...
  local i=2 n=${#ARGS[@]} a
  printf 'docker run'
  while ((i < n)); do
    a="${ARGS[i]}"
    case "$a" in
      -v|--name|--add-host|--net|--cgroupns) printf ' \\\n  %s %q' "$a" "${ARGS[i+1]}"; i=$((i + 2)) ;;
      -it|--rm) printf ' %s' "$a"; i=$((i + 1)) ;;
      *) printf ' \\\n  %q' "$a"; i=$((i + 1)) ;;
    esac
  done
  printf '\n'
}

if [[ "$RUN" == 0 ]]; then
  print_cmd
  cat >&2 <<EOF

# Dentro del contenedor (prompt [apps-layer:15.1 ...] /apps-layer#):
#   source /apps-layer/.env && cd /apps-layer
#   apps-installer ${ROOT_YAML}          # tenant keos
#   apps-installer ${TENANT_YAML}   # tenant ${TENANT_NAME}  (antes: scripts/check-apps-layer.sh)
# El zip del universo ${UNIVERSE_VERSION} y universe-images.lst se han descargado ahora y se montan sobre los de la imagen. Si el contenedor ya esta
# arrancado, no se refresca solo: hay que relanzarlo (y recuerda que su entrypoint recrea keos-installer_${CLUSTER_NAME}).
# Si ya tienes un contenedor apps-layer arrancado, no lances otro: haz  source /apps-layer/.env  en el existente.
EOF
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "no se encuentra docker"
if [[ "$FORCE" == 0 ]]; then
  running="$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /apps-layer-automation/ {print $1}' | tr '\n' ' ' || true)"
  [[ -z "${running// /}" ]] || die "ya hay contenedores apps-layer en marcha: ${running}. Usa ese (source /apps-layer/.env) o --force (el entrypoint borrara keos-installer_${CLUSTER_NAME})."
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then die "ya existe el contenedor $NAME: docker rm $NAME o --force"; fi
fi
if [[ "$FORCE" == 1 ]] && docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then docker rm -f "$NAME" >/dev/null; fi
exec "${ARGS[@]}"

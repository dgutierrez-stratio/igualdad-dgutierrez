#!/usr/bin/env bash
# derive-cluster-vars.sh — paso 7: variables derivadas del EKS ya creado (SOLO LECTURA).
# Usage: derive-cluster-vars.sh [--dir DIR]      Imprime líneas `export VAR=valor` (evaluables con: eval "$(...)").
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
DIR=""; while [[ $# -gt 0 ]]; do case "$1" in --dir) DIR="$2"; shift 2 ;; *) die "opción desconocida: $1" ;; esac; done
DIR="$(resolve_dir "$DIR")"; need_tools aws jq
load_env "$DIR" CLUSTER_NAME AWS_ACCOUNT_ID AWS_REGION CP_PROFILE EXTERNAL_DOMAIN
set_aws "$CP_PROFILE" "$AWS_REGION"; assert_account "$AWS_ACCOUNT_ID"
derive_vars
for v in VPC_ID SUBNET_IDS CLUSTER_SG OIDC_ISSUER PUBLIC_ZONE_ID PRIVATE_ZONE_ID; do printf 'export %s=%q\n' "$v" "${!v}"; done
if [[ -f "$DIR/${CLUSTER_NAME}.json" ]]; then
  want="$(jq -r .vpc_id "$DIR/${CLUSTER_NAME}.json")"
  [[ "$want" == "$VPC_ID" ]] && echo "# ok: la VPC del EKS coincide con ${CLUSTER_NAME}.json" >&2 || echo "# KO: la VPC del EKS ($VPC_ID) NO coincide con ${CLUSTER_NAME}.json ($want)" >&2
fi
echo "# nodegroups: $(awsx eks list-nodegroups --cluster-name "$CLUSTER_NAME" --output json | jq -r '.nodegroups|join(" ")')" >&2

#!/usr/bin/env bash
# create-test-vpc.sh — create a generic test VPC with public/private (+ optional pods/secondary-CIDR) subnets across N AZs
#
# Usage (flags):
#   1-aws-cluster/create-test-vpc.sh --name NAME [--azs N] [--region REGION] [--profile PROFILE] \
#       [--vpc-cidr CIDR] [--pods-cidr CIDR] [--nat-mode per-az|single|none] [--output FILE | --no-output]
#
# Usage (interactive menu, no flags):
#   1-aws-cluster/create-test-vpc.sh
#
# Output: by default the JSON summary is written to <this dir>/estado/NAME.json (the file that
# render-cluster.sh reads; override the directory with STATE_DIR=...). Use --output FILE to choose
# another path or --no-output to skip it.
#
# Layout per AZ: 1 public subnet (kubernetes.io/role/elb=1) + 1 private subnet
# (kubernetes.io/role/internal-elb=1). If --pods-cidr is set, adds 1 extra "pods"
# subnet per AZ carved from that secondary CIDR, tagged
# sigs.k8s.io/cluster-api-provider-aws/association=secondary (consumed by Skind's
# ENIConfig custom-networking logic, see cluster-operator PLT-4509/PLT-4511).
#
# NAT modes:
#   per-az  — one NAT Gateway per AZ (HA, ~3x cost)          [default]
#   single  — one NAT Gateway in the first AZ, shared by all private/pods route tables
#   none    — no NAT Gateways; private/pods subnets get no default route (fully isolated)
#
# Defaults: --profile from $AWS_PROFILE (required if unset), --region from $AWS_REGION /
# $AWS_DEFAULT_REGION (falls back to eu-west-1). Aborts if a VPC with Name=NAME already exists.
#
# Prints a summary at the end and, with --output, dumps a JSON map of
# {vpc_id, azs: [{az, public_subnet, private_subnet, pods_subnet, nat_gateway}]}
# ready to be spliced into a cluster descriptor.

set -euo pipefail

NAME=""
AZ_COUNT=3
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
PROFILE="${AWS_PROFILE:-}"
VPC_CIDR="10.0.0.0/16"
PODS_CIDR=""
NAT_MODE="per-az"
OUTPUT_FILE=""
NO_OUTPUT=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/estado}"
ALL_AZS=(a b c d e f)

usage() {
  cat <<EOF
Usage: $0 --name NAME [options]

  --name NAME           Base name for all resources (required; used as tag Name=NAME, Name=NAME-public-N, ...)
  --azs N               Number of AZs (default: 3)
  --region REGION       AWS region (default: \$AWS_REGION, \$AWS_DEFAULT_REGION or eu-west-1)
  --profile PROFILE     AWS CLI profile (default: \$AWS_PROFILE; required if unset)
  --vpc-cidr CIDR       Primary VPC CIDR (default: 10.0.0.0/16)
  --pods-cidr CIDR      Secondary CIDR for custom-networking pod subnets (optional, e.g. 100.64.0.0/16)
  --nat-mode MODE       per-az | single | none (default: per-az)
  --output FILE         Write a JSON summary of created resources to FILE (default: estado/NAME.json next to this script)
  --no-output           Do not write the JSON summary
  -h, --help            Show this help

No flags: launches an interactive menu asking for each value.
EOF
}

if [[ $# -eq 0 ]]; then
  read -rp "Name (base, e.g. my-cluster-vpc): " NAME
  read -rp "Number of AZs [3]: " _azs; AZ_COUNT="${_azs:-3}"
  read -rp "Region [$REGION]: " _region; REGION="${_region:-$REGION}"
  read -rp "AWS profile [${PROFILE:-none}]: " _profile; PROFILE="${_profile:-$PROFILE}"
  read -rp "VPC CIDR [10.0.0.0/16]: " _vc; VPC_CIDR="${_vc:-10.0.0.0/16}"
  read -rp "Pods/secondary CIDR (blank = no pods subnets): " PODS_CIDR
  read -rp "NAT mode: per-az | single | none [per-az]: " _nat; NAT_MODE="${_nat:-per-az}"
  read -rp "Output JSON file (blank = $STATE_DIR/<name>.json): " OUTPUT_FILE
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)       NAME="$2"; shift 2 ;;
      --azs)        AZ_COUNT="$2"; shift 2 ;;
      --region)     REGION="$2"; shift 2 ;;
      --profile)    PROFILE="$2"; shift 2 ;;
      --vpc-cidr)   VPC_CIDR="$2"; shift 2 ;;
      --pods-cidr)  PODS_CIDR="$2"; shift 2 ;;
      --nat-mode)   NAT_MODE="$2"; shift 2 ;;
      --output)     OUTPUT_FILE="$2"; shift 2 ;;
      --no-output)  NO_OUTPUT=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
fi

[[ -z "$NAME" ]] && { echo "ERROR: --name is required"; usage; exit 1; }
[[ -z "$PROFILE" ]] && { echo "ERROR: no AWS profile: pass --profile or export AWS_PROFILE"; usage; exit 1; }
[[ "$NAT_MODE" =~ ^(per-az|single|none)$ ]] || { echo "ERROR: --nat-mode must be per-az|single|none"; exit 1; }
[[ "$AZ_COUNT" -ge 1 && "$AZ_COUNT" -le 6 ]] || { echo "ERROR: --azs must be between 1 and 6"; exit 1; }

if [[ "$NO_OUTPUT" -eq 0 && -z "$OUTPUT_FILE" ]]; then OUTPUT_FILE="$STATE_DIR/${NAME}.json"; fi
if [[ -n "$OUTPUT_FILE" ]]; then mkdir -p "$(dirname "$OUTPUT_FILE")"; fi

# AWS_PAGER="" instead of --no-cli-pager: the flag does not exist in AWS CLI v1 (which may come first in PATH under bash)
aws() { AWS_PAGER="" command aws --profile "$PROFILE" --region "$REGION" "$@"; }

EXISTING_VPCS=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}" --query 'Vpcs[].VpcId' --output text)
[[ -z "$EXISTING_VPCS" ]] || { echo "ERROR: a VPC named '$NAME' already exists in $REGION ($EXISTING_VPCS); pick another --name or delete it first"; exit 1; }

echo "=== create-test-vpc: name=$NAME azs=$AZ_COUNT region=$REGION profile=$PROFILE vpc_cidr=$VPC_CIDR pods_cidr=${PODS_CIDR:-<none>} nat_mode=$NAT_MODE ==="

echo "== VPC =="
VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}}]" \
  --query 'Vpc.VpcId' --output text)
echo "VPC_ID=$VPC_ID"

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

if [[ -n "$PODS_CIDR" ]]; then
  echo "== Secondary CIDR (pods): $PODS_CIDR =="
  aws ec2 associate-vpc-cidr-block --vpc-id "$VPC_ID" --cidr-block "$PODS_CIDR" >/dev/null
  for i in $(seq 1 30); do
    STATE=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
      --query "Vpcs[0].CidrBlockAssociationSet[?CidrBlock==\`${PODS_CIDR}\`].CidrBlockState.State" --output text)
    [[ "$STATE" == "associated" ]] && break
    sleep 2
  done
  echo "secondary CIDR state=$STATE"
fi

echo "== IGW =="
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME}}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "IGW_ID=$IGW_ID"

# Derive /24 public+private CIDRs from the VPC's second octet-aligned space, and
# /18 pods CIDRs from PODS_CIDR, purely by index — assumes VPC_CIDR is a /16 and
# PODS_CIDR (if set) is a /16. For non-default CIDRs, edit the subnet math below.
VPC_BASE=$(echo "$VPC_CIDR" | cut -d. -f1-2)
PODS_BASE=$(echo "${PODS_CIDR:-0.0.0.0/16}" | cut -d. -f1-2)

declare -a AZ PUB_ID PRIV_ID PODS_ID EIP_ID NAT_ID PRIV_RT_ID
SHARED_NAT_ID=""

echo "== Subnets =="
for idx in $(seq 0 $((AZ_COUNT - 1))); do
  n=$((idx + 1))
  AZ[$idx]="${REGION}${ALL_AZS[$idx]}"
  pub_cidr="${VPC_BASE}.$((idx*2 + 2)).0/24"
  priv_cidr="${VPC_BASE}.$((idx*2 + 1)).0/24"

  PUB_ID[$idx]=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$pub_cidr" \
    --availability-zone "${AZ[$idx]}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-public-${n}},{Key=kubernetes.io/role/elb,Value=1}]" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 modify-subnet-attribute --subnet-id "${PUB_ID[$idx]}" --map-public-ip-on-launch

  PRIV_ID[$idx]=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$priv_cidr" \
    --availability-zone "${AZ[$idx]}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-private-${n}},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
    --query 'Subnet.SubnetId' --output text)

  if [[ -n "$PODS_CIDR" ]]; then
    pods_cidr="${PODS_BASE}.$((idx*64)).0/18"
    PODS_ID[$idx]=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$pods_cidr" \
      --availability-zone "${AZ[$idx]}" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-pods-${n}},{Key=sigs.k8s.io/cluster-api-provider-aws/association,Value=secondary}]" \
      --query 'Subnet.SubnetId' --output text)
  fi

  echo "AZ ${AZ[$idx]}: public=${PUB_ID[$idx]} private=${PRIV_ID[$idx]} pods=${PODS_ID[$idx]:-<none>}"
done

echo "== Public route table =="
PUB_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-public}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PUB_RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
for idx in $(seq 0 $((AZ_COUNT - 1))); do
  aws ec2 associate-route-table --route-table-id "$PUB_RT_ID" --subnet-id "${PUB_ID[$idx]}" >/dev/null
done
echo "PUB_RT_ID=$PUB_RT_ID"

if [[ "$NAT_MODE" != "none" ]]; then
  echo "== NAT Gateway(s), mode=$NAT_MODE =="
  if [[ "$NAT_MODE" == "single" ]]; then
    EIP_ID[0]=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}-nat}]" \
      --query 'AllocationId' --output text)
    SHARED_NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "${PUB_ID[0]}" --allocation-id "${EIP_ID[0]}" \
      --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME}-nat}]" \
      --query 'NatGateway.NatGatewayId' --output text)
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$SHARED_NAT_ID"
    echo "Shared NAT=$SHARED_NAT_ID available"
  else
    for idx in $(seq 0 $((AZ_COUNT - 1))); do
      n=$((idx + 1))
      EIP_ID[$idx]=$(aws ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}-nat-${n}}]" \
        --query 'AllocationId' --output text)
      NAT_ID[$idx]=$(aws ec2 create-nat-gateway --subnet-id "${PUB_ID[$idx]}" --allocation-id "${EIP_ID[$idx]}" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAME}-nat-${n}}]" \
        --query 'NatGateway.NatGatewayId' --output text)
      echo "AZ ${AZ[$idx]}: EIP=${EIP_ID[$idx]} NAT=${NAT_ID[$idx]} (provisioning...)"
    done
    for idx in $(seq 0 $((AZ_COUNT - 1))); do
      aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_ID[$idx]}"
      echo "NAT ${NAT_ID[$idx]} available"
    done
  fi
fi

echo "== Private route tables (+ pods subnets, if any) =="
for idx in $(seq 0 $((AZ_COUNT - 1))); do
  n=$((idx + 1))
  PRIV_RT_ID[$idx]=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-private-${n}}]" \
    --query 'RouteTable.RouteTableId' --output text)

  if [[ "$NAT_MODE" == "per-az" ]]; then
    aws ec2 create-route --route-table-id "${PRIV_RT_ID[$idx]}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_ID[$idx]}" >/dev/null
  elif [[ "$NAT_MODE" == "single" ]]; then
    aws ec2 create-route --route-table-id "${PRIV_RT_ID[$idx]}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$SHARED_NAT_ID" >/dev/null
  fi

  aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID[$idx]}" --subnet-id "${PRIV_ID[$idx]}" >/dev/null
  if [[ -n "$PODS_CIDR" ]]; then
    aws ec2 associate-route-table --route-table-id "${PRIV_RT_ID[$idx]}" --subnet-id "${PODS_ID[$idx]}" >/dev/null
  fi
  echo "AZ ${AZ[$idx]}: PRIV_RT=${PRIV_RT_ID[$idx]}"
done

echo ""
echo "== DONE =="
echo "VPC_ID=$VPC_ID"
for idx in $(seq 0 $((AZ_COUNT - 1))); do
  echo "AZ ${AZ[$idx]}: public=${PUB_ID[$idx]} private=${PRIV_ID[$idx]} pods=${PODS_ID[$idx]:-<none>} nat=${NAT_ID[$idx]:-${SHARED_NAT_ID:-<none>}}"
done

if [[ -n "$OUTPUT_FILE" ]]; then
  jstr() { if [[ -n "$1" ]]; then printf '"%s"' "$1"; else printf 'null'; fi; }
  {
    echo "{"
    echo "  \"vpc_id\": \"$VPC_ID\","
    echo "  \"azs\": ["
    for idx in $(seq 0 $((AZ_COUNT - 1))); do
      comma=","; [[ "$idx" -eq $((AZ_COUNT - 1)) ]] && comma=""
      nat_ref="${NAT_ID[$idx]:-$SHARED_NAT_ID}"
      echo "    {\"az\": \"${AZ[$idx]}\", \"public_subnet\": \"${PUB_ID[$idx]}\", \"private_subnet\": \"${PRIV_ID[$idx]}\", \"pods_subnet\": $(jstr "${PODS_ID[$idx]:-}"), \"nat_gateway\": $(jstr "$nat_ref")}$comma"
    done
    echo "  ]"
    echo "}"
  } > "$OUTPUT_FILE"
  echo ""
  echo "Summary written to $OUTPUT_FILE"
fi

echo ""
echo "Cleanup: all resources carry a Name tag starting with '$NAME' (profile=$PROFILE region=$REGION)"

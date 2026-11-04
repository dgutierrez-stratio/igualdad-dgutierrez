#!/usr/bin/env bash
# create-test-vpc.sh — create a generic test VPC with public/private (+ optional pods/secondary-CIDR) subnets across N AZs
#
# Usage (flags):
#   ./create-test-vpc.sh --name NAME [--azs N] [--region REGION] [--profile PROFILE] \
#       [--vpc-cidr CIDR] [--pods-cidr CIDR] [--nat-mode per-az|single|none] [--output FILE]
#
# Usage (interactive menu, no flags):
#   ./create-test-vpc.sh
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
# DELETE MODE (added by the legacy-eks-cluster skill):
#   ./create-test-vpc.sh --delete --name NAME --expect-account ACCOUNT [--vpc-id vpc-xxx] [--from-json FILE] \
#       [--profile P] [--region R] [--apply]
#   Dry-run by default: lists what it would delete (with IDs). Only --apply deletes. Safety rules:
#     * aborts unless `sts get-caller-identity` returns --expect-account;
#     * the VPC is found by tag Name=NAME (exact) and must not be the default VPC; --vpc-id / --from-json (the JSON
#       written by --output) must match it; >1 match without --vpc-id => abort;
#     * aborts if instances, load balancers, VPC endpoints or in-use ENIs remain in the VPC (delete the cluster first);
#     * deletes only objects INSIDE that VPC (NAT GWs, their EIPs, IGW, subnets, route tables, leftover SGs/NACLs,
#       `available` ENIs) plus EIPs tagged Name=NAME-nat*; idempotent and resumable (re-run continues).
#   Env TEARDOWN_NO_WAIT=1 skips the waits (tests only).
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
DELETE=0; APPLY=0; EXPECT_ACCOUNT=""; VPC_ID_ARG=""; FROM_JSON=""
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
  --output FILE         Write a JSON summary of created resources to FILE
  --expect-account ID   Abort unless the profile operates in this AWS account (always used by the skill)
  --delete              DELETE MODE (dry-run unless --apply); see the header of this script
  --apply               With --delete: really delete
  --vpc-id ID / --from-json FILE   With --delete: extra proof of which VPC is meant
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
  read -rp "Output JSON file (blank = skip): " OUTPUT_FILE
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
      --expect-account) EXPECT_ACCOUNT="$2"; shift 2 ;;
      --delete)     DELETE=1; shift ;;
      --apply)      APPLY=1; shift ;;
      --vpc-id)     VPC_ID_ARG="$2"; shift 2 ;;
      --from-json)  FROM_JSON="$2"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
fi

[[ -z "$NAME" ]] && { echo "ERROR: --name is required"; usage; exit 1; }
[[ -z "$PROFILE" ]] && { echo "ERROR: no AWS profile: pass --profile or export AWS_PROFILE"; usage; exit 1; }
[[ "$NAT_MODE" =~ ^(per-az|single|none)$ ]] || { echo "ERROR: --nat-mode must be per-az|single|none"; exit 1; }
[[ "$AZ_COUNT" -ge 1 && "$AZ_COUNT" -le 6 ]] || { echo "ERROR: --azs must be between 1 and 6"; exit 1; }

# AWS_PAGER="" instead of --no-cli-pager: the flag does not exist in AWS CLI v1 (which may come first in PATH under bash).
# Prefer an AWS CLI v2 binary when several are in PATH (a v1 may come first under bash); fall back to the first one.
AWS_REAL="$(command -v aws)"
for _p in $(type -ap aws 2>/dev/null); do if "$_p" --version 2>&1 | grep -q '^aws-cli/2'; then AWS_REAL="$_p"; break; fi; done
aws() { AWS_PAGER="" "$AWS_REAL" --profile "$PROFILE" --region "$REGION" "$@"; }

if [[ -n "$EXPECT_ACCOUNT" ]]; then
  _acct=$(aws sts get-caller-identity --output json | jq -r '.Account') || { echo "ERROR: sts get-caller-identity failed"; exit 1; }
  [[ "$_acct" == "$EXPECT_ACCOUNT" ]] || { echo "ERROR: wrong account: profile $PROFILE operates in $_acct, expected $EXPECT_ACCOUNT. Nothing touched."; exit 1; }
fi

# ------------------------------------------------------------------------------------------------------------
# DELETE MODE
# ------------------------------------------------------------------------------------------------------------
if [[ "$DELETE" -eq 1 ]]; then
  command -v jq >/dev/null || { echo "ERROR: jq is required for --delete"; exit 1; }
  [[ -n "$EXPECT_ACCOUNT" ]] || { echo "ERROR: --delete requires --expect-account"; exit 1; }
  [[ "$EXPECT_ACCOUNT" =~ ^[0-9]{12}$ ]] || { echo "ERROR: --expect-account must be 12 digits"; exit 1; }
  MODE="DRY-RUN"; [[ "$APPLY" -eq 1 ]] && MODE="APPLY"
  say() { echo "[$MODE] $*"; }
  # run <description> <aws args...> : executes only with --apply
  run() { local d="$1"; shift; if [[ "$APPLY" -eq 1 ]]; then echo "[APPLY] $d"; aws "$@" >/dev/null; else echo "[DRY-RUN] would: $d"; fi; }
  wait_until() {  # wait_until "<desc>" <seconds> <cmd...>  (cmd returns 0 when done)
    local d="$1" max="$2"; shift 2
    [[ "$APPLY" -eq 1 && -z "${TEARDOWN_NO_WAIT:-}" ]] || return 0
    local t=0; until "$@"; do (( t >= max )) && { echo "ERROR: timeout waiting for: $d"; exit 1; }; sleep 10; t=$((t+10)); done
  }

  VPCJ=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}" --output json)
  mapfile -t FOUND < <(jq -r '.Vpcs[]? | select(.IsDefault != true) | .VpcId' <<<"$VPCJ")
  if [[ ${#FOUND[@]} -eq 0 ]]; then say "no VPC with Name=$NAME in $REGION: nothing to delete (already gone?)"; exit 0; fi
  if [[ -n "$FROM_JSON" ]]; then
    [[ -f "$FROM_JSON" ]] || { echo "ERROR: $FROM_JSON not found"; exit 1; }
    _j=$(jq -er '.vpc_id' "$FROM_JSON") || { echo "ERROR: $FROM_JSON has no vpc_id"; exit 1; }
    [[ -z "$VPC_ID_ARG" || "$VPC_ID_ARG" == "$_j" ]] || { echo "ERROR: --vpc-id ($VPC_ID_ARG) differs from vpc_id in $FROM_JSON ($_j)"; exit 1; }
    VPC_ID_ARG="$_j"
  fi
  if [[ -n "$VPC_ID_ARG" ]]; then
    printf '%s\n' "${FOUND[@]}" | grep -qx "$VPC_ID_ARG" || { echo "ERROR: $VPC_ID_ARG does not have tag Name=$NAME (found: ${FOUND[*]}). Ambiguous: aborting."; exit 1; }
    VPC_ID="$VPC_ID_ARG"
  elif [[ ${#FOUND[@]} -eq 1 ]]; then VPC_ID="${FOUND[0]}"
  else echo "ERROR: ${#FOUND[@]} VPCs named $NAME (${FOUND[*]}); pass --vpc-id. Aborting."; exit 1; fi
  echo "== delete VPC $VPC_ID (Name=$NAME, account $EXPECT_ACCOUNT, $REGION) [$MODE] =="

  # 1) blockers: things that must be removed by deleting the cluster first (never deleted here)
  BLOCK=0
  inst=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" --output json | jq -r '[.Reservations[].Instances[] | select(.State.Name != "terminated") | .InstanceId] | join(" ")')
  [[ -z "$inst" ]] || { echo "BLOCKER: instances still in the VPC: $inst"; BLOCK=1; }
  lbs=$(aws elbv2 describe-load-balancers --output json 2>/dev/null | jq -r --arg v "$VPC_ID" '[.LoadBalancers[]? | select(.VpcId==$v) | .LoadBalancerArn] | join(" ")' || true)
  [[ -z "$lbs" ]] || { echo "BLOCKER: load balancers (elbv2) in the VPC: $lbs"; BLOCK=1; }
  clb=$(aws elb describe-load-balancers --output json 2>/dev/null | jq -r --arg v "$VPC_ID" '[.LoadBalancerDescriptions[]? | select(.VPCId==$v) | .LoadBalancerName] | join(" ")' || true)
  [[ -z "$clb" ]] || { echo "BLOCKER: classic load balancers in the VPC: $clb"; BLOCK=1; }
  vpce=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --output json | jq -r '[.VpcEndpoints[]? | select(.State != "deleted") | .VpcEndpointId] | join(" ")')
  [[ -z "$vpce" ]] || { echo "BLOCKER: VPC endpoints in the VPC (ambiguous owner): $vpce"; BLOCK=1; }
  ENIJ=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --output json)
  busy=$(jq -r '[.NetworkInterfaces[] | select(.Status=="in-use" and .InterfaceType != "nat_gateway") | .NetworkInterfaceId + "(" + (.Description // "-") + ")"] | join(" ")' <<<"$ENIJ")
  [[ -z "$busy" ]] || { echo "BLOCKER: in-use ENIs (nodes/LBs/EKS control plane still alive): $busy"; BLOCK=1; }
  [[ "$BLOCK" -eq 0 ]] || { echo "ERROR: resources that depend on the VPC still exist: delete the cluster/LBs first. Aborting."; exit 1; }

  # 2) orphan ENIs (status available) inside this VPC
  for eni in $(jq -r '.NetworkInterfaces[] | select(.Status=="available") | .NetworkInterfaceId' <<<"$ENIJ"); do
    run "delete-network-interface $eni (available, in $VPC_ID)" ec2 delete-network-interface --network-interface-id "$eni"
  done

  # 3) NAT gateways (+ their EIPs)
  NATJ=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --output json)
  mapfile -t NATS < <(jq -r '.NatGateways[] | select(.State != "deleted") | .NatGatewayId' <<<"$NATJ")
  mapfile -t NAT_EIPS < <(jq -r '.NatGateways[] | .NatGatewayAddresses[]?.AllocationId // empty' <<<"$NATJ" | sort -u)
  for n in "${NATS[@]:-}"; do [[ -n "$n" ]] || continue; run "delete-nat-gateway $n" ec2 delete-nat-gateway --nat-gateway-id "$n"; done
  nats_gone() { [[ "$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --output json | jq '[.NatGateways[] | select(.State != "deleted")] | length')" -eq 0 ]]; }
  [[ ${#NATS[@]} -eq 0 || -z "${NATS[0]:-}" ]] || wait_until "NAT gateways deleted" 900 nats_gone
  # EIPs: those of the NATs + those tagged Name=NAME-nat* (never untagged or foreign ones)
  EIPJ=$(aws ec2 describe-addresses --output json)
  mapfile -t TAGGED_EIPS < <(jq -r --arg n "${NAME}-nat" '.Addresses[] | select(any(.Tags[]?; .Key=="Name" and (.Value==$n or (.Value|startswith($n + "-"))))) | .AllocationId' <<<"$EIPJ")
  for a in $(printf '%s\n' "${NAT_EIPS[@]:-}" "${TAGGED_EIPS[@]:-}" | grep -v '^$' | sort -u); do
    assoc=$(jq -r --arg a "$a" '.Addresses[] | select(.AllocationId==$a) | (.AssociationId // "")' <<<"$EIPJ")
    if [[ -n "$assoc" && "$APPLY" -eq 1 && -z "${TEARDOWN_NO_WAIT:-}" ]]; then echo "WARN: EIP $a still associated ($assoc); skipping (re-run later)"; continue; fi
    run "release-address $a" ec2 release-address --allocation-id "$a"
  done

  # 4) internet gateway(s)
  for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --output json | jq -r '.InternetGateways[].InternetGatewayId'); do
    run "detach-internet-gateway $igw from $VPC_ID" ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
    run "delete-internet-gateway $igw" ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done

  # 5) subnets
  for sn in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --output json | jq -r '.Subnets[].SubnetId'); do
    run "delete-subnet $sn" ec2 delete-subnet --subnet-id "$sn"
  done

  # 6) route tables (non-main)
  RTJ=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --output json)
  for assoc in $(jq -r '.RouteTables[].Associations[]? | select(.Main != true) | .RouteTableAssociationId' <<<"$RTJ"); do
    run "disassociate-route-table $assoc" ec2 disassociate-route-table --association-id "$assoc"
  done
  for rt in $(jq -r '.RouteTables[] | select(all(.Associations[]?; .Main != true)) | .RouteTableId' <<<"$RTJ"); do
    run "delete-route-table $rt" ec2 delete-route-table --route-table-id "$rt"
  done

  # 7) leftover security groups (non-default) of this VPC: revoke all rules first (cross references), then delete
  SGJ=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --output json)
  mapfile -t SGS < <(jq -r '.SecurityGroups[] | select(.GroupName != "default") | .GroupId' <<<"$SGJ")
  for sg in "${SGS[@]:-}"; do
    [[ -n "$sg" ]] || continue
    if [[ "$(jq -r --arg g "$sg" '.SecurityGroups[] | select(.GroupId==$g) | (.IpPermissions|length)' <<<"$SGJ")" -gt 0 ]]; then
      run "revoke ingress rules of $sg" ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "$(jq -c --arg g "$sg" '.SecurityGroups[] | select(.GroupId==$g) | .IpPermissions' <<<"$SGJ")"
    fi
    if [[ "$(jq -r --arg g "$sg" '.SecurityGroups[] | select(.GroupId==$g) | (.IpPermissionsEgress|length)' <<<"$SGJ")" -gt 0 ]]; then
      run "revoke egress rules of $sg" ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions "$(jq -c --arg g "$sg" '.SecurityGroups[] | select(.GroupId==$g) | .IpPermissionsEgress' <<<"$SGJ")"
    fi
  done
  for sg in "${SGS[@]:-}"; do [[ -n "$sg" ]] || continue; run "delete-security-group $sg" ec2 delete-security-group --group-id "$sg"; done

  # 8) custom network ACLs (non-default)
  for acl in $(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID" --output json | jq -r '.NetworkAcls[] | select(.IsDefault != true) | .NetworkAclId'); do
    run "delete-network-acl $acl" ec2 delete-network-acl --network-acl-id "$acl"
  done

  # 9) the VPC
  run "delete-vpc $VPC_ID" ec2 delete-vpc --vpc-id "$VPC_ID"
  [[ "$APPLY" -eq 1 ]] && echo "VPC $VPC_ID deletion requested" || echo "DRY-RUN finished: nothing deleted. Re-run with --apply."
  exit 0
fi

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

# Ownership tags on everything created (lets the teardown prove the resources belong to this cluster/VPC).
TAG_IDS=("$VPC_ID" "$IGW_ID" "$PUB_RT_ID")
for idx in $(seq 0 $((AZ_COUNT - 1))); do TAG_IDS+=("${PUB_ID[$idx]}" "${PRIV_ID[$idx]}" "${PRIV_RT_ID[$idx]}"); [[ -n "${PODS_ID[$idx]:-}" ]] && TAG_IDS+=("${PODS_ID[$idx]}"); done
for idx in "${!EIP_ID[@]}"; do TAG_IDS+=("${EIP_ID[$idx]}"); done
[[ -z "$SHARED_NAT_ID" ]] || TAG_IDS+=("$SHARED_NAT_ID")
for idx in "${!NAT_ID[@]}"; do TAG_IDS+=("${NAT_ID[$idx]}"); done
aws ec2 create-tags --resources "${TAG_IDS[@]}" --tags "Key=keos.stratio.com/owner,Value=${NAME}" "Key=managed-by,Value=legacy-eks-cluster" >/dev/null

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
echo "Cleanup: all resources carry Name tag '$NAME*' and keos.stratio.com/owner=$NAME; delete with: $0 --delete --name $NAME --expect-account <account> [--apply]"

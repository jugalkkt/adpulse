#!/usr/bin/env bash
# Destroy everything AdPulse created on AWS (plan step 12.13), used by `make aws-down`.
#   1. aws-prod stack on the VM (infra/terraform/envs/aws), if its state has resources
#   2. VM, network, key pair (infra/terraform/aws)
#   3. verify with the AWS CLI that nothing tagged Project=AdPulse is left
# Each destroy is planned to a file, shown, and applied only after you type "yes" (rule R4).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_DIR="$ROOT/infra/terraform/aws"
STACK_DIR="$ROOT/infra/terraform/envs/aws"
PROFILE="${AWS_PROFILE:-adpulse}"
REGION="${AWS_REGION:-ap-south-1}"

confirm() {
  local answer
  read -r -p "$1 Type 'yes' to destroy: " answer
  [[ "$answer" == "yes" ]] || { echo "aborted, nothing destroyed" >&2; exit 1; }
}

count() { terraform -chdir="$1" state list 2>/dev/null | wc -l; }

# 1. Stack on the VM (needs the VM's IP, so it must go first).
if [[ -d "$STACK_DIR/.terraform" && "$(count "$STACK_DIR")" -gt 0 ]]; then
  bash "$ROOT/scripts/terraform.sh" aws plan -destroy -input=false -out=destroy.tfplan
  confirm "Destroy the aws-prod stack ($(count "$STACK_DIR") resources)?"
  bash "$ROOT/scripts/terraform.sh" aws apply -input=false destroy.tfplan
  rm -f "$STACK_DIR/destroy.tfplan"
else
  echo "aws-prod stack: state empty, skipping"
fi

# 2. VM, network and key pair. my_ip only satisfies the variable; destroy ignores it.
if [[ "$(count "$AWS_DIR")" -gt 0 ]]; then
  terraform -chdir="$AWS_DIR" plan -destroy -input=false -var my_ip=127.0.0.1 -out=destroy.tfplan
  confirm "Destroy the AWS infrastructure ($(count "$AWS_DIR") resources)?"
  terraform -chdir="$AWS_DIR" apply -input=false destroy.tfplan
  rm -f "$AWS_DIR/destroy.tfplan"
else
  echo "aws infrastructure: state empty, skipping"
fi
rm -f "$ROOT/ansible/inventories/aws/hosts.yml"

# 3. Verify (plan 12.13.2): every list must be empty.
aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }
tag=Name=tag:Project,Values=AdPulse
left=0
check() {
  local name="$1"; shift
  # A failed call (e.g. dead credentials) must abort, never count as "0 left".
  local out n; out="$("$@" --output text)"
  n="$(grep -c . <<<"$out" || true)"
  printf '  %-16s %s\n' "$name" "$n"; left=$((left + n))
}
echo "Left on AWS (tag Project=AdPulse, $REGION):"
check instances      aws ec2 describe-instances --filters "$tag" Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId'
check volumes        aws ec2 describe-volumes --filters "$tag" --query 'Volumes[].VolumeId'
check elastic-ips    aws ec2 describe-addresses --query 'Addresses[].AllocationId'
check security-grps  aws ec2 describe-security-groups --filters "$tag" --query 'SecurityGroups[].GroupId'
check vpcs           aws ec2 describe-vpcs --filters "$tag" --query 'Vpcs[].VpcId'
check key-pairs      aws ec2 describe-key-pairs --filters Name=key-name,Values=adpulse-aws --query 'KeyPairs[].KeyName'
if [[ "$left" -eq 0 ]]; then
  echo "AWS TORN DOWN at $(date -u +%Y-%m-%dT%H:%M:%SZ). Next: delete the access key in IAM; check Billing -> Credits tomorrow."
else
  echo "WARNING: $left resource(s) still exist; check the AWS console (region $REGION)." >&2; exit 1
fi

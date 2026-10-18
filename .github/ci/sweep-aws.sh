#!/usr/bin/env bash
# Lists what an aws-ecs-fargate stack left behind after `terraform destroy`.
# Read-only. Exits 1 when anything the destroy should have removed remains,
# 0 when only the expected remnants are left: a secret in its recovery window
# and deregistered task definitions.
#
#   AWS_PROFILE=<profile> sweep-aws.sh <name> [region]
#
# The Resource Groups Tagging API keeps listing deleted ECS tasks and services
# for a while, so every check asks the owning service instead.
set -euo pipefail

name=${1:?usage: sweep-aws.sh <name> [region]}
region=${2:-$(aws configure get region || true)}
[ -n "$region" ] || { echo "no region given and none configured" >&2; exit 2; }
[[ $name =~ ^[A-Za-z0-9-]+$ ]] || { echo "unexpected stack name: $name" >&2; exit 2; }
export AWS_REGION=$region AWS_PAGER=""

left=0
found() { echo "LEFT  $1: $2"; left=1; }
note() { echo "NOTE  $1: $2"; }
# Every query is captured before it is read, so a failed call stops the sweep
# instead of reading as nothing left. Rows keep their tab-separated columns;
# a list query gets one item per line.
rows() { aws "$@" --output text | sed '/^None$/d; /^$/d'; }
list() { rows "$@" | tr '\t' '\n'; }
# Every match is on a name the recipe generates, never a bare prefix, so a
# sweep never reports another stack whose name starts with this one.
# name_prefix adds a timestamp and hex counter.
generated() { grep -E "^${name}-${1:-}[0-9a-f]+$" || true; }

echo "Sweeping stack $name in $region"

status=$(rows ecs describe-clusters --clusters "$name" --query 'clusters[0].status')
if [ "$status" = ACTIVE ] || [ "$status" = PROVISIONING ]; then
  found "ECS cluster" "$name ($status)"
  out=$(rows ecs describe-services --cluster "$name" --services "$name-app" "$name-worker" \
    --query "services[?status!='INACTIVE'].[serviceName,status]")
  while read -r svc st; do [ -z "$svc" ] || found "ECS service" "$svc ($st)"; done <<<"$out"
  out=$(list ecs list-tasks --cluster "$name" --query 'taskArns')
  for task in $out; do found "ECS task" "${task##*/}"; done
fi

for family in app worker migrate; do
  out=$(list ecs list-task-definitions --family-prefix "$name-$family" --status ACTIVE \
    --query 'taskDefinitionArns')
  for td in $out; do
    td=${td##*/}
    [ "${td%:*}" != "$name-$family" ] || found "ECS task definition (ACTIVE)" "$td"
  done
done

out=$(list rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' | generated)
for db in $out; do found "RDS instance" "$db"; done
out=$(rows rds describe-db-snapshots \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,DBInstanceIdentifier,SnapshotType]')
while read -r snap db type; do
  if [[ $snap =~ ^${name}-final-[0-9]{14}$ || $db =~ ^${name}-[0-9a-f]+$ ]]; then
    found "RDS snapshot ($type)" "$snap"
  fi
done <<<"$out"
out=$(rows rds describe-db-instance-automated-backups \
  --query 'DBInstanceAutomatedBackups[].[DBInstanceIdentifier,Status]')
while read -r db st; do
  [[ ! $db =~ ^${name}-[0-9a-f]+$ ]] || found "RDS automated backup" "$db ($st)"
done <<<"$out"
out=$(list rds describe-db-subnet-groups --query 'DBSubnetGroups[].DBSubnetGroupName' | generated)
for group in $out; do found "RDS subnet group" "$group"; done

out=$(list elasticache describe-replication-groups \
  --query "ReplicationGroups[?ReplicationGroupId=='$name-cache'].ReplicationGroupId")
for rg in $out; do found "ElastiCache replication group" "$rg"; done
out=$(list elasticache describe-cache-clusters \
  --query "CacheClusters[?ReplicationGroupId=='$name-cache'].CacheClusterId")
for cc in $out; do found "ElastiCache cluster" "$cc"; done
out=$(list elasticache describe-serverless-caches \
  --query "ServerlessCaches[?ServerlessCacheName=='$name-cache'].ServerlessCacheName")
for sc in $out; do found "ElastiCache serverless cache" "$sc"; done
out=$(list elasticache describe-cache-subnet-groups \
  --query "CacheSubnetGroups[?CacheSubnetGroupName=='$name-cache'].CacheSubnetGroupName")
for group in $out; do found "ElastiCache subnet group" "$group"; done

out=$(list s3api list-buckets --query "Buckets[?starts_with(Name, '$name-')].Name" | generated)
# list-buckets is global; a bucket counts only in the region being swept.
for bucket in $out; do
  where=$(rows s3api get-bucket-location --bucket "$bucket" --query LocationConstraint)
  case ${where:-us-east-1} in EU) where=eu-west-1 ;; esac
  [ "${where:-us-east-1}" != "$region" ] || found "S3 bucket" "$bucket"
done

vpcs=$(list ec2 describe-vpcs --filters "Name=tag:Name,Values=$name" --query 'Vpcs[].VpcId')
for vpc in $vpcs; do found "VPC" "$vpc"; done
out=$(list ec2 describe-internet-gateways --filters "Name=tag:Name,Values=$name" \
  --query 'InternetGateways[].InternetGatewayId')
for igw in $out; do found "internet gateway" "$igw"; done
out=$(list ec2 describe-security-groups \
  --filters "Name=group-name,Values=$name-alb-*,$name-app-*,$name-data-*" \
  --query 'SecurityGroups[].GroupName')
for kind in alb app data; do
  for sg in $(generated "$kind-" <<<"$out"); do found "security group" "$sg"; done
done
out=$(list ec2 describe-addresses --filters "Name=tag:Name,Values=$name" --query 'Addresses[].PublicIp')
for eip in $out; do found "Elastic IP" "$eip"; done
if [ -n "$vpcs" ]; then
  vpc_list=$(paste -sd, - <<<"$vpcs")
  out=$(list ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_list" \
    --query 'NetworkInterfaces[].NetworkInterfaceId')
  for eni in $out; do found "network interface" "$eni"; done
  out=$(list ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_list" \
    --query "NatGateways[?State!='deleted'].NatGatewayId")
  for nat in $out; do found "NAT gateway" "$nat"; done
fi

# Load balancer and target group names keep only the first six characters of
# the stack name, so a match counts when it sits in this stack's VPC or its
# VPC is gone, not in another stack's.
prefix=${name:0:6}
elb() {
  local kind=$1 rows_=$2 item vpc others
  while read -r item vpc; do
    [ -n "$item" ] || continue
    others=""
    if ! grep -qx "$vpc" <<<"$vpcs"; then
      others=$(list ec2 describe-vpcs --filters "Name=vpc-id,Values=$vpc" --query 'Vpcs[].VpcId')
    fi
    if [ -z "$others" ]; then
      found "$kind" "$item"
    else
      note "$kind" "$item shares the name prefix but sits in another VPC"
    fi
  done <<<"$rows_"
}
out=$(rows elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName, '$prefix')].[LoadBalancerName,VpcId]")
elb "load balancer" "$out"
out=$(rows elbv2 describe-target-groups \
  --query "TargetGroups[?starts_with(TargetGroupName, '$prefix')].[TargetGroupName,VpcId]")
elb "target group" "$out"

out=$(list logs describe-log-groups --log-group-name-prefix "/ecs/$name-" --query 'logGroups[].logGroupName')
for group in $out; do
  case $group in "/ecs/$name-app" | "/ecs/$name-worker" | "/ecs/$name-migrate") found "log group" "$group" ;; esac
done

out=$(aws secretsmanager list-secrets --include-planned-deletion --filters "Key=name,Values=$name/app-" \
  --query 'SecretList[].[Name,DeletedDate]' --output text)
while read -r secret deleted; do
  [[ $secret =~ ^${name}/app-[0-9a-f]+$ ]] || continue
  if [ "$deleted" = None ]; then
    found "secret" "$secret"
  else
    note "secret" "$secret is pending deletion since $deleted; to free it now: aws secretsmanager delete-secret --force-delete-without-recovery --secret-id $secret"
  fi
done <<<"$out"

out=$(list iam list-roles \
  --query "Roles[?starts_with(RoleName, '$name-exec-') || starts_with(RoleName, '$name-task-')].RoleName")
for kind in exec task; do
  for role in $(generated "$kind-" <<<"$out"); do found "IAM role" "$role"; done
done

[ "$left" = 1 ] || echo "Nothing left for $name in $region beyond the notes above"
exit "$left"

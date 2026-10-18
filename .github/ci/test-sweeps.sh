#!/usr/bin/env bash
# Runs sweep-aws.sh and sweep-azure.sh against stub aws and az commands, so
# CI checks how they classify and fail without a cloud account. Each stub
# prints a canned reply for "<service> <operation>", already shaped as the
# script's --query would leave it; this tests the scripts' own logic, not the
# JMESPath.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A reply file is <service>__<operation>, or <service>__<operation>__<token>
# when it applies only to calls whose arguments contain <token>. A .fail
# suffix makes the call fail the way the CLI does.
mkdir "$work/bin"
cat > "$work/bin/stub" <<'EOF'
#!/usr/bin/env bash
key="$1__$2"
args=" $* "
for file in "$REPLIES/$key"__*; do
  [ -e "$file" ] || continue
  token=${file##*__}
  token=${token%.fail}
  [[ $args == *"$token"* ]] || continue
  [[ $file != *.fail ]] || { echo "stub: $key failed" >&2; exit 255; }
  cat "$file"
  exit 0
done
[ ! -e "$REPLIES/$key.fail" ] || { echo "stub: $key failed" >&2; exit 255; }
[ ! -e "$REPLIES/$key" ] || cat "$REPLIES/$key"
EOF
chmod +x "$work/bin/stub"
ln -s stub "$work/bin/aws"
ln -s stub "$work/bin/az"

failures=0
# run <case> <want-exit> <script> <args...>; replies come from $work/<case>.
run() {
  local case=$1 want=$2 script=$3 code=0
  shift 3
  REPLIES="$work/$case" PATH="$work/bin:$PATH" bash "$here/$script" "$@" > "$work/$case.out" 2>&1 || code=$?
  if [ "$code" != "$want" ]; then
    printf 'FAIL: %s exited %s, want %s:\n' "$case" "$code" "$want"
    cat "$work/$case.out"
    failures=1
    return 1
  fi
}
has() {
  grep -qF -- "$2" "$work/$1.out" || { printf 'FAIL: %s lacks "%s":\n' "$1" "$2"; cat "$work/$1.out"; failures=1; return 1; }
}
lacks() {
  ! grep -qF -- "$2" "$work/$1.out" || { printf 'FAIL: %s has "%s":\n' "$1" "$2"; cat "$work/$1.out"; failures=1; return 1; }
}
pass() { printf 'PASS: %s\n' "$1"; }
reply() { mkdir -p "$work/$1"; printf '%b' "$3" > "$work/$1/$2"; }

reply aws-notes iam__list-roles 'glv1-exec-2026101809000012340000000a\t2026-10-18T09:00:00Z\nglv1-exec-extra\t2026-01-01T00:00:00Z\n'
reply aws-notes elbv2__describe-target-groups 'glv120261018090000123400000001\tvpc-0gone\tip\nglv120261018090000123400000002\tNone\tlambda\n'
run aws-notes 0 sweep-aws.sh glv1 us-east-1 &&
  has aws-notes 'NOTE  IAM role: glv1-exec-2026101809000012340000000a, created 2026-10-18T09:00:00Z' &&
  has aws-notes 'NOTE  target group: glv120261018090000123400000001 shares the name prefix and its VPC vpc-0gone is gone' &&
  lacks aws-notes 'glv1-exec-extra' && lacks aws-notes 'lambda' && lacks aws-notes 'LEFT' &&
  pass "AWS: a global IAM role and a target group without its VPC are notes, not leftovers"

reply aws-left ecs__describe-clusters 'ACTIVE\n'
reply aws-left ec2__describe-vpcs__Name=tag:Name 'vpc-0stack\n'
reply aws-left elbv2__describe-target-groups 'glv120261018090000123400000001\tvpc-0stack\tip\n'
run aws-left 1 sweep-aws.sh glv1 us-east-1 &&
  has aws-left 'LEFT  ECS cluster: glv1 (ACTIVE)' &&
  has aws-left 'LEFT  VPC: vpc-0stack' &&
  has aws-left 'LEFT  target group: glv120261018090000123400000001' &&
  lacks aws-left 'Nothing left' &&
  pass "AWS: exact leftovers are LEFT and exit 1"

reply aws-fail iam__list-roles.fail ''
run aws-fail 255 sweep-aws.sh glv1 us-east-1 &&
  lacks aws-fail 'Nothing left' &&
  pass "AWS: a failed call stops the sweep"

reply az-other group__exists 'false\n'
reply az-other monitor__log-analytics '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/other-rg/providers/Microsoft.OperationalInsights/workspaces/glv1-logs\n'
run az-other 0 sweep-azure.sh glv1 00000000-0000-0000-0000-000000000000 &&
  has az-other 'Nothing left for glv1' &&
  pass "Azure: a deleted workspace of the same name in another group is ignored"

reply az-left group__exists__glv1-rg-infra 'false\n'
reply az-left group__exists 'true\n'
reply az-left resource__list 'Microsoft.App/containerApps\tglv1-app\n'
reply az-left monitor__log-analytics '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/GLV1-RG/providers/Microsoft.OperationalInsights/workspaces/glv1-logs\n'
run az-left 1 sweep-azure.sh glv1 00000000-0000-0000-0000-000000000000 &&
  has az-left 'LEFT  resource group: glv1-rg' &&
  has az-left 'LEFT  Microsoft.App/containerApps: glv1-app (resource group glv1-rg)' &&
  has az-left 'LEFT  soft-deleted Log Analytics workspace: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/GLV1-RG/' &&
  lacks az-left 'glv1-rg-infra' &&
  pass "Azure: the stack's groups, their resources and its deleted workspace are LEFT"

reply az-fail group__exists 'false\n'
reply az-fail monitor__log-analytics.fail ''
run az-fail 255 sweep-azure.sh glv1 00000000-0000-0000-0000-000000000000 &&
  lacks az-fail 'Nothing left' &&
  pass "Azure: a failed call stops the sweep"

exit "$failures"

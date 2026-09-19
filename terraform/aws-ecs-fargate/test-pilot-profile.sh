#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

assert_profile_valid() {
  local output normalized_output
  output=$(terraform console -no-color -var-file=pilot.tfvars.example <<< 'var.pilot_profile' 2>&1)
  normalized_output=$(printf '%s' "$output" | tr '\n' ' ' | awk '{$1=$1; print}')
  if [[ "$normalized_output" != "true" ]]; then
    printf 'FAIL: valid pilot profile was rejected:\n%s\n' "$output" >&2
    return 1
  fi
  printf 'PASS: valid pilot profile\n'
}

assert_profile_rejected() {
  local name=$1
  local expected=$2
  shift 2

  local output normalized_output
  output=$(terraform console -no-color -var-file=pilot.tfvars.example "$@" <<< 'var.pilot_profile' 2>&1 || true)
  normalized_output=$(printf '%s' "$output" | tr '\n' ' ' | awk '{$1=$1; print}')
  if [[ "$normalized_output" != *"$expected"* ]]; then
    printf 'FAIL: %s did not produce the expected validation error:\n%s\n' "$name" "$output" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$name"
}

assert_profile_valid
assert_profile_rejected \
  'deletion protection is required' \
  'pilot_profile requires a geolens-<org-slug> name' \
  -var=deletion_protection=false
assert_profile_rejected \
  'pilot profile requires HTTPS' \
  'With acm_certificate_arn set, public_app_url must be HTTPS' \
  -var=public_app_url=http://maps.example.org
assert_profile_rejected \
  'S3 versioning is required' \
  'pilot_profile requires a geolens-<org-slug> name' \
  -var=s3_versioning_enabled=false
assert_profile_rejected \
  'reserved storage environment variables cannot be overridden' \
  'pilot_profile reserves the database, migration/runtime-role, TLS, AWS credential and task-role S3 environment settings' \
  '-var=extra_env={S3_BUCKET="another-org-bucket"}'
assert_profile_rejected \
  'extra secrets must use the deployment-specific path' \
  'under the stack-specific Secrets Manager path <name>/' \
  '-var=extra_secrets={OPENAI_API_KEY="arn:aws:secretsmanager:us-east-1:111111111111:secret:other/ai-AbCdEf"}'

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
  'pilot_profile reserves the database, migration/runtime-role, TLS, admin, JWT, encryption-key, AWS credential and S3 settings' \
  '-var=extra_env={S3_BUCKET="another-org-bucket"}'
assert_profile_rejected \
  'a reserved name cannot come in through extra_secrets either' \
  'pilot_profile reserves the database, migration/runtime-role, TLS, admin, JWT, encryption-key, AWS credential and S3 settings' \
  '-var=extra_secrets={STORAGE_PROVIDER="arn:aws:secretsmanager:us-east-1:111111111111:secret:geolens-org-slug/storage-AbCdEf"}'
assert_profile_rejected \
  'extra_env cannot set a recipe-generated secret' \
  'extra_env cannot set DATABASE_URL_OVERRIDE, JWT_SECRET_KEY' \
  '-var=extra_env={JWT_SECRET_KEY="weak"}'
assert_profile_rejected \
  'extra_secrets cannot redefine a recipe-generated secret' \
  'extra_secrets cannot redefine DATABASE_URL_OVERRIDE, JWT_SECRET_KEY' \
  '-var=extra_secrets={SECRET_ENCRYPTION_KEY="arn:aws:secretsmanager:us-east-1:111111111111:secret:geolens-org-slug/key-AbCdEf"}'
assert_profile_rejected \
  'one name cannot be both plain and secret' \
  'A name cannot be in both extra_env and extra_secrets' \
  '-var=extra_env={SMTP_PASSWORD="plain"}' \
  '-var=extra_secrets={SMTP_PASSWORD="arn:aws:secretsmanager:us-east-1:111111111111:secret:geolens-org-slug/smtp-AbCdEf"}'
assert_profile_rejected \
  'cpu_architecture takes only Fargate values' \
  'cpu_architecture must be ARM64 or X86_64' \
  -var=cpu_architecture=amd64
assert_profile_rejected \
  'extra secrets must use the deployment-specific path' \
  'under the stack-specific Secrets Manager path <name>/' \
  '-var=extra_secrets={OPENAI_API_KEY="arn:aws:secretsmanager:us-east-1:111111111111:secret:other/ai-AbCdEf"}'

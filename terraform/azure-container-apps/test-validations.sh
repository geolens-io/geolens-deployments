#!/usr/bin/env bash
# The variable validations that stop a plan before anything is created (codex
# review on #59). terraform console runs them without Azure credentials, so CI
# calls this after init -backend=false.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

subscription='-var=subscription_id=00000000-0000-0000-0000-000000000000'

accepted() {
  local name=$1 output
  shift
  if ! output=$(terraform console -no-color "$subscription" "$@" <<< 'var.name' 2>&1); then
    printf 'FAIL: %s was rejected:\n%s\n' "$name" "$output" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$name"
}

rejected() {
  local name=$1 expected=$2 output
  shift 2
  output=$(terraform console -no-color "$subscription" "$@" <<< 'var.name' 2>&1 || true)
  if [[ "$(printf '%s' "$output" | tr '\n' ' ' | awk '{$1=$1; print}')" != *"$expected"* ]]; then
    printf 'FAIL: %s did not fail with "%s":\n%s\n' "$name" "$expected" "$output" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$name"
}

accepted 'the defaults'
accepted 'ordinary names in both escape hatches' \
  '-var=extra_env={REGISTRATION_ENABLED="true"}' '-var=extra_secrets={OPENAI_API_KEY="sk-test"}'
rejected 'a name with consecutive hyphens' 'name must be 3 to 20' '-var=name=team--geolens'
rejected 'extra_env cannot set a generated secret' 'extra_env cannot set' '-var=extra_env={JWT_SECRET_KEY="weak"}'
rejected 'extra_env cannot pin the secrets digest' 'extra_env cannot set' '-var=extra_env={SECRETS_REVISION="pinned"}'
rejected 'extra_secrets cannot replace the migrate bootstrap' 'extra_secrets cannot redefine' \
  '-var=extra_secrets={GEOLENS_BOOTSTRAP_B64="x"}'
rejected 'migrations cannot move back into the api' 'extra_env cannot set' '-var=extra_env={GEOLENS_API_RUN_MIGRATIONS="true"}'
rejected 'the staging path cannot move off the share' 'extra_secrets cannot redefine' '-var=extra_secrets={UPLOAD_STAGING_DIR="/tmp/staging"}'
rejected 'the api metrics directory cannot reach the worker' 'extra_env cannot set' '-var=extra_env={PROMETHEUS_MULTIPROC_DIR="/tmp/prometheus-multiproc"}'
rejected 'the upload limit comes from its variable' 'extra_secrets cannot redefine' '-var=extra_secrets={UPLOAD_MAX_SIZE_MB="2000"}'
rejected 'storage cannot switch away from what titiler reads' 'extra_env cannot set' '-var=extra_env={STORAGE_PROVIDER="s3"}'
rejected 'a secret key ending in an underscore' 'extra_secrets keys must be' '-var=extra_secrets={SMTP_PASSWORD_="x"}'
rejected 'one name cannot be both plain and secret' 'A name cannot be in both' \
  '-var=extra_env={SMTP_PASSWORD="a"}' '-var=extra_secrets={SMTP_PASSWORD="b"}'
rejected 'an IPv6 address space' 'vnet_cidr must be an IPv4 CIDR' '-var=vnet_cidr=2001:db8::/16'
rejected 'an address space larger than Azure takes' 'vnet_cidr must be an IPv4 CIDR' '-var=vnet_cidr=0.0.0.0/1'
rejected 'a blank admin username' 'admin_username must not be blank' '-var=admin_username= '
accepted 'a supplied admin password that meets the policy' '-var=admin_password=Str0ng-enough-pw'
rejected 'a short admin password' 'admin_password must be empty' '-var=admin_password=Short1!'
rejected 'an admin password with two character classes' 'admin_password must be empty' '-var=admin_password=alllowercase123'
rejected 'an admin password over 72 bytes' 'admin_password must be empty' "-var=admin_password=Aa1$(printf '%070d' 0)"
accepted 'a custom domain origin' '-var=public_app_url=https://geolens.example.com/'
rejected 'a hostname with an empty label' 'public_app_url must be empty' '-var=public_app_url=https://geo..example.com'
rejected 'a label that starts with a hyphen' 'public_app_url must be empty' '-var=public_app_url=https://geo.-example.com'
rejected 'more than one app replica needs the cache' 'app_replicas above 1 needs cache_enabled' '-var=app_replicas=2'

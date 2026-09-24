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
rejected 'a connection string cannot move the api to another account' 'extra_secrets cannot redefine' '-var=extra_secrets={AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=other"}'
rejected 'the api cannot lose its titiler sidecar' 'extra_env cannot set' '-var=extra_env={TITILER_BASE_URL="http://titiler:8000"}'
rejected 'the database TLS mode is pinned' 'extra_env cannot set' '-var=extra_env={DATABASE_SSL_MODE="disable"}'
rejected 'migrations cannot move to another login' 'extra_secrets cannot redefine' '-var=extra_secrets={MIGRATION_DATABASE_URL_OVERRIDE="postgresql://other:pw@db/geolens"}'
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
rejected 'a network address with host bits set' 'vnet_cidr must be an IPv4 CIDR' '-var=vnet_cidr=10.30.1.0/16'
rejected 'a link-local network' 'vnet_cidr must not overlap' '-var=vnet_cidr=169.254.0.0/16'
rejected 'an apps subnet inside a Container Apps reserved range' 'Container Apps subnet and must not overlap' '-var=vnet_cidr=172.31.0.0/16'
accepted 'a network around a reserved range whose apps subnet avoids it' '-var=vnet_cidr=172.16.0.0/12'
accepted 'a custom domain origin' '-var=public_app_url=https://geolens.example.com/'
rejected 'a hostname with an empty label' 'public_app_url must be empty' '-var=public_app_url=https://geo..example.com'
rejected 'a label that starts with a hyphen' 'public_app_url must be empty' '-var=public_app_url=https://geo.-example.com'
rejected 'more than one app replica needs the cache' 'app_replicas above 1 needs cache_enabled' '-var=app_replicas=2'

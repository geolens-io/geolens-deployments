#!/usr/bin/env bash
# Lists what an azure-container-apps stack left behind after
# `terraform destroy`. Read-only. Exits 1 when anything the destroy should have
# removed remains, soft-deleted workspaces and vaults included, since they hold
# the name for the next apply.
#
#   sweep-azure.sh <name> <subscription-id>
#
# Azure keeps a recovery record of each deleted storage account. It is not
# billed and nothing here reports it. NetworkWatcher_<region> is shared by
# the region and is not the stack's either.
set -euo pipefail

name=${1:?usage: sweep-azure.sh <name> <subscription-id>}
subscription=${2:?usage: sweep-azure.sh <name> <subscription-id>}
[[ $name =~ ^[a-z0-9-]+$ ]] || { echo "unexpected stack name: $name" >&2; exit 2; }

left=0
found() { echo "LEFT  $1: $2"; left=1; }
# Captured before it is read, so a failed call stops the sweep instead of
# reading as nothing left.
rows() { az "$@" --subscription "$subscription" --output tsv; }

# The storage account drops hyphens and keeps 18 characters before its
# six-character suffix.
storage=${name//-/}
storage=${storage:0:18}
storage_query="type == 'Microsoft.Storage/storageAccounts' && starts_with(name, '$storage') && length(name) == \`$((${#storage} + 6))\`"

echo "Sweeping stack $name"

for group in "$name-rg" "$name-rg-infra"; do
  exists=$(rows group exists --name "$group")
  [ "$exists" != true ] || found "resource group" "$group"
done

# Every resource the recipe names, wherever it sits, Managed Redis included.
out=$(rows resource list \
  --query "[?starts_with(name, '$name-') || starts_with(name, '$name.') || ($storage_query)].[type, name]")
while IFS=$'\t' read -r type item; do
  [ -z "$item" ] || found "$type" "$item"
done <<<"$out"

out=$(rows monitor log-analytics workspace list-deleted-workspaces \
  --query "[?starts_with(name, '$name-')].name")
for ws in $out; do found "soft-deleted Log Analytics workspace" "$ws"; done

out=$(rows keyvault list-deleted --resource-type vault --query "[?starts_with(name, '$name')].name")
for kv in $out; do found "soft-deleted key vault" "$kv"; done

[ "$left" = 1 ] || echo "Nothing left for $name"
exit "$left"

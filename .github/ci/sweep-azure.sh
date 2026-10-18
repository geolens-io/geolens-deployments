#!/usr/bin/env bash
# Lists what an azure-container-apps stack left behind after
# `terraform destroy`. Read-only. Exits 1 when anything the destroy should have
# removed remains, a soft-deleted workspace included, since it holds the name
# for the next apply. The recipe creates no Key Vault, so none is checked.
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

# Only the names the recipe generates, so a sweep never reports another stack
# whose name merely starts with this one. The database server and cache add
# a six-character suffix; the storage account drops hyphens and keeps 18
# characters before it.
storage=${name//-/}
storage=${storage:0:18}
ours() {
  local group=$1 type=$2 item=$3
  case $group in "$name-rg" | "$name-rg-infra") return 0 ;; esac
  case $type in
    Microsoft.DBforPostgreSQL/flexibleServers | Microsoft.Cache/redisEnterprise)
      [[ $item =~ ^${name}-[a-z0-9]{6}$ ]] ;;
    Microsoft.Storage/storageAccounts) [[ $item =~ ^${storage}[a-z0-9]{6}$ ]] ;;
    Microsoft.Network/privateDnsZones) [ "$item" = "$name.private.postgres.database.azure.com" ] ;;
    *)
      case $item in
        "$name-vnet" | "$name-logs" | "$name-env" | "$name-app" | "$name-worker" | "$name-migrate") return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

echo "Sweeping stack $name"

for group in "$name-rg" "$name-rg-infra"; do
  exists=$(rows group exists --name "$group")
  [ "$exists" != true ] || found "resource group" "$group"
done

# Resource group names compare case-insensitively in Azure; the CLI may
# report either case.
out=$(rows resource list --query "[].[resourceGroup, type, name]")
while IFS=$'\t' read -r group type item; do
  [ -n "$item" ] || continue
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$group")
  if ours "$lower" "$type" "$item"; then
    found "$type" "$item (resource group $group)"
  fi
done <<<"$out"

out=$(rows monitor log-analytics workspace list-deleted-workspaces \
  --query "[?name == '$name-logs'].[resourceGroup, name]")
while IFS=$'\t' read -r group ws; do
  [ -z "$ws" ] || found "soft-deleted Log Analytics workspace" "$ws (resource group $group)"
done <<<"$out"

[ "$left" = 1 ] || echo "Nothing left for $name"
exit "$left"

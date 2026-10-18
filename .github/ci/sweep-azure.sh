#!/usr/bin/env bash
# Lists what an azure-container-apps stack left behind after
# `terraform destroy`. Read-only. Every LEFT line is in the stack's own
# resource groups, a soft-deleted workspace included, since it holds the name
# for the next apply; delete it. Exits 1 on any LEFT. The recipe creates no
# Key Vault, so none is checked.
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
# A configured default resource group would silently narrow the
# subscription-wide queries.
export AZURE_DEFAULTS_GROUP=""

echo "Sweeping stack $name"

# Every resource the recipe creates sits in <name>-rg, and the Container Apps
# environment's own in <name>-rg-infra. A resource cannot outlive its group,
# so the two groups bound the sweep; matching names across the subscription
# would also catch other stacks.
for group in "$name-rg" "$name-rg-infra"; do
  exists=$(rows group exists --name "$group")
  [ "$exists" = true ] || continue
  found "resource group" "$group"
  out=$(rows resource list --resource-group "$group" --query "[].[type, name]")
  while IFS=$'\t' read -r type item; do
    [ -z "$item" ] || found "$type" "$item (resource group $group)"
  done <<<"$out"
done

# The deleted-workspace list spans the subscription; only one whose ID names
# this stack's group is ours. Azure IDs vary in case.
out=$(rows monitor log-analytics workspace list-deleted-workspaces \
  --query "[?name == '$name-logs'].id")
for id in $out; do
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$id")
  [[ $lower != */resourcegroups/"$name"-rg/* ]] || found "soft-deleted Log Analytics workspace" "$id"
done

[ "$left" = 1 ] || echo "Nothing left for $name"
exit "$left"

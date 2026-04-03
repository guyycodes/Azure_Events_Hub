#!/usr/bin/env bash
# ============================================================================
# Azure Event-Driven Demo — Delete All Resources
#
# This deletes the entire resource group and everything in it.
# There is no undo. All data will be lost.
#
# Usage:
#   bash scripts/cleanup.sh rg-eventdemo-yourname0403
# ============================================================================

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: bash scripts/cleanup.sh <RESOURCE_GROUP_NAME>"
    echo ""
    echo "Example: bash scripts/cleanup.sh rg-eventdemo-mbeals0403"
    exit 1
fi

RESOURCE_GROUP="$1"

echo "This will DELETE the resource group: $RESOURCE_GROUP"
echo "and ALL resources inside it (Event Hub, SQL, Storage, Functions)."
echo ""
read -p "Type the resource group name to confirm: " CONFIRM

if [ "$CONFIRM" != "$RESOURCE_GROUP" ]; then
    echo "Names don't match. Aborting."
    exit 1
fi

echo ">>> Deleting resource group: $RESOURCE_GROUP ..."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

echo ""
echo "Deletion started (runs in background, takes 2-5 minutes)."
echo "Verify with: az group show --name $RESOURCE_GROUP"
echo "When done, you'll see a 'not found' error — that means it's deleted."

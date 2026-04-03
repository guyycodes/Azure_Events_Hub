#!/usr/bin/env bash
# ============================================================================
# Azure Event-Driven Demo — Provision All Resources
#
# Usage:
#   1. Edit the SUFFIX variable below (must be globally unique)
#   2. Run: bash scripts/provision.sh
#
# This script is meant to be READ and understood, not blindly executed.
# Each section matches a step in GUIDE.md.
# ============================================================================

set -euo pipefail

# ---------- EDIT THIS ----------
SUFFIX="yourname$(date +%m%d)"   # e.g. "mbeals0403"
# -------------------------------

RESOURCE_GROUP="rg-eventdemo-${SUFFIX}"
LOCATION="eastus"

EVENTHUB_NAMESPACE="ehns-eventdemo-${SUFFIX}"
EVENTHUB_NAME="eh-events"
CONSUMER_GROUP="\$Default"   # Basic tier only supports $Default

SQL_SERVER="sql-eventdemo-${SUFFIX}"
SQL_DB="sqldb-eventdemo"
SQL_ADMIN_USER="sqladmin"
SQL_ADMIN_PASS="P@ssw0rd$(date +%s | tail -c 5)!"

STORAGE_ACCOUNT="stevt${SUFFIX}"   # max 24 chars, no hyphens, lowercase only
FUNCTION_APP="func-eventdemo-${SUFFIX}"

echo "========================================="
echo "  SAVE THESE VALUES"
echo "========================================="
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  SQL Password:    $SQL_ADMIN_PASS"
echo "  Event Hub NS:    $EVENTHUB_NAMESPACE"
echo "  SQL Server:      $SQL_SERVER"
echo "  Function App:    $FUNCTION_APP"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "========================================="
echo ""

# ---- 1. Resource Group ----
echo ">>> Creating Resource Group..."
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --output none

# ---- 2. Event Hubs Namespace + Hub + Consumer Group ----
echo ">>> Creating Event Hubs Namespace (this starts billing ~\$0.015/hr)..."
az eventhubs namespace create \
  --name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Basic \
  --output none

echo ">>> Creating Event Hub..."
az eventhubs eventhub create \
  --name $EVENTHUB_NAME \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --partition-count 1 \
  --cleanup-policy Delete \
  --retention-time 24 \
  --output none

# Consumer group: Basic tier only has $Default (no create needed).
# Standard tier would let you create custom groups per consumer.

EVENTHUB_CONN_STR=$(az eventhubs namespace authorization-rule keys list \
  --name RootManageSharedAccessKey \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --query primaryConnectionString \
  --output tsv)

# ---- 3. Azure SQL Server + Database ----
echo ">>> Registering Microsoft.Sql provider (one-time)..."
az provider register --namespace Microsoft.Sql --wait

echo ">>> Creating SQL Server..."
az sql server create \
  --name $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --admin-user $SQL_ADMIN_USER \
  --admin-password $SQL_ADMIN_PASS \
  --output none

echo ">>> Creating SQL Database (Serverless, auto-pauses after 60 min)..."
az sql db create \
  --name $SQL_DB \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --edition GeneralPurpose \
  --compute-model Serverless \
  --family Gen5 \
  --capacity 1 \
  --min-capacity 0.5 \
  --auto-pause-delay 60 \
  --output none

echo ">>> Setting firewall rules..."
MY_IP=$(curl -s -4 ifconfig.me)  # -4 forces IPv4 (Azure SQL firewall rejects IPv6)

az sql server firewall-rule create \
  --name AllowMyIP \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP \
  --output none

az sql server firewall-rule create \
  --name AllowAzureServices \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 \
  --output none

# ---- 4. Storage Account ----
echo ">>> Registering Microsoft.Storage provider (one-time)..."
az provider register --namespace Microsoft.Storage --wait

echo ">>> Creating Storage Account..."
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --output none

STORAGE_CONN_STR=$(az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query connectionString \
  --output tsv)

# ---- 5. Function App ----
echo ">>> Registering Microsoft.Web provider (one-time)..."
az provider register --namespace Microsoft.Web --wait

echo ">>> Creating Function App (Consumption plan, Node 24)..."
az functionapp create \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT \
  --consumption-plan-location $LOCATION \
  --runtime node \
  --runtime-version 24 \
  --functions-version 4 \
  --os-type Linux \
  --output none

echo ">>> Configuring App Settings..."
az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --settings \
    "EventHubConnection=$EVENTHUB_CONN_STR" \
    "SQL_SERVER=${SQL_SERVER}.database.windows.net" \
    "SQL_DATABASE=$SQL_DB" \
    "SQL_USER=$SQL_ADMIN_USER" \
    "SQL_PASSWORD=$SQL_ADMIN_PASS" \
  --output none

# ---- Done ----
echo ""
echo "========================================="
echo "  ALL RESOURCES CREATED SUCCESSFULLY"
echo "========================================="
echo ""
echo "Paste these into event-driven-functions/local.settings.json:"
echo ""
echo "  AzureWebJobsStorage:  $STORAGE_CONN_STR"
echo "  EventHubConnection:   $EVENTHUB_CONN_STR"
echo "  SQL_SERVER:           ${SQL_SERVER}.database.windows.net"
echo "  SQL_DATABASE:         $SQL_DB"
echo "  SQL_USER:             $SQL_ADMIN_USER"
echo "  SQL_PASSWORD:         $SQL_ADMIN_PASS"
echo ""
echo "Next steps:"
echo "  1. Update local.settings.json with the values above"
echo "  2. Create the SQL table:  See GUIDE.md Step 5"
echo "  3. Build and test locally: cd event-driven-functions && npm install && npm start"
echo "========================================="

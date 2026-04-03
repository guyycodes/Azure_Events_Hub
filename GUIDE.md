# Azure Event-Driven System — Hands-On Guide

## What We're Building

```
curl POST /publishEvent
         │
         ▼
┌──────────────────┐
│  publishEvent    │  HTTP trigger → publishes to Event Hub
│  Azure Function  │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Azure Event Hub │  Managed event streaming service
└────────┬─────────┘
         │ triggers
         ▼
┌──────────────────┐
│  processEvent    │  Event Hub trigger → writes to SQL
│  Azure Function  │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   Azure SQL      │  Serverless relational database
└────────┬─────────┘
         │
         ▼
curl GET /queryData → returns rows from events table
```

Three Azure Functions, one Event Hub, one SQL database. Simple event-driven pipeline.

---

## Step 1: Environment Setup

### Install Prerequisites

```bash
# 1. Node.js 18 LTS (Azure Functions v4 runtime requires Node 18 or 20)
node --version
# If you need it: https://nodejs.org or use nvm:
#   nvm install 18

# 2. Azure CLI — the command-line tool for managing Azure resources
#    (AWS equivalent: aws cli | GCP equivalent: gcloud cli)
brew install azure-cli
az --version

# 3. Azure Functions Core Tools v4 — local runtime/emulator for Functions
#    This lets you run and debug Functions on your laptop before deploying.
#    There's no AWS Lambda equivalent — with Lambda you use SAM or test in the cloud.
brew tap azure/functions
brew install azure-functions-core-tools@4
func --version

# 4. (Optional) SQL command-line tool for running SQL directly
#    You can also use the Azure Portal query editor instead.
brew install sqlcmd
```

### Create an Azure Free Account

If you don't have one:
1. Go to https://azure.microsoft.com/free/
2. You get **$200 credit for 30 days** + **12 months of free services**
3. A credit card is required for identity verification but you won't be charged unless you explicitly upgrade
4. Free tier includes: Azure Functions (1M executions/month), 250 GB SQL storage

### Log In via CLI

```bash
# Opens a browser for OAuth login
az login

# Verify you're logged in and see your subscription
az account show --output table

# If you have multiple subscriptions, pick the right one:
# az account set --subscription "YOUR_SUBSCRIPTION_NAME_OR_ID"
```

**Verify before moving on:** `az account show` prints your subscription name and state = "Enabled".

---

## Step 2: Provision Azure Resources

### Cost Breakdown — Read This First

| Resource | SKU | Cost |
|----------|-----|------|
| Resource Group | N/A | **Free** (just a logical container) |
| Event Hubs Namespace | Basic tier | **~$0.015/hr ≈ $11/month** ⚠️ |
| Event Hub | 1 partition | Included in namespace price |
| Azure SQL Database | Serverless, Gen5 | **Auto-pauses after 60 min idle → $0 when paused** ⚠️ |
| Storage Account | Standard LRS | **Pennies/month** for our volume |
| Function App | Consumption plan | **Free** (first 1M exec/month) |

**Bottom line:** If you work through this exercise and delete everything within a few hours, total cost is **well under $1**. The Event Hubs namespace is the main cost driver — delete it when done.

### Understand the Resource Hierarchy

```
Azure Subscription (your billing account)
  └── Resource Group (logical folder — groups related resources for lifecycle management)
        ├── Event Hubs Namespace (the server/cluster — this is the billing unit)
        │     └── Event Hub (a single stream/topic inside the namespace)
        │           └── Consumer Group (an independent reader position on the stream)
        ├── SQL Server (logical management endpoint — holds logins + firewall rules, no compute)
        │     └── SQL Database (actual compute + storage lives here)
        ├── Storage Account (blob/file storage — Azure Functions needs this internally)
        └── Function App (the compute host that runs your function code)
```

**Cloud mapping cheat sheet:**

| Concept | Azure | AWS | GCP |
|---------|-------|-----|-----|
| Resource folder | Resource Group | (tags / CloudFormation stack) | Project |
| Event stream | Event Hub | Kinesis Data Stream | Pub/Sub |
| Serverless SQL | Azure SQL Serverless | Aurora Serverless | Cloud SQL |
| Serverless functions | Azure Functions | Lambda | Cloud Functions |
| Blob storage | Storage Account | S3 | Cloud Storage |

### Set Shell Variables

Run this block to set all the names we'll use. Everything flows from `SUFFIX` to keep names globally unique.

```bash
# Unique suffix to avoid Azure global naming conflicts
SUFFIX="mbeals0403$(date +%m%d)"

RESOURCE_GROUP="rg-eventdemo-${SUFFIX}"
LOCATION="eastus"

# Event Hubs
EVENTHUB_NAMESPACE="ehns-even
CONSUMER_GROUP="\$Default"   # Basic tier only supports $Default (custom groups need Standard)

# SQL
SQL_SERVER="sql-eventdemo-${SUFFIX}"
SQL_DB="sqldb-eventdemo"
SQL_ADMIN_USER="sqladmin"
SQL_ADMIN_PASS="P@ssw0rd$(date +%s | tail -c 5)!"   # semi-random; save this

# Storage + Function App
STORAGE_ACCOUNT="stevt${SUFFIX}"   # no hyphens, max 24 chars, lowercase only
FUNCTION_APP="func-eventdemo-${SUFFIX}"

echo "-------- SAVE THESE VALUES --------"
echo "Resource Group:  $RESOURCE_GROUP" # rg-eventdemo-mbeals04030403
echo "SQL Password:    $SQL_ADMIN_PASS" # P@ssw0rd9364
echo "Event Hub NS:    $EVENTHUB_NAMESPACE" # ehns-eventdemo-mbeals04030403
echo "SQL Server:      $SQL_SERVER" # sql-eventdemo-mbeals04030403
echo "-----------------------------------"
```

> **Tip:** You can also run `scripts/provision.sh` which wraps all of these commands. But run them one-by-one first to understand what each does.

### 2.1 — Create the Resource Group

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION
```

A Resource Group is just a logical container. No compute, no cost. Its purpose is lifecycle management — when you delete the group, everything inside gets deleted too. That's how we'll clean up in Step 8.

```bash
# Verify:
az group show --name $RESOURCE_GROUP --output table
```

### 2.2 — Create Event Hubs Namespace + Event Hub

The **namespace** is the billing unit and network endpoint — think of it as a Kafka cluster. The **event hub** is a specific topic/stream inside that cluster.

```bash
# ⚠️ This starts billing (~$0.015/hr on Basic tier)
az eventhubs namespace create \
  --name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Basic
```

```bash
# Create the event hub (a single stream).
# --partition-count 1: Partitions are parallelism units. 1 is the minimum for Basic.
#   In production you'd use more partitions for throughput (like Kafka partitions).
# --cleanup-policy Delete: Required when setting retention. (Alternative: Compact, for log compaction on Standard+)
# --retention-time 24: Keep messages for 24 hours (Basic tier max is 24 hours / 1 day).
az eventhubs eventhub create \
  --name $EVENTHUB_NAME \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --partition-count 1 \
  --cleanup-policy Delete \
  --retention-time 24
```

```bash
# CONSUMER GROUPS: An independent "cursor" into the stream. Each consumer group
# tracks its own position (offset). Same concept as Kafka consumer groups.
# tracks its own position (offset). The $Default group always exists, but best
# practice is one consumer group per logical consumer.
#
# On Basic tier, you can ONLY use the built-in $Default consumer group.
# Custom consumer groups require Standard tier or higher.
# For this exercise, $Default is all we need. In production with multiple
# consumers, you'd use Standard tier and create one group per consumer.
#
# (No command needed — $Default already exists.)
# az eventhubs eventhub consumer-group create \
#   --name $CONSUMER_GROUP \
#   --eventhub-name $EVENTHUB_NAME \
#   --namespace-name $EVENTHUB_NAMESPACE \
#   --resource-group $RESOURCE_GROUP


```

```bash
# Get the connection string — you'll paste this into local.settings.json.
# This uses the default "RootManageSharedAccessKey" policy (full access).
# In production you'd create separate send-only and listen-only policies.
EVENTHUB_CONN_STR=$(az eventhubs namespace authorization-rule keys list \
  --name RootManageSharedAccessKey \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --query primaryConnectionString \
  --output tsv)

echo "Event Hub Connection String:"
echo "$EVENTHUB_CONN_STR"
```

```bash
# Verify the hub exists:
az eventhubs eventhub show \
  --name $EVENTHUB_NAME \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --output table
```

### 2.3 — Create Azure SQL Server + Database

```bash
# First time using SQL in this subscription? You need to register the provider.
# This is a one-time operation — Azure requires explicit opt-in per service type.
# Takes ~1-2 minutes. If already registered, this returns immediately.
az provider register --namespace Microsoft.Sql --wait
```

```bash
# LOGICAL SERVER: A management endpoint that holds credentials and firewall rules.
# No compute is allocated yet — the server itself is free.
az sql server create \
  --name $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --admin-user $SQL_ADMIN_USER \
  --admin-password $SQL_ADMIN_PASS
```

```bash
# DATABASE: This is where actual compute + storage lives.
# --compute-model Serverless: CPU scales automatically AND auto-pauses after idle.
#   When paused, you pay only for storage (~$5/month for 1 GB). When active, you
#   pay per vCore-second. This is the cheapest option for development.
# --auto-pause-delay 60: Pause after 60 minutes of inactivity.
# ⚠️ First query after pause takes ~60 seconds (cold start while it resumes).
az sql db create \
  --name $SQL_DB \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --edition GeneralPurpose \
  --compute-model Serverless \
  --family Gen5 \
  --capacity 1 \
  --min-capacity 0.5 \
  --auto-pause-delay 60
```

```bash
# FIREWALL RULES: Azure SQL blocks ALL connections by default.

# Allow YOUR local IP (for development):
# -4 forces IPv4 — Azure SQL firewall doesn't accept IPv6 addresses.
MY_IP=$(curl -s -4 ifconfig.me)
echo "Your IP: $MY_IP"

az sql server firewall-rule create \
  --name AllowMyIP \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP

# Allow Azure services (so your deployed Function App can reach SQL).
# The 0.0.0.0 range is a special Azure convention meaning "allow Azure-internal traffic".
az sql server firewall-rule create \
  --name AllowAzureServices \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0
```

```bash
# Verify:
az sql db show --name $SQL_DB --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP --output table
```

### 2.4 — Create Storage Account

```bash
# Register the provider (one-time, same as Microsoft.Sql above)
az provider register --namespace Microsoft.Storage --wait
```

```bash
# Azure Functions REQUIRES a Storage Account to store:
# - Function metadata and code (when deployed)
# - Trigger state (Event Hub checkpoints — "where did I last read?")
# - Logs and diagnostics
# This is like Lambda needing S3 behind the scenes, except you manage it explicitly.

az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS   # Locally redundant = cheapest option

STORAGE_CONN_STR=$(az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query connectionString \
  --output tsv)

echo "Storage Connection String:"
echo "$STORAGE_CONN_STR"
```

### 2.5 — Create Function App

```bash
# Register the provider (one-time per subscription)
az provider register --namespace Microsoft.Web --wait
```

```bash
# The Function App is the compute host. It's where your code runs.
#
# --consumption-plan-location: Uses the Consumption (serverless) plan.
#   → Scale to zero when idle (no cost)
#   → Scale out automatically under load
#   → First 1,000,000 executions per month are FREE
#   → Max execution time: 10 minutes (default 5)
#   → This is the closest equivalent to AWS Lambda's pricing model.
#
# --runtime node --runtime-version 20: Node.js 24 runtime
# --functions-version 4: Azure Functions v4 (current major version)

az functionapp create \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT \
  --consumption-plan-location $LOCATION \
  --runtime node \
  --runtime-version 24 \
  --functions-version 4 \
  --os-type Linux
```

```bash
# Configure app settings.
# These become environment variables available to your Function code.
# This is Azure's equivalent of Lambda environment variables or SSM Parameter Store.

az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --settings \
    "EventHubConnection=$EVENTHUB_CONN_STR" \
    "SQL_SERVER=${SQL_SERVER}.database.windows.net" \
    "SQL_DATABASE=$SQL_DB" \
    "SQL_USER=$SQL_ADMIN_USER" \
    "SQL_PASSWORD=$SQL_ADMIN_PASS"
```

```bash
# Verify everything was created:
az resource list --resource-group $RESOURCE_GROUP --output table

# You should see 5-6 resources:
#  - Event Hubs Namespace
#  - SQL Server
#  - SQL Database
#  - Storage Account
#  - Function App
#  - App Service Plan (auto-created by the consumption plan)
```

**Checkpoint:** All Azure resources are provisioned. Save your connection strings and password — you'll need them in the next step.

---

## Step 3: Project Setup

### Initialize the Project

```bash
# Create a new Azure Functions project with TypeScript and the v4 programming model.
# The v4 model is the latest — functions are registered in code (no function.json files).
cd /path/to/Azure_hands_on

func init event-driven-functions --typescript --model V4

cd event-driven-functions
```

This creates the scaffolding: `package.json`, `tsconfig.json`, `host.json`, `local.settings.json`, and `.gitignore`.

### Install Dependencies

```bash
# @azure/event-hubs: SDK to PRODUCE events (used by publishEvent)
# mssql: SQL Server client library (used by processEvent and queryData)
npm install @azure/event-hubs mssql

# Type definitions for mssql (TypeScript needs these for autocomplete/checking)
npm install -D @types/mssql
```

> **Why `@azure/event-hubs` for producing but not consuming?** The consumer (processEvent) uses a built-in **trigger binding** — the Azure Functions runtime handles the Event Hub connection, checkpointing, and delivery. You only need the SDK when you want to do something the runtime doesn't handle for you (like producing events).

### Project Structure

After setup, your project should look like this:

```
event-driven-functions/
├── src/
│   └── functions/
│       ├── publishEvent.ts    ← YOU CREATE THIS (Step 4)
│       ├── processEvent.ts    ← YOU CREATE THIS (Step 4)
│       └── queryData.ts       ← YOU CREATE THIS (Step 4)
├── package.json               ← Created by func init + npm install
├── tsconfig.json              ← Created by func init
├── host.json                  ← Created by func init
├── local.settings.json        ← YOU EDIT THIS (below)
└── .gitignore
```

### Configure local.settings.json

This file holds your secrets for local development. It's `.gitignore`d by default (never commit secrets).

Open `local.settings.json` and replace its contents with:

```json
{
  "IsEncrypted": false,
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "AzureWebJobsStorage": "<PASTE_STORAGE_CONN_STR_HERE>",
    "EventHubConnection": "<PASTE_EVENTHUB_CONN_STR_HERE>",
    "SQL_SERVER": "<YOUR_SQL_SERVER>.database.windows.net",
    "SQL_DATABASE": "sqldb-eventdemo",
    "SQL_USER": "sqladmin",
    "SQL_PASSWORD": "<YOUR_SQL_PASSWORD>"
  }
}
```

Replace the `<...>` placeholders with the actual values you saved from Step 2.

**How this works:**
- `local.settings.json` is for **local development only**. It's never deployed.
- When deployed, these values come from **App Settings** (configured in Step 2.5).
- The Functions runtime reads these values and exposes them as `process.env.KEY_NAME`.
- `AzureWebJobsStorage` is special — the runtime uses it internally for trigger state management.
- `EventHubConnection` is referenced by name in the Event Hub trigger binding.

---

## Step 4: Implement the Functions

### 4.1 — publishEvent (HTTP Trigger → Event Hub)

Create `src/functions/publishEvent.ts`:

```typescript
import { app, HttpRequest, HttpResponseInit, InvocationContext } from '@azure/functions';
import { EventHubProducerClient } from '@azure/event-hubs';

// Reuse the producer across invocations (connection pooling).
// In the Consumption plan, the host can be recycled at any time, but while
// it's alive, this singleton avoids reconnecting on every request.
let producer: EventHubProducerClient | null = null;

function getProducer(): EventHubProducerClient {
    if (!producer) {
        const connectionString = process.env.EventHubConnection;
        if (!connectionString) {
            throw new Error('EventHubConnection is not configured');
        }
        // Second arg is the specific event hub name within the namespace
        producer = new EventHubProducerClient(connectionString, 'eh-events');
    }
    return producer;
}

async function handler(
    request: HttpRequest,
    context: InvocationContext
): Promise<HttpResponseInit> {
    context.log('publishEvent: received request');

    let body: Record<string, unknown>;
    try {
        body = (await request.json()) as Record<string, unknown>;
    } catch {
        return { status: 400, jsonBody: { error: 'Request body must be valid JSON' } };
    }

    const eventType = (body.eventType as string) || 'unknown';
    const payload = body.payload ?? body;

    try {
        const client = getProducer();
        // A batch groups one or more events into a single send call.
        // Events in a batch go to the same partition (efficient for throughput).
        const batch = await client.createBatch();
        batch.tryAdd({
            body: { eventType, payload, publishedAt: new Date().toISOString() },
        });
        await client.sendBatch(batch);

        context.log(`publishEvent: sent event type="${eventType}"`);
        return {
            status: 200,
            jsonBody: { success: true, message: `Event "${eventType}" published` },
        };
    } catch (error) {
        context.error('publishEvent failed:', error);
        return {
            status: 500,
            jsonBody: { error: error instanceof Error ? error.message : 'Unknown error' },
        };
    }
}

// Register the function with the v4 runtime.
// authLevel: 'anonymous' means no API key needed (fine for dev, lock down in prod).
app.http('publishEvent', {
    methods: ['POST'],
    authLevel: 'anonymous',
    handler,
});
```

**Key concepts:**
- `EventHubProducerClient` is the SDK class for sending events. You create it once and reuse it.
- Events are sent in **batches** (even if just one event). This is the SDK's design — it handles serialization and partition assignment.
- The `connection string` contains the namespace endpoint and auth key. The event hub name is passed as a separate argument.
- `app.http(...)` replaces the old `function.json` binding config from v3. Everything is in code now.

### 4.2 — processEvent (Event Hub Trigger → Azure SQL)

Create `src/functions/processEvent.ts`:

```typescript
import { app, InvocationContext } from '@azure/functions';
import * as sql from 'mssql';

// Connection pool — reused across invocations while the host is alive.
let pool: sql.ConnectionPool | null = null;

async function getPool(): Promise<sql.ConnectionPool> {
    if (!pool) {
        pool = await sql.connect({
            server: process.env.SQL_SERVER!,
            database: process.env.SQL_DATABASE!,
            user: process.env.SQL_USER!,
            password: process.env.SQL_PASSWORD!,
            port: 1433,
            options: {
                encrypt: true,               // required for Azure SQL
                trustServerCertificate: false,
            },
        });
    }
    return pool;
}

// Handler receives an array because cardinality is 'many' (batch mode).
// The Functions runtime delivers events in batches for efficiency.
async function handler(
    messages: unknown[],
    context: InvocationContext
): Promise<void> {
    context.log(`processEvent: received batch of ${messages.length} event(s)`);

    const db = await getPool();

    for (const message of messages) {
        const event = message as {
            eventType?: string;
            payload?: unknown;
            publishedAt?: string;
        };
        const eventType = event.eventType || 'unknown';
        const payload = JSON.stringify(event.payload ?? event);

        context.log(`processEvent: writing event type="${eventType}"`);

        // Parameterized query prevents SQL injection
        await db
            .request()
            .input('eventType', sql.NVarChar(100), eventType)
            .input('payload', sql.NVarChar(sql.MAX), payload)
            .input('receivedAt', sql.DateTime2, new Date())
            .query(`
                INSERT INTO events (event_type, payload, received_at)
                VALUES (@eventType, @payload, @receivedAt)
            `);
    }

    context.log(`processEvent: wrote ${messages.length} event(s) to SQL`);
}

// Register the Event Hub trigger.
// 'connection' is the APP SETTING NAME (not the connection string itself).
// The runtime reads process.env.EventHubConnection to get the actual string.
app.eventHub('processEvent', {
    connection: 'EventHubConnection',
    eventHubName: 'eh-events',
    // consumerGroup: 'func-consumer', // Basic tier only supports $Default (custom groups need Standard)
    consumerGroup: '$Default',
    cardinality: 'many',
    handler,
});
```

**Key concepts:**
- **Trigger binding vs SDK:** Here we DON'T use `@azure/event-hubs`. The Functions runtime manages the connection, reads events, and tracks checkpoints (offsets) automatically. Your code just receives the messages.
- **Cardinality `'many'`:** The runtime delivers events in batches for efficiency. Your handler gets an array. With `'one'`, you'd get a single event per invocation.
- **Checkpointing:** After your handler returns successfully, the runtime saves the checkpoint (current offset) to the Storage Account. If the function fails, it retries from the last checkpoint. This is similar to Kafka consumer offset commits.
- **Connection pooling:** The `mssql` pool is created once and reused. Azure Functions can recycle the host process at any time (especially on Consumption plan), so the pool will be recreated when that happens.
- **`connection: 'EventHubConnection'`** is a reference to an app setting name, not the connection string value. This indirection lets you change the connection without redeploying code.

### 4.3 — queryData (HTTP Trigger → SQL Read)

Create `src/functions/queryData.ts`:

```typescript
import { app, HttpRequest, HttpResponseInit, InvocationContext } from '@azure/functions';
import * as sql from 'mssql';

let pool: sql.ConnectionPool | null = null;

async function getPool(): Promise<sql.ConnectionPool> {
    if (!pool) {
        pool = await sql.connect({
            server: process.env.SQL_SERVER!,
            database: process.env.SQL_DATABASE!,
            user: process.env.SQL_USER!,
            password: process.env.SQL_PASSWORD!,
            port: 1433,
            options: {
                encrypt: true,
                trustServerCertificate: false,
            },
        });
    }
    return pool;
}

async function handler(
    request: HttpRequest,
    context: InvocationContext
): Promise<HttpResponseInit> {
    context.log('queryData: received request');

    try {
        const db = await getPool();

        // Optional query params for filtering
        const eventType = request.query.get('eventType');
        const limit = Math.min(parseInt(request.query.get('limit') || '50', 10), 500);

        let query = 'SELECT TOP (@limit) id, event_type, payload, received_at FROM events';
        const dbRequest = db.request().input('limit', sql.Int, limit);

        if (eventType) {
            query += ' WHERE event_type = @eventType';
            dbRequest.input('eventType', sql.NVarChar(100), eventType);
        }

        query += ' ORDER BY received_at DESC';

        const result = await dbRequest.query(query);

        return {
            status: 200,
            jsonBody: { count: result.recordset.length, events: result.recordset },
        };
    } catch (error) {
        context.error('queryData failed:', error);
        return {
            status: 500,
            jsonBody: { error: error instanceof Error ? error.message : 'Unknown error' },
        };
    }
}

app.http('queryData', {
    methods: ['GET'],
    authLevel: 'anonymous',
    handler,
});
```

**Key concepts:**
- This is a straightforward HTTP → SQL read. Parameterized queries prevent injection.
- `request.query.get('eventType')` reads URL query parameters (e.g., `/api/queryData?eventType=order.created`).
- `TOP (@limit)` caps results to prevent accidentally returning millions of rows.
- In production, you'd add pagination (offset/cursor) and proper authentication.

### How Secrets Flow

```
LOCAL DEVELOPMENT:
  local.settings.json  →  process.env.SQL_SERVER  →  your code reads it

DEPLOYED TO AZURE:
  App Settings (configured via az CLI or Portal)  →  process.env.SQL_SERVER  →  same code

Your code always reads process.env — it doesn't know or care where the value came from.
```

---

## Step 5: Create the SQL Table

Before events can be written, the `events` table must exist.

### The SQL

```sql
-- Create the events table
**Easiest way — use the Azure Portal:**

1. Go to https://portal.azure.com
2. Search for sqldb-eventdemo in the top search bar
3. Click Query editor in the left sidebar
4. Log in: sqladmin / your password (P@ssw0rd9364)
5. Paste and run:

```sql
CREATE TABLE events (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    event_type  NVARCHAR(100)     NOT NULL,
    payload     NVARCHAR(MAX)     NOT NULL,
    received_at DATETIME2         NOT NULL
);

CREATE INDEX IX_events_event_type ON events (event_type);
CREATE INDEX IX_events_received_at ON events (received_at DESC);
```

**Or from your terminal (since your IP is in the firewall) from inside /event-driven-functions directory:**

```bash
sqlcmd -S "sql-eventdemo-mbeals04030403.database.windows.net" \
       -d sqldb-eventdemo \
       -U sqladmin \
       -P "$SQL_ADMIN_PASS" \
       -i ../scripts/setup-sql.sql
```

**This is what processEvent writes to and queryData reads from.**

```sql
-- This is what processEvent writes to and queryData reads from.
CREATE TABLE events (
    id          INT IDENTITY(1,1) PRIMARY KEY,  -- auto-increment ID
    event_type  NVARCHAR(100)     NOT NULL,      -- e.g. "order.created"
    payload     NVARCHAR(MAX)     NOT NULL,      -- JSON payload (stored as string)
    received_at DATETIME2         NOT NULL        -- when the function processed it
);

-- Index for filtering by event_type (queryData supports ?eventType=...)
CREATE INDEX IX_events_event_type ON events (event_type);

-- Index for ordering by time (queryData sorts by received_at DESC)
CREATE INDEX IX_events_received_at ON events (received_at DESC);
```

This SQL is also saved in `scripts/setup-sql.sql`.

### How to Run It

**Option A: Azure Portal (easiest)**

1. Go to https://portal.azure.com
2. Navigate to your SQL Database (search for `sqldb-eventdemo` in the search bar)
3. Click **Query editor** in the left sidebar
4. Log in with your SQL admin credentials (`sqladmin` / your password)
5. Paste the SQL above and click **Run**

**Option B: sqlcmd CLI**

```bash
sqlcmd -S "${SQL_SERVER}.database.windows.net" \
       -d $SQL_DB \
       -U $SQL_ADMIN_USER \
       -P $SQL_ADMIN_PASS \
       -i scripts/setup-sql.sql
```

**Option C: From Node.js** (if sqlcmd isn't installed)

```bash
cd event-driven-functions
npx ts-node -e "
const sql = require('mssql');
async function run() {
    await sql.connect({
        server: '${SQL_SERVER}.database.windows.net',
        database: '${SQL_DB}',
        user: '${SQL_ADMIN_USER}',
        password: '${SQL_ADMIN_PASS}',
        port: 1433,
        options: { encrypt: true, trustServerCertificate: false },
    });
    await sql.query\`
        CREATE TABLE events (
            id INT IDENTITY(1,1) PRIMARY KEY,
            event_type NVARCHAR(100) NOT NULL,
            payload NVARCHAR(MAX) NOT NULL,
            received_at DATETIME2 NOT NULL
        );
        CREATE INDEX IX_events_event_type ON events (event_type);
        CREATE INDEX IX_events_received_at ON events (received_at DESC);
    \`;
    console.log('Table created!');
    process.exit(0);
}
run().catch(err => { console.error(err); process.exit(1); });
"
```

**Verify:** Run `SELECT COUNT(*) FROM events;` — it should return 0.


**or Verify by running:**

```bash
sqlcmd -S "sql-eventdemo-mbeals04030403.database.windows.net" \
       -d sqldb-eventdemo \
       -U sqladmin \
       -P "$SQL_ADMIN_PASS" \
       -Q "SELECT COUNT(*) FROM events;"
```

> **Note:** If your SQL database has auto-paused, the first connection takes ~30-60 seconds while Azure resumes it. This is normal.

---

## Step 6: Test Locally

### Build and Start the Functions

```bash
cd event-driven-functions

# Compile TypeScript → JavaScript
npm run build

# Start the local Functions runtime
npm run start
# Or equivalently: func start
```

You should see output like:

```
Azure Functions Core Tools
...
Functions:
        publishEvent: [POST] http://localhost:7071/api/publishEvent
        processEvent: eventHubTrigger
        queryData: [GET] http://localhost:7071/api/queryData
```

**Important:** Even though you're running locally, the functions connect to the REAL Azure Event Hub and REAL Azure SQL. There's no local emulator for Event Hubs. Your `local.settings.json` connection strings point to the cloud resources.

### Test the Pipeline

Open a new terminal and run these commands:

**1. Publish an event:**

```bash
curl -X POST http://localhost:7071/api/publishEvent \
  -H "Content-Type: application/json" \
  -d '{"eventType": "order.created", "payload": {"orderId": "ORD-001", "amount": 99.99}}'
```

Expected response:

```json
{"success": true, "message": "Event \"order.created\" published"}
```

**2. Wait a few seconds for processEvent to fire.**

Watch the terminal where `func start` is running. You should see log lines like:

```
processEvent: received batch of 1 event(s)
processEvent: writing event type="order.created"
processEvent: wrote 1 event(s) to SQL
```

> **If you don't see processEvent fire:** Give it 10-15 seconds. The Event Hub trigger has a polling interval. Also check that your `EventHubConnection` in `local.settings.json` is correct.

> **If SQL connection fails:** Make sure your IP firewall rule is set (Step 2.3) and the database isn't paused (first connection after pause takes ~60s).

**3. Query the data:**

```bash
curl http://localhost:7071/api/queryData
```

Expected response:

```json
{
  "count": 1,
  "events": [
    {
      "id": 1,
      "event_type": "order.created",
      "payload": "{\"orderId\":\"ORD-001\",\"amount\":99.99}",
      "received_at": "2025-04-03T..."
    }
  ]
}
```

**4. Send a few more events and query with filters:**

```bash
# Send different event types
curl -X POST http://localhost:7071/api/publishEvent \
  -H "Content-Type: application/json" \
  -d '{"eventType": "user.signup", "payload": {"userId": "U-42", "email": "test@example.com"}}'

curl -X POST http://localhost:7071/api/publishEvent \
  -H "Content-Type: application/json" \
  -d '{"eventType": "order.created", "payload": {"orderId": "ORD-002", "amount": 149.50}}'

# Wait a few seconds, then query with a filter
curl "http://localhost:7071/api/queryData?eventType=order.created"

# Limit results
curl "http://localhost:7071/api/queryData?limit=1"
```

**Checkpoint:** If all three curl commands work, your local system is fully functional. Press `Ctrl+C` to stop the local runtime.

---

## Step 7: Deploy to Azure

### Deploy the Function Code

```bash
cd event-driven-functions

# Build first (deploy sends compiled JS, not TypeScript source)
npm run build

# Deploy to your Function App in Azure.
# This zips your code and pushes it to the Function App.
func azure functionapp publish $FUNCTION_APP
```

This takes 1-2 minutes. When done, you'll see the deployed function URLs:

```
Functions in func-eventdemo-...:
    publishEvent - [POST] https://func-eventdemo-....azurewebsites.net/api/publishEvent
    processEvent - eventHubTrigger
    queryData - [GET] https://func-eventdemo-....azurewebsites.net/api/queryData
```

### Test in the Cloud

```bash
# Use the URLs from the deploy output (replace with your actual URL)
FUNC_URL="https://${FUNCTION_APP}.azurewebsites.net"

# 1. Publish an event
curl -X POST "${FUNC_URL}/api/publishEvent" \
  -H "Content-Type: application/json" \
  -d '{"eventType": "order.created", "payload": {"orderId": "CLOUD-001", "amount": 250.00}}'

# 2. Wait 10-15 seconds for processEvent to pick it up
sleep 15

# 3. Query the data
curl "${FUNC_URL}/api/queryData"
```

You should see both your local test events AND the new cloud event in the results.

### Check Logs

**Option A: Stream live logs from CLI**

```bash
func azure functionapp logstream $FUNCTION_APP
# Press Ctrl+C to stop streaming
```

**Option B: Azure Portal**

1. Go to https://portal.azure.com
2. Navigate to your Function App
3. Click **Functions** in the left sidebar → click a function name
4. Click **Monitor** → **Logs** tab
5. Or click **Log stream** in the Function App's left sidebar for live output

**Option C: Query logs via CLI**

```bash
# View recent invocations (requires Application Insights, which may be auto-enabled)
az monitor app-insights query \
  --app $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --analytics-query "traces | order by timestamp desc | take 20"
```

### Troubleshooting Deployment

| Problem | Solution |
|---------|----------|
| Functions don't appear after deploy | Wait 1-2 min, then run `az functionapp function list --name $FUNCTION_APP --resource-group $RESOURCE_GROUP` |
| processEvent doesn't fire | Check App Settings have `EventHubConnection` set: `az functionapp config appsettings list --name $FUNCTION_APP --resource-group $RESOURCE_GROUP` |
| SQL connection fails | Verify the AllowAzureServices firewall rule exists (Step 2.3) and SQL App Settings are correct |
| Cold start is slow | Normal for Consumption plan — first invocation after idle takes 5-30 seconds |

---

## Step 8: Cleanup

**Delete everything to stop all charges.** Deleting the resource group removes all resources inside it.

```bash
# This single command deletes EVERYTHING: Event Hub, SQL, Storage, Function App
az group delete --name $RESOURCE_GROUP --yes --no-wait

# Verify (may take a few minutes to fully delete):
az group show --name $RESOURCE_GROUP 2>&1 | head -5
# Should eventually return "Resource group ... could not be found"
```

The `--no-wait` flag returns immediately while deletion happens in the background. Full cleanup takes 2-5 minutes.

> **Why one command?** This is the power of Resource Groups. By putting all related resources in one group, cleanup is one operation. This is a common Azure pattern — one resource group per environment (dev, staging, prod) or per project.

---

## Bonus: When to Use What — Interview Talking Points

You can now confidently say:

> "I stood up Functions on a consumption plan for event-driven work, and I understand when App Service or AKS would be the better choice."

Here's the decision framework:

### Azure Functions (Consumption Plan) — What You Just Built

**Use when:**
- Event-driven workloads (HTTP triggers, queue/event triggers, timers)
- Spiky or unpredictable traffic (scales to zero, scales out automatically)
- Individual operations < 10 minutes
- You want zero infrastructure management
- Cost efficiency matters (pay only for what you use)

**Limitations:**
- Max execution time: 10 min (default 5 min)
- Cold starts: 1-10 seconds on Consumption plan
- No control over the underlying VM/container
- Stateless by design (no persistent local storage between invocations)
- Limited to supported trigger types

**AWS equivalent:** Lambda
**GCP equivalent:** Cloud Functions

### Azure App Service — When You Need More Control

**Use when:**
- Long-running HTTP services (web APIs, web apps)
- You need WebSockets, persistent connections
- Predictable, steady traffic (always-on is more cost-effective than per-invocation)
- You need more than 10 minutes of execution time
- You want to run containers but don't need orchestration
- Background jobs that run continuously (WebJobs)

**Key difference from Functions:** App Service runs continuously (you pay for the VM whether it's handling requests or not). Functions scale to zero.

**AWS equivalent:** Elastic Beanstalk, ECS on Fargate (loosely)
**GCP equivalent:** App Engine, Cloud Run

### Azure Kubernetes Service (AKS) — When You Need Full Control

**Use when:**
- Microservices architecture with many interdependent services
- You need fine-grained control over networking, scaling, and deployment
- Multi-container applications with sidecar patterns
- You need custom runtimes or system-level configurations
- Your team already knows Kubernetes
- Complex scheduling, service mesh, or traffic splitting requirements

**Trade-off:** Maximum flexibility but maximum operational overhead. You manage the cluster, nodes, networking, and upgrades.

**AWS equivalent:** EKS
**GCP equivalent:** GKE

### The Decision Flowchart

```
Is it event-driven (reacting to events/triggers)?
├── YES → Azure Functions (Consumption Plan)
│         └── Execution > 10 min? → Functions Premium Plan or Durable Functions
└── NO → Is it a web API or long-running service?
          ├── YES → How complex?
          │         ├── Simple/few services → App Service
          │         └── Many microservices, need orchestration → AKS
          └── NO → Batch processing?
                    ├── Short tasks → Functions + Timer trigger
                    └── Long/complex → Azure Container Instances or Azure Batch
```

### Functions Premium Plan — The Middle Ground

Worth mentioning: the **Functions Premium Plan** gives you:
- Pre-warmed instances (no cold starts)
- VNET integration (private networking)
- Unlimited execution time
- More powerful instances

It's still "functions-as-a-service" but without the Consumption plan limitations. You pay for always-on instances. Think of it as the bridge between Consumption and App Service.

---

## Quick Reference: All Shell Variables

For easy copy-paste if you need to resume in a new terminal:

```bash
SUFFIX="yourname0403"                              # CHANGE THIS to match what you used
RESOURCE_GROUP="rg-eventdemo-${SUFFIX}"
LOCATION="eastus"
EVENTHUB_NAMESPACE="ehns-eventdemo-${SUFFIX}"
EVENTHUB_NAME="eh-events"
# consumerGroup: 'func-consumer',
CONSUMER_GROUP="\$Default"   # Basic tier only supports $Default (custom groups need Standard)
SQL_SERVER="sql-eventdemo-${SUFFIX}"
SQL_DB="sqldb-eventdemo"
SQL_ADMIN_USER="sqladmin"
SQL_ADMIN_PASS="YOUR_PASSWORD_HERE"                # CHANGE THIS
STORAGE_ACCOUNT="stevt${SUFFIX}"
FUNCTION_APP="func-eventdemo-${SUFFIX}"
```

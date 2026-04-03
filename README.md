# Azure Event-Driven System — Implementation Walkthrough

An event-driven pipeline built on Azure using TypeScript Azure Functions, Event Hubs, and Azure SQL. This documents the full implementation from resource provisioning through local verification and cloud deployment.

## Architecture

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

Three Azure Functions, one Event Hub, one SQL database. An HTTP request enters the system, flows through an event stream, lands in a relational store, and is queryable via a second HTTP endpoint.

---

## Step 1: Environment Setup

### Prerequisites

```bash
# Node.js 18+ (Azure Functions v4 runtime)
node --version

# Azure CLI — manages Azure resources from the terminal
# (AWS equivalent: aws cli | GCP equivalent: gcloud cli)
brew install azure-cli
az --version

# Azure Functions Core Tools v4 — local runtime for Functions
# Enables running and debugging Functions locally before deploying
brew tap azure/functions
brew install azure-functions-core-tools@4
func --version

# (Optional) SQL Server CLI for running queries directly
brew install sqlcmd
```

### Azure Account

1. Sign up at https://azure.microsoft.com/free/
2. $200 credit for 30 days, plus 12 months of free-tier services
3. Credit card required for identity verification — no charges unless explicitly upgraded
4. Free tier includes Azure Functions (1M executions/month) and 250 GB SQL storage

### CLI Authentication

```bash
az login
az account show --output table

# If multiple subscriptions exist:
# az account set --subscription "YOUR_SUBSCRIPTION_NAME_OR_ID"
```

**Verify:** `az account show` should print the subscription name with state = "Enabled".

---

## Step 2: Provision Azure Resources

### Cost Summary

| Resource | SKU | Cost |
|----------|-----|------|
| Resource Group | N/A | **Free** — logical container only |
| Event Hubs Namespace | Basic | **~$0.015/hr (~$11/month)** |
| Event Hub | 1 partition | Included in namespace |
| Azure SQL Database | Serverless Gen5 | **Auto-pauses after idle → $0 when paused** |
| Storage Account | Standard LRS | **Pennies/month** at this volume |
| Function App | Consumption plan | **Free** — first 1M executions/month |

Completing this exercise and deleting resources within a few hours costs well under $1. The Event Hubs namespace is the primary cost driver.

### Resource Hierarchy

```
Azure Subscription
  └── Resource Group (logical container — lifecycle management boundary)
        ├── Event Hubs Namespace (billing unit / network endpoint)
        │     └── Event Hub (single stream/topic)
        │           └── Consumer Group (independent reader position)
        ├── SQL Server (management endpoint — credentials + firewall, no compute)
        │     └── SQL Database (compute + storage)
        ├── Storage Account (blob/file storage — required by Functions runtime)
        └── Function App (compute host for function code)
```

**Cross-cloud mapping:**

| Concept | Azure | AWS | GCP |
|---------|-------|-----|-----|
| Resource container | Resource Group | CloudFormation stack / tags | Project |
| Event stream | Event Hub | Kinesis Data Stream | Pub/Sub |
| Serverless SQL | Azure SQL Serverless | Aurora Serverless | Cloud SQL |
| Serverless functions | Azure Functions | Lambda | Cloud Functions |
| Object storage | Storage Account | S3 | Cloud Storage |

### Shell Variables

All resource names derive from a single suffix to ensure global uniqueness.

```bash
SUFFIX="yourname$(date +%m%d)"

RESOURCE_GROUP="rg-eventdemo-${SUFFIX}"
LOCATION="eastus"

EVENTHUB_NAMESPACE="ehns-eventdemo-${SUFFIX}"
EVENTHUB_NAME="eh-events"
CONSUMER_GROUP="\$Default"   # Basic tier only supports $Default; custom groups require Standard

SQL_SERVER="sql-eventdemo-${SUFFIX}"
SQL_DB="sqldb-eventdemo"
SQL_ADMIN_USER="sqladmin"
SQL_ADMIN_PASS="P@ssw0rd$(date +%s | tail -c 5)!"

STORAGE_ACCOUNT="stevt${SUFFIX}"   # max 24 chars, lowercase, no hyphens
FUNCTION_APP="func-eventdemo-${SUFFIX}"

echo "-------- SAVE THESE VALUES --------"
echo "Resource Group:  $RESOURCE_GROUP"
echo "SQL Password:    $SQL_ADMIN_PASS"
echo "Event Hub NS:    $EVENTHUB_NAMESPACE"
echo "SQL Server:      $SQL_SERVER"
echo "-----------------------------------"
```

> The provisioning script at `scripts/provision.sh` wraps all commands below. Running them individually first builds understanding of the resource model.

### 2.1 — Resource Group

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION
```

A Resource Group is a logical container with no compute cost. Its purpose is lifecycle management — deleting the group removes all resources inside it. This is how cleanup works in Step 8.

```bash
# Verify
az group show --name $RESOURCE_GROUP --output table
```

### 2.2 — Event Hubs Namespace + Event Hub

The namespace is the billing unit and network endpoint (analogous to a Kafka cluster). The event hub is a specific stream/topic within that namespace.

```bash
# Starts billing (~$0.015/hr on Basic tier)
az eventhubs namespace create \
  --name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Basic
```

```bash
# --partition-count 1: Partitions are parallelism units. Minimum for Basic tier.
# --cleanup-policy Delete: Required when specifying retention.
# --retention-time 24: Retain messages for 24 hours (Basic tier maximum).
az eventhubs eventhub create \
  --name $EVENTHUB_NAME \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --partition-count 1 \
  --cleanup-policy Delete \
  --retention-time 24
```

```bash
# Consumer groups provide independent read positions on the stream (same concept
# as Kafka consumer groups). Basic tier only supports the built-in $Default group.
# Custom consumer groups require Standard tier or higher.
# No command needed — $Default exists automatically.
```

```bash
# Retrieve the namespace connection string for local.settings.json.
# Uses the default RootManageSharedAccessKey policy (full access).
# Production environments should use separate send-only and listen-only policies.
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
# Verify
az eventhubs eventhub show \
  --name $EVENTHUB_NAME \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --output table
```

### 2.3 — Azure SQL Server + Database

```bash
# Register the Microsoft.Sql provider (one-time per subscription).
# Azure requires explicit opt-in before creating resources of each service type.
az provider register --namespace Microsoft.Sql --wait
```

```bash
# Logical server: management endpoint for credentials and firewall rules. No compute cost.
az sql server create \
  --name $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --admin-user $SQL_ADMIN_USER \
  --admin-password $SQL_ADMIN_PASS
```

> **Note:** If `eastus` rejects provisioning, use `centralus` or `westus2` for the `--location` flag. The SQL server can reside in a different region from the resource group.

```bash
# Database with serverless compute model.
# --compute-model Serverless: auto-scales vCores and pauses after idle period.
#   When paused, only storage is billed (~$5/month for 1 GB).
# --auto-pause-delay 60: Pause after 60 minutes of inactivity.
# First query after pause incurs ~60 second cold start while the database resumes.
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
# Firewall rules — Azure SQL blocks all connections by default.

# Allow local development IP.
# -4 forces IPv4 (Azure SQL firewall does not accept IPv6 addresses).
MY_IP=$(curl -s -4 ifconfig.me)
echo "Your IP: $MY_IP"

az sql server firewall-rule create \
  --name AllowMyIP \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP

# Allow Azure-internal traffic (enables deployed Function App to reach SQL).
# The 0.0.0.0 range is an Azure convention for "allow Azure services".
az sql server firewall-rule create \
  --name AllowAzureServices \
  --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0
```

```bash
# Verify
az sql db show --name $SQL_DB --server $SQL_SERVER \
  --resource-group $RESOURCE_GROUP --output table
```

### 2.4 — Storage Account

```bash
az provider register --namespace Microsoft.Storage --wait
```

```bash
# Azure Functions requires a Storage Account for:
# - Deployed function code
# - Trigger state (Event Hub checkpoint/offset tracking)
# - Logs and diagnostics
# Analogous to Lambda's internal use of S3, except explicitly managed.

az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS

STORAGE_CONN_STR=$(az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query connectionString \
  --output tsv)

echo "Storage Connection String:"
echo "$STORAGE_CONN_STR"
```

### 2.5 — Function App

```bash
az provider register --namespace Microsoft.Web --wait
```

```bash
# Consumption plan: scale-to-zero serverless compute.
#   - No cost when idle
#   - Automatic scale-out under load
#   - First 1,000,000 executions/month free
#   - Max execution time: 10 minutes (default 5)
#   - Closest AWS equivalent: Lambda pricing model

az functionapp create \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT \
  --consumption-plan-location $LOCATION \
  --runtime node \
  --runtime-version 20 \
  --functions-version 4 \
  --os-type Linux
```

```bash
# App settings become environment variables in the Function runtime.
# Equivalent to Lambda environment variables or SSM Parameter Store.

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
# Verify all resources
az resource list --resource-group $RESOURCE_GROUP --output table
```

Expected resources: Event Hubs Namespace, SQL Server, SQL Database, Storage Account, Function App, App Service Plan (auto-created), and Application Insights (auto-created).

---

## Step 3: Project Setup

### Initialize

```bash
func init event-driven-functions --typescript --model V4
cd event-driven-functions
```

### Install Dependencies

```bash
# @azure/event-hubs: SDK for producing events (used by publishEvent)
# mssql: SQL Server client (used by processEvent and queryData)
npm install @azure/event-hubs mssql
npm install -D @types/mssql
```

> The consumer function (processEvent) does not use the Event Hubs SDK. It uses a built-in trigger binding — the Functions runtime handles the Event Hub connection, checkpointing, and message delivery. The SDK is only needed for operations the runtime doesn't provide, such as producing events.

### Project Structure

```
event-driven-functions/
├── src/
│   └── functions/
│       ├── publishEvent.ts    ← HTTP trigger → Event Hub
│       ├── processEvent.ts    ← Event Hub trigger → SQL
│       └── queryData.ts       ← HTTP trigger → SQL read
├── package.json
├── tsconfig.json
├── host.json
├── local.settings.json        ← connection strings (gitignored)
└── .gitignore
```

### Configure local.settings.json

This file holds connection strings for local development. It is gitignored by default — secrets should never be committed.

```json
{
  "IsEncrypted": false,
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "AzureWebJobsStorage": "<STORAGE_CONNECTION_STRING>",
    "EventHubConnection": "<EVENTHUB_NAMESPACE_CONNECTION_STRING>",
    "SQL_SERVER": "<SQL_SERVER_NAME>.database.windows.net",
    "SQL_DATABASE": "sqldb-eventdemo",
    "SQL_USER": "sqladmin",
    "SQL_PASSWORD": "<SQL_PASSWORD>"
  }
}
```

**Secret management model:**
- **Local:** `local.settings.json` → `process.env.KEY` → function code reads it
- **Deployed:** App Settings (set via CLI or Portal) → `process.env.KEY` → same code

The function code always reads `process.env` and is agnostic to the source.

---

## Step 4: Implement the Functions

### 4.1 — publishEvent (HTTP Trigger → Event Hub)

`src/functions/publishEvent.ts`

```typescript
import { app, HttpRequest, HttpResponseInit, InvocationContext } from '@azure/functions';
import { EventHubProducerClient } from '@azure/event-hubs';

let producer: EventHubProducerClient | null = null;

function getProducer(): EventHubProducerClient {
    if (!producer) {
        const connectionString = process.env.EventHubConnection;
        if (!connectionString) {
            throw new Error('EventHubConnection is not configured');
        }
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

app.http('publishEvent', {
    methods: ['POST'],
    authLevel: 'anonymous',
    handler,
});
```

**Design notes:**
- `EventHubProducerClient` is instantiated once and reused across invocations (connection pooling). The Consumption plan can recycle the host at any time, at which point the singleton is recreated.
- Events are sent in batches — this is the SDK's wire format, even for single events. Batches within a partition are efficient for throughput.
- `app.http(...)` is the v4 programming model. It replaces the `function.json` binding configuration from v3 — all routing is defined in code.

### 4.2 — processEvent (Event Hub Trigger → Azure SQL)

`src/functions/processEvent.ts`

```typescript
import { app, InvocationContext } from '@azure/functions';
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

app.eventHub('processEvent', {
    connection: 'EventHubConnection',
    eventHubName: 'eh-events',
    consumerGroup: '$Default',
    cardinality: 'many',
    handler,
});
```

**Design notes:**
- **Trigger binding vs SDK:** This function does not use `@azure/event-hubs`. The Functions runtime manages the Event Hub connection, reads events, and tracks checkpoints automatically. The code only receives deserialized messages.
- **Cardinality `'many'`:** The runtime delivers events in batches. The handler receives an array. Setting `'one'` delivers a single event per invocation.
- **Checkpointing:** On successful handler return, the runtime persists the checkpoint (current stream offset) to the Storage Account. On failure, it retries from the last checkpoint. This is the same model as Kafka consumer offset commits.
- **`connection: 'EventHubConnection'`** references an app setting name, not the connection string value. This indirection allows connection changes without code redeployment.

### 4.3 — queryData (HTTP Trigger → SQL Read)

`src/functions/queryData.ts`

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

**Design notes:**
- Parameterized queries via `.input()` prevent SQL injection.
- `TOP (@limit)` caps result size. Production would add cursor-based pagination.
- The `eventType` query parameter enables filtering (e.g., `/api/queryData?eventType=order.created`).

---

## Step 5: Create the SQL Table

The `events` table must exist before the pipeline can operate.

### Schema

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

This SQL is also available at `scripts/setup-sql.sql`.

### Execute via CLI

```bash
sqlcmd -S "${SQL_SERVER}.database.windows.net" \
       -d $SQL_DB \
       -U $SQL_ADMIN_USER \
       -P "$SQL_ADMIN_PASS" \
       -i scripts/setup-sql.sql
```

Alternatively, use the Azure Portal: navigate to the SQL Database → **Query editor** → authenticate → paste and run.

### Verify

```bash
sqlcmd -S "${SQL_SERVER}.database.windows.net" \
       -d $SQL_DB \
       -U $SQL_ADMIN_USER \
       -P "$SQL_ADMIN_PASS" \
       -Q "SELECT COUNT(*) FROM events;"
```

Should return 0.

> If the database has auto-paused, the first connection takes ~30-60 seconds while it resumes. This is expected behavior for the serverless compute model.

---

## Step 6: Local Testing

### Build and Start

```bash
cd event-driven-functions
npm run build
npm run start
```

Expected output:

```
Functions:
        publishEvent: [POST] http://localhost:7071/api/publishEvent
        processEvent: eventHubTrigger
        queryData: [GET] http://localhost:7071/api/queryData
```

**Note:** The functions run locally but connect to real Azure services. There is no local emulator for Event Hubs — `local.settings.json` connection strings point to cloud resources.

### Test the Pipeline

In a separate terminal:

**1. Publish an event:**

```bash
curl -X POST http://localhost:7071/api/publishEvent \
  -H "Content-Type: application/json" \
  -d '{"eventType": "order.created", "payload": {"orderId": "ORD-001", "amount": 99.99}}'
```

Expected: `{"success":true,"message":"Event \"order.created\" published"}`

**2. Observe processEvent in the function runtime terminal:**

```
processEvent: received batch of 1 event(s)
processEvent: writing event type="order.created"
processEvent: wrote 1 event(s) to SQL
```

**3. Query the data:**

```bash
curl http://localhost:7071/api/queryData
```

Expected: JSON containing the event with `orderId: "ORD-001"`.

**4. Test filtering and pagination:**

```bash
curl -X POST http://localhost:7071/api/publishEvent \
  -H "Content-Type: application/json" \
  -d '{"eventType": "user.signup", "payload": {"userId": "U-42", "email": "test@example.com"}}'

# After a few seconds:
curl "http://localhost:7071/api/queryData?eventType=order.created"
curl "http://localhost:7071/api/queryData?limit=1"
```

---

## Step 7: Deploy to Azure

### Push Function Code

```bash
cd event-driven-functions
npm run build
func azure functionapp publish $FUNCTION_APP
```

Deployment takes 1-2 minutes. Output includes the deployed function URLs.

### Verify in the Cloud

```bash
FUNC_URL="https://${FUNCTION_APP}.azurewebsites.net"

curl -X POST "${FUNC_URL}/api/publishEvent" \
  -H "Content-Type: application/json" \
  -d '{"eventType": "order.created", "payload": {"orderId": "CLOUD-001", "amount": 250.00}}'

sleep 15

curl "${FUNC_URL}/api/queryData"
```

### Logs

```bash
# Stream live logs
func azure functionapp logstream $FUNCTION_APP

# Or via Portal: Function App → Log stream
```

### Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Functions missing after deploy | Wait 1-2 min, then verify with `az functionapp function list` |
| processEvent not firing | Verify `EventHubConnection` in App Settings |
| SQL connection failure | Confirm AllowAzureServices firewall rule exists |
| Slow first invocation | Expected — Consumption plan cold start is 5-30 seconds |

---

## Step 8: Cleanup

Deleting the resource group removes all resources inside it and stops all charges.

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

Verify deletion (takes 2-5 minutes):

```bash
az group show --name $RESOURCE_GROUP 2>&1
# "could not be found" confirms full deletion
```

This is the value of Resource Groups — all related resources share a lifecycle boundary. One delete operation tears down the entire environment. Common pattern: one resource group per environment (dev, staging, prod).

---

## Compute Model Decision Framework

> "I stood up Functions on a consumption plan for event-driven work, and I understand when App Service or AKS would be the better choice."

### Azure Functions (Consumption Plan)

**Appropriate for:**
- Event-driven workloads (HTTP triggers, queue/event triggers, timers)
- Spiky or unpredictable traffic patterns
- Individual operations under 10 minutes
- Zero infrastructure management requirements
- Pay-per-execution cost model

**Constraints:**
- 10-minute max execution time (5 min default)
- Cold starts: 1-10 seconds
- No control over underlying compute
- Stateless — no persistent local storage between invocations

**Equivalents:** AWS Lambda, GCP Cloud Functions

### Azure App Service

**Appropriate for:**
- Long-running HTTP services and web APIs
- WebSocket or persistent connection requirements
- Predictable, steady traffic (always-on is more cost-effective than per-invocation)
- Execution times exceeding 10 minutes
- Container hosting without orchestration overhead

**Key distinction:** App Service runs continuously — you pay for the VM regardless of request volume. Functions scale to zero.

**Equivalents:** AWS Elastic Beanstalk / ECS Fargate, GCP App Engine / Cloud Run

### Azure Kubernetes Service (AKS)

**Appropriate for:**
- Microservices with complex interdependencies
- Fine-grained control over networking, scaling, and deployment
- Multi-container applications with sidecar patterns
- Custom runtimes or system-level configuration requirements
- Teams with existing Kubernetes expertise
- Service mesh, traffic splitting, or advanced scheduling needs

**Trade-off:** Maximum flexibility, maximum operational overhead.

**Equivalents:** AWS EKS, GCP GKE

### Decision Flow

```
Event-driven (reacting to triggers)?
├── YES → Azure Functions (Consumption)
│         └── Execution > 10 min? → Functions Premium Plan or Durable Functions
└── NO → Web API or long-running service?
          ├── YES → Complexity?
          │         ├── Simple / few services → App Service
          │         └── Many microservices, orchestration needed → AKS
          └── NO → Batch processing?
                    ├── Short tasks → Functions + Timer trigger
                    └── Long/complex → Container Instances or Azure Batch
```

### Functions Premium Plan — Middle Ground

Worth noting: the Premium Plan provides pre-warmed instances (no cold starts), VNET integration, unlimited execution time, and more powerful instances. Still functions-as-a-service, but without Consumption plan constraints. You pay for always-on instances. It bridges the gap between Consumption and App Service.

---

## Reference: Shell Variables

For resuming in a new terminal session:

```bash
SUFFIX="yourname0403"                    # match your original value
RESOURCE_GROUP="rg-eventdemo-${SUFFIX}"
LOCATION="eastus"
EVENTHUB_NAMESPACE="ehns-eventdemo-${SUFFIX}"
EVENTHUB_NAME="eh-events"
CONSUMER_GROUP="\$Default"
SQL_SERVER="sql-eventdemo-${SUFFIX}"
SQL_DB="sqldb-eventdemo"
SQL_ADMIN_USER="sqladmin"
SQL_ADMIN_PASS="YOUR_PASSWORD_HERE"      # match your original value
STORAGE_ACCOUNT="stevt${SUFFIX}"
FUNCTION_APP="func-eventdemo-${SUFFIX}"
```

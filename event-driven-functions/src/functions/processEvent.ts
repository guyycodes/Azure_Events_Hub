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

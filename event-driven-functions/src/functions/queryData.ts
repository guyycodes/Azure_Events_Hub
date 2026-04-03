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

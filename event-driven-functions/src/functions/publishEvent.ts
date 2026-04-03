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

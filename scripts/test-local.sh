#!/usr/bin/env bash
# ============================================================================
# Azure Event-Driven Demo — Local Test Commands
#
# Run these AFTER `npm start` is running in event-driven-functions/.
# Open a separate terminal and run each curl command.
# ============================================================================

BASE_URL="http://localhost:7071/api"

echo "=== 1. Publish an order.created event ==="
curl -s -X POST "${BASE_URL}/publishEvent" \
  -H "Content-Type: application/json" \
  -d '{"eventType": "order.created", "payload": {"orderId": "ORD-001", "amount": 99.99}}' | jq .

echo ""
echo "=== 2. Publish a user.signup event ==="
curl -s -X POST "${BASE_URL}/publishEvent" \
  -H "Content-Type: application/json" \
  -d '{"eventType": "user.signup", "payload": {"userId": "U-42", "email": "test@example.com"}}' | jq .

echo ""
echo ">>> Waiting 10 seconds for processEvent to consume from Event Hub..."
sleep 10

echo ""
echo "=== 3. Query all events ==="
curl -s "${BASE_URL}/queryData" | jq .

echo ""
echo "=== 4. Query filtered by eventType ==="
curl -s "${BASE_URL}/queryData?eventType=order.created" | jq .

echo ""
echo "=== 5. Query with limit ==="
curl -s "${BASE_URL}/queryData?limit=1" | jq .

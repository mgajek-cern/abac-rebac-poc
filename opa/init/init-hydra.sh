#!/bin/sh

set -e

echo "Creating OAuth2 client..."

# Use Hydra's admin API instead of CLI
CLIENT_RESPONSE=$(curl -s -X POST "${HYDRA_ADMIN_URL}/admin/clients" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "",
    "client_secret": "",
    "grant_types": ["client_credentials"],
    "response_types": ["token"],
    "scope": ""
  }')

CLIENT_ID=$(echo "$CLIENT_RESPONSE" | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)
CLIENT_SECRET=$(echo "$CLIENT_RESPONSE" | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)

echo "Created OAuth2 client:"
echo "Client ID: $CLIENT_ID"
echo "Client Secret: $CLIENT_SECRET"

# Save client credentials to shared volume
echo "$CLIENT_ID" > /shared/hydra-client-id
echo "$CLIENT_SECRET" > /shared/hydra-client-secret

echo "Hydra initialization complete!"
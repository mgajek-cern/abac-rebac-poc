#!/bin/bash

echo "=== Comprehensive Production ReBAC API Test Script ==="
echo

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
BASE_URL="http://localhost:8000"
API_ERRORS=0

echo "Getting config..."
config=$(curl -s $BASE_URL/debug/config)
echo -e "${GREEN}✅ Got config${NC}"

# Get credentials
echo "Getting credentials..."
if curl -s $BASE_URL/debug/credentials >/dev/null 2>&1; then
    credentials=$(curl -s $BASE_URL/debug/credentials)
    client_id=$(echo $credentials | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)
    client_secret=$(echo $credentials | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)
else
    echo "Reading credentials from shared files..."
    if [ -f "/shared/hydra-client-id" ] && [ -f "/shared/hydra-client-secret" ]; then
        client_id=$(cat /shared/hydra-client-id)
        client_secret=$(cat /shared/hydra-client-secret)
    else
        echo -e "${RED}❌ Failed to get credentials from API or files${NC}"
        exit 1
    fi
fi

if [ "$client_id" = "" ] || [ "$client_secret" = "" ]; then
    echo -e "${RED}❌ Failed to get credentials${NC}"
    exit 1
fi

echo "Setting up clean test data for current client..."
CLIENT_ID="$client_id"
STORE_ID=$(curl -s $BASE_URL/debug/config | grep -o '"openfga_store_id":"[^"]*"' | cut -d'"' -f4)

# Setup test data using individual operations to handle existing tuples gracefully
echo "Setting up test data (handling existing tuples)..."

# Function to write tuple safely (simplified approach)
write_tuple_safe() {
    local user=$1
    local relation=$2
    local object=$3
    
    # Always attempt to write - let OpenFGA handle duplicates
    write_response=$(curl -s -X POST "http://localhost:8080/stores/$STORE_ID/write" \
        -H "Content-Type: application/json" \
        -d "{\"writes\":{\"tuple_keys\":[{\"user\":\"$user\",\"relation\":\"$relation\",\"object\":\"$object\"}]}}")
    
    if echo "$write_response" | grep -q '"code"'; then
        if echo "$write_response" | grep -q "already exists"; then
            echo "  ✅ Tuple already exists: $user -> $relation -> $object"
        else
            echo "  ⚠️  Write failed: $user -> $relation -> $object ($(echo "$write_response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4))"
        fi
    else
        echo "  ✅ Written: $user -> $relation -> $object"
    fi
}

# Write all required tuples safely
write_tuple_safe "user:$CLIENT_ID" "can_view" "resource:test-document"
write_tuple_safe "user:$CLIENT_ID" "owner" "resource:demo-file"
write_tuple_safe "user:$CLIENT_ID" "can_edit" "resource:shared-doc"
write_tuple_safe "user:$CLIENT_ID" "owner" "resource:grant-test-doc"

write_tuple_safe "user:$CLIENT_ID" "member" "group:developers"
write_tuple_safe "group:developers#member" "can_view" "resource:team-doc"
write_tuple_safe "group:developers#member" "can_edit" "resource:dev-tools"

write_tuple_safe "user:$CLIENT_ID" "member" "organization:acme"
write_tuple_safe "organization:acme#member" "can_view" "resource:company-docs"

write_tuple_safe "user:$CLIENT_ID" "can_view" "resource:folder1"
write_tuple_safe "resource:folder1" "parent" "resource:child-doc"

echo -e "${GREEN}✅ Test data setup completed${NC}"

# Debug: Let's see what tuples actually got written
echo "Checking all tuples in the store..."
all_tuples=$(curl -s -X POST "http://localhost:8080/stores/$STORE_ID/read" \
    -H "Content-Type: application/json" \
    -d '{}')
echo "All tuples in store: $all_tuples"
echo

# Debug: Verify the grant-test-doc owner relationship was created
echo "Verifying grant-test-doc ownership..."
verify_response=$(curl -s -X POST "http://localhost:8080/stores/$STORE_ID/check" \
    -H "Content-Type: application/json" \
    -d "{\"tuple_key\":{\"user\":\"user:$CLIENT_ID\",\"relation\":\"owner\",\"object\":\"resource:grant-test-doc\"}}")

if echo "$verify_response" | grep -q '"allowed":true'; then
    echo -e "${GREEN}✅ Confirmed: $CLIENT_ID is owner of grant-test-doc${NC}"
else
    echo -e "${YELLOW}⚠️  Warning: Owner relationship not confirmed for grant-test-doc${NC}"
    echo "   Check response: $verify_response"
    
    # Try to diagnose the issue
    echo "   Diagnosing store connectivity..."
    store_list=$(curl -s -X GET "http://localhost:8080/stores")
    echo "   Available stores: $store_list"
    
    echo "   Checking current store info..."
    store_info=$(curl -s -X GET "http://localhost:8080/stores/$STORE_ID")
    echo "   Store info: $store_info"
fi

echo "Test data setup complete for client: $CLIENT_ID"

# Get OAuth2 token
echo "Getting OAuth2 token..."
token_response=$(curl -s -u "$client_id:$client_secret" \
    -d 'grant_type=client_credentials' \
    http://localhost:4444/oauth2/token)

access_token=$(echo $token_response | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ "$access_token" = "" ]; then
    echo -e "${RED}❌ Failed to get access token${NC}"
    echo "Token response: $token_response"
    exit 1
fi

echo -e "${GREEN}✅ Got access token${NC}"
echo

# Test function for resource operations
test_resource_operation() {
    local method=$1
    local resource=$2
    local expected=$3
    local description=$4
    local body=$5
    
    echo -e "${BLUE}Testing: $description${NC}"
    
    if [ "$method" = "GET" ]; then
        response=$(curl -s -X GET \
            -H "Authorization: Bearer $access_token" \
            "$BASE_URL/resources/$resource")
    elif [ "$method" = "PUT" ]; then
        response=$(curl -s -X PUT \
            -H "Authorization: Bearer $access_token" \
            -H "Content-Type: application/json" \
            -d "${body:-{}}" \
            "$BASE_URL/resources/$resource")
    elif [ "$method" = "DELETE" ]; then
        response=$(curl -s -X DELETE \
            -H "Authorization: Bearer $access_token" \
            "$BASE_URL/resources/$resource")
    elif [ "$method" = "POST" ] && [[ "$resource" == *"/grant" ]]; then
        response=$(curl -s -X POST \
            -H "Authorization: Bearer $access_token" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$BASE_URL/resources/$resource")
    fi
    
    if echo "$response" | grep -q -E '("access":"granted"|"action":"updated"|"action":"deleted"|"message":"Access granted successfully")'; then
        if [ "$expected" = "granted" ]; then
            echo -e "${GREEN}✅ PASS: Operation successful as expected${NC}"
            # Extract relevant info based on response type
            if echo "$response" | grep -q '"permission"'; then
                permission=$(echo "$response" | grep -o '"permission":"[^"]*"' | cut -d'"' -f4)
                echo "   Permission required: $permission"
            fi
            if echo "$response" | grep -q '"action"'; then
                action=$(echo "$response" | grep -o '"action":"[^"]*"' | cut -d'"' -f4)
                echo "   Action performed: $action"
            fi
        else
            echo -e "${RED}❌ FAIL: Expected denied, got success${NC}"
            API_ERRORS=$((API_ERRORS + 1))
        fi
    elif echo "$response" | grep -q -E '("Access denied"|"Only resource owners can grant access"|"Failed to grant access")'; then
        if [ "$expected" = "denied" ]; then
            echo -e "${GREEN}✅ PASS: Access denied as expected${NC}"
        else
            echo -e "${RED}❌ FAIL: Expected success, got denied${NC}"
            API_ERRORS=$((API_ERRORS + 1))
        fi
    else
        echo -e "${YELLOW}⚠️  UNEXPECTED: Response format unexpected${NC}"
        API_ERRORS=$((API_ERRORS + 1))
    fi
    echo "   Response: $response"
    echo
}

# Test health endpoint
echo -e "${CYAN}=== Health Check ===${NC}"
health_response=$(curl -s $BASE_URL/health)
if echo "$health_response" | grep -q '"status":"healthy"'; then
    echo -e "${GREEN}✅ Health check passed${NC}"
else
    echo -e "${RED}❌ Health check failed${NC}"
    API_ERRORS=$((API_ERRORS + 1))
fi
echo "   Response: $health_response"
echo

echo -e "${CYAN}=== GET Resource Tests (can_view permission) ===${NC}"
test_resource_operation "GET" "test-document" "granted" "GET test-document (should have can_view)"
test_resource_operation "GET" "demo-file" "granted" "GET demo-file (should be owner)"
test_resource_operation "GET" "shared-doc" "granted" "GET shared-doc (should have can_edit -> can_view)"
test_resource_operation "GET" "team-doc" "granted" "GET team-doc (via group membership)"
test_resource_operation "GET" "child-doc" "granted" "GET child-doc (inherited access)"
test_resource_operation "GET" "nonexistent" "denied" "GET nonexistent resource"

echo -e "${CYAN}=== PUT Resource Tests (can_edit permission) ===${NC}"
test_resource_operation "PUT" "demo-file" "granted" "PUT demo-file (owner -> can_edit)" '{"data": "updated content"}'
test_resource_operation "PUT" "shared-doc" "granted" "PUT shared-doc (has can_edit)" '{"data": "updated content"}'
test_resource_operation "PUT" "test-document" "denied" "PUT test-document (only has can_view)" '{"data": "updated content"}'
test_resource_operation "PUT" "nonexistent" "denied" "PUT nonexistent resource" '{"data": "new content"}'

echo -e "${CYAN}=== Grant Access Tests (owner permission required) ===${NC}"

# Debug: Check all relationships for grant-test-doc before testing
echo -e "${BLUE}Debug: Checking all relationships for grant-test-doc...${NC}"
all_tuples_response=$(curl -s -X POST "http://localhost:8080/stores/$STORE_ID/read" \
    -H "Content-Type: application/json" \
    -d "{\"tuple_key\":{\"object\":\"resource:grant-test-doc\"}}")
echo "   All tuples for grant-test-doc: $all_tuples_response"

# Debug: Double-check ownership via both OpenFGA and the app API
echo -e "${BLUE}Debug: Verifying ownership through application API...${NC}"
ownership_check=$(curl -s -X GET \
    -H "Authorization: Bearer $access_token" \
    "$BASE_URL/resources/grant-test-doc")
echo "   Application ownership check: $ownership_check"

# Test granting access to a resource we haven't deleted
# Use timestamp to ensure unique user names across test runs
TIMESTAMP=$(date +%s)
test_resource_operation "POST" "grant-test-doc/grant" "granted" "Grant access to grant-test-doc (is owner)" "{\"user\": \"user:testuser-$TIMESTAMP\", \"relation\": \"can_view\"}"

# Alternative debug test: Try granting to demo-file before it gets deleted
echo -e "${BLUE}Debug: Testing grant on demo-file before deletion...${NC}"
demo_grant_response=$(curl -s -X POST \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/json" \
    -d '{"user": "user:debuguser", "relation": "can_view"}' \
    "$BASE_URL/resources/demo-file/grant")
echo "   Demo-file grant response: $demo_grant_response"
echo
test_resource_operation "POST" "shared-doc/grant" "denied" "Grant access to shared-doc (only has can_edit)" '{"user": "user:testuser", "relation": "can_view"}'
test_resource_operation "POST" "test-document/grant" "denied" "Grant access to test-document (only has can_view)" '{"user": "user:testuser", "relation": "can_view"}'

echo -e "${CYAN}=== DELETE Resource Tests (owner permission) ===${NC}"
# Move DELETE tests after grant tests to avoid state dependency
test_resource_operation "DELETE" "demo-file" "granted" "DELETE demo-file (is owner)"
test_resource_operation "DELETE" "shared-doc" "denied" "DELETE shared-doc (only has can_edit, not owner)"
test_resource_operation "DELETE" "test-document" "denied" "DELETE test-document (only has can_view)"
test_resource_operation "DELETE" "nonexistent" "denied" "DELETE nonexistent resource"

echo -e "${CYAN}=== Group-Based Permission Tests ===${NC}"
test_resource_operation "GET" "team-doc" "granted" "GET team-doc (via group:developers membership)"
test_resource_operation "PUT" "dev-tools" "granted" "PUT dev-tools (group can_edit permission)"

echo -e "${CYAN}=== Organization-Based Permission Tests ===${NC}"
test_resource_operation "GET" "company-docs" "granted" "GET company-docs (via organization:acme membership)"

echo -e "${CYAN}=== Authentication Tests ===${NC}"
echo -e "${BLUE}Testing: Request without token${NC}"
no_auth_response=$(curl -s $BASE_URL/resources/test-document)
if echo "$no_auth_response" | grep -q "Missing token"; then
    echo -e "${GREEN}✅ PASS: Correctly rejected request without token${NC}"
else
    echo -e "${RED}❌ FAIL: Should reject request without token${NC}"
    API_ERRORS=$((API_ERRORS + 1))
fi
echo "   Response: $no_auth_response"
echo

echo -e "${BLUE}Testing: Request with invalid token${NC}"
invalid_auth_response=$(curl -s -H "Authorization: Bearer invalid_token_here" $BASE_URL/resources/test-document)
if echo "$invalid_auth_response" | grep -q -E "(Token introspection failed|Token is not active|Invalid token)"; then
    echo -e "${GREEN}✅ PASS: Correctly rejected request with invalid token${NC}"
else
    echo -e "${RED}❌ FAIL: Should reject request with invalid token${NC}"
    API_ERRORS=$((API_ERRORS + 1))
fi
echo "   Response: $invalid_auth_response"
echo

echo -e "${CYAN}=== Configuration Summary ===${NC}"
echo -e "${YELLOW}OAuth2 Client ID: $client_id${NC}"
echo -e "${YELLOW}Base URL: $BASE_URL${NC}"
echo -e "${YELLOW}Expected permissions for this client:${NC}"
echo "- can_view: resource:test-document"
echo "- owner: resource:demo-file (implies can_view and can_edit)"
echo "- can_edit: resource:shared-doc (implies can_view)"
echo "- owner: resource:grant-test-doc (for testing grant operations)"
echo "- member: group:developers (grants access to team resources)"
echo "- can_view: resource:folder1 (grants access to child resources)"
echo

echo -e "${CYAN}=== Test Results Summary ===${NC}"
if [ $API_ERRORS -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed! (0 errors)${NC}"
else
    echo -e "${RED}❌ $API_ERRORS test(s) failed${NC}"
fi

echo
echo -e "${CYAN}=== Useful Debug Commands ===${NC}"
echo "View config: curl $BASE_URL/debug/config"
echo "View health: curl $BASE_URL/health"
echo "View all relationship tuples: curl $BASE_URL/debug/tuples"
echo
store_id=$(curl -s $BASE_URL/debug/config | grep -o '"openfga_store_id":"[^"]*"' | cut -d'"' -f4)
if [ "$store_id" != "" ] && [ "$store_id" != "null" ]; then
    echo -e "${YELLOW}Direct OpenFGA Store ID: $store_id${NC}"
    echo "Direct OpenFGA check example:"
    echo "curl -X POST http://localhost:8080/stores/$store_id/check \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"tuple_key\":{\"user\":\"user:$client_id\",\"relation\":\"can_view\",\"object\":\"resource:test-document\"}}'"
fi

exit $API_ERRORS
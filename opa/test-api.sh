#!/bin/bash

echo "=== Comprehensive OPA-Based ReBAC API Test Script ==="
echo "Showcasing advanced policy-based authorization vs graph traversal"
echo

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
BASE_URL="http://localhost:8000"
OPA_URL="http://localhost:8181"
API_ERRORS=0

echo "Getting config..."
config=$(curl -s $BASE_URL/debug/config)
echo -e "${GREEN}✅ Got config${NC}"

# Get credentials
echo "Getting credentials..."
credentials=$(curl -s $BASE_URL/debug/credentials)
client_id=$(echo $credentials | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)
client_secret=$(echo $credentials | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)

if [ "$client_id" = "" ] || [ "$client_secret" = "" ]; then
    echo -e "${RED}❌ Failed to get credentials${NC}"
    exit 1
fi

echo "Setting up comprehensive OPA data with rich context..."
CLIENT_ID="$client_id"

# Setup comprehensive permissions with context-aware data
curl -s -X PUT "$OPA_URL/v1/data/permissions" \
  -H "Content-Type: application/json" \
  -d "{
    \"$CLIENT_ID\": {
      \"test-document\": {\"read\": true},
      \"demo-file\": {\"read\": true, \"update\": true, \"delete\": true, \"grant_permission\": true},
      \"shared-doc\": {\"read\": true, \"update\": true},
      \"sensitive-doc\": {\"read\": false, \"update\": false},
      \"team-project\": {\"read\": true}
    },
    \"user:alice\": {
      \"sensitive-doc\": {\"read\": true, \"update\": true}
    }
  }"

# Setup user profiles with rich metadata
curl -s -X PUT "$OPA_URL/v1/data/users" \
  -H "Content-Type: application/json" \
  -d "{
    \"$CLIENT_ID\": {
      \"name\": \"Test User\",
      \"department\": \"engineering\",
      \"clearance_level\": \"standard\",
      \"groups\": [\"developers\", \"contractors\"],
      \"organization\": \"acme\",
      \"location\": \"us-west\",
      \"employment_type\": \"contractor\"
    },
    \"user:alice\": {
      \"name\": \"Alice Admin\",
      \"department\": \"security\",
      \"clearance_level\": \"high\",
      \"groups\": [\"admins\", \"security-team\"],
      \"organization\": \"acme\",
      \"location\": \"us-east\",
      \"employment_type\": \"full-time\"
    }
  }"

# Setup group permissions
curl -s -X PUT "$OPA_URL/v1/data/group_permissions" \
  -H "Content-Type: application/json" \
  -d "{
    \"developers\": {
      \"team-project\": {\"read\": true, \"update\": true},
      \"dev-tools\": {\"read\": true, \"update\": true}
    },
    \"contractors\": {
      \"contractor-resources\": {\"read\": true}
    },
    \"security-team\": {
      \"sensitive-doc\": {\"read\": true, \"update\": true, \"delete\": true}
    }
  }"

# Setup organization policies
curl -s -X PUT "$OPA_URL/v1/data/organizations" \
  -H "Content-Type: application/json" \
  -d "{
    \"acme\": {
      \"company-wide\": {\"read\": true},
      \"policies\": {
        \"data_retention_days\": 90,
        \"require_mfa_for_sensitive\": true,
        \"business_hours_only\": false
      }
    }
  }"

# Setup resource metadata for context-aware policies
curl -s -X PUT "$OPA_URL/v1/data/resources" \
  -H "Content-Type: application/json" \
  -d "{
    \"test-document\": {
      \"type\": \"document\",
      \"sensitivity\": \"public\",
      \"department\": \"engineering\",
      \"created_by\": \"$CLIENT_ID\"
    },
    \"demo-file\": {
      \"type\": \"file\",
      \"sensitivity\": \"internal\",
      \"department\": \"engineering\",
      \"created_by\": \"$CLIENT_ID\"
    },
    \"sensitive-doc\": {
      \"type\": \"document\",
      \"sensitivity\": \"confidential\",
      \"department\": \"security\",
      \"requires_clearance\": \"high\",
      \"created_by\": \"user:alice\"
    },
    \"team-project\": {
      \"type\": \"project\",
      \"sensitivity\": \"internal\",
      \"department\": \"engineering\",
      \"team_resource\": true
    }
  }"

echo "Enhanced OPA data setup complete for client: $CLIENT_ID"

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
        if echo "$body" | jq . > /dev/null 2>&1; then
            response=$(curl -s -X PUT \
                -H "Authorization: Bearer $access_token" \
                -H "Content-Type: application/json" \
                -d "$body" \
                "$BASE_URL/resources/$resource")
        else
            response='{"error": "Invalid JSON in test"}'
        fi
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
            echo -e "${GREEN}✅ PASS: Operation successful${NC}"
            if echo "$response" | grep -q '"context"'; then
                echo "   Context-aware authorization applied"
            fi
        else
            echo -e "${RED}❌ FAIL: Expected denied, got success${NC}"
            API_ERRORS=$((API_ERRORS + 1))
        fi
    elif echo "$response" | grep -q -E '("Access denied"|"Only resource administrators|"Failed to grant access")'; then
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
    if echo "$health_response" | grep -q '"authorization_engine":"OPA"'; then
        echo "   Using OPA authorization engine"
    fi
else
    echo -e "${RED}❌ Health check failed${NC}"
    API_ERRORS=$((API_ERRORS + 1))
fi
echo "   Response: $health_response"
echo

echo -e "${CYAN}=== Basic Permission Tests ===${NC}"
test_resource_operation "GET" "test-document" "granted" "GET test-document (direct permission)"
test_resource_operation "GET" "demo-file" "granted" "GET demo-file (owner permissions)"
test_resource_operation "GET" "shared-doc" "granted" "GET shared-doc (update implies read)"

echo -e "${CYAN}=== Context-Aware Permission Tests ===${NC}"
test_resource_operation "GET" "sensitive-doc" "denied" "GET sensitive-doc (requires high clearance - should fail)"

echo -e "${CYAN}=== Group-Based Permission Tests ===${NC}"
test_resource_operation "GET" "team-project" "granted" "GET team-project (via developers group)"

echo -e "${CYAN}=== Content-Aware Update Tests ===${NC}"
test_resource_operation "PUT" "demo-file" "granted" "PUT demo-file (standard content)" '{"data": "normal content", "sensitivity": "normal"}'
test_resource_operation "PUT" "shared-doc" "granted" "PUT shared-doc (has update permission)" '{"data": "updated content", "sensitivity": "internal"}'
test_resource_operation "PUT" "test-document" "denied" "PUT test-document (only has read)" '{"data": "updated content"}'
test_resource_operation "PUT" "nonexistent" "denied" "PUT nonexistent resource" '{"data": "new content"}'

echo -e "${CYAN}=== Administrative Permission Tests ===${NC}"
test_resource_operation "DELETE" "demo-file" "granted" "DELETE demo-file (has delete permission)"
test_resource_operation "DELETE" "shared-doc" "denied" "DELETE shared-doc (no delete permission)"

echo -e "${CYAN}=== Grant Permission Tests ===${NC}"
test_resource_operation "POST" "demo-file/grant" "granted" "Grant permission on demo-file" '{"user": "user:testuser", "relation": "read"}'
test_resource_operation "POST" "shared-doc/grant" "denied" "Grant permission on shared-doc (no grant permission)" '{"user": "user:testuser", "relation": "read"}'

echo -e "${CYAN}=== Dynamic Policy Updates ===${NC}"
echo -e "${BLUE}Testing: Dynamic permission update${NC}"
dynamic_update_response=$(curl -s -X POST "$BASE_URL/admin/permissions" \
  -H "Content-Type: application/json" \
  -d "{
    \"permissions\": {
      \"$CLIENT_ID\": {
        \"dynamic-resource\": {\"read\": true, \"update\": true}
      }
    }
  }")

if echo "$dynamic_update_response" | grep -q "updated successfully"; then
    echo -e "${GREEN}✅ PASS: Dynamic permission update successful${NC}"
    
    # Test the newly granted permission
    test_resource_operation "GET" "dynamic-resource" "granted" "GET dynamic-resource (after dynamic grant)"
else
    echo -e "${RED}❌ FAIL: Dynamic permission update failed${NC}"
    API_ERRORS=$((API_ERRORS + 1))
fi
echo "   Response: $dynamic_update_response"
echo

echo -e "${CYAN}=== Debug Information ===${NC}"
echo -e "${BLUE}Viewing OPA data structure:${NC}"
opa_data=$(curl -s $BASE_URL/debug/opa-data | head -c 500)
echo "$opa_data..."
echo

echo -e "${BLUE}Testing direct OPA query:${NC}"
direct_opa_query=$(curl -s -X POST "$BASE_URL/debug/opa-query" \
  -H "Content-Type: application/json" \
  -d "{
    \"path\": \"authz/allow\",
    \"input\": {
      \"user\": \"$CLIENT_ID\",
      \"resource\": \"test-document\",
      \"action\": \"read\",
      \"context\": {\"department\": \"engineering\"}
    }
  }")
echo "Direct OPA query result: $direct_opa_query"
echo

echo -e "${CYAN}=== Authentication Tests ===${NC}"
echo -e "${BLUE}Testing: Request without token${NC}"
no_auth_response=$(curl -s $BASE_URL/resources/test-document)
if echo "$no_auth_response" | grep -q "Missing token"; then
    echo -e "${GREEN}✅ PASS: Correctly rejected request without token${NC}"
else
    echo -e "${RED}❌ FAIL: Should reject request without token${NC}"
    API_ERRORS=$((API_ERRORS + 1))
fi
echo

echo -e "${CYAN}=== Test Results Summary ===${NC}"
if [ $API_ERRORS -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed! (0 errors)${NC}"
    echo -e "${PURPLE}OPA successfully demonstrated advanced policy capabilities!${NC}"
else
    echo -e "${RED}❌ $API_ERRORS test(s) failed${NC}"
fi

echo
echo -e "${CYAN}=== Key OPA Features Showcased ===${NC}"
echo "🔐 Attribute-Based Access Control (ABAC)"
echo "📊 Context-aware decision making"
echo "🏢 Organization and department policies"
echo "👥 Group-based permissions with metadata"
echo "🔄 Dynamic policy and data updates"
echo "📝 Content inspection and validation"
echo "⚡ Complex business logic in policies"
echo "🎯 Fine-grained permission control"

echo
echo -e "${CYAN}=== Useful Debug Commands ===${NC}"
echo "View OPA data: curl $BASE_URL/debug/opa-data"
echo "View OPA policies: curl $BASE_URL/debug/opa-policies"  
echo "Update permissions: curl -X POST $BASE_URL/admin/permissions -d '{...}'"
echo "Direct OPA query: curl -X POST $OPA_URL/v1/data/authz/allow -d '{\"input\":{...}}'"

exit $API_ERRORS
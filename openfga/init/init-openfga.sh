#!/bin/sh
set -e
echo "Creating OpenFGA store..."
STORE_RESPONSE=$(curl -s -X POST "${OPENFGA_URL}/stores" \
-H "Content-Type: application/json" \
-d "{\"name\": \"${STORE_NAME}\"}")
STORE_ID=$(echo "$STORE_RESPONSE" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
echo "Created store with ID: $STORE_ID"
# Save store ID to shared volume
echo "$STORE_ID" > /shared/openfga-store-id
echo "Creating enhanced authorization model..."
AUTH_MODEL='{
  "schema_version": "1.1",
  "type_definitions": [
    {
      "type": "user"
    },
    {
      "type": "group",
      "relations": {
        "member": {
          "this": {}
        }
      },
      "metadata": {
        "relations": {
          "member": {
            "directly_related_user_types": [
              {"type": "user"}
            ]
          }
        }
      }
    },
    {
      "type": "resource",
      "relations": {
        "can_view": {
          "union": {
            "child": [
              {"this": {}},
              {"computedUserset": {"relation": "owner"}},
              {"computedUserset": {"relation": "can_edit"}},
              {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "can_view"}}}
            ]
          }
        },
        "can_edit": {
          "union": {
            "child": [
              {"this": {}},
              {"computedUserset": {"relation": "owner"}}
            ]
          }
        },
        "owner": {
          "this": {}
        },
        "parent": {
          "this": {}
        }
      },
      "metadata": {
        "relations": {
          "can_view": {
            "directly_related_user_types": [
              {"type": "user"},
              {"type": "group", "relation": "member"},
              {"type": "organization", "relation": "member"}
            ]
          },
          "can_edit": {
            "directly_related_user_types": [
              {"type": "user"},
              {"type": "group", "relation": "member"},
              {"type": "organization", "relation": "member"}
            ]
          },
          "owner": {
            "directly_related_user_types": [
              {"type": "user"}
            ]
          },
          "parent": {
            "directly_related_user_types": [
              {"type": "resource"}
            ]
          }
        }
      }
    },
    {
      "type": "organization",
      "relations": {
        "member": {
          "this": {}
        },
        "admin": {
          "this": {}
        }
      },
      "metadata": {
        "relations": {
          "member": {
            "directly_related_user_types": [
              {"type": "user"}
            ]
          },
          "admin": {
            "directly_related_user_types": [
              {"type": "user"}
            ]
          }
        }
      }
    }
  ]
}'
MODEL_RESPONSE=$(curl -s -X POST "${OPENFGA_URL}/stores/${STORE_ID}/authorization-models" \
-H "Content-Type: application/json" \
-d "$AUTH_MODEL")
MODEL_ID=$(echo "$MODEL_RESPONSE" | grep -o '"authorization_model_id":"[^"]*"' | cut -d'"' -f4)
echo "Created model with ID: $MODEL_ID"
echo "OpenFGA infrastructure initialization complete!"
echo "Store ID: $STORE_ID"
echo "Model ID: $MODEL_ID"
echo ""
echo "Authorization model configured with:"
echo "- User and group types"
echo "- Resource permissions: owner -> can_edit -> can_view"
echo "- Hierarchical inheritance via parent relationships"
echo "- Group-based access control"
echo ""
echo "Ready for relationship tuples to be added by applications or tests."
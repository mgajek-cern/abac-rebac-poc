#!/bin/sh
set -e
echo "Initializing OPA with base policies..."

# Upload base authorization policy
curl -s -X PUT "$OPA_URL/v1/policies/authz" \
  -H "Content-Type: text/plain" \
  -d 'package authz

import rego.v1

# Default deny
default allow := false

# Allow if user has direct permission
allow if {
    input.action == "read"
    data.permissions[input.user][input.resource].read == true
}

allow if {
    input.action == "update"  
    data.permissions[input.user][input.resource].update == true
}

allow if {
    input.action == "delete"
    data.permissions[input.user][input.resource].delete == true
}

# Grant permission requires special grant_permission flag
allow if {
    input.action == "create"
    input.context.action == "grant_permission"
    data.permissions[input.user][input.resource].grant_permission == true
}

# Group-based permissions
allow if {
    input.action == "read"
    user_data := data.users[input.user]
    group := user_data.groups[_]
    data.group_permissions[group][input.resource].read == true
}

allow if {
    input.action == "update"
    user_data := data.users[input.user] 
    group := user_data.groups[_]
    data.group_permissions[group][input.resource].update == true
}

# Context-aware rules
allow if {
    input.action == "read"
    user_data := data.users[input.user]
    resource_data := data.resources[input.resource]
    user_data.clearance_level == "high"
    resource_data.sensitivity == "confidential"
    data.permissions[input.user][input.resource].read == true
}'

echo "OPA policy initialization complete!"
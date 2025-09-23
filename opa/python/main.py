from fastapi import FastAPI, HTTPException, Depends, Header, Request
from typing import Optional, Dict, Any
import httpx
import json
import os
from datetime import datetime

app = FastAPI()

# Environment variables
OPA_URL = os.getenv("OPA_URL", "http://localhost:8181")
HYDRA_INTROSPECT_URL = os.getenv("HYDRA_INTROSPECT_URL", "http://localhost:4445/admin/oauth2/introspect")

# Map HTTP methods to required actions for OPA
ENDPOINT_ACTIONS = {
    "GET": "read",
    "POST": "create", 
    "PUT": "update",
    "PATCH": "update",
    "DELETE": "delete"
}

async def auth_middleware(authorization: Optional[str] = Header(None)):
    """Verify token via Hydra introspection"""
    if not authorization:
        raise HTTPException(401, "Missing token")
    
    try:
        token = authorization.replace("Bearer ", "")
        
        async with httpx.AsyncClient() as client:
            introspect_response = await client.post(
                HYDRA_INTROSPECT_URL,
                data={"token": token}
            )
            
            if introspect_response.status_code != 200:
                raise HTTPException(401, "Token introspection failed")
            
            token_info = introspect_response.json()
            
            if not token_info.get("active", False):
                raise HTTPException(401, "Token is not active")
            
            user_id = token_info.get("client_id", "unknown")
            
            return {
                "user_id": user_id,
                "client_id": token_info.get("client_id", "unknown"),
                "token": token,
                "scope": token_info.get("scope", "")
            }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(401, f"Invalid token: {str(e)}")

async def check_authorization(user_id: str, resource_id: str, method: str, context: Dict[str, Any] = None) -> bool:
    """Check authorization using OPA with rich context"""
    try:
        async with httpx.AsyncClient() as client:
            # Build rich context for OPA policy evaluation
            policy_input = {
                "user": user_id,
                "resource": resource_id,
                "action": ENDPOINT_ACTIONS.get(method, method.lower()),
                "method": method,
                "timestamp": datetime.utcnow().isoformat(),
                "context": context or {}
            }
            
            print(f"DEBUG: OPA input - {json.dumps(policy_input, indent=2)}")
            
            opa_response = await client.post(
                f"{OPA_URL}/v1/data/authz/allow",
                json={"input": policy_input}
            )
            
            if opa_response.status_code != 200:
                print(f"DEBUG: OPA error: {opa_response.text}")
                return False
            
            result = opa_response.json()
            allowed = result.get("result", False)
            
            print(f"DEBUG: OPA decision - user={user_id}, resource={resource_id}, action={ENDPOINT_ACTIONS.get(method)}, allowed={allowed}")
            
            return allowed
                
    except Exception as e:
        print(f"DEBUG: Authorization check failed: {e}")
        return False

@app.get("/resources/{resource_id}")
async def get_resource(
    resource_id: str,
    request: Request,
    user: dict = Depends(auth_middleware)
):
    """Get resource - requires read permission with context awareness"""
    
    # Add context for more sophisticated policy decisions
    context = {
        "resource_type": "document",
        "sensitivity_level": "normal",
        "department": "engineering"
    }
    
    if not await check_authorization(user["user_id"], resource_id, request.method, context):
        raise HTTPException(403, "Access denied")
    
    return {
        "resource_id": resource_id,
        "access": "granted",
        "user": user["user_id"],
        "action": ENDPOINT_ACTIONS[request.method],
        "context": context
    }

@app.put("/resources/{resource_id}")
async def update_resource(
    resource_id: str,
    request: Request,
    request_body: dict,
    user: dict = Depends(auth_middleware)
):
    """Update resource - requires update permission with content awareness"""
    
    # Context-aware authorization based on content
    context = {
        "resource_type": "document",
        "sensitivity_level": request_body.get("sensitivity", "normal"),
        "content_size": len(str(request_body)),
        "modification_type": "content_update",
        "department": "engineering"
    }
    
    if not await check_authorization(user["user_id"], resource_id, request.method, context):
        raise HTTPException(403, "Access denied")
    
    return {
        "resource_id": resource_id,
        "action": "updated",
        "user": user["user_id"],
        "context": context
    }

@app.delete("/resources/{resource_id}")
async def delete_resource(
    resource_id: str,
    request: Request,
    user: dict = Depends(auth_middleware)
):
    """Delete resource - requires delete permission with cascading checks"""
    
    # Complex context for deletion policies
    context = {
        "resource_type": "document",
        "has_dependencies": False,  # In real app, check if resource has children
        "backup_available": True,
        "deletion_reason": "user_request",
        "department": "engineering"
    }
    
    if not await check_authorization(user["user_id"], resource_id, request.method, context):
        raise HTTPException(403, "Access denied")
    
    return {
        "resource_id": resource_id,
        "action": "deleted",
        "user": user["user_id"],
        "context": context
    }

@app.post("/resources/{resource_id}/grant")
async def grant_access(
    resource_id: str,
    request_body: dict,
    user: dict = Depends(auth_middleware)
):
    """Grant access to a resource - requires admin permission"""
    
    context = {
        "resource_type": "document",
        "grant_type": "permission_delegation",
        "target_user": request_body.get("user", "unknown"),
        "permission_level": request_body.get("relation", "read"),
        "department": "engineering"
    }
    
    # Check if user can grant permissions (requires special admin action)
    if not await check_authorization(user["user_id"], resource_id, "POST", {**context, "action": "grant_permission"}):
        raise HTTPException(403, "Only resource administrators can grant access")
    
    target_user = request_body.get("user")
    permission = request_body.get("relation", "read")
    
    try:
        # Dynamically update OPA data with new permission
        async with httpx.AsyncClient() as client:
            # Get current permissions
            current_data_response = await client.get(f"{OPA_URL}/v1/data/permissions")
            current_permissions = {}
            if current_data_response.status_code == 200:
                current_permissions = current_data_response.json().get("result", {})
            
            # Add new permission
            if target_user not in current_permissions:
                current_permissions[target_user] = {}
            if resource_id not in current_permissions[target_user]:
                current_permissions[target_user][resource_id] = {}
            
            current_permissions[target_user][resource_id][permission] = True
            
            # Update OPA data
            update_response = await client.put(
                f"{OPA_URL}/v1/data/permissions",
                json=current_permissions
            )
            
            if update_response.status_code not in [200, 204]:
                raise Exception(f"OPA update failed: {update_response.text}")
        
        return {
            "message": "Access granted successfully",
            "granted_to": target_user,
            "permission": permission,
            "resource": resource_id,
            "context": context
        }
    except Exception as e:
        print(f"DEBUG: Grant permission failed: {e}")
        raise HTTPException(500, "Failed to grant access")

@app.post("/admin/permissions")
async def update_permissions(request_body: dict):
    """Dynamically update permissions and policies in OPA"""
    try:
        async with httpx.AsyncClient() as client:
            updated_sections = []
            
            # Update user permissions
            if "permissions" in request_body:
                await client.put(
                    f"{OPA_URL}/v1/data/permissions",
                    json=request_body["permissions"]
                )
                updated_sections.append("permissions")
            
            # Update group permissions
            if "group_permissions" in request_body:
                await client.put(
                    f"{OPA_URL}/v1/data/group_permissions",
                    json=request_body["group_permissions"]
                )
                updated_sections.append("group_permissions")
            
            # Update user-group mappings
            if "users" in request_body:
                await client.put(
                    f"{OPA_URL}/v1/data/users",
                    json=request_body["users"]
                )
                updated_sections.append("users")
            
            # Update organization data
            if "organizations" in request_body:
                await client.put(
                    f"{OPA_URL}/v1/data/organizations",
                    json=request_body["organizations"]
                )
                updated_sections.append("organizations")
            
            # Update resource metadata
            if "resources" in request_body:
                await client.put(
                    f"{OPA_URL}/v1/data/resources",
                    json=request_body["resources"]
                )
                updated_sections.append("resources")
        
        return {
            "message": "Permissions updated successfully",
            "updated_sections": updated_sections,
            "timestamp": datetime.utcnow().isoformat()
        }
    except Exception as e:
        raise HTTPException(500, f"Failed to update permissions: {str(e)}")

@app.post("/admin/policy")
async def update_policy(request_body: dict):
    """Dynamically update OPA policies"""
    try:
        policy_name = request_body.get("name", "authz")
        policy_content = request_body.get("policy")
        
        if not policy_content:
            raise HTTPException(400, "Policy content is required")
        
        async with httpx.AsyncClient() as client:
            response = await client.put(
                f"{OPA_URL}/v1/policies/{policy_name}",
                headers={"Content-Type": "text/plain"},
                data=policy_content
            )
            
            if response.status_code not in [200, 204]:
                raise Exception(f"Policy update failed: {response.text}")
        
        return {
            "message": f"Policy '{policy_name}' updated successfully",
            "timestamp": datetime.utcnow().isoformat()
        }
    except Exception as e:
        raise HTTPException(500, f"Failed to update policy: {str(e)}")

# Debug endpoints
@app.get("/debug/config")
async def debug_config():
    """Debug endpoint to show current configuration"""
    return {
        "opa_url": OPA_URL,
        "hydra_introspect_url": HYDRA_INTROSPECT_URL,
        "endpoint_actions": ENDPOINT_ACTIONS
    }

@app.get("/debug/opa-data")
async def debug_opa_data():
    """View all OPA data for debugging"""
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(f"{OPA_URL}/v1/data")
            return response.json()
    except Exception as e:
        return {"error": f"Failed to get OPA data: {str(e)}"}

@app.get("/debug/opa-policies")
async def debug_opa_policies():
    """View all OPA policies"""
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(f"{OPA_URL}/v1/policies")
            return response.json()
    except Exception as e:
        return {"error": f"Failed to get OPA policies: {str(e)}"}

@app.post("/debug/opa-query")
async def debug_opa_query(request_body: dict):
    """Execute arbitrary OPA query for debugging"""
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{OPA_URL}/v1/data/{request_body.get('path', 'authz/allow')}",
                json={"input": request_body.get("input", {})}
            )
            return response.json()
    except Exception as e:
        return {"error": f"Failed to query OPA: {str(e)}"}

@app.get("/debug/credentials")
async def debug_credentials():
    """Debug endpoint to get OAuth2 credentials"""
    try:
        client_id = None
        client_secret = None
        
        if os.path.exists("/shared/hydra-client-id"):
            with open("/shared/hydra-client-id", 'r') as f:
                client_id = f.read().strip()
        
        if os.path.exists("/shared/hydra-client-secret"):
            with open("/shared/hydra-client-secret", 'r') as f:
                client_secret = f.read().strip()
        
        return {
            "client_id": client_id,
            "client_secret": client_secret,
            "client_id_file_exists": os.path.exists("/shared/hydra-client-id"),
            "client_secret_file_exists": os.path.exists("/shared/hydra-client-secret")
        }
    except Exception as e:
        return {
            "error": f"Failed to read credentials: {str(e)}",
            "client_id": None,
            "client_secret": None
        }

@app.get("/health")
async def health():
    return {"status": "healthy", "authorization_engine": "OPA"}
from fastapi import FastAPI, HTTPException, Depends, Header, Request
from typing import Optional
import httpx
import json
import os

import openfga_sdk
from openfga_sdk.client import ClientConfiguration, OpenFgaClient

app = FastAPI()

# Environment variables for external services
OPENFGA_URL = os.getenv("OPENFGA_URL", "http://localhost:8080")
OPENFGA_STORE_ID_FILE = os.getenv("OPENFGA_STORE_ID_FILE", "/shared/openfga-store-id")
HYDRA_INTROSPECT_URL = os.getenv("HYDRA_INTROSPECT_URL", "http://localhost:4445/admin/oauth2/introspect")

# Map HTTP methods to required OpenFGA relations (production pattern)
ENDPOINT_PERMISSIONS = {
    "GET": "can_view",
    "POST": "can_edit", 
    "PUT": "can_edit",
    "PATCH": "can_edit",
    "DELETE": "owner"
}

def get_store_id():
    """Read store ID from shared file"""
    try:
        if os.path.exists(OPENFGA_STORE_ID_FILE):
            with open(OPENFGA_STORE_ID_FILE, 'r') as f:
                return f.read().strip()
        return None
    except Exception as e:
        print(f"DEBUG: Error reading store ID file: {e}")
        return None

OPENFGA_STORE_ID = get_store_id()
print(f"DEBUG: Starting with config - OpenFGA: {OPENFGA_URL}, Store: {OPENFGA_STORE_ID}")

# Connection pool for OpenFGA client
_fga_client = None

async def get_fga_client():
    """Get or create OpenFGA client with connection reuse"""
    global _fga_client
    if _fga_client is None:
        current_store_id = get_store_id() or OPENFGA_STORE_ID
        if not current_store_id:
            raise HTTPException(500, "OpenFGA store ID not available")
        
        configuration = ClientConfiguration(
            api_url=OPENFGA_URL,
            store_id=current_store_id,
        )
        _fga_client = OpenFgaClient(configuration)
    return _fga_client

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
            
            # Use preferred_username if available, otherwise fall back to client_id
            user_id = token_info.get("preferred_username") or token_info.get("client_id", "unknown")
            
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

async def check_authorization(user_id: str, resource_id: str, required_permission: str) -> bool:
    """Authorization check - OpenFGA handles group/org resolution automatically"""
    print(f"DEBUG: Authorization check - user_id='{user_id}', resource='{resource_id}', permission='{required_permission}'")
    
    try:
        fga_client = await get_fga_client()
        
        from openfga_sdk.client.models import ClientCheckRequest
        
        check_request = ClientCheckRequest(
            user=f"user:{user_id}",
            relation=required_permission,
            object=f"resource:{resource_id}"
        )
        
        response = await fga_client.check(check_request)
        print(f"DEBUG: OpenFGA response - allowed={response.allowed}")
        return response.allowed
                
    except Exception as e:
        print(f"DEBUG: Authorization check failed: {e}")
        return False

@app.get("/resources/{resource_id}")
async def get_resource(
    resource_id: str,
    request: Request,
    user: dict = Depends(auth_middleware)
):
    """Get resource - requires can_view permission"""
    
    # Map HTTP method to required permission
    required_permission = ENDPOINT_PERMISSIONS[request.method]
    
    # Single authorization check
    if not await check_authorization(user["user_id"], resource_id, required_permission):
        raise HTTPException(403, "Access denied")
    
    return {
        "resource_id": resource_id,
        "access": "granted",
        "user": user["user_id"],
        "permission": required_permission
    }

@app.put("/resources/{resource_id}")
async def update_resource(
    resource_id: str,
    request: Request,
    user: dict = Depends(auth_middleware)
):
    """Update resource - requires can_edit permission"""
    
    required_permission = ENDPOINT_PERMISSIONS[request.method]
    
    if not await check_authorization(user["user_id"], resource_id, required_permission):
        raise HTTPException(403, "Access denied")
    
    return {
        "resource_id": resource_id,
        "action": "updated",
        "user": user["user_id"],
        "permission": required_permission
    }

@app.delete("/resources/{resource_id}")
async def delete_resource(
    resource_id: str,
    request: Request,
    user: dict = Depends(auth_middleware)
):
    """Delete resource - requires owner permission"""
    
    required_permission = ENDPOINT_PERMISSIONS[request.method]
    
    if not await check_authorization(user["user_id"], resource_id, required_permission):
        raise HTTPException(403, "Access denied")
    
    return {
        "resource_id": resource_id,
        "action": "deleted",
        "user": user["user_id"],
        "permission": required_permission
    }

@app.post("/resources/{resource_id}/grant")
async def grant_access(
    resource_id: str,
    request_body: dict,
    user: dict = Depends(auth_middleware)
):
    """Grant access to a resource - requires owner permission"""
    
    # Check if user is owner
    if not await check_authorization(user["user_id"], resource_id, "owner"):
        raise HTTPException(403, "Only resource owners can grant access")
    
    try:
        fga_client = await get_fga_client()
        
        target_user = request_body.get("user")
        relation = request_body.get("relation", "can_view")
        
        # Try to write the tuple directly - OpenFGA will handle duplicates gracefully in newer versions
        from openfga_sdk.client.models import ClientWriteRequest, ClientTuple
        
        write_request = ClientWriteRequest(
            writes=[
                ClientTuple(
                    user=target_user,
                    relation=relation,
                    object=f"resource:{resource_id}"
                )
            ]
        )
        
        try:
            await fga_client.write(write_request)
            return {
                "message": "Access granted successfully",
                "granted_to": target_user,
                "relation": relation,
                "resource": resource_id,
                "status": "newly_granted"
            }
        except Exception as write_error:
            # Check if it's a duplicate tuple error
            if "already exists" in str(write_error).lower():
                return {
                    "message": "Access already granted (no change needed)",
                    "granted_to": target_user,
                    "relation": relation,
                    "resource": resource_id,
                    "status": "already_exists"
                }
            else:
                # Re-raise other errors
                raise write_error
        
    except Exception as e:
        print(f"DEBUG: Grant operation failed: {e}")
        # Log the specific error for debugging
        import traceback
        print(f"DEBUG: Full traceback: {traceback.format_exc()}")
        raise HTTPException(500, f"Failed to grant access: {str(e)}")

# Debug endpoints (remove in production)
@app.get("/debug/config")
async def debug_config():
    """Debug endpoint to show current configuration"""
    return {
        "openfga_url": OPENFGA_URL,
        "openfga_store_id": get_store_id(),
        "hydra_introspect_url": HYDRA_INTROSPECT_URL,
        "endpoint_permissions": ENDPOINT_PERMISSIONS
    }

@app.get("/debug/tuples")
async def debug_tuples():
    """Debug endpoint to view all relationship tuples"""
    try:
        fga_client = await get_fga_client()
        
        from openfga_sdk.client.models import ClientReadRequest
        
        read_request = ClientReadRequest()
        response = await fga_client.read(read_request)
        
        return {
            "tuples": [
                {
                    "user": tuple.user,
                    "relation": tuple.relation,
                    "object": tuple.object
                }
                for tuple in response.tuples
            ],
            "total": len(response.tuples)
        }
    except Exception as e:
        return {"error": f"Failed to read tuples: {str(e)}"}

@app.get("/debug/test-openfga")
async def debug_test_openfga():
    """Debug endpoint to test OpenFGA connectivity and SDK"""
    try:
        fga_client = await get_fga_client()
        
        from openfga_sdk.client.models import ClientCheckRequest
        
        check_request = ClientCheckRequest(
            user="user:test-user",
            relation="can_view",
            object="resource:test-resource"
        )
        
        response = await fga_client.check(check_request)
        return {
            "test_result": "success",
            "response_allowed": response.allowed,
            "response_type": str(type(response))
        }
    except Exception as e:
        return {
            "error": str(e),
            "error_type": str(type(e).__name__)
        }

@app.get("/debug/credentials")
async def debug_credentials():
    """Debug endpoint to get OAuth2 credentials"""
    try:
        client_id = None
        client_secret = None
        
        # Try to read client ID
        if os.path.exists("/shared/hydra-client-id"):
            with open("/shared/hydra-client-id", 'r') as f:
                client_id = f.read().strip()
        
        # Try to read client secret
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
            "client_secret": None,
            "client_id_file_exists": False,
            "client_secret_file_exists": False
        }

@app.get("/health")
async def health():
    return {"status": "healthy"}
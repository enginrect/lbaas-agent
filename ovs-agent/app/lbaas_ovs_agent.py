# =============================
# Entrypoint (FastAPI)
# =============================
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .adaptors import subprocess_runner, ovn_sb_adapter, ovs_adapter
from .usecases import insert_openflow_rule, delete_openflow_rule
from .ports import CommandRunner, OVNSouthboundPort, OVSBridgePort

app = FastAPI(title="LBaaS OVS Agent", version="0.2.0")

runner: CommandRunner = subprocess_runner
ovn: OVNSouthboundPort = ovn_sb_adapter(runner)
ovs: OVSBridgePort = ovs_adapter(runner)

class CreateRuleReq(BaseModel):
    bm_neutron_port_id: str = Field(..., description="baremetal's neutron port id (UUID)")
    cookie_value: str = Field(..., description="hex string without 0x (1..16 hex digits)")

@app.post("/v1/openflow/rule")
def create_rule(req: CreateRuleReq):
    try:
        return insert_openflow_rule(req.bm_neutron_port_id, req.cookie_value, ovn, ovs)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        msg = str(e)
        if "already used" in msg:
            raise HTTPException(status_code=409, detail=msg)
        if "not found" in msg:
            raise HTTPException(status_code=404, detail=msg)
        raise HTTPException(status_code=500, detail=msg)

@app.delete("/v1/openflow/rule/{cookie_value}")
def delete_rule(cookie_value: str):
    try:
        return delete_openflow_rule(cookie_value, ovs)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        msg = str(e)
        if "not found" in msg:
            raise HTTPException(status_code=404, detail=msg)
        if "Too many" in msg or "validation failed" in msg:
            raise HTTPException(status_code=409, detail=msg)
        raise HTTPException(status_code=500, detail=msg)

@app.get("/healthz")
def healthz():
    return {"ok": True}

def main():
    import uvicorn
    uvicorn.run("app.lbaas_ovs_agent:app", host="127.0.0.1", port=8088)
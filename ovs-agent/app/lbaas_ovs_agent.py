# =============================
# Entrypoint (FastAPI)
# =============================
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from adaptors import subprocess_runner, ovn_sb_adapter, ovs_adapter
from usecases import insert_openflow_rule, delete_openflow_rule
from ports import CommandRunner, OVNSouthboundPort, OVSBridgePort

app = FastAPI(title="LBaaS OVS Agent", version="0.1.0")

# Ports (adapters)
runner: CommandRunner = subprocess_runner
ovn: OVNSouthboundPort = ovn_sb_adapter(runner)
ovs: OVSBridgePort = ovs_adapter(runner)

class InsertBody(BaseModel):
    bm_neutron_port_id: str = Field(..., description="baremetal의 neutron port id (UUID)")
    cookie_value: str = Field(..., description="생성할 rule의 cookie 값 (hex, without 0x)")

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.post("/v1/openflow/rule")
def post_openflow_rule(body: InsertBody):
    try:
        return insert_openflow_rule(body.bm_neutron_port_id, body.cookie_value, ovn, ovs)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.delete("/v1/openflow/rule/{cookie_value}")
def delete_openflow(cookie_value: str):
    try:
        return delete_openflow_rule(cookie_value, ovs)
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

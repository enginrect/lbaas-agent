# domain.py
import re
from dataclasses import dataclass

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
MAC_RE  = re.compile(r"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$")
HEX_RE  = re.compile(r"^[0-9a-fA-F]{1,16}$")  # cookie (0x 없이 최대 16자리)

def _lines(t: str) -> list[str]:
    return [x.strip() for x in (t or "").splitlines() if x.strip()]

def _to_0x(n: int) -> str:
    return f"0x{n:x}"

@dataclass(frozen=True)
class PortBindingInfo:
    datapath_uuid: str
    pb_tunnel_key: int

@dataclass(frozen=True)
class DatapathInfo:
    dp_uuid: str
    dp_tunnel_key: int

def parse_port_binding_find(text: str) -> PortBindingInfo:
    """
    기대 입력 (BARE):
      줄1: datapath uuid
      줄2: port_binding tunnel_key (10진 또는 0x..)
    """
    ls = _lines(text)
    if len(ls) < 2:
        raise ValueError("port_binding not found")
    dp_uuid, pb_tk_s = ls[0], ls[1]
    if not UUID_RE.match(dp_uuid):
        # 혹시 순서가 뒤바뀐 환경 방어
        if UUID_RE.match(pb_tk_s):
            dp_uuid, pb_tk_s = pb_tk_s, dp_uuid
        else:
            raise ValueError("invalid datapath uuid")
    try:
        pb_tk = int(pb_tk_s, 0)
    except ValueError:
        raise ValueError("invalid tunnel_key in port_binding")
    return PortBindingInfo(datapath_uuid=dp_uuid, pb_tunnel_key=pb_tk)

def parse_datapath_binding(text: str, target_dp_uuid: str) -> DatapathInfo:
    """
    기대 입력 (BARE):
      한 줄: dp tunnel_key
    """
    ls = _lines(text)
    if not ls:
        raise ValueError("datapath_binding not found")
    try:
        dp_tk = int(ls[0], 0)
    except ValueError:
        raise ValueError("invalid tunnel_key in datapath_binding")
    return DatapathInfo(dp_uuid=target_dp_uuid, dp_tunnel_key=dp_tk)

def parse_service_monitor_src_mac(text: str) -> str:
    """
    기대 입력 (BARE):
      한 줄: src_mac
    """
    ls = _lines(text)
    if not ls:
        raise ValueError("service_monitor not found")
    mac = ls[0]
    if not MAC_RE.match(mac):
        raise ValueError("invalid src_mac")
    return mac

def build_add_flow_cmd(of_version: str, bridge: str,
                       *, cookie_hex: str, table: int, priority: int,
                       dp_tunnel_key: int, hm_mac: str,
                       pb_tunnel_key: int, userdata: str) -> list[str]:
    if not HEX_RE.match(cookie_hex):
        raise ValueError("cookie_value must be 1..16 hex digits (without 0x)")
    flow = (
        f"cookie=0x{cookie_hex.lower()},table={table},priority={priority},tcp,"
        f"metadata={_to_0x(dp_tunnel_key)},dl_dst={hm_mac} "
        f"actions=load:{_to_0x(pb_tunnel_key)}->NXM_NX_REG14[],"
        f"controller(userdata={userdata})"
    )
    return ["ovs-ofctl", "-O", of_version, "add-flow", bridge, flow]
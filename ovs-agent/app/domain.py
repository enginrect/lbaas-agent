# =============================
# Domain (Pure Functions Only)
# =============================
import re
from dataclasses import dataclass

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
MAC_RE = re.compile(r"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$")
HEX_RE = re.compile(r"^[0-9a-fA-F]{1,16}$")  # up to 64-bit cookie

@dataclass(frozen=True)
class PortBindingInfo:
    datapath_uuid: str
    pb_tunnel_key: int

@dataclass(frozen=True)
class DatapathInfo:
    dp_tunnel_key: int

def _lines(s: str) -> list[str]:
    return [ln.strip() for ln in (s or "").splitlines() if ln.strip()]

def parse_port_binding_tunnel_key(text: str) -> int:
    """ovn-sbctl --bare --columns=tunnel_key find port_binding logical_port=..."""
    ls = _lines(text)
    if not ls:
        raise ValueError("baremetal's logical switch port not found")
    val = ls[0]
    try:
        return int(val, 0)
    except ValueError:
        raise ValueError("invalid port_binding.tunnel_key")

def parse_port_binding_datapath(text: str) -> str:
    """ovn-sbctl --bare --columns=datapath find port_binding logical_port=..."""
    ls = _lines(text)
    if not ls:
        raise ValueError("baremetal's datapath not found")
    dp_uuid = ls[0]
    if not UUID_RE.match(dp_uuid):
        raise ValueError("invalid datapath uuid")
    return dp_uuid

def parse_datapath_binding_list_for_tunnel_key(text: str) -> int:
    """ovn-sbctl list datapath_binding <uuid> → parse line 'tunnel_key : <int>'"""
    # Accept formats: 'tunnel_key          : 4' or 'tunnel_key : 0x4'
    for ln in _lines(text):
        if ln.lower().startswith("tunnel_key") and ":" in ln:
            right = ln.split(":",1)[1].strip()
            try:
                return int(right, 0)
            except ValueError:
                pass
    raise ValueError("datapath_binding.tunnel_key not found")

def parse_service_monitor_src_mac(text: str) -> str:
    """ovn-sbctl --bare --columns=src_mac find service_monitor logical_port=..."""
    ls = _lines(text)
    if not ls:
        raise ValueError("baremetal's service monitor not found")
    mac = ls[0]
    if not MAC_RE.match(mac):
        raise ValueError("invalid service_monitor.src_mac")
    return mac

def to_hex_0x(val: int) -> str:
    return f"0x{val:x}"

def build_add_flow_cmd(of_version: str, bridge: str,
                       *, cookie_hex: str, table: int, priority: int,
                       dp_tunnel_key: int, hm_mac: str,
                       pb_tunnel_key: int, userdata: str) -> list[str]:
    if not HEX_RE.match(cookie_hex):
        raise ValueError("cookie_value must be 1..16 hex chars")
    cookie_str = f"0x{cookie_hex.lower()}"
    flow = (
        f"cookie={cookie_str},table={table},priority={priority},tcp,"
        f"metadata={to_hex_0x(dp_tunnel_key)},dl_dst={hm_mac} "
        f"actions=load:{to_hex_0x(pb_tunnel_key)}->NXM_NX_REG14[],"
        f"controller(userdata={userdata})"
    )
    return ["ovs-ofctl", "-O", of_version, "add-flow", bridge, flow]

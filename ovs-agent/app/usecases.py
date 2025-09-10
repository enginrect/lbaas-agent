import re
from typing import Mapping

from .domain import (
    build_add_flow_cmd,
    parse_port_binding_tunnel_key,
    parse_port_binding_datapath,
    parse_datapath_binding_list_for_tunnel_key,
    parse_service_monitor_src_mac,
    UUID_RE, HEX_RE
)
from .ports import OVSBridgePort, OVNSouthboundPort

OF_VERSION = "OpenFlow15"
BRIDGE = "br-int"
TABLE = 36
PRIORITY = 110
OVS_CONTAINER = "openvswitch_vswitchd"
OVN_CONTAINER = "ovn_sb_db"
USERDATA = "00.00.00.12.00.00.00.00"

def _find_cookie_lines(ovs: OVSBridgePort, cookie_hex: str) -> list[str]:
    txt = ovs.dump_flows_filter(OVS_CONTAINER, OF_VERSION, BRIDGE, f"cookie=0x{cookie_hex}/-1")
    return [ln.strip() for ln in txt.splitlines() if "cookie=" in ln]

def _is_lbaas_action(line: str) -> bool:
    reg14_ok = re.search(r"set_field:0x[0-9a-fA-F]+->reg14\b", line) is not None
    userdata_ok = f"controller(userdata={USERDATA})" in line
    return bool(reg14_ok and userdata_ok)

def _find_same_match_lines(ovs: OVSBridgePort, dp_tunnel_key: int, hm_mac: str) -> list[str]:
    txt = ovs.dump_flows(OVS_CONTAINER, OF_VERSION, BRIDGE)
    expected = {
        f"table={TABLE}",
        f"priority={PRIORITY}",
        "tcp",
        f"metadata=0x{dp_tunnel_key:x}",
        f"dl_dst={hm_mac}",
    }
    hits: list[str] = []
    for raw in txt.splitlines():
        line = raw.strip()
        if not line:
            continue
        lhs = line.split("actions=", 1)[0]
        tokens = {t.strip() for t in lhs.split(",") if t.strip()}
        if expected.issubset(tokens):
            hits.append(line)
    return hits

def insert_openflow_rule(bm_neutron_port_id: str, cookie_value: str,
                         ovn: OVNSouthboundPort, ovs: OVSBridgePort) -> Mapping[str, str]:
    # 0) validate inputs
    if not UUID_RE.match(bm_neutron_port_id):
        raise ValueError("bm_neutron_port_id must be UUID like xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
    if not HEX_RE.match(cookie_value):
        raise ValueError("cookie_value must be 1..16 hex chars (without 0x)")

    cookie_value = cookie_value.lower()

    # 1) seek duplicated cookie value
    if _find_cookie_lines(ovs, cookie_value):
        raise RuntimeError("cookie_value is already used")

    # 2) find in OVN SB DB
    pb_tk_text = ovn.port_binding_tunnel_key(OVN_CONTAINER, bm_neutron_port_id)
    pb_tunnel_key = parse_port_binding_tunnel_key(pb_tk_text)

    dp_text = ovn.port_binding_datapath(OVN_CONTAINER, bm_neutron_port_id)
    dp_uuid = parse_port_binding_datapath(dp_text)

    dp_list_text = ovn.datapath_binding_list(OVN_CONTAINER, dp_uuid)
    dp_tunnel_key = parse_datapath_binding_list_for_tunnel_key(dp_list_text)

    sm_text = ovn.service_monitor_src_mac(OVN_CONTAINER, bm_neutron_port_id)
    hm_mac = parse_service_monitor_src_mac(sm_text)

    # 3) seek duplicated matched/action line
    same = _find_same_match_lines(ovs, dp_tunnel_key, hm_mac)
    if same:
        exist_cookies = []
        has_our_action = False
        for ln in same:
            m = re.search(r"cookie=0x([0-9a-fA-F]+)", ln)
            if m:
                exist_cookies.append(m.group(1).lower())
            if _is_lbaas_action(ln):
                has_our_action = True
        suffix = f" (existing cookies: {', '.join(exist_cookies)})" if exist_cookies else ""
        if has_our_action:
            raise RuntimeError(f"OpenFlow rule for this match already exists as LBaaS rule{suffix}")
        else:
            raise RuntimeError(f"Conflicting OpenFlow rule exists with the same match; refusing to override{suffix}")

    # 4) add-flow
    argv = build_add_flow_cmd(
        OF_VERSION, BRIDGE,
        cookie_hex=cookie_value,
        table=TABLE, priority=PRIORITY,
        dp_tunnel_key=dp_tunnel_key, hm_mac=hm_mac,
        pb_tunnel_key=pb_tunnel_key, userdata=USERDATA
    )
    ovs.add_flow(OVS_CONTAINER, argv)

    return {"cookie_value": cookie_value, "rule": argv[-1]}

def delete_openflow_rule(cookie_value: str, ovs: OVSBridgePort) -> Mapping[str, bool]:
    if not HEX_RE.match(cookie_value):
        raise ValueError("cookie_value must be 1..16 hex digits (without 0x)")
    cookie_value = cookie_value.lower()

    lines = _find_cookie_lines(ovs, cookie_value)
    if not lines:
        raise RuntimeError(f"OpenFlow rule not found (cookie_value : {cookie_value})")
    if len(lines) > 1:
        raise RuntimeError(f"Too many OpenFlow rule was found (cookie_value : {cookie_value})")

    line = lines[0]
    required = [f"table={TABLE}", f"priority={PRIORITY}", "tcp", f"controller(userdata={USERDATA})"]
    for part in required:
        if part not in line:
            raise RuntimeError(f"OpenFlow rule validation failed: missing '{part}'")
    if not _is_lbaas_action(line):
        raise RuntimeError("OpenFlow rule validation failed: reg14 write action not found")

    cookie_int = int(cookie_value, 16)
    ovs.del_flows_by_cookie(OVS_CONTAINER, OF_VERSION, BRIDGE, cookie_int)
    return {"ok": True}

import re
from typing import Mapping

from domain import (
    UUID_RE, HEX_RE,
    parse_port_binding_find,
    parse_datapath_binding,
    parse_service_monitor_src_mac,
    build_add_flow_cmd,
)
from ports import OVNSouthboundPort, OVSBridgePort

OVN_CONTAINER = "ovn_sb_db"
OVS_CONTAINER = "openvswitch_vswitchd"
BRIDGE        = "br-int"
OF_VERSION    = "OpenFlow15"
TABLE         = 36
PRIORITY      = 110
USERDATA      = "00.00.00.12.00.00.00.00"

def _find_cookie_lines(ovs: OVSBridgePort, cookie_hex: str) -> list[str]:
    txt = ovs.dump_flows(OVS_CONTAINER, OF_VERSION, BRIDGE)
    pat = re.compile(rf"cookie=0x{cookie_hex.lower()}(?:/|-|\b)")
    return [line for line in txt.splitlines() if pat.search(line)]

def insert_openflow_rule(bm_neutron_port_id: str, cookie_value: str,
                         ovn: OVNSouthboundPort, ovs: OVSBridgePort) -> Mapping[str, str]:
    # 입력 검증
    if not UUID_RE.match(bm_neutron_port_id):
        raise ValueError("bm_neutron_port_id must be UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)")
    if not HEX_RE.match(cookie_value):
        raise ValueError("cookie_value must be 1..16 hex digits (without 0x)")
    cookie_value = cookie_value.lower()

    # 1) 쿠키 중복 검사
    if _find_cookie_lines(ovs, cookie_value):
        raise RuntimeError("cookie_value is already used")

    # 2) OVN 조회 (전부 --bare 출력 파싱)
    pb_text = ovn.port_binding_find(OVN_CONTAINER, bm_neutron_port_id)
    try:
        pb = parse_port_binding_find(pb_text)
    except ValueError as e:
        raise RuntimeError(f"baremetal's logical switch port not found (bm_neutron_port_id : {bm_neutron_port_id})")

    dp_text = ovn.datapath_binding_find(OVN_CONTAINER, pb.datapath_uuid)
    try:
        dp = parse_datapath_binding(dp_text, pb.datapath_uuid)
    except ValueError:
        raise RuntimeError(f"baremetal's datapath not found (bm_neutron_port_id : {bm_neutron_port_id})")

    sm_text = ovn.service_monitor_find(OVN_CONTAINER, bm_neutron_port_id)
    try:
        hm_mac = parse_service_monitor_src_mac(sm_text)
    except ValueError:
        raise RuntimeError(f"baremetal's service monitor not found (bm_neutron_port_id : {bm_neutron_port_id})")

    # 3) add-flow
    argv = build_add_flow_cmd(
        OF_VERSION, BRIDGE,
        cookie_hex=cookie_value, table=TABLE, priority=PRIORITY,
        dp_tunnel_key=dp.dp_tunnel_key, hm_mac=hm_mac,
        pb_tunnel_key=pb.pb_tunnel_key, userdata=USERDATA
    )
    ovs.add_flow(OVS_CONTAINER, argv)

    return {
        "cookie_value": cookie_value,
        "rule": argv[-1]
    }

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

    cookie_int = int(cookie_value, 16)
    ovs.del_flows_by_cookie(OVS_CONTAINER, OF_VERSION, BRIDGE, cookie_int)
    return {"ok": True}
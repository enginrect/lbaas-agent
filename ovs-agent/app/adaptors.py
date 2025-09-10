# =============================
# Adapters (subprocess + docker exec)
# =============================
import subprocess
from .ports import CommandRunner, OVNSouthboundPort, OVSBridgePort

def subprocess_runner(argv: list[str], timeout: int = 10) -> str:
    """Run a command without shell. Raise on non-zero."""
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"timeout: {' '.join(argv)}")
    if res.returncode != 0:
        raise RuntimeError(f"cmd failed: {' '.join(argv)}\n{res.stderr.strip()}")
    return res.stdout

# ---------- OVN southbound ----------
def ovn_sb_adapter(runner: CommandRunner) -> OVNSouthboundPort:
    def port_binding_tunnel_key(container: str, neutron_port_id: str) -> str:
        return runner([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=tunnel_key",
            "find","port_binding", f"logical_port={neutron_port_id}"
        ])

    def port_binding_datapath(container: str, neutron_port_id: str) -> str:
        return runner([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=datapath",
            "find","port_binding", f"logical_port={neutron_port_id}"
        ])

    def datapath_binding_list(container: str, datapath_uuid: str) -> str:
        # list by _uuid only; 'find' doesn't accept _uuid column for Datapath_Binding
        return runner([
            "docker","exec","-i",container,
            "ovn-sbctl","list","datapath_binding", datapath_uuid
        ])

    def service_monitor_src_mac(container: str, neutron_port_id: str) -> str:
        return runner([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=src_mac",
            "find","service_monitor", f"logical_port={neutron_port_id}"
        ])

    class _OVN(OVNSouthboundPort):
        port_binding_tunnel_key = staticmethod(port_binding_tunnel_key)
        port_binding_datapath = staticmethod(port_binding_datapath)
        datapath_binding_list = staticmethod(datapath_binding_list)
        service_monitor_src_mac = staticmethod(service_monitor_src_mac)
    return _OVN()

# ---------- OVS bridge ----------
def ovs_adapter(runner: CommandRunner) -> OVSBridgePort:
    def dump_flows(container: str, of_version: str, bridge: str) -> str:
        return runner(["docker","exec","-i",container,
                       "ovs-ofctl","-O",of_version,"dump-flows",bridge])

    def dump_flows_filter(container: str, of_version: str, bridge: str, match_filter: str) -> str:
        # match_filter example: 'cookie=0xfeedcafe/-1'
        return runner(["docker","exec","-i",container,
                       "ovs-ofctl","-O",of_version,"dump-flows",bridge, match_filter])

    def add_flow(container: str, argv: list[str]) -> None:
        runner(["docker","exec","-i",container] + argv)

    def del_flows_by_cookie(container: str, of_version: str, bridge: str, cookie: int) -> None:
        runner(["docker","exec","-i",container,
                "ovs-ofctl","-O",of_version,"del-flows",bridge, f"cookie=0x{cookie:x}/-1"])

    class _OVS(OVSBridgePort):
        dump_flows = staticmethod(dump_flows)
        dump_flows_filter = staticmethod(dump_flows_filter)
        add_flow = staticmethod(add_flow)
        del_flows_by_cookie = staticmethod(del_flows_by_cookie)
    return _OVS()

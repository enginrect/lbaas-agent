# =============================
# Adapters (subprocess + docker exec)
# =============================
from __future__ import annotations
import subprocess
from .ports import CommandRunner, OVNSouthboundPort, OVSBridgePort

def subprocess_runner(argv: list[str], timeout: int = 10) -> str:
    """Run a command without shell. Raise on non-zero."""
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"timeout: {' '.join(argv)}")
    if res.returncode != 0:
        err = (res.stderr or "").strip()
        raise RuntimeError(f"cmd failed: {' '.join(argv)}\n{err}")
    # stdout may end with newline
    return res.stdout

# ---------- OVN southbound ----------
class OVNAdapter(OVNSouthboundPort):
    def __init__(self, runner: CommandRunner):
        self._run = runner

    def port_binding_tunnel_key(self, container: str, neutron_port_id: str) -> str:
        # logical_port는 문자열 → 반드시 따옴표로 감싸야 함
        return self._run([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=tunnel_key",
            "find","port_binding", f'logical_port="{neutron_port_id}"'
        ])

    def port_binding_datapath(self, container: str, neutron_port_id: str) -> str:
        return self._run([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=datapath",
            "find","port_binding", f'logical_port="{neutron_port_id}"'
        ])

    def datapath_binding_list(self, container: str, datapath_uuid: str) -> str:
        # Datapath_Binding은 _uuid로만 접근 → list 사용
        # 숫자만 한 줄로 받기 위해 --bare + --columns=tunnel_key 사용
        return self._run([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=tunnel_key",
            "list","datapath_binding", datapath_uuid
        ])

    def service_monitor_src_mac(self, container: str, neutron_port_id: str) -> str:
        return self._run([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=src_mac",
            "find","service_monitor", f'logical_port="{neutron_port_id}"'
        ])

# ---------- OVS bridge ----------
class OVSAdapter(OVSBridgePort):
    def __init__(self, runner: CommandRunner):
        self._run = runner

    def dump_flows(self, container: str, of_version: str, bridge: str) -> str:
        return self._run([
            "docker","exec","-i",container,
            "ovs-ofctl","-O",of_version,"dump-flows",bridge
        ])

    def dump_flows_filter(self, container: str, of_version: str, bridge: str, match_filter: str) -> str:
        # 예: match_filter = 'cookie=0xfeedcafe/-1' (priority 같은 건 넣지 말 것)
        return self._run([
            "docker","exec","-i",container,
            "ovs-ofctl","-O",of_version,"dump-flows",bridge, match_filter
        ])

    def add_flow(self, container: str, argv: list[str]) -> None:
        # argv는 ["ovs-ofctl","-O","OpenFlow15","add-flow","br-int", "<flow>"] 형태라고 가정
        self._run(["docker","exec","-i",container] + argv)

    def del_flows_by_cookie(self, container: str, of_version: str, bridge: str, cookie: int) -> None:
        self._run([
            "docker","exec","-i",container,
            "ovs-ofctl","-O",of_version,"del-flows",bridge, f"cookie=0x{cookie:x}/-1"
        ])

# factory helpers
def ovn_sb_adapter(runner: CommandRunner) -> OVNSouthboundPort:
    return OVNAdapter(runner)

def ovs_adapter(runner: CommandRunner) -> OVSBridgePort:
    return OVSAdapter(runner)
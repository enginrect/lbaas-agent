# adaptors.py
import subprocess
from .ports import CommandRunner, OVNSouthboundPort, OVSBridgePort

def subprocess_runner(argv: list[str], timeout: int = 10) -> str:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"timeout: {' '.join(argv)}")
    if p.returncode != 0:
        raise RuntimeError(f"cmd failed: {' '.join(argv)}\n{p.stderr.strip()}")
    return p.stdout

class OVNAdapter:
    def __init__(self, runner: CommandRunner):
        self._run = runner

    def port_binding_find(self, container: str, neutron_port_id: str) -> str:
        return self._run([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=datapath,tunnel_key",
            "find","port_binding", f'logical_port="{neutron_port_id}"'
        ])

    def datapath_binding_find(self, container: str, datapath_uuid: str) -> str:
        return self._run([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=tunnel_key",
            "list","datapath_binding", datapath_uuid
        ])

    def service_monitor_find(self, container: str, neutron_port_id: str) -> str:
        return self._run([
            "docker","exec","-i",container,
            "ovn-sbctl","--bare","--columns=src_mac",
            "find","service_monitor", f'logical_port="{neutron_port_id}"'
        ])

class OVSAdapter:
    def __init__(self, runner: CommandRunner):
        self._run = runner

    def dump_flows(self, container: str, of_version: str, bridge: str) -> str:
        return self._run(["docker","exec","-i",container,
                          "ovs-ofctl","-O",of_version,"dump-flows",bridge])

    def add_flow(self, container: str, argv: list[str]) -> None:
        self._run(["docker","exec","-i",container] + argv)

    def del_flows_by_cookie(self, container: str, of_version: str, bridge: str, cookie: int) -> None:
        self._run(["docker","exec","-i",container,
                   "ovs-ofctl","-O",of_version,"del-flows",bridge, f"cookie=0x{cookie:x}/-1"])

def ovn_sb_adapter(runner: CommandRunner) -> OVNSouthboundPort:
    return OVNAdapter(runner)

def ovs_adapter(runner: CommandRunner) -> OVSBridgePort:
    return OVSAdapter(runner)
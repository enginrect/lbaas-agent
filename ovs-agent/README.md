# LBaaS OVS Agent (Go, Hexagonal)

This is a Go port of the Python LBaaS OVS agent. It:
- Connects to **OVN Southbound** using `github.com/ovn-org/libovsdb`.
- Interacts with **OVS** via `docker exec <openvswitch_vswitchd> ovs-ofctl` (same behavior as the Python agent).
- Exposes a small HTTP API:
  - `GET /healthz`
  - `POST /flows` with JSON `{ "cookie_value": "<hex>", "bm_neutron_port_id": "<neutron-port-uuid>" }`
  - `DELETE /flows/{cookie_value}`

## Config (env)
- `OVN_SB_ENDPOINT` (default `tcp:127.0.0.1:6642`)
- `OVS_CONTAINER` (default `openvswitch_vswitchd`)

## Build
Requires Go 1.25.
```bash
go mod download
go build -o bin/lbaas-ovs-agent ./cmd/lbaas-ovs-agent
./bin/lbaas-ovs-agent -bind 0.0.0.0:9406
```

## Install (systemd)
Use the provided scripts:
```bash
sudo ./scripts/install.sh
# ... to remove later
sudo ./scripts/cleanup.sh --yes
```

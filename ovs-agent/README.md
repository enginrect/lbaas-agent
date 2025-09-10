# LBaaS OVS Agent

## 1. 개요

- **목적**: 백엔드 애플리케이션이 Open vSwitch(OVS)에 OpenFlow 룰을 직접 삽입/삭제할 수 있게 하는 로컬 에이전트
- **환경**:
  - OpenStack Controller Node에서 Docker로 **OVN SB DB**(`ovn_sb_db`), **OVS**(`openvswitch_vswitchd`) 실행
  - 에이전트는 **localhost:8088**에서 FastAPI(uvicorn)로 동작
- **동작 흐름(삽입)**:
  1) **중복 쿠키 확인**: `ovs-ofctl -O OpenFlow15 dump-flows br-int "cookie=0x{cookie}/-1"`
  2) **OVN 조회(모두 --bare)**  
     - PB → `ovn-sbctl --bare --columns=datapath,tunnel_key find port_binding logical_port="{bm_neutron_port_id}"`  
       (줄1: dp uuid, 줄2: pb tunnel_key)  
     - DP → `ovn-sbctl --bare --columns=tunnel_key list datapath_binding <dp_uuid>`  
       (줄1: dp tunnel_key) ← **find가 아니라 list!**  
     - SM → `ovn-sbctl --bare --columns=src_mac find service_monitor logical_port="{bm_neutron_port_id}"`
  3) **OVS 룰 삽입**:  
     ```
     ovs-ofctl -O OpenFlow15 add-flow br-int \
       "cookie=0x{cookie},table=36,priority=110,tcp,metadata=0x{dp_tk},dl_dst={src_mac} \
        actions=load:0x{pb_tk}->NXM_NX_REG14[],controller(userdata=00.00.00.12.00.00.00.00)"
     ```

---

## 2. 설치방법

> 예시 OS: Ubuntu 24.04  
> 경로: `/opt/lbaasovsagent`  
> 사용자: `lbaasovsagent` (docker 그룹 포함)

1) 폴더/유저 준비
```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin lbaasovsagent
sudo usermod -aG docker lbaasovsagent

sudo mkdir -p /opt/lbaasovsagent
sudo chown -R lbaasovsagent:lbaasovsagent /opt/lbaasovsagent
```
2) 코드/가상환경
```bash
# 다음 파일을 /opt/lbaasovsagent 에 배치:
# adaptors.py, domain.py, ports.py, usecases.py, lbaas_ovs_agent.py
sudo -u lbaasovsagent python3 -m venv /opt/lbaasovsagent/venv
sudo -u lbaasovsagent /opt/lbaasovsagent/venv/bin/pip install --upgrade pip
sudo -u lbaasovsagent /opt/lbaasovsagent/venv/bin/pip install \
  "fastapi==0.115.0" "uvicorn[standard]==0.30.6" "pydantic==2.8.2"
```
3) systemd 유닛

```unit file (systemd)
# /etc/systemd/system/ovs-agent.service
[Unit]
Description=LBaaS OVS Agent (FastAPI)
After=network.target docker.service
Requires=docker.service

[Service]
WorkingDirectory=/opt/lbaasovsagent
ExecStart=/opt/lbaasovsagent/venv/bin/uvicorn lbaas_ovs_agent:app --host 127.0.0.1 --port 8088
User=lbaasovsagent
Group=lbaasovsagent
Restart=always
RestartSec=2
Environment="PYTHONUNBUFFERED=1"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/lbaasovsagent
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ovs-agent
sudo systemctl status ovs-agent --no-pager
```

## 3. 테스트 curl
### 3-1) 생성 (POST /v1/openflow/rule)
```bash
curl -s -X POST http://127.0.0.1:8088/v1/openflow/rule \
  -H 'Content-Type: application/json' \
  -d '{
    "bm_neutron_port_id": "4b8bc0ad-9942-4381-90f6-dfce865ddef8",
    "cookie_value": "feedcafe"
  }' | jq
```
성공 예
```json
{
  "cookie_value": "feedcafe",
  "rule": "cookie=0xfeedcafe,table=36,priority=110,tcp,metadata=0x4,dl_dst=66:df:ec:fc:64:f0 actions=load:0x2e->NXM_NX_REG14[],controller(userdata=00.00.00.12.00.00.00.00)"
}
```

### 3-2) 삭제 (DELETE /v1/openflow/rule/{cookie_value})

```bash
curl -s -X DELETE http://127.0.0.1:8088/v1/openflow/rule/feedcafe | jq
# {"ok": true}
```

오류 케이스:
- 중복 생성: 409 cookie_value is already used
- 삭제 대상 없음: 404 OpenFlow rule not found (cookie_value : feedcafe)
- 룰 여러 개 매치: 409 Too many OpenFlow rule was found (cookie_value : feedcafe)
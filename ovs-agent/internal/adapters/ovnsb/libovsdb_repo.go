package ovnsb

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/ovn-org/libovsdb/client"
	"github.com/ovn-org/libovsdb/model"
)

// Minimal models we need from OVN_Southbound
type PortBinding struct {
	UUID        string `ovsdb:"_uuid"`
	LogicalPort string `ovsdb:"logical_port"`
	Datapath    string `ovsdb:"datapath"`   // weak ref uuid as string
	TunnelKey   *int   `ovsdb:"tunnel_key"` // optional
}

type DatapathBinding struct {
	UUID      string `ovsdb:"_uuid"`
	TunnelKey *int   `ovsdb:"tunnel_key"`
}

type ServiceMonitor struct {
	UUID        string `ovsdb:"_uuid"`
	LogicalPort string `ovsdb:"logical_port"`
	SrcMAC      string `ovsdb:"src_mac"`
}

type LibOVNSB struct {
	cli client.Client
}

func NewLibOVNSB() (*LibOVNSB, error) {
	endpoint := os.Getenv("OVN_SB_ENDPOINT")
	if endpoint == "" {
		// Default to SB on tcp:127.0.0.1:6642
		endpoint = "tcp:127.0.0.1:6642"
	}
	dbModel, err := model.NewClientDBModel("OVN_Southbound", map[string]model.Model{
		"Port_Binding":     &PortBinding{},
		"Datapath_Binding": &DatapathBinding{},
		"Service_Monitor":  &ServiceMonitor{},
	})
	if err != nil { return nil, err }

	cli, err := client.NewOVSDBClient(*dbModel, client.WithEndpoint(endpoint))
	if err != nil { return nil, err }
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := cli.Connect(ctx); err != nil { return nil, err }
	// Monitor for cache usage
	if err := cli.MonitorAll(ctx); err != nil { return nil, err }
	return &LibOVNSB{cli: cli}, nil
}

func (s *LibOVNSB) PortBindingTunnelKey(logicalPort string) (int, error) {
	var pbs []PortBinding
	// Query cache to reduce load
	if err := s.cli.WhereCache(func(pb *PortBinding) bool { return pb.LogicalPort == logicalPort }).List(&pbs); err != nil {
		return 0, err
	}
	if len(pbs) == 0 { return 0, fmt.Errorf("baremetal's logical switch port not found") }
	// Take first match
	if pbs[0].TunnelKey == nil {
		return 0, fmt.Errorf("invalid tunnel_key in port_binding")
	}
	return *pbs[0].TunnelKey, nil
}

func (s *LibOVNSB) PortBindingDatapathUUID(logicalPort string) (string, error) {
	var pbs []PortBinding
	if err := s.cli.WhereCache(func(pb *PortBinding) bool { return pb.LogicalPort == logicalPort }).List(&pbs); err != nil {
		return "", err
	}
	if len(pbs) == 0 { return "", fmt.Errorf("baremetal's logical switch port not found") }
	v := strings.TrimSpace(pbs[0].Datapath)
	if v == "" { return "", fmt.Errorf("invalid datapath in port_binding") }
	return v, nil
}

func (s *LibOVNSB) DatapathBindingTunnelKey(datapathUUID string) (int, error) {
	var dps []DatapathBinding
	// Lookup by UUID index
	q := &DatapathBinding{UUID: datapathUUID}
	if err := s.cli.Where(q).List(&dps); err != nil {
		return 0, err
	}
	if len(dps) == 0 { return 0, fmt.Errorf("datapath_binding not found") }
	if dps[0].TunnelKey == nil { return 0, fmt.Errorf("invalid tunnel_key in datapath_binding") }
	return *dps[0].TunnelKey, nil
}

func (s *LibOVNSB) ServiceMonitorSrcMAC(logicalPort string) (string, error) {
	var sms []ServiceMonitor
	if err := s.cli.WhereCache(func(sm *ServiceMonitor) bool { return sm.LogicalPort == logicalPort }).List(&sms); err != nil {
		return "", err
	}
	if len(sms) == 0 { return "", fmt.Errorf("baremetal's service monitor not found") }
	v := strings.TrimSpace(sms[0].SrcMAC)
	if v == "" { return "", fmt.Errorf("invalid src_mac in service_monitor") }
	return v, nil
}

package ports

// OVNSouthboundPort is a hexagonal port for accessing OVN SB DB.
type OVNSouthboundPort interface {
	PortBindingTunnelKey(logicalPort string) (int, error)
	PortBindingDatapathUUID(logicalPort string) (string, error)
	DatapathBindingTunnelKey(datapathUUID string) (int, error)
	ServiceMonitorSrcMAC(logicalPort string) (string, error)
}

// OVSBridgePort is a hexagonal port for manipulating OpenFlow rules in OVS (via ovs-ofctl).
type OVSBridgePort interface {
	DumpFlows(ofVersion, bridge string) (string, error)
	DumpFlowsFilter(ofVersion, bridge, matchFilter string) (string, error)
	AddFlow(argv []string) error
	DelFlowsByCookie(ofVersion, bridge string, cookie uint64) error
}

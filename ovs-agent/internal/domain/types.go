package domain

type OVNContext struct {
	PBTunnelKey   int    // Port_Binding.tunnel_key
	DatapathUUID  string // Port_Binding.datapath (UUID)
	DPTunnelKey   int    // Datapath_Binding.tunnel_key
	ServiceMAC    string // Service_Monitor.src_mac
}

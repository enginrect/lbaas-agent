package domain

const (
	OFVersion   = "OpenFlow15"
	Bridge      = "br-int"
	Table       = 36
	Priority    = 110

	// default container names (Kolla)
	DefaultOVSContainer = "openvswitch_vswitchd"

	// userdata marker to identify our LBaaS flow
	Userdata = "00.00.00.12.00.00.00.00"
)

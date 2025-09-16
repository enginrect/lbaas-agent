package usecase

import (
	"github.com/enginrect/lbaas-agent/ovs-agent/internal/domain"
	"github.com/enginrect/lbaas-agent/ovs-agent/internal/ports"
)

func ResolveOVNContext(ovn ports.OVNSouthboundPort, logicalPort string) (domain.OVNContext, error) {
	pbKey, err := ovn.PortBindingTunnelKey(logicalPort)
	if err != nil {
		return domain.OVNContext{}, err
	}

	dpUUID, err := ovn.PortBindingDatapathUUID(logicalPort)
	if err != nil {
		return domain.OVNContext{}, err
	}

	dpKey, err := ovn.DatapathBindingTunnelKey(dpUUID)
	if err != nil {
		return domain.OVNContext{}, err
	}

	srcMAC, err := ovn.ServiceMonitorSrcMAC(logicalPort)
	if err != nil {
		return domain.OVNContext{}, err
	}

	return domain.OVNContext{
		PBTunnelKey:  pbKey,
		DatapathUUID: dpUUID,
		DPTunnelKey:  dpKey,
		ServiceMAC:   srcMAC,
	}, nil
}

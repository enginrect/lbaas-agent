package usecase

import (
	"fmt"

	ovsAdapter "github.com/enginrect/lbaas-agent/ovs-agent/internal/adapters/ovs"
	"github.com/enginrect/lbaas-agent/ovs-agent/internal/domain"
	"github.com/enginrect/lbaas-agent/ovs-agent/internal/ports"
)

func EnsureNoCookieConflict(ovsPort ports.OVSBridgePort, cookieHex string) error {
	out, err := ovsPort.DumpFlowsFilter(domain.OFVersion, domain.Bridge, fmt.Sprintf("cookie=0x%s/-1", cookieHex))
	if err != nil {
		return err
	}
	for _, ln := range splitLines(out) {
		if stringsContains(ln, "cookie=") {
			return fmt.Errorf("Conflicting cookie already exists (cookie_value : %s)", cookieHex)
		}
	}
	return nil
}

func EnsureNoMatchConflict(ovsPort ports.OVSBridgePort, ctx domain.OVNContext) error {
	// We scan full dump and check if any line matches our match tokens.
	out, err := ovsPort.DumpFlows(domain.OFVersion, domain.Bridge)
	if err != nil {
		return err
	}
	expected := []string{
		fmt.Sprintf("table=%d", domain.Table),
		fmt.Sprintf("priority=%d", domain.Priority),
		"tcp",
		fmt.Sprintf("metadata=0x%x", ctx.DPTunnelKey),
		"dl_dst=" + ctx.ServiceMAC,
	}
	existCookies := []string{}
	hasOurAction := false
	for _, ln := range splitLines(out) {
		if matchAllTokens(ln, expected) {
			if c, ok := ovsAdapter.ExtractCookieHex(ln); ok {
				existCookies = append(existCookies, c)
			}
			if isLBaaSAction(ln) {
				hasOurAction = true
			}
		}
	}
	if len(existCookies) == 0 && !hasOurAction {
		return nil
	}
	suffix := ""
	if len(existCookies) > 0 {
		suffix = fmt.Sprintf(" (existing cookies: %s)", stringsJoin(existCookies, ", "))
	}
	if hasOurAction {
		return fmt.Errorf("OpenFlow rule for this match already exists as LBaaS rule%s", suffix)
	}
	return fmt.Errorf("Conflicting OpenFlow rule exists with the same match; refusing to override%s", suffix)
}

func AddFlowForContext(ovsPort ports.OVSBridgePort, cookieHex string, ctx domain.OVNContext) (map[string]string, error) {
	argv := ovsAdapter.BuildAddFlowCommand(domain.OFVersion, domain.Bridge, cookieHex, domain.Table, domain.Priority, ctx.DPTunnelKey, ctx.ServiceMAC, ctx.PBTunnelKey, domain.Userdata)
	if err := ovsPort.AddFlow(argv); err != nil {
		return nil, err
	}
	return map[string]string{"cookie_value": cookieHex, "rule": argv[len(argv)-1]}, nil
}

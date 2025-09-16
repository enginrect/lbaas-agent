package usecase

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/enginrect/lbaas-agent/ovs-agent/internal/domain"
	"github.com/enginrect/lbaas-agent/ovs-agent/internal/ports"
)

func DeleteFlowByCookie(ovsPort ports.OVSBridgePort, cookieHex string) (map[string]bool, error) {
	out, err := ovsPort.DumpFlowsFilter(domain.OFVersion, domain.Bridge, fmt.Sprintf("cookie=0x%s/-1", cookieHex))
	if err != nil {
		return nil, err
	}
	lines := []string{}
	for _, ln := range strings.Split(out, "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		if strings.Contains(ln, "cookie=") {
			lines = append(lines, ln)
		}
	}
	if len(lines) == 0 {
		return nil, fmt.Errorf("OpenFlow rule not found (cookie_value : %s)", cookieHex)
	}
	if len(lines) > 1 {
		return nil, fmt.Errorf("Too many OpenFlow rule was found (cookie_value : %s)", cookieHex)
	}
	lhs := strings.SplitN(lines[0], "actions=", 2)[0]
	required := []string{fmt.Sprintf("table=%d", domain.Table), fmt.Sprintf("priority=%d", domain.Priority), "tcp"}
	ok := true
	for _, t := range required {
		if !strings.Contains(lhs, t) {
			ok = false
			break
		}
	}
	if !ok || !strings.Contains(lines[0], "controller(userdata=") || !strings.Contains(lines[0], "->reg14") {
		return nil, fmt.Errorf("Matched OpenFlow rule was not LBaaS Rule")
	}
	cookie, err := strconv.ParseUint(cookieHex, 16, 64)
	if err != nil {
		return nil, fmt.Errorf("invalid cookie hex: %w", err)
	}
	if err := ovsPort.DelFlowsByCookie(domain.OFVersion, domain.Bridge, cookie); err != nil {
		return nil, err
	}
	return map[string]bool{"ok": true}, nil
}

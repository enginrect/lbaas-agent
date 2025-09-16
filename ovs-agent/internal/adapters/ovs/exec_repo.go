package ovs

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/enginrect/lbaas-agent/ovs-agent/internal/infra/executor"
)

type ExecOVS struct {
	Exec      executor.Executor
	Container string // docker container that has ovs-ofctl
}

func NewExecOVS(exec executor.Executor) *ExecOVS {
	container := os.Getenv("OVS_CONTAINER")
	if container == "" {
		container = "openvswitch_vswitchd"
	}
	return &ExecOVS{Exec: exec, Container: container}
}

func (o *ExecOVS) DumpFlows(ofVersion, bridge string) (string, error) {
	ctx, cancel := executor.WithTimeout(10 * time.Second)
	defer cancel()
	argv := []string{"docker", "exec", "-i", o.Container, "ovs-ofctl", "-O", ofVersion, "dump-flows", bridge}
	return o.Exec.Run(ctx, argv)
}

func (o *ExecOVS) DumpFlowsFilter(ofVersion, bridge, matchFilter string) (string, error) {
	ctx, cancel := executor.WithTimeout(10 * time.Second)
	defer cancel()
	argv := []string{"docker", "exec", "-i", o.Container, "ovs-ofctl", "-O", ofVersion, "dump-flows", bridge, matchFilter}
	return o.Exec.Run(ctx, argv)
}

func (o *ExecOVS) AddFlow(argv []string) error {
	ctx, cancel := executor.WithTimeout(10 * time.Second)
	defer cancel()
	full := append([]string{"docker", "exec", "-i", o.Container}, argv...)
	_, err := o.Exec.Run(ctx, full)
	return err
}

func (o *ExecOVS) DelFlowsByCookie(ofVersion, bridge string, cookie uint64) error {
	ctx, cancel := executor.WithTimeout(10 * time.Second)
	defer cancel()
	mask := "-1"
	match := fmt.Sprintf("cookie=0x%x/%s", cookie, mask)
	argv := []string{"docker", "exec", "-i", o.Container, "ovs-ofctl", "-O", ofVersion, "del-flows", bridge, match}
	_, err := o.Exec.Run(ctx, argv)
	return err
}

// BuildAddFlowCommand builds the argv for ovs-ofctl add-flow.
func BuildAddFlowCommand(ofVersion, bridge string, cookieHex string, table, priority int, dpTunnelKey int, serviceMAC string, pbTunnelKey int, userdata string) []string {
	match := []string{
		"cookie=0x" + strings.ToLower(cookieHex),
		fmt.Sprintf("table=%d", table),
		fmt.Sprintf("priority=%d", priority),
		"tcp",
		fmt.Sprintf("metadata=0x%x", dpTunnelKey),
		"dl_dst=" + serviceMAC,
	}
	actions := []string{
		fmt.Sprintf("set_field:0x%x->reg14", pbTunnelKey),
		"controller(userdata=" + userdata + ")",
	}
	rule := strings.Join(match, ",") + " actions=" + strings.Join(actions, ",")
	return []string{"ovs-ofctl", "-O", ofVersion, "add-flow", bridge, rule}
}

// Helpers to parse cookie from dump line
func ExtractCookieHex(line string) (string, bool) {
	// lines contain 'cookie=0xabcdef0123456789,'
	ix := strings.Index(line, "cookie=0x")
	if ix < 0 {
		return "", false
	}
	end := strings.Index(line[ix+7:], ",")
	if end < 0 {
		return "", false
	}
	return strings.ToLower(line[ix+7 : ix+7+end]), true
}

// String-to-uint64 helper
func ParseHexToUint64(hex string) (uint64, error) {
	return strconv.ParseUint(strings.TrimPrefix(strings.ToLower(hex), "0x"), 16, 64)
}

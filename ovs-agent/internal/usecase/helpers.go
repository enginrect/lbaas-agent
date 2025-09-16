package usecase

import "strings"

func splitLines(s string) []string {
	arr := strings.Split(s, "\n")
	out := make([]string, 0, len(arr))
	for _, v := range arr {
		v = strings.TrimSpace(v)
		if v != "" { out = append(out, v) }
	}
	return out
}

func matchAllTokens(s string, tokens []string) bool {
	for _, t := range tokens {
		if !strings.Contains(s, t) { return false }
	}
	return true
}

func stringsContains(s, sub string) bool { return strings.Contains(s, sub) }
func stringsJoin(arr []string, sep string) string { return strings.Join(arr, sep) }

func isLBaaSAction(line string) bool {
	// Requires set_field to reg14 AND controller(userdata=Userdata)
	return strings.Contains(line, "->reg14") && strings.Contains(line, "controller(userdata=")
}

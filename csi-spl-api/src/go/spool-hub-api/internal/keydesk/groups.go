package keydesk

import (
	"strconv"
	"strings"
)

// rootEquivalent are the groups that read every process on the machine (127
// 5.3, the desk start check's list).
var rootEquivalent = []string{"sudo", "wheel", "admin", "docker", "lxd", "disk"}

// RootEquivalentIn returns the first root-equivalent group (by the
// /etc/group text) that one of gids names, or "".
func RootEquivalentIn(etcGroup string, gids []uint32) string {
	byGID := map[uint32]string{}
	for _, l := range strings.Split(etcGroup, "\n") {
		f := strings.Split(l, ":")
		if len(f) < 3 {
			continue
		}
		n, err := strconv.ParseUint(f[2], 10, 32)
		if err == nil {
			byGID[uint32(n)] = f[0]
		}
	}
	for _, g := range gids {
		name := byGID[g]
		for _, re := range rootEquivalent {
			if name == re {
				return name
			}
		}
	}
	return ""
}

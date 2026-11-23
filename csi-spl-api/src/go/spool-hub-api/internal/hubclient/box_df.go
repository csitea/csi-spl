package hubclient

import (
	"os"
	"strconv"
	"strings"
	"syscall"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The df mount rule of spec 071 8.3.1 (SPL-6318 row T11), on `df -kPT`:
//  1. a row whose 1024-blocks and Available are whole numbers, each mount
//     path once (a network mount that prints "-" is skipped);
//  2. the pseudo, virtual and image filesystems are dropped (boxDFPseudo);
//  3. every real local or network filesystem is kept; two block-device
//     rows on one st_dev (a bind mount) keep the shortest mount path;
//  4. tmpfs and overlay are dropped, except a mount whose st_dev is the
//     st_dev of an agent root ($SPOOL_ROOT, $SPL_WT_ROOT,
//     $SPL_VAR_APP_DIR), or of /tmp when it is a dedicated mount of at
//     least 1 GiB. So /run, /run/user/*, /dev/shm and a container's
//     overlay stay out.
//
// At most store.BoxDisksMax mounts, in df's order. A df without the Type
// column (the tick's own `df -kP`, the parity fixtures) is parsed as the
// tick does, by parseBoxDF.

// boxDFPseudo are spec 8.3.1 step 2's filesystems, never a disk.
var boxDFPseudo = map[string]bool{
	"devtmpfs": true, "squashfs": true, "efivarfs": true, "proc": true, "sysfs": true, "cgroup": true,
	"cgroup2": true, "debugfs": true, "tracefs": true, "fusectl": true, "pstore": true, "securityfs": true,
	"autofs": true, "mqueue": true, "hugetlbfs": true, "rpc_pipefs": true, "nsfs": true, "ramfs": true,
}

// boxDFTmpMinKB is the size from which a tmpfs /tmp counts (1 GiB).
const boxDFTmpMinKB = 1048576

// boxDFRow is one usable `df -kPT` row.
type boxDFRow struct {
	source string
	disk   store.BoxDisk
}

// parseDF is the mount rule: `df -kPT` output in, the sample's disks out.
func (s BoxSampler) parseDF(out []byte) []store.BoxDisk {
	lines := strings.Split(string(out), "\n")
	if h := strings.Fields(lines[0]); len(h) < 2 || h[1] != "Type" {
		return parseBoxDF(out)
	}
	dev := s.Dev
	if dev == nil {
		dev = boxStatDev
	}
	agent, tmp, tmpOK := s.rootDevs(dev)
	disks := []store.BoxDisk{}
	byDev := map[uint64]int{} // st_dev -> index in disks
	for _, r := range parseBoxDFTyped(lines[1:]) {
		d, ok := uint64(0), false
		switch fs := r.disk.FSType; {
		case boxDFPseudo[fs]:
			continue
		case fs == "tmpfs" || fs == "overlay":
			if d, ok = dev(r.disk.Mount); !ok || !(agent[d] || (tmpOK && tmp == d && r.disk.TotalKB >= boxDFTmpMinKB)) {
				continue
			}
		case strings.HasPrefix(r.source, "/dev/"):
			d, ok = dev(r.disk.Mount)
		}
		if i, seen := byDev[d]; ok && seen {
			if len(r.disk.Mount) < len(disks[i].Mount) {
				disks[i] = r.disk
			}
			continue
		}
		if ok {
			byDev[d] = len(disks)
		}
		disks = append(disks, r.disk)
	}
	return disks[:min(len(disks), store.BoxDisksMax)]
}

// rootDevs is the st_dev of each agent root that can be read, and of /tmp.
func (s BoxSampler) rootDevs(dev func(string) (uint64, bool)) (agent map[uint64]bool, tmp uint64, tmpOK bool) {
	roots := s.AgentRoots
	if roots == nil {
		roots = []string{os.Getenv("SPOOL_ROOT"), os.Getenv("SPL_WT_ROOT"), os.Getenv("SPL_VAR_APP_DIR")}
	}
	agent = map[uint64]bool{}
	for _, p := range roots {
		if p == "" {
			continue
		}
		if d, ok := dev(p); ok {
			agent[d] = true
		}
	}
	tmp, tmpOK = dev(orDefault(s.TmpDir, "/tmp"))
	return agent, tmp, tmpOK
}

// parseBoxDFTyped reads the `df -kPT` rows of rule 1: the mount is field 7
// to the end, joined by one space; only an absolute mount, each once;
// used_kb only when Used is a number; fstype only when the hub takes it.
func parseBoxDFTyped(lines []string) []boxDFRow {
	rows := []boxDFRow{}
	seen := map[string]bool{}
	for _, line := range lines {
		f := strings.Fields(line)
		if len(f) < 7 || !boxDigitsRe.MatchString(f[2]) || !boxDigitsRe.MatchString(f[4]) {
			continue
		}
		mount := strings.Join(f[6:], " ")
		if !strings.HasPrefix(mount, "/") || seen[mount] {
			continue
		}
		seen[mount] = true
		d := store.BoxDisk{Mount: mount}
		if store.BoxFSTypeRe.MatchString(f[1]) {
			d.FSType = f[1]
		}
		d.TotalKB, _ = strconv.ParseInt(f[2], 10, 64)
		d.AvailKB, _ = strconv.ParseInt(f[4], 10, 64)
		if boxDigitsRe.MatchString(f[3]) {
			d.UsedKB, _ = strconv.ParseInt(f[3], 10, 64)
		}
		rows = append(rows, boxDFRow{source: f[0], disk: d})
	}
	return rows
}

// boxStatDev is stat(path).st_dev.
func boxStatDev(path string) (uint64, bool) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return uint64(st.Dev), true //nolint:unconvert // Dev is int32 on darwin
}

package mcp

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// deskRootRe is a workspace desk's spool root, <cloud>/<env>/desk/<tenant>/<box>/spool:
// the root spool-mcp.sh serves every seat from.
var deskRootRe = regexp.MustCompile(`/desk/[^/]+/[^/]+/spool$`)

// errLaneOnDesk refuses a lane's DM on a desk root (SPL-3959).
var errLaneOnDesk = errors.New("a lane's message on a desk spool root reaches nobody")

// deskRootGuard refuses an agent-to-agent send from a lane while the server
// runs on a desk root (SPL-3959). c-423's task 9bb91e55 (2026-10-27) went
// through spool_send, was reported "local", and landed in c-189's inbox under
// the desk root: c-189 reads the fleet root, so nothing read it. A desk root
// is its own seats' only: the role seats (001-003) and the ids a desk alias in
// it links to (RSP-01 -> c-684). A channel post or a DM to a human goes to the
// hub and reaches its reader: not refused.
func (t tools) deskRootGuard(from string, in SendIn) error {
	to, _ := agentid.SplitAtBox(in.To)
	if t.cfg == nil || in.Channel != "" || !agentid.IsAgent(to) {
		return nil
	}
	root := deskRootResolved(t.cfg.SpoolRoot)
	if !deskRootRe.MatchString(filepath.ToSlash(root)) || deskSeat(root, from) {
		return nil
	}
	return fmt.Errorf("spool: from %s on the desk spool root %s: %w; nothing reads a lane's inbox there (SPL-3959). "+
		"Send with spool-send.sh on the fleet root (SPOOL_ROOT=/var/spool-hub). Nothing was sent (exit 78)", from, t.cfg.SpoolRoot, errLaneOnDesk)
}

// deskRootResolved is root with its symlinks resolved and cleaned, so a link
// to a desk root, or a //, /. or /.. spelling of one, is matched as one.
func deskRootResolved(root string) string {
	if r, err := filepath.EvalSymlinks(root); err == nil {
		return r
	}
	return filepath.Clean(root)
}

// deskSeat reports whether id is a seat of the desk whose spool root is root.
func deskSeat(root, id string) bool {
	id, _ = agentid.SplitAtBox(id)
	if agentid.IsRoleSeat(id) {
		return true
	}
	ents, err := os.ReadDir(root)
	if err != nil {
		return false
	}
	for _, e := range ents {
		if e.Type()&os.ModeSymlink == 0 || agentid.IsNew(e.Name()) {
			continue
		}
		if dst, err := os.Readlink(filepath.Join(root, e.Name())); err == nil && strings.TrimSuffix(dst, "/") == id {
			return true
		}
	}
	return false
}

package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// Per-workspace agent caps by vendor (spec 147, rdb 0212, SPL-2675). A cap
// is (workspace, vendor, max_live): at most max_live concurrent live agents
// of that vendor. No row = uncapped (spec 147 P4); max_live 0 forbids the
// vendor. SetRoster is the one gate (vendorCapGate, P5): every box hello and
// announce goes through it, so no host-side path can seat past a cap.
//
// Live (spec 147 section 4.1) is a (box_id, agent_id) roster pair whose box
// stamped its presence within CapPresenceTTL, or the announcing box itself.
// Role seats run once per box, so c-001 on two boxes counts twice (AC-07).

// AgentCapVendors are the vendors a cap may name (rdb 0212's CHECK), the
// kinds agentid.Kind answers.
var AgentCapVendors = []string{"claude", "grok", "mistral", "agy", "qwen"}

// CapPresenceTTL is how old a box's presence stamp (boxes.last_hello_at) may
// be and its roster still count as live: the hub's presenceTTL() on a
// deploy (2 x SPOOL_HUB_WS_PING_INTERVAL 30 s, hub/presence.go). A box past
// it is offline and holds no seat (spec 147 control C4).
const CapPresenceTTL = 60 * time.Second

// ErrVendorCapExceeded refuses a roster replace that adds an agent of a
// vendor already at its workspace cap. Nothing was written. errors.As with
// *VendorCapError gives the detail; the hub answers 409 vendor_cap_exceeded.
var ErrVendorCapExceeded = errors.New("vendor cap exceeded")

// ErrBadCapVendor / ErrBadCapValue refuse a SetAgentCaps request before any
// write: a vendor no cap may name, or a max_live below 0 (400 bad_vendor /
// bad_cap, spec 147 6.1).
var (
	ErrBadCapVendor = errors.New("store: vendor is not supported")
	ErrBadCapValue  = errors.New("store: max_live must be a non-negative integer")
)

// VendorCapError is ErrVendorCapExceeded with its numbers (spec 147 P6).
type VendorCapError struct {
	Tenant string
	Vendor string
	Cap    int // the workspace's max_live for Vendor
	Live   int // live Vendor agents the replace would leave
}

// Error names workspace, vendor, cap and count (spec 147 P6).
func (e *VendorCapError) Error() string {
	return fmt.Sprintf("refused: %s agent cap reached for workspace %s: max %d live, requested %d live",
		e.Vendor, e.Tenant, e.Cap, e.Live)
}

// Unwrap makes errors.Is(err, ErrVendorCapExceeded) hold.
func (e *VendorCapError) Unwrap() error { return ErrVendorCapExceeded }

// AgentCaps is one workspace's caps: vendor -> max_live, capped vendors only.
// UpdatedAt / UpdatedBy are the newest row's (zero / "" with no row).
type AgentCaps struct {
	TenantID  string
	Caps      map[string]int
	UpdatedAt time.Time
	UpdatedBy string
}

// AgentCapActor is who changes caps: the operator admin, for the audit row.
type AgentCapActor struct {
	Tenant string // the operator workspace
	Hum    string // the operator admin's human id
}

// Operator audit actions of the caps routes (rdb 0212 widens the CHECK).
const (
	AuditSetAgentCaps   = "set_agent_caps"
	AuditDeleteAgentCap = "delete_agent_cap"
)

// AgentCapStore is implemented by Memory and Postgres.
type AgentCapStore interface {
	// AgentCaps reads the workspace's caps in its own scope.
	AgentCaps(ctx context.Context, tenant string) (AgentCaps, error)
	// SetAgentCaps writes caps as the operator: a non-nil value sets
	// (>= 0) that vendor's cap, a nil one removes it; a vendor not in the
	// map is left as it is. One audit row per changed vendor. It answers the
	// caps after the write. ErrNotFound: no such workspace.
	SetAgentCaps(ctx context.Context, tenant string, caps map[string]*int, by AgentCapActor, now time.Time) (AgentCaps, error)
	// LiveAgents counts the workspace's live agents per vendor at now.
	LiveAgents(ctx context.Context, tenant string, now time.Time) (map[string]int, error)
}

var (
	_ AgentCapStore = (*Memory)(nil)
	_ AgentCapStore = (*Postgres)(nil)
)

// IsAgentCapVendor reports whether v may carry a cap.
func IsAgentCapVendor(v string) bool {
	for _, k := range AgentCapVendors {
		if k == v {
			return true
		}
	}
	return false
}

// checkAgentCaps validates a SetAgentCaps request before any write.
func checkAgentCaps(caps map[string]*int) error {
	for v, n := range caps {
		if !IsAgentCapVendor(v) {
			return fmt.Errorf("%w: %q", ErrBadCapVendor, v)
		}
		if n != nil && *n < 0 {
			return fmt.Errorf("%w: %s %d", ErrBadCapValue, v, *n)
		}
	}
	return nil
}

// capRosterRow is one roster pair of the workspace with its box's presence.
type capRosterRow struct {
	box, agent string
	live       bool // the box stamped presence within CapPresenceTTL
}

// liveByVendor counts live pairs per vendor (spec 147 4.1).
func liveByVendor(rows []capRosterRow) map[string]int {
	out := map[string]int{}
	for _, r := range rows {
		if k := agentid.Kind(r.agent); r.live && k != "" {
			out[k]++
		}
	}
	return out
}

// overVendorCap is vendorCapGate's math: the roster after box's set is
// replaced by next, counted per capped vendor. It refuses only a replace that
// ADDS a vendor's agent to box (an id not in box's current set) while that
// vendor ends over its cap, so a lowered cap never unseats agents already
// there, as overBotCap (009 D-3). nil = admitted.
func overVendorCap(tenant, box string, caps map[string]int, rows []capRosterRow, next []string) error {
	if len(caps) == 0 {
		return nil
	}
	had := map[string]bool{}
	var others []capRosterRow
	for _, r := range rows {
		if r.box == box {
			had[r.agent] = true
			continue
		}
		others = append(others, r)
	}
	count := liveByVendor(others)
	adds := map[string]bool{}
	for _, a := range next {
		k := agentid.Kind(a)
		if k == "" {
			continue
		}
		count[k]++ // the announcing box is live by definition
		if !had[a] {
			adds[k] = true
		}
	}
	for _, v := range AgentCapVendors {
		if c, ok := caps[v]; ok && adds[v] && count[v] > c {
			return &VendorCapError{Tenant: tenant, Vendor: v, Cap: c, Live: count[v]}
		}
	}
	return nil
}

// boxLive reports whether a presence stamp is fresh at now.
func boxLive(lastHello, now time.Time) bool {
	return !lastHello.IsZero() && !lastHello.Before(now.Add(-CapPresenceTTL))
}

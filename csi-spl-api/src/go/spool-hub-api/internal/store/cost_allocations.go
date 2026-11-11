package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// An estate cost assigned or split to workspaces by hand (SPL-5291, rdb 0275
// cost_allocations, spec 143 costs-allocation.md; owner HUM-10, t1 41a74806
// poll 0c5e94b4 answer C part B, poll 01cbbdea answers 1B 2B 3B). An item is
// one Persons or Cloud estate part of the month answer, keyed (source,
// project_or_vendor, kind); its split gives workspaces shares in basis
// points that sum to 10000, for every month, past ones too. Tokens are never
// split by hand. Operator scope only, like cost_entries.

// CostSourceAllocated is the month read's source of a workspace's share of
// an estate item split by hand.
const CostSourceAllocated = "allocated"

// CostAllocMaxBP is a whole item: a split's shares sum to it.
const CostAllocMaxBP = 10000

// ErrCostAllocOutside is a customer admin's split that would move cost into
// or out of a workspace they do not administer (costs-allocation.md section
// 3, rules 1..4). The wrapped text names the rule.
var ErrCostAllocOutside = errors.New("cost allocation outside the workspaces you administer")

// CostItemKey names one estate cost item, stable across months.
type CostItemKey struct {
	Source          string `json:"source"`
	ProjectOrVendor string `json:"project_or_vendor"`
	Kind            string `json:"kind"`
}

// CostItemTokens is an item of the Tokens label, which stays automatic
// (answer 1 B): the paid AI items, their shares and the token burn, which
// is "fleet_tokens" per workspace and "fleet_tokens.<box>" on the estate
// (orc spl-db-cost-reinsert).
func CostItemTokens(source string) bool {
	return source == CostSourceAIPaid || source == CostSourceAIShare ||
		source == "fleet_tokens" || strings.HasPrefix(source, "fleet_tokens.")
}

// CostAllocShare is one workspace's share of an item.
type CostAllocShare struct {
	WorkspaceID string `json:"workspace_id"`
	ShareBP     int    `json:"share_bp"`
}

// CostAllocation is one item's split (no shares = not allocated).
type CostAllocation struct {
	CostItemKey
	Shares    []CostAllocShare `json:"shares"`
	CreatedBy string           `json:"created_by"`
	CreatedAt time.Time        `json:"created_at"`
}

// CheckCostAllocation names the first thing a split may not carry ("" =
// fine): the Go side of rdb 0275's CHECKs, a Tokens item and the sum, which
// only a whole split can show.
func CheckCostAllocation(a CostAllocation) string {
	if why := CheckCostAllocShares(a); why != "" {
		return why
	}
	sum := 0
	for _, sh := range a.Shares {
		sum += sh.ShareBP
	}
	if len(a.Shares) > 0 && sum != CostAllocMaxBP {
		return fmt.Sprintf("the shares sum to %d basis points, not 10000 (100 %%)", sum)
	}
	return ""
}

// CheckCostAllocShares is CheckCostAllocation without the sum: a customer
// admin's body names only their own workspaces' shares, which sum to what
// those workspaces hold, not to 10000 (MergeCostAllocWithin completes it).
func CheckCostAllocShares(a CostAllocation) string {
	for _, f := range []string{a.Source, a.ProjectOrVendor, a.Kind} {
		if strings.TrimSpace(f) == "" || len(f) > 200 {
			return "source, project_or_vendor and kind must be 1..200 characters"
		}
	}
	if CostItemTokens(a.Source) {
		return "a Tokens item is shared automatically by tokens, never split by hand"
	}
	seen := map[string]bool{}
	for _, sh := range a.Shares {
		switch {
		case strings.TrimSpace(sh.WorkspaceID) == "" || len(sh.WorkspaceID) > 200:
			return "every share needs a workspace_id"
		case seen[sh.WorkspaceID]:
			return "workspace " + sh.WorkspaceID + " has two shares"
		case sh.ShareBP < 1 || sh.ShareBP > CostAllocMaxBP:
			return "a share must be 1..10000 basis points (0.01 %..100 %)"
		}
		seen[sh.WorkspaceID] = true
	}
	return ""
}

// MergeCostAllocWithin completes a customer admin's body into a whole
// split: the body's shares, then each stored share of a workspace outside
// admin that the body does not name. The admin never reads those shares
// (costs-allocation.md section 3), so their body cannot carry them; a body
// that does name one is kept as sent, and CheckCostAllocWithin then judges
// it (rule 1 when it differs from the stored share).
func MergeCostAllocWithin(old, body []CostAllocShare, admin map[string]bool) []CostAllocShare {
	named := map[string]bool{}
	out := append([]CostAllocShare{}, body...)
	for _, sh := range body {
		named[sh.WorkspaceID] = true
	}
	for _, sh := range old {
		if !admin[sh.WorkspaceID] && !named[sh.WorkspaceID] {
			out = append(out, sh)
		}
	}
	return out
}

// CheckCostAllocWithin is the customer admin's rule (costs-allocation.md
// section 3): with admin the workspaces they administer, the new split may
// differ from the old one only in the shares of those workspaces, and those
// shares keep their sum. "" = fine, else the broken rule.
func CheckCostAllocWithin(old, new []CostAllocShare, admin map[string]bool) string {
	before, after := map[string]int{}, map[string]int{}
	heldBefore, heldAfter := 0, 0
	for _, sh := range old {
		before[sh.WorkspaceID] = sh.ShareBP
		if admin[sh.WorkspaceID] {
			heldBefore += sh.ShareBP
		}
	}
	for _, sh := range new {
		after[sh.WorkspaceID] = sh.ShareBP
		if admin[sh.WorkspaceID] {
			heldAfter += sh.ShareBP
		}
	}
	if heldBefore == 0 {
		return "rule 4: no workspace you administer holds a share of this item"
	}
	for ws, bp := range before {
		if !admin[ws] && after[ws] != bp {
			return "rule 1: the share of workspace " + ws + " is not yours to change"
		}
	}
	for ws := range after {
		if _, had := before[ws]; !admin[ws] && !had {
			return "rule 2: workspace " + ws + " is not one you administer"
		}
	}
	if heldAfter != heldBefore {
		return fmt.Sprintf("rule 3: your workspaces hold %d basis points; the split gives them %d", heldBefore, heldAfter)
	}
	return ""
}

// CostAllocShareOf is bp basis points of micros, rounded down; the remainder
// stays with the estate. Split so micros*bp never overflows int64.
func CostAllocShareOf(micros int64, bp int) int64 {
	if micros <= 0 || bp <= 0 {
		return 0
	}
	b := int64(bp)
	return (micros/CostAllocMaxBP)*b + (micros%CostAllocMaxBP)*b/CostAllocMaxBP
}

// CostAllocationStore is the store half of rdb 0275. Optional: the routes
// answer unsupported on a store without it.
type CostAllocationStore interface {
	// CostAllocations is every item's split, item order.
	CostAllocations(ctx context.Context) ([]CostAllocation, error)
	// PutCostAllocation replaces the item's split with a in one
	// transaction and answers what is stored. A non-nil within is a
	// customer admin's set of administered workspaces: the split is then
	// checked against the stored one by CheckCostAllocWithin inside the
	// transaction (ErrCostAllocOutside on a refusal).
	PutCostAllocation(ctx context.Context, a CostAllocation, within map[string]bool) (CostAllocation, error)
}

func sortCostAllocations(out []CostAllocation) {
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i].CostItemKey, out[j].CostItemKey
		if a.Source != b.Source {
			return a.Source < b.Source
		}
		if a.ProjectOrVendor != b.ProjectOrVendor {
			return a.ProjectOrVendor < b.ProjectOrVendor
		}
		return a.Kind < b.Kind
	})
	for _, a := range out {
		sort.Slice(a.Shares, func(i, j int) bool { return a.Shares[i].WorkspaceID < a.Shares[j].WorkspaceID })
	}
}

// checkCostAllocPut is the whole write check and answers the split to
// store. The operator's body is the whole split. A customer admin's (within
// non-nil) is first completed with the stored shares outside their
// workspaces (MergeCostAllocWithin), judged by their rule against old, and
// only then checked as a whole split.
func checkCostAllocPut(a CostAllocation, old []CostAllocShare, within map[string]bool) (CostAllocation, error) {
	if within != nil {
		a.Shares = MergeCostAllocWithin(old, a.Shares, within)
		if why := CheckCostAllocWithin(old, a.Shares, within); why != "" {
			return CostAllocation{}, fmt.Errorf("%w: %s", ErrCostAllocOutside, why)
		}
	}
	if why := CheckCostAllocation(a); why != "" {
		return CostAllocation{}, fmt.Errorf("cost allocation: %s", why)
	}
	return a, nil
}

// The Memory driver keeps its splits beside the store, like the entries.
var (
	memCostAllocMu sync.Mutex
	memCostAlloc   = map[*Memory]map[CostItemKey]CostAllocation{}
)

// CostAllocations is CostAllocationStore on Memory.
func (s *Memory) CostAllocations(_ context.Context) ([]CostAllocation, error) {
	memCostAllocMu.Lock()
	defer memCostAllocMu.Unlock()
	out := make([]CostAllocation, 0, len(memCostAlloc[s]))
	for _, a := range memCostAlloc[s] {
		a.Shares = append([]CostAllocShare(nil), a.Shares...)
		out = append(out, a)
	}
	sortCostAllocations(out)
	return out, nil
}

// PutCostAllocation is CostAllocationStore on Memory.
func (s *Memory) PutCostAllocation(_ context.Context, a CostAllocation, within map[string]bool) (CostAllocation, error) {
	memCostAllocMu.Lock()
	defer memCostAllocMu.Unlock()
	a, err := checkCostAllocPut(a, memCostAlloc[s][a.CostItemKey].Shares, within)
	if err != nil {
		return CostAllocation{}, err
	}
	if memCostAlloc[s] == nil {
		memCostAlloc[s] = map[CostItemKey]CostAllocation{}
	}
	a.Shares = append([]CostAllocShare{}, a.Shares...)
	a.CreatedAt = time.Now().UTC().Truncate(time.Microsecond)
	if len(a.Shares) == 0 {
		delete(memCostAlloc[s], a.CostItemKey)
	} else {
		memCostAlloc[s][a.CostItemKey] = a
	}
	sortCostAllocations([]CostAllocation{a})
	return a, nil
}

var _ CostAllocationStore = (*Memory)(nil)

package store

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"sync"
	"time"
)

// Each workspace's view of the estate's costs (SPL-6086, rdb 0304
// cost_view_rules, spec 143 costs-workspace-views.md sections 3.1-3.2, row
// R1; owner HUM-10, csitea bc9956bf: csitea shows every cost, spool-hub a
// part of the same costs). A view rule is a share in basis points of one
// label of the estate's costs; a view, not a partition, so the shares of one
// label across workspaces need not sum to 10000. Operator scope only, like
// cost_allocations and cost_splits. The overlap of two Cloud matches of one
// workspace (section 3.1) is the route's check (row R2), not the store's.

// View rule labels of rdb 0304 (costs-redesign.md 3.9; Total has no rule).
const (
	CostViewCloud   = "cloud"   // GCP projects and cloud cost entries; match "*" or "<prefix>*"
	CostViewPersons = "persons" // every hr cost; match ""
	CostViewTokens  = "tokens"  // every paid AI item; match ""
)

// CostViewMatchAll is the Cloud match of every GCP project and every cloud
// cost entry.
const CostViewMatchAll = "*"

// costViewPrefixRe is rdb 0304's '<prefix>*' match.
var costViewPrefixRe = regexp.MustCompile(`^[a-z0-9-]{1,60}\*$`)

// CostViewRule is one (workspace, label, match) share.
type CostViewRule struct {
	WorkspaceID string    `json:"workspace_id"`
	Label       string    `json:"label"`
	Match       string    `json:"match"`
	ShareBP     int       `json:"share_bp"`
	CreatedBy   string    `json:"created_by"`
	CreatedAt   time.Time `json:"created_at"`
}

// costViewKey is rdb 0304's primary key within one workspace.
type costViewKey struct{ label, match string }

// CheckCostViewRule names the first thing a rule may not carry ("" = fine):
// the Go side of rdb 0304's CHECKs.
func CheckCostViewRule(r CostViewRule) string {
	switch r.Label {
	case CostViewCloud:
		if r.Match != CostViewMatchAll && !costViewPrefixRe.MatchString(r.Match) {
			return "a cloud match is * or <prefix>* ([a-z0-9-]{1,60} then *)"
		}
	case CostViewPersons, CostViewTokens:
		if r.Match != "" {
			return "only a cloud rule takes a match"
		}
	default:
		return "label must be cloud, persons or tokens"
	}
	if r.ShareBP < 1 || r.ShareBP > 10000 {
		return "share_bp must be 1..10000"
	}
	return ""
}

// CheckCostViewRules is CheckCostViewRule for each rule of one workspace's
// set, and no (label, match) twice.
func CheckCostViewRules(rules []CostViewRule) string {
	seen := map[costViewKey]bool{}
	for _, r := range rules {
		if why := CheckCostViewRule(r); why != "" {
			return why
		}
		k := costViewKey{r.Label, r.Match}
		if seen[k] {
			return fmt.Sprintf("%s %q twice", r.Label, r.Match)
		}
		seen[k] = true
	}
	return ""
}

// CostViewRuleStore is the store half of rdb 0304. Optional: the routes
// answer unsupported on a store without it.
type CostViewRuleStore interface {
	// CostViewRules is every workspace's rules, in (workspace, label,
	// match) order.
	CostViewRules(ctx context.Context) ([]CostViewRule, error)
	// PutCostViewRules replaces the workspace's rules whole in one
	// transaction (none = remove them) and answers what is stored. Each
	// rule's WorkspaceID and CreatedBy are set from the arguments.
	PutCostViewRules(ctx context.Context, workspaceID, createdBy string, rules []CostViewRule) ([]CostViewRule, error)
}

// costViewPrepare checks a put and stamps the workspace and the writer on a
// copy of its rules, in key order.
func costViewPrepare(workspaceID, createdBy string, rules []CostViewRule) ([]CostViewRule, error) {
	if workspaceID == "" {
		return nil, fmt.Errorf("cost view rules: no workspace")
	}
	if why := CheckCostViewRules(rules); why != "" {
		return nil, fmt.Errorf("cost view rules: %s", why)
	}
	out := make([]CostViewRule, 0, len(rules))
	for _, r := range rules {
		r.WorkspaceID, r.CreatedBy = workspaceID, createdBy
		out = append(out, r)
	}
	sortCostViewRules(out)
	return out, nil
}

func sortCostViewRules(out []CostViewRule) {
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.WorkspaceID != b.WorkspaceID {
			return a.WorkspaceID < b.WorkspaceID
		}
		if a.Label != b.Label {
			return a.Label < b.Label
		}
		return a.Match < b.Match
	})
}

// The Memory driver keeps its view rules beside the store, per workspace.
var (
	memCostViewMu sync.Mutex
	memCostView   = map[*Memory]map[string][]CostViewRule{}
)

// CostViewRules is CostViewRuleStore on Memory.
func (s *Memory) CostViewRules(_ context.Context) ([]CostViewRule, error) {
	memCostViewMu.Lock()
	defer memCostViewMu.Unlock()
	out := []CostViewRule{}
	for _, rules := range memCostView[s] {
		out = append(out, rules...)
	}
	sortCostViewRules(out)
	return out, nil
}

// PutCostViewRules is CostViewRuleStore on Memory. It refuses what rdb
// 0304 refuses: a created_by outside 1..200 and a workspace the store does
// not hold (the FK).
func (s *Memory) PutCostViewRules(ctx context.Context, workspaceID, createdBy string, rules []CostViewRule) ([]CostViewRule, error) {
	out, err := costViewPrepare(workspaceID, createdBy, rules)
	if err != nil {
		return nil, err
	}
	if len(out) > 0 {
		if createdBy == "" || len(createdBy) > 200 {
			return nil, fmt.Errorf("cost view rules: created_by must be 1..200 characters")
		}
		if _, err := s.GetTenant(ctx, workspaceID); err != nil {
			return nil, fmt.Errorf("cost view rules: workspace %s: %w", workspaceID, err)
		}
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	for i := range out {
		out[i].CreatedAt = now
	}
	memCostViewMu.Lock()
	defer memCostViewMu.Unlock()
	if memCostView[s] == nil {
		memCostView[s] = map[string][]CostViewRule{}
	}
	if len(out) == 0 {
		delete(memCostView[s], workspaceID)
	} else {
		memCostView[s][workspaceID] = append([]CostViewRule(nil), out...)
	}
	return out, nil
}

var _ CostViewRuleStore = (*Memory)(nil)

package store

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// The instance's splits of the paid AI items and of a person's hr costs
// over the workspaces (SPL-5768, rdb 0291 cost_splits, spec 143
// costs-allocation.md section 7; owner HUM-10, csitea f655b326 msg
// 3440bf12: "the admin and the business owner should be able to define
// percentages for the division of the costs, both for the tokens and for
// the personnel costs, on a percentage basis, divided for each workspace").
// A split is a share per workspace in basis points that sum to 10000, for
// every month. Operator scope only, like cost_allocations.

// Split kinds of rdb 0291.
const (
	CostSplitTokens = "tokens" // every paid AI item; subject ""
	CostSplitPerson = "person" // every hr entry of one person; subject the hr person id
)

// CostSplitKey names one split.
type CostSplitKey struct {
	Kind    string `json:"split_kind"`
	Subject string `json:"subject"`
}

// CostSplit is one split's shares (none = not set).
type CostSplit struct {
	CostSplitKey
	Shares    []CostAllocShare `json:"shares"`
	CreatedBy string           `json:"created_by"`
	CreatedAt time.Time        `json:"created_at"`
}

// CheckCostSplit names the first thing a split may not carry ("" = fine):
// the Go side of rdb 0291's CHECKs and the sum.
func CheckCostSplit(sp CostSplit) string {
	switch {
	case sp.Kind != CostSplitTokens && sp.Kind != CostSplitPerson:
		return "split_kind must be tokens or person"
	case sp.Kind == CostSplitTokens && sp.Subject != "":
		return "a tokens split has no subject"
	case sp.Kind == CostSplitPerson && (strings.TrimSpace(sp.Subject) == "" || len(sp.Subject) > 200):
		return "a person split's subject is the hr person id"
	}
	// the item key only carries the shares' check: any non-Tokens source
	k := CostItemKey{Source: "split", ProjectOrVendor: sp.Kind, Kind: "split"}
	return CheckCostAllocation(CostAllocation{CostItemKey: k, Shares: sp.Shares})
}

// CostSplitStore is the store half of rdb 0291. Optional: the routes answer
// unsupported on a store without it.
type CostSplitStore interface {
	// CostSplits is every split, key order.
	CostSplits(ctx context.Context) ([]CostSplit, error)
	// PutCostSplit replaces the split's shares in one transaction (none =
	// remove) and answers what is stored.
	PutCostSplit(ctx context.Context, sp CostSplit) (CostSplit, error)
}

// CostSplitShares indexes splits: the tokens split's shares, and each
// person's by person id.
func CostSplitShares(splits []CostSplit) (tokens []CostAllocShare, person map[string][]CostAllocShare) {
	person = map[string][]CostAllocShare{}
	for _, sp := range splits {
		switch sp.Kind {
		case CostSplitTokens:
			tokens = sp.Shares
		case CostSplitPerson:
			person[sp.Subject] = sp.Shares
		}
	}
	return tokens, person
}

// ShareOf is ws's basis points in shares (0 = none).
func ShareOf(shares []CostAllocShare, ws string) int {
	for _, sh := range shares {
		if sh.WorkspaceID == ws {
			return sh.ShareBP
		}
	}
	return 0
}

func sortCostSplits(out []CostSplit) {
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Subject < out[j].Subject
	})
	for _, sp := range out {
		sort.Slice(sp.Shares, func(i, j int) bool { return sp.Shares[i].WorkspaceID < sp.Shares[j].WorkspaceID })
	}
}

// The Memory driver keeps its splits beside the store.
var (
	memCostSplitMu sync.Mutex
	memCostSplit   = map[*Memory]map[CostSplitKey]CostSplit{}
)

// CostSplits is CostSplitStore on Memory.
func (s *Memory) CostSplits(_ context.Context) ([]CostSplit, error) {
	memCostSplitMu.Lock()
	defer memCostSplitMu.Unlock()
	out := make([]CostSplit, 0, len(memCostSplit[s]))
	for _, sp := range memCostSplit[s] {
		sp.Shares = append([]CostAllocShare(nil), sp.Shares...)
		out = append(out, sp)
	}
	sortCostSplits(out)
	return out, nil
}

// PutCostSplit is CostSplitStore on Memory.
func (s *Memory) PutCostSplit(_ context.Context, sp CostSplit) (CostSplit, error) {
	if why := CheckCostSplit(sp); why != "" {
		return CostSplit{}, fmt.Errorf("cost split: %s", why)
	}
	memCostSplitMu.Lock()
	defer memCostSplitMu.Unlock()
	if memCostSplit[s] == nil {
		memCostSplit[s] = map[CostSplitKey]CostSplit{}
	}
	sp.Shares = append([]CostAllocShare{}, sp.Shares...)
	sp.CreatedAt = time.Now().UTC().Truncate(time.Microsecond)
	if len(sp.Shares) == 0 {
		delete(memCostSplit[s], sp.CostSplitKey)
	} else {
		memCostSplit[s][sp.CostSplitKey] = sp
	}
	sortCostSplits([]CostSplit{sp})
	return sp, nil
}

var _ CostSplitStore = (*Memory)(nil)

package store

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// The instance's splits of the paid AI items and of a person's hr costs
// over the workspaces (SPL-5768, rdb 0293 cost_splits, spec 143
// costs-allocation.md section 7; owner HUM-10, csitea f655b326 msg
// 3440bf12: "the admin and the business owner should be able to define
// percentages for the division of the costs, both for the tokens and for
// the personnel costs, on a percentage basis, divided for each workspace").
// A split is a share per workspace in basis points that sum to 10000, for
// every month. Operator scope only, like cost_allocations. SPL-6301 adds
// tokens_vendor: one vendor's paid items over a month range.

// Split kinds of rdb 0293.
const (
	CostSplitTokens = "tokens" // every paid AI item; subject ""
	CostSplitPerson = "person" // every hr entry of one person; subject the hr person id
	// CostSplitTokensVendor is the paid AI items of one vendor over a month
	// range, in place of the tokens split for those parts only (SPL-6301,
	// costs-allocation.md 7.7); subject "<vendor>:<from>:<to>".
	CostSplitTokensVendor = "tokens_vendor"
)

// CostSplitVendors are the vendors of rdb 0205 fleet_token_paid_items.
var CostSplitVendors = []string{"claude", "mistral", "grok", "agy", "qwen"}

// costSplitMonthRx is one month, YYYY-MM.
var costSplitMonthRx = regexp.MustCompile(`^[0-9]{4}-(0[1-9]|1[0-2])$`)

// CostSplitVendorRange is the vendor and the months from..to (both
// included) of a tokens_vendor subject; ok false when it is not one.
func CostSplitVendorRange(subject string) (vendor, from, to string, ok bool) {
	f := strings.Split(subject, ":")
	if len(f) != 3 || !slices.Contains(CostSplitVendors, f[0]) ||
		!costSplitMonthRx.MatchString(f[1]) || !costSplitMonthRx.MatchString(f[2]) || f[1] > f[2] {
		return "", "", "", false
	}
	return f[0], f[1], f[2], true
}

// CostSplitVendorShares is the shares of the tokens_vendor split of vendor
// that covers month (YYYY-MM); nil when none does.
func CostSplitVendorShares(splits []CostSplit, vendor, month string) []CostAllocShare {
	for _, sp := range splits {
		if sp.Kind != CostSplitTokensVendor {
			continue
		}
		if v, from, to, ok := CostSplitVendorRange(sp.Subject); ok && v == vendor && from <= month && month <= to {
			return sp.Shares
		}
	}
	return nil
}

// CostSplitVendorOverlap is the subject of a stored tokens_vendor split
// (other than sp's own) of sp's vendor whose months meet sp's ("" = none).
func CostSplitVendorOverlap(splits []CostSplit, sp CostSplit) string {
	v, from, to, ok := CostSplitVendorRange(sp.Subject)
	if !ok {
		return ""
	}
	for _, o := range splits {
		ov, ofrom, oto, ook := CostSplitVendorRange(o.Subject)
		if o.Kind == CostSplitTokensVendor && o.Subject != sp.Subject && ook && ov == v && ofrom <= to && from <= oto {
			return o.Subject
		}
	}
	return ""
}

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
// the Go side of rdb 0293's CHECKs and the sum.
func CheckCostSplit(sp CostSplit) string {
	switch {
	case sp.Kind != CostSplitTokens && sp.Kind != CostSplitPerson && sp.Kind != CostSplitTokensVendor:
		return "split_kind must be tokens, person or tokens_vendor"
	case sp.Kind == CostSplitTokens && sp.Subject != "":
		return "a tokens split has no subject"
	case sp.Kind == CostSplitPerson && (strings.TrimSpace(sp.Subject) == "" || len(sp.Subject) > 200):
		return "a person split's subject is the hr person id"
	case sp.Kind == CostSplitTokensVendor && !costSplitVendorSubjectOK(sp.Subject):
		return "a tokens_vendor split's subject is <vendor>:<from YYYY-MM>:<to YYYY-MM>, from <= to"
	}
	// the item key only carries the shares' check: any non-Tokens source
	k := CostItemKey{Source: "split", ProjectOrVendor: sp.Kind, Kind: "split"}
	return CheckCostAllocation(CostAllocation{CostItemKey: k, Shares: sp.Shares})
}

func costSplitVendorSubjectOK(subject string) bool {
	_, _, _, ok := CostSplitVendorRange(subject)
	return ok
}

// CostSplitStore is the store half of rdb 0293. Optional: the routes answer
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

package store

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// The Cloud infra and HR costs the operator types on the Expenses page
// (SPL-4383, rdb 0245 cost_entries; owner HUM-10, t1 4f48f878 msg b0ccc0aa).
// One row is one cost of one month. AI costs are fleet_token_paid_items
// (rdb 0205), not these. Operator scope only, like the paid items.

// CostEntryTypes are rdb 0245's type CHECK.
var CostEntryTypes = []string{"cloud", "hr"}

// CostEntry is one row of cost_entries. Period is the month YYYY-MM.
type CostEntry struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Label     string    `json:"label"`
	Amount    float64   `json:"amount"`
	Currency  string    `json:"currency"`
	Period    string    `json:"period"`
	Note      string    `json:"note"`
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
	// The hr line's fields (rdb 0280, SPL-5433); empty on a cloud entry.
	// PersonID "" = the organisation's line; PeriodKind "" reads as month.
	PersonID       string `json:"person_id,omitempty"`
	Component      string `json:"component,omitempty"`
	Source         string `json:"source,omitempty"`
	Account        string `json:"account,omitempty"`
	PeriodKind     string `json:"period_kind,omitempty"`
	CorrectsPeriod string `json:"corrects_period,omitempty"`
}

// IsCostMonth is a month YYYY-MM.
func IsCostMonth(v string) bool {
	t, err := time.Parse("2006-01", v)
	return err == nil && t.Format("2006-01") == v
}

// CheckCostEntry names the first thing it may not carry ("" = fine): the Go
// side of rdb 0245's CHECKs.
func CheckCostEntry(e CostEntry) string {
	switch {
	case !slices.Contains(CostEntryTypes, e.Type):
		return "type must be cloud or hr"
	case strings.TrimSpace(e.Label) == "" || len(e.Label) > 100:
		return "label must be 1..100 characters"
	case math.IsNaN(e.Amount) || math.IsInf(e.Amount, 0) || e.Amount <= 0 || e.Amount >= 1e10:
		return "amount must be a number above 0"
	case !IsCurrencyCode(e.Currency):
		return "currency must be an ISO 4217 code such as USD or EUR"
	case !IsCostMonth(e.Period):
		return "period must be a month YYYY-MM"
	case len(e.Note) > 2000:
		return "note must be at most 2000 characters"
	}
	return checkHRLine(e)
}

// checkHRLine is rdb 0280's part of CheckCostEntry: the hr fields, on hr
// lines only. A yearly line sits on the year's January; a correction names
// an earlier month.
func checkHRLine(e CostEntry) string {
	hrOnly := e.PersonID != "" || e.Component != "" || e.Source != "" || e.Account != "" || e.CorrectsPeriod != "" || (e.PeriodKind != "" && e.PeriodKind != "month")
	switch {
	case e.Type != "hr" && hrOnly:
		return "person_id, component, source, account, period_kind and corrects_period are for hr lines only"
	case e.PersonID != "" && !uuidRe.MatchString(e.PersonID):
		return "person_id must be a person's id"
	case e.PersonID != "" && e.Component == "":
		return "a person's line needs a component"
	case e.Component != "" && !hrComponentRe.MatchString(e.Component):
		return "component must be an hr component's id, e.g. monthly_salary"
	case len(e.Source) > 200:
		return "source must be at most 200 characters"
	case len(e.Account) > 20:
		return "account must be at most 20 characters"
	case e.PeriodKind != "" && e.PeriodKind != "month" && e.PeriodKind != "year":
		return "period_kind must be month or year"
	case e.PeriodKind == "year" && !strings.HasSuffix(e.Period, "-01"):
		return "a yearly line's period is the year's January, YYYY-01"
	case e.CorrectsPeriod != "" && (!IsCostMonth(e.CorrectsPeriod) || e.CorrectsPeriod >= e.Period):
		return "corrects_period must be a month YYYY-MM before the line's own"
	}
	return ""
}

// hrComponentRe is rdb 0280's component CHECK; the table's FK says whether it
// exists (Postgres), the seed list does on Memory.
var hrComponentRe = regexp.MustCompile(`^[a-z][a-z0-9_]{1,59}$`)

// CostEntryStore is the store half of rdb 0245. Optional: the routes answer
// unsupported on a store without it.
type CostEntryStore interface {
	// ListCostEntries is the entries of type typ ("" = every type) and month
	// YYYY-MM ("" = every month), period then created_at order.
	ListCostEntries(ctx context.Context, typ, month string) ([]CostEntry, error)
	// CreateCostEntry stores a checked entry under a new id and answers it.
	CreateCostEntry(ctx context.Context, e CostEntry) (CostEntry, error)
	// DeleteCostEntry removes entry id; ErrNotFound when there is none.
	DeleteCostEntry(ctx context.Context, id string) error
}

// The Memory driver keeps its rows beside the store, like the paid items.
var (
	memCostEntriesMu sync.Mutex
	memCostEntries   = map[*Memory]map[string]CostEntry{}
)

// ListCostEntries is CostEntryStore on Memory.
func (s *Memory) ListCostEntries(_ context.Context, typ, month string) ([]CostEntry, error) {
	memCostEntriesMu.Lock()
	defer memCostEntriesMu.Unlock()
	out := []CostEntry{}
	for _, e := range memCostEntries[s] {
		if (typ == "" || e.Type == typ) && (month == "" || e.Period == month) {
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Period != out[j].Period {
			return out[i].Period < out[j].Period
		}
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.Before(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

// CreateCostEntry is CostEntryStore on Memory.
func (s *Memory) CreateCostEntry(_ context.Context, e CostEntry) (CostEntry, error) {
	if why := CheckCostEntry(e); why != "" {
		return CostEntry{}, fmt.Errorf("cost entry: %s", why)
	}
	if e.Component != "" && !slices.ContainsFunc(DefaultHRComponents, func(c HRComponent) bool { return c.Component == e.Component }) {
		return CostEntry{}, fmt.Errorf("cost entry: no hr component %q", e.Component)
	}
	if e.PersonID != "" && !memHRPersonExists(s, e.PersonID) {
		return CostEntry{}, fmt.Errorf("cost entry: no hr person %s", e.PersonID)
	}
	if e.Type == "hr" && e.PeriodKind == "" {
		e.PeriodKind = "month"
	}
	memCostEntriesMu.Lock()
	defer memCostEntriesMu.Unlock()
	if memCostEntries[s] == nil {
		memCostEntries[s] = map[string]CostEntry{}
	}
	e.ID, e.CreatedAt = uuid.New(), time.Now().UTC().Truncate(time.Microsecond)
	memCostEntries[s][e.ID] = e
	return e, nil
}

// DeleteCostEntry is CostEntryStore on Memory.
func (s *Memory) DeleteCostEntry(_ context.Context, id string) error {
	memCostEntriesMu.Lock()
	defer memCostEntriesMu.Unlock()
	if _, ok := memCostEntries[s][id]; !ok {
		return ErrNotFound
	}
	delete(memCostEntries[s], id)
	return nil
}

var _ CostEntryStore = (*Memory)(nil)

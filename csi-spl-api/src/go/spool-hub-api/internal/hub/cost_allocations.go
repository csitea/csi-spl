package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// An estate cost assigned or split to workspaces by hand (SPL-5291, rdb
// 0275, spec 143 costs-allocation.md; owner HUM-10, t1 41a74806 poll
// 0c5e94b4 answer C part B: "A cost (e.g. a shared cloud bill, a person's
// hours) can be assigned or split to workspaces by hand, and each
// workspace's page shows its share"; poll 01cbbdea answers 1B 2B 3B: Tokens
// stay automatic, a split holds for every month, a customer workspace's
// admin may also split among the workspaces they administer).
//
// The operator's routes, behind the doors of the cost entries (the GET
// operatorReadCaller's, the PUT the operator workspace's admin or the
// operator service account, fleetLoadCaller):
//
//	GET /v1/operator/cost-allocations?month=YYYY-MM
//	    {month, second_currency, items: [{source, project_or_vendor, kind,
//	     origin, label, usd_micros, eur_micros, second_micros, unpriced,
//	     shares}], workspaces: [{id, name}]}
//	PUT /v1/operator/cost-allocations
//	    {source, project_or_vendor, kind, shares: [{workspace_id, share_bp}]}
//	    -> 200 the split; shares [] removes it
//
// The customer admin's routes: cost_allocations_tenant.go. A workspace's
// GET /v1/tenant/costs adds one part per item allocated to it
// (costAllocatedParts); the estate answer keeps the full amounts and names
// each part's split (costAllocAnnotate).

// costAllocBodyMax bounds one split's body (a few hundred shares at most).
const costAllocBodyMax = 64 << 10

// costAllocEdit is the PUT body of both doors.
type costAllocEdit struct {
	Source          string                 `json:"source"`
	ProjectOrVendor string                 `json:"project_or_vendor"`
	Kind            string                 `json:"kind"`
	Shares          []store.CostAllocShare `json:"shares"`
}

// costAllocItemOut is one estate item of the month with its split.
type costAllocItemOut struct {
	store.CostItemKey
	Origin       string                 `json:"origin"`
	Label        string                 `json:"label"` // persons | cloud
	USDMicros    int64                  `json:"usd_micros"`
	EURMicros    int64                  `json:"eur_micros"`
	SecondMicros *int64                 `json:"second_micros"`
	Unpriced     bool                   `json:"unpriced,omitempty"`
	Shares       []store.CostAllocShare `json:"shares"`
}

type costAllocWorkspace struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (s *Server) routeCostAllocations(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/cost-allocations", s.handleCostAllocList)
	mux.HandleFunc("PUT /v1/operator/cost-allocations", s.handleCostAllocPut)
	mux.HandleFunc("OPTIONS /v1/operator/cost-allocations", s.operatorWorkspacesPreflight)
	mux.HandleFunc("GET /v1/tenant/cost-allocations", s.handleTenantCostAllocList)
	mux.HandleFunc("PUT /v1/tenant/cost-allocations", s.handleTenantCostAllocPut)
	mux.HandleFunc("OPTIONS /v1/tenant/cost-allocations", s.preflight)
}

// CostItemLabel files an estate item under one of the Costs labels: an hr
// entry is Persons, the AI items and token burn Tokens, the rest Cloud.
func CostItemLabel(source, kind string) string {
	switch {
	case source == store.CostSourceEntry && kind == "hr":
		return "persons"
	case store.CostItemTokens(source):
		return "tokens"
	}
	return "cloud"
}

// costAllocStore is the store half, or answered 501.
func (s *Server) costAllocStore(w http.ResponseWriter) (store.CostAllocationStore, bool) {
	ca, ok := s.o.Store.(store.CostAllocationStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost allocations")
	}
	return ca, ok
}

func (s *Server) handleCostAllocList(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := s.operatorReadCaller(w, r); !ok {
		return
	}
	ca, ok := s.costAllocStore(w)
	if !ok {
		return
	}
	win, why := costWindow(r.URL.Query().Get("month"), s.o.Now())
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_cost_allocation", why)
		return
	}
	body, err := s.costAllocListBody(r.Context(), ca, win)
	if err != nil {
		s.o.Log.Error().Err(err).Str("month", win.Month).Msg("cost allocation list")
		writeErr(w, http.StatusInternalServerError, "internal", "cost allocations unavailable")
		return
	}
	writeJSON(w, http.StatusOK, body)
}

// costAllocListBody is the operator's GET answer: the month's Persons and
// Cloud estate items, each with its split, and the workspaces a share may
// go to.
func (s *Server) costAllocListBody(ctx context.Context, ca store.CostAllocationStore, win costMonthWindow) (map[string]any, error) {
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return nil, err
	}
	cur := store.DefaultSecondCurrency
	items, err := s.costEstateItems(ctx, op, win, cur)
	if err != nil {
		return nil, err
	}
	splits, err := ca.CostAllocations(ctx)
	if err != nil {
		return nil, err
	}
	byKey := costAllocByKey(splits)
	out := make([]costAllocItemOut, 0, len(items))
	for _, p := range items {
		key := costItemKeyOf(p)
		o := costAllocItemOut{CostItemKey: key, Origin: p.Origin, Label: CostItemLabel(p.Source, p.Kind),
			USDMicros: p.USDMicros, EURMicros: p.EURMicros, SecondMicros: p.SecondMicros, Unpriced: p.Unpriced,
			Shares: []store.CostAllocShare{}}
		if a, ok := byKey[key]; ok {
			o.Shares = a.Shares
		}
		out = append(out, o)
	}
	ws, err := s.costAllocWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	return map[string]any{"month": win.Month, "second_currency": cur, "items": out, "workspaces": ws}, nil
}

func costItemKeyOf(p store.CostPart) store.CostItemKey {
	return store.CostItemKey{Source: p.Source, ProjectOrVendor: p.ProjectOrVendor, Kind: p.Kind}
}

// costAllocWorkspaces is every live workspace a share may go to, by name.
func (s *Server) costAllocWorkspaces(ctx context.Context) ([]costAllocWorkspace, error) {
	ow, ok := s.o.Store.(store.OperatorWorkspaces)
	if !ok {
		return []costAllocWorkspace{}, nil
	}
	all, err := ow.ListWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	out := []costAllocWorkspace{}
	for _, t := range all {
		if t.ArchivedAt.IsZero() && t.SuspendedAt.IsZero() {
			out = append(out, costAllocWorkspace{ID: t.ID, Name: t.DisplayName})
		}
	}
	sortCostAllocWorkspaces(out)
	return out, nil
}

func sortCostAllocWorkspaces(out []costAllocWorkspace) {
	slices.SortFunc(out, func(a, b costAllocWorkspace) int {
		if c := strings.Compare(a.Name, b.Name); c != 0 {
			return c
		}
		return strings.Compare(a.ID, b.ID)
	})
}

func (s *Server) handleCostAllocPut(w http.ResponseWriter, r *http.Request) {
	_, _, who, ok := s.fleetLoadCaller(w, r)
	if !ok {
		return
	}
	ca, ok := s.costAllocStore(w)
	if !ok {
		return
	}
	in, ok := readCostAllocEdit(w, r, who, store.CheckCostAllocation)
	if !ok {
		return
	}
	if why := s.checkCostAllocWorkspaces(r.Context(), in); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_cost_allocation", why)
		return
	}
	s.putCostAlloc(w, r, ca, in, nil)
}

// readCostAllocEdit decodes the PUT body and checks it with check (the whole
// split for the operator, the shares only for a customer admin); false =
// answered.
func readCostAllocEdit(w http.ResponseWriter, r *http.Request, who string, check func(store.CostAllocation) string) (store.CostAllocation, bool) {
	var e costAllocEdit
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, costAllocBodyMax))
	if err == nil {
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		err = dec.Decode(&e)
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {source, project_or_vendor, kind, shares}: "+err.Error())
		return store.CostAllocation{}, false
	}
	in := store.CostAllocation{CostItemKey: store.CostItemKey{Source: e.Source, ProjectOrVendor: e.ProjectOrVendor, Kind: e.Kind},
		Shares: e.Shares, CreatedBy: who}
	if why := check(in); why != "" {
		writeErr(w, http.StatusBadRequest, "bad_cost_allocation", why)
		return store.CostAllocation{}, false
	}
	return in, true
}

// putCostAlloc writes the split (within: a customer admin's workspaces) and
// answers it.
func (s *Server) putCostAlloc(w http.ResponseWriter, r *http.Request, ca store.CostAllocationStore, in store.CostAllocation, within map[string]bool) {
	out, err := ca.PutCostAllocation(r.Context(), in, within)
	switch {
	case errors.Is(err, store.ErrCostAllocOutside):
		writeErr(w, http.StatusForbidden, "cost_allocation.outside", err.Error())
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("cost allocation put")
		writeErr(w, http.StatusInternalServerError, "internal", "cost allocation not stored")
		return
	}
	s.o.Log.Info().Str("source", out.Source).Str("item", out.ProjectOrVendor).Int("shares", len(out.Shares)).
		Str("by", in.CreatedBy).Bool("customer_admin", within != nil).Msg("cost allocation set")
	writeJSON(w, http.StatusOK, out)
}

// checkCostAllocWorkspaces names a share to a workspace that is not live
// ("" = every one is).
func (s *Server) checkCostAllocWorkspaces(ctx context.Context, a store.CostAllocation) string {
	if len(a.Shares) == 0 {
		return ""
	}
	ws, err := s.costAllocWorkspaces(ctx)
	if err != nil {
		return "the workspaces were not read"
	}
	live := map[string]bool{}
	for _, w := range ws {
		live[w.ID] = true
	}
	for _, sh := range a.Shares {
		if !live[sh.WorkspaceID] {
			return "no live workspace " + sh.WorkspaceID
		}
	}
	return ""
}

// costEstateItems is the month's Persons and Cloud estate items: the estate
// answer's cost-line parts, its cost entries and its Human rows (never a
// Tokens item: answer 1 B), in the second currency cur.
func (s *Server) costEstateItems(ctx context.Context, op string, win costMonthWindow, cur string) ([]store.CostPart, error) {
	var items []store.CostPart
	if cr, ok := s.o.Store.(store.CostRead); ok {
		cm, err := cr.CostMonthRead(ctx, store.CostMonthQuery{Tenant: op, Estate: true,
			From: win.From, To: win.To, CoverTo: win.CoverTo, Currency: cur})
		if err != nil {
			return nil, err
		}
		for _, p := range cm.Parts {
			if p.Estate && !store.CostItemTokens(p.Source) {
				items = append(items, p)
			}
		}
	}
	spend, human, err := s.costEntryMonthParts(ctx, win.Month, cur)
	if err != nil {
		return nil, err
	}
	return append(append(items, spend...), human...), nil
}

// costAllocByKey indexes splits by item.
func costAllocByKey(splits []store.CostAllocation) map[store.CostItemKey]store.CostAllocation {
	out := make(map[store.CostItemKey]store.CostAllocation, len(splits))
	for _, a := range splits {
		out[a.CostItemKey] = a
	}
	return out
}

// costAllocSplits is every split; none on a store without them.
func (s *Server) costAllocSplits(ctx context.Context) ([]store.CostAllocation, error) {
	ca, ok := s.o.Store.(store.CostAllocationStore)
	if !ok {
		return nil, nil
	}
	return ca.CostAllocations(ctx)
}

// costAllocatedParts is workspace tenant's share of every estate item
// allocated to it, in this month: source allocated, the item's key and
// origin, its own source in allocated_source, and each amount floor(amount
// * share_bp / 10000). spend counts in the workspace's total, human (hr
// items) in its Human rows, as the estate's (SPL-4840).
func (s *Server) costAllocatedParts(ctx context.Context, op, tenant string, win costMonthWindow, cur string,
	splits []store.CostAllocation) (spend, human []store.CostPart, err error) {
	mine := map[store.CostItemKey]int{}
	for _, a := range splits {
		for _, sh := range a.Shares {
			if sh.WorkspaceID == tenant {
				mine[a.CostItemKey] = sh.ShareBP
			}
		}
	}
	if len(mine) == 0 {
		return nil, nil, nil
	}
	items, err := s.costEstateItems(ctx, op, win, cur)
	if err != nil {
		return nil, nil, err
	}
	for _, p := range items {
		bp, ok := mine[costItemKeyOf(p)]
		if !ok {
			continue
		}
		q := costAllocShare(p, bp)
		if CostItemLabel(p.Source, p.Kind) == "persons" {
			human = append(human, q)
		} else {
			spend = append(spend, q)
		}
	}
	return spend, human, nil
}

// costAllocShare is bp basis points of the estate part p.
func costAllocShare(p store.CostPart, bp int) store.CostPart {
	q := p
	q.Estate, q.Source, q.AllocatedSource, q.ShareBP = false, store.CostSourceAllocated, p.Source, bp
	q.USDMicros, q.EURMicros = store.CostAllocShareOf(p.USDMicros, bp), store.CostAllocShareOf(p.EURMicros, bp)
	q.EntryMicros = store.CostAllocShareOf(p.EntryMicros, bp)
	q.Units = p.Units * float64(bp) / store.CostAllocMaxBP
	if p.SecondMicros != nil {
		v := store.CostAllocShareOf(*p.SecondMicros, bp)
		q.SecondMicros = &v
	}
	if p.ListValueMicros != nil {
		v := store.CostAllocShareOf(*p.ListValueMicros, bp)
		q.ListValueMicros = &v
	}
	return q
}

// costAllocAnnotate names, on the estate answer, each part's and Human
// row's split (the amounts stay whole: a share is an attribution).
func costAllocAnnotate(b *costMonthBody, splits []store.CostAllocation) {
	byKey := costAllocByKey(splits)
	for _, rows := range [][]costPartOut{b.Parts, b.Human} {
		for i := range rows {
			if a, ok := byKey[costItemKeyOf(rows[i].CostPart)]; ok {
				rows[i].Allocation = a.Shares
			}
		}
	}
}

package hub

import (
	"context"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A customer workspace's admin splits a cost among the workspaces they
// administer (SPL-5291, owner HUM-10 poll 01cbbdea answer 3 B: "Also a
// customer workspace's admin, among the workspaces they administer"; spec
// 143 costs-allocation.md section 3):
//
//	GET /v1/tenant/cost-allocations?month=YYYY-MM
//	    {month, second_currency, items: [{source, project_or_vendor, kind,
//	     label, held_bp, shares: [{workspace_id, share_bp, usd_micros,
//	     eur_micros, second_micros}]}], workspaces: [{id, name}]}
//	PUT /v1/tenant/cost-allocations   the operator's body; the rules below
//
// "The workspaces they administer" (costAllocAdminSet): every live workspace
// where the signed-in person (a HUM-* of a signed session; never an agent
// seat, an act-as clone or a service account) holds the admin role, read
// from Memberships(hum) and the hub's access at the request, never from a
// header or the body. The caller must also be an admin of the workspace
// they call from. The store checks the split against the stored one inside
// its transaction (store.CheckCostAllocWithin): no share outside the set
// changes or is added, the set's sum stays, and the item must already give
// the set a share; a refusal is 403 cost_allocation.outside. The GET shows
// only the set's shares and their money, never the item's whole amount or
// another workspace's share.

// costAllocAdmin is the customer admin's set; false = answered.
func (s *Server) costAllocAdmin(w http.ResponseWriter, r *http.Request) (map[string]bool, string, bool) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return nil, "", false
	}
	ctx := r.Context()
	if !a.Has(rbac.Admin) || s.readerIsActAsClone(ctx, t.ID, a.HumanID) {
		writeForbidden(w, rbac.TenantSettings, "only a workspace's admin, signed in as themself, splits a cost")
		return nil, "", false
	}
	set, err := s.costAllocAdminSet(ctx, a.HumanID)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost allocation admin set")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "your workspaces were not read")
		return nil, "", false
	}
	if !set[t.ID] {
		writeForbidden(w, rbac.TenantSettings, "this workspace is not live")
		return nil, "", false
	}
	return set, a.HumanID, true
}

// costAllocAdminSet is A(hum): the live workspaces where hum is an admin.
func (s *Server) costAllocAdminSet(ctx context.Context, hum string) (map[string]bool, error) {
	ml, ok := s.o.Store.(store.MembershipLister)
	if !ok {
		return map[string]bool{}, nil
	}
	ms, err := ml.Memberships(ctx, hum)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, m := range ms {
		a, err := s.access(ctx, hum, m.TenantID)
		if err != nil || !a.Has(rbac.Admin) || s.readerIsActAsClone(ctx, m.TenantID, hum) {
			continue
		}
		t, err := s.o.Store.GetTenant(ctx, m.TenantID)
		if err != nil || t.Suspended() || !t.ArchivedAt.IsZero() {
			continue
		}
		out[m.TenantID] = true
	}
	return out, nil
}

func (s *Server) handleTenantCostAllocPut(w http.ResponseWriter, r *http.Request) {
	set, hum, ok := s.costAllocAdmin(w, r)
	if !ok {
		return
	}
	ca, ok := s.costAllocStore(w)
	if !ok {
		return
	}
	// the body names the admin's workspaces' shares only (they never read
	// the others); the store completes it with the stored ones
	in, ok := readCostAllocEdit(w, r, hum, store.CheckCostAllocShares)
	if !ok {
		return
	}
	s.putCostAlloc(w, r, ca, in, set)
}

// costAllocHeldShare is one of the admin's workspaces' share with its money.
type costAllocHeldShare struct {
	store.CostAllocShare
	USDMicros    int64  `json:"usd_micros"`
	EURMicros    int64  `json:"eur_micros"`
	SecondMicros *int64 `json:"second_micros"`
}

type costAllocHeldItem struct {
	store.CostItemKey
	Label  string               `json:"label"`
	HeldBP int                  `json:"held_bp"`
	Shares []costAllocHeldShare `json:"shares"`
}

func (s *Server) handleTenantCostAllocList(w http.ResponseWriter, r *http.Request) {
	set, _, ok := s.costAllocAdmin(w, r)
	if !ok {
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
	items, ws, err := s.costAllocHeld(r.Context(), ca, set, win)
	if err != nil {
		s.o.Log.Error().Err(err).Str("month", win.Month).Msg("cost allocation held list")
		writeErr(w, http.StatusInternalServerError, "internal", "cost allocations unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"month": win.Month, "second_currency": store.DefaultSecondCurrency,
		"items": items, "workspaces": ws})
}

// costAllocHeld is every split giving set a share, the set's shares only,
// each with its money of the month (0 when the item has none that month).
func (s *Server) costAllocHeld(ctx context.Context, ca store.CostAllocationStore, set map[string]bool,
	win costMonthWindow) ([]costAllocHeldItem, []costAllocWorkspace, error) {
	splits, err := ca.CostAllocations(ctx)
	if err != nil {
		return nil, nil, err
	}
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return nil, nil, err
	}
	estate, err := s.costEstateItems(ctx, op, win, store.DefaultSecondCurrency)
	if err != nil {
		return nil, nil, err
	}
	money := map[store.CostItemKey][]store.CostPart{}
	for _, p := range estate {
		money[costItemKeyOf(p)] = append(money[costItemKeyOf(p)], p)
	}
	items := []costAllocHeldItem{}
	for _, a := range splits {
		it := costAllocHeldItem{CostItemKey: a.CostItemKey, Label: CostItemLabel(a.Source, a.Kind), Shares: []costAllocHeldShare{}}
		for _, sh := range a.Shares {
			if set[sh.WorkspaceID] {
				it.HeldBP += sh.ShareBP
				it.Shares = append(it.Shares, costAllocHeldMoney(sh, money[a.CostItemKey]))
			}
		}
		if it.HeldBP > 0 {
			items = append(items, it)
		}
	}
	ws, err := s.costAllocWorkspaces(ctx)
	if err != nil {
		return nil, nil, err
	}
	mine := []costAllocWorkspace{}
	for _, w := range ws {
		if set[w.ID] {
			mine = append(mine, w)
		}
	}
	return items, mine, nil
}

// costAllocHeldMoney is sh's money of the item's parts this month.
func costAllocHeldMoney(sh store.CostAllocShare, parts []store.CostPart) costAllocHeldShare {
	out := costAllocHeldShare{CostAllocShare: sh}
	var second int64
	complete := true
	for _, p := range parts {
		q := costAllocShare(p, sh.ShareBP)
		out.USDMicros += q.USDMicros
		out.EURMicros += q.EURMicros
		if q.SecondMicros == nil {
			complete = false
		} else {
			second += *q.SecondMicros
		}
	}
	if complete {
		out.SecondMicros = &second
	}
	return out
}

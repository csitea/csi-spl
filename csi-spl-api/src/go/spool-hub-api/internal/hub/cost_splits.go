package hub

import (
	"context"
	"math"
	"net/http"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The instance's splits of the paid AI items and of a person's hr costs
// over the workspaces (SPL-5768, rdb 0291, spec 143 costs-allocation.md
// section 7; owner HUM-10, csitea f655b326 msg 3440bf12: "the admin and the
// business owner should be able to define percentages for the division of
// the costs, both for the tokens and for the personnel costs, on a
// percentage basis, divided for each workspace. This should be done on a
// cloud-instance basis.").
//
// Read and written by the operator workspace's admin and biz_owner, or the
// operator service account; never a live act-as clone:
//
//	GET /v1/operator/cost-splits
//	    {splits: [{split_kind, subject, shares, created_by, created_at}],
//	     people: [{id, code}], workspaces: [{id, name}]}
//	PUT /v1/operator/cost-splits
//	    {split_kind, subject, shares: [{workspace_id, share_bp}]}
//	    -> 200 the split; shares [] removes it
//
// A customer workspace's month read applies them (costSplitAIParts,
// costAllocatedParts); the estate answer keeps the full amounts and names
// each split (costAllocAnnotate).

// costSplitRoles are the operator workspace's roles that read and write the
// splits (msg 3440bf12: "the admin and the business owner").
var costSplitRoles = []string{rbac.Admin, rbac.BizOwner}

// costSplitEdit is the PUT body.
type costSplitEdit struct {
	Kind    string                 `json:"split_kind"`
	Subject string                 `json:"subject"`
	Shares  []store.CostAllocShare `json:"shares"`
}

type costSplitPerson struct {
	ID   string `json:"id"`
	Code string `json:"code"`
}

func (s *Server) routeCostSplits(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/cost-splits", s.handleCostSplitList)
	mux.HandleFunc("PUT /v1/operator/cost-splits", s.handleCostSplitPut)
	mux.HandleFunc("OPTIONS /v1/operator/cost-splits", s.operatorWorkspacesPreflight)
}

// costSplitCaller is the gate of both routes; false = answered.
func (s *Server) costSplitCaller(w http.ResponseWriter, r *http.Request) (store.CostSplitStore, string, bool) {
	_, _, who, ok := s.estateReadCaller(w, r, costSplitRoles,
		"only an admin or a biz_owner of the operator workspace sets the cost splits")
	if !ok {
		return nil, "", false
	}
	cs, ok := s.o.Store.(store.CostSplitStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost splits")
	}
	return cs, who, ok
}

func (s *Server) handleCostSplitList(w http.ResponseWriter, r *http.Request) {
	cs, _, ok := s.costSplitCaller(w, r)
	if !ok {
		return
	}
	splits, err := cs.CostSplits(r.Context())
	var people []costSplitPerson
	var ws []costAllocWorkspace
	if err == nil {
		people, err = s.costSplitPeople(r.Context())
	}
	if err == nil {
		ws, err = s.costAllocWorkspaces(r.Context())
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost split list")
		writeErr(w, http.StatusInternalServerError, "internal", "cost splits unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"splits": splits, "people": people, "workspaces": ws})
}

// costSplitPeople is every hr person by id and code (never a name).
func (s *Server) costSplitPeople(ctx context.Context) ([]costSplitPerson, error) {
	out := []costSplitPerson{}
	hs, ok := s.o.Store.(store.HRCostStore)
	if !ok {
		return out, nil
	}
	ps, err := hs.ListHRPeople(ctx, false)
	for _, p := range ps {
		out = append(out, costSplitPerson{ID: p.ID, Code: p.Code})
	}
	return out, err
}

func (s *Server) handleCostSplitPut(w http.ResponseWriter, r *http.Request) {
	cs, who, ok := s.costSplitCaller(w, r)
	if !ok {
		return
	}
	var e costSplitEdit
	if !decodeStrict(w, r, &e, "body must be {split_kind, subject, shares}") {
		return
	}
	sp := store.CostSplit{CostSplitKey: store.CostSplitKey{Kind: e.Kind, Subject: e.Subject}, Shares: e.Shares, CreatedBy: who}
	why := store.CheckCostSplit(sp)
	if why == "" && len(sp.Shares) > 0 {
		why = s.costSplitRefs(r.Context(), sp)
	}
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_cost_split", why)
		return
	}
	out, err := cs.PutCostSplit(r.Context(), sp)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost split put")
		writeErr(w, http.StatusInternalServerError, "internal", "cost split not stored")
		return
	}
	s.o.Log.Info().Str("split_kind", out.Kind).Str("subject", out.Subject).Int("shares", len(out.Shares)).
		Str("by", who).Msg("cost split set")
	writeJSON(w, http.StatusOK, out)
}

// costSplitRefs names a share to a workspace that is not live, or a person
// split whose subject is no hr person ("" = fine).
func (s *Server) costSplitRefs(ctx context.Context, sp store.CostSplit) string {
	if why := s.checkCostAllocWorkspaces(ctx, store.CostAllocation{Shares: sp.Shares}); why != "" {
		return why
	}
	if sp.Kind != store.CostSplitPerson {
		return ""
	}
	people, err := s.costSplitPeople(ctx)
	if err != nil {
		return "the hr people were not read"
	}
	if !slices.ContainsFunc(people, func(p costSplitPerson) bool { return p.ID == sp.Subject }) {
		return "no hr person " + sp.Subject
	}
	return ""
}

// costSplitsOf is every split; none on a store without them.
func (s *Server) costSplitsOf(ctx context.Context) ([]store.CostSplit, error) {
	cs, ok := s.o.Store.(store.CostSplitStore)
	if !ok {
		return nil, nil
	}
	return cs.CostSplits(ctx)
}

// costSplitAIParts is customer workspace tenant's AI parts under the tokens
// split shares (section 7.5): the estate's paid items at tenant's share,
// one ai_share part per agent type (no plan, as the automatic share), each
// amount floor(amount * share_bp / 10000) per estate part.
func (s *Server) costSplitAIParts(ctx context.Context, op, tenant string, win costMonthWindow, cur string,
	shares []store.CostAllocShare) (*store.AIPaidMonth, error) {
	m, err := s.aiCostParts(ctx, op, true, tenant, win, cur)
	if err != nil || m == nil {
		return m, err
	}
	out := &store.AIPaidMonth{Coverage: m.Coverage, ShareFrom: win.From}
	out.Coverage.Source = store.CostSourceAIShare
	bp := store.ShareOf(shares, tenant)
	if bp == 0 {
		return out, nil
	}
	byVendor := map[string]int{}
	for _, p := range m.Parts {
		q := costAllocShare(p, bp)
		q.Source, q.Kind, q.AllocatedSource = store.CostSourceAIShare, "share", store.CostSourceAIPaid
		q.FXRate, q.FXRateDay, q.FXRateFirstDay = nil, nil, nil
		i, seen := byVendor[q.ProjectOrVendor]
		if !seen {
			byVendor[q.ProjectOrVendor] = len(out.Parts)
			out.Parts = append(out.Parts, q)
			continue
		}
		out.Parts[i] = costSplitAddPart(out.Parts[i], q)
	}
	return out, nil
}

// costPersonSplitParts is customer workspace q.tenant's share of the
// month's hr lines of every person whose split holds it (section 7.5):
// each line's amount at the tenant's share, rounded down to the micro, then
// summed per component like the estate's rows (hrReportEntries: no row is a
// person's, spec 123 13.6). A row whose estate item has its own item split
// is left out: the item split wins. share_bp is set only when every split
// person gives the tenant the same share.
func (s *Server) costPersonSplitParts(ctx context.Context, q costAllocQuery, person map[string][]store.CostAllocShare,
	itemSplit map[store.CostItemKey]store.CostAllocation) ([]store.CostPart, error) {
	ce, ok := s.o.Store.(store.CostEntryStore)
	if !ok || len(person) == 0 {
		return nil, nil
	}
	entries, err := ce.ListCostEntries(ctx, "hr", q.win.Month)
	if err != nil {
		return nil, err
	}
	mine, bps := []store.CostEntry{}, map[int]bool{}
	for _, e := range entries {
		bp := store.ShareOf(person[e.PersonID], q.tenant)
		if e.PersonID == "" || bp == 0 {
			continue
		}
		e.Amount = float64(store.CostAllocShareOf(int64(math.Round(e.Amount*1e6)), bp)) / 1e6
		mine, bps[bp] = append(mine, e), true
	}
	if len(mine) == 0 {
		return nil, nil
	}
	mine, groups, err := s.hrReportEntries(ctx, mine)
	if err != nil {
		return nil, err
	}
	one := 0
	if len(bps) == 1 {
		for bp := range bps {
			one = bp
		}
	}
	parts, err := store.CostEntryParts(ctx, mine, q.cur, s.costEntryRate())
	out := []store.CostPart{}
	for i, p := range parts { // one part per entry, in order (CostEntryParts)
		if _, own := itemSplit[costItemKeyOf(p)]; own {
			continue
		}
		if mine[i].Component != "" {
			p.Component, p.Group = mine[i].Component, groups[mine[i].Component]
		}
		p.Estate, p.Source, p.AllocatedSource, p.ShareBP = false, store.CostSourceAllocated, p.Source, one
		out = append(out, p)
	}
	return out, err
}

// costSplitAddPart is a with q's money added (the same agent type's share
// of another plan); a nil second amount on either side stays nil.
func costSplitAddPart(a, q store.CostPart) store.CostPart {
	a.USDMicros += q.USDMicros
	a.EURMicros += q.EURMicros
	a.Units += q.Units
	a.Days = max(a.Days, q.Days)
	if a.SecondMicros == nil || q.SecondMicros == nil {
		a.SecondMicros = nil
	} else {
		v := *a.SecondMicros + *q.SecondMicros
		a.SecondMicros = &v
	}
	if a.ListValueMicros != nil && q.ListValueMicros != nil {
		v := *a.ListValueMicros + *q.ListValueMicros
		a.ListValueMicros = &v
	}
	return a
}

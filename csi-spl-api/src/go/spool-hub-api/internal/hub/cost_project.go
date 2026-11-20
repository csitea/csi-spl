package hub

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The project's cost (spec 123 section 13, row P01; owner HUM-10, t1
// e2c0e6b4 msg 3a190b70 "These the costs of this project"):
//
//	GET /v1/tenant/costs/project?month=YYYY-MM   default: the current UTC month so far
//	GET /v1/tenant/costs/project?year=YYYY       the year to date: its months so far
//
// costs.read, the month read's scope (5.2): the operator workspace's estate
// reader gets four parts, Cloud, Owned hardware, AI tokens and Human; any
// other reader its workspace's two, AI tokens and Human (Q-8 A, 13.7). Each
// part is the month read's parts folded (store/cost_project.go), with its
// amount in USD, EUR and the reader's second currency (null where it is not
// known, never 0), its share of total.priced and its completeness in words
// (13.5); the parts sum to total.priced. Human is not_tracked until P02.
// Money in no part (a customer workspace's allocated share) is named in
// left_out. The human money mask is P03's.

type costProjectBody struct {
	Period   string                     `json:"period"` // month | year
	Month    string                     `json:"month,omitempty"`
	Year     string                     `json:"year,omitempty"`
	From     string                     `json:"from"`
	To       string                     `json:"to"` // last day, inclusive
	Status   string                     `json:"status"`
	Scope    string                     `json:"scope"` // estate | workspace
	Currency string                     `json:"second_currency"`
	Days     int                        `json:"days"`
	Ended    int                        `json:"days_ended"`
	Parts    []store.CostProjectPart    `json:"parts"`
	Total    store.CostProjectTotal     `json:"total"`
	LeftOut  []store.CostProjectLeftOut `json:"left_out"`
}

func (s *Server) routeCostProject(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/costs/project", s.handleCostProject)
	mux.HandleFunc("OPTIONS /v1/tenant/costs/project", s.preflight)
}

// costProjectWindows is the period's months as of now: month= (default the
// current one) or year= (January to the current month, or to December of a
// past year); both, a bad shape or a future period is refused.
func costProjectWindows(month, year string, now time.Time) ([]costMonthWindow, string) {
	if year == "" {
		w, why := costWindow(month, now)
		return []costMonthWindow{w}, why
	}
	y, err := strconv.Atoi(year)
	switch {
	case month != "":
		return nil, "month and year are one period: ask one"
	case err != nil || len(year) != 4 || y < 2000:
		return nil, "year must be YYYY"
	case y > now.UTC().Year():
		return nil, "year " + year + " has not started"
	}
	last := 12
	if y == now.UTC().Year() {
		last = int(now.UTC().Month())
	}
	out := make([]costMonthWindow, 0, last)
	for m := 1; m <= last; m++ {
		w, why := costWindow(time.Date(y, time.Month(m), 1, 0, 0, 0, 0, time.UTC).Format("2006-01"), now)
		if why != "" {
			return nil, why
		}
		out = append(out, w)
	}
	return out, ""
}

// GET /v1/tenant/costs/project?month=YYYY-MM | year=YYYY
func (s *Server) handleCostProject(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.CostsRead)
	if !ok {
		return
	}
	_, lines := s.o.Store.(store.CostRead)
	_, burns := s.o.Store.(store.WorkspaceTokens)
	if !lines && !burns {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost lines")
		return
	}
	q := r.URL.Query()
	wins, why := costProjectWindows(q.Get("month"), q.Get("year"), s.o.Now())
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_query", why)
		return
	}
	op, err := s.operatorTenant(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return
	}
	estate := s.readsCostEstate(r.Context(), op, t.ID, a) // the month read's rule (5.2, SPL-4187)
	cur, err := s.secondCurrency(r.Context(), a.HumanID, t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("cost.project_currency_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "your second currency was not read")
		return
	}
	in, err := s.costProjectInput(r.Context(), costProjectAsk{op: op, tenant: t.ID, estate: estate, cur: cur}, wins)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("from", wins[0].From).Msg("cost.project_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "project cost unavailable")
		return
	}
	writeJSON(w, http.StatusOK, costProjectAnswer(q.Get("year"), wins, estate, cur, store.CostProjectParts(in)))
}

// costProjectAsk is who reads the project's cost, in which currency.
type costProjectAsk struct {
	op, tenant, cur string
	estate          bool
}

// costProjectInput is the month read (cost_read.go) of every window, its
// parts and coverage gathered for store.CostProjectParts.
func (s *Server) costProjectInput(ctx context.Context, k costProjectAsk, wins []costMonthWindow) (store.CostProjectInput, error) {
	in := store.CostProjectInput{Estate: k.estate}
	cr, lines := s.o.Store.(store.CostRead)
	for _, win := range wins {
		cm := store.CostMonth{Parts: []store.CostPart{}, Coverage: []store.CostSourceDays{}}
		var err error
		if lines {
			cm, err = cr.CostMonthRead(ctx, store.CostMonthQuery{Tenant: k.tenant, Estate: k.estate,
				From: win.From, To: win.To, CoverTo: win.CoverTo, Currency: k.cur})
		}
		if err != nil {
			return in, err
		}
		d, err := s.costReadGather(ctx, k.op, k.tenant, k.estate, win, k.cur)
		if err != nil {
			return in, err
		}
		b := costReadBody(win, k.estate, k.cur, cm, d)
		for _, p := range b.Parts {
			in.Parts = append(in.Parts, p.CostPart)
		}
		for _, c := range b.Coverage {
			in.Coverage = append(in.Coverage, c.CostSourceDays)
		}
		in.DaysEnded += win.Ended
		in.AIRead = in.AIRead || d.ai != nil
	}
	return in, nil
}

// costProjectAnswer shapes cp over the windows.
func costProjectAnswer(year string, wins []costMonthWindow, estate bool, cur string, cp store.CostProject) costProjectBody {
	first, last := wins[0], wins[len(wins)-1]
	end, _ := time.Parse(time.DateOnly, last.To)
	b := costProjectBody{Period: "month", Month: first.Month, From: first.From, To: end.AddDate(0, 0, -1).Format(time.DateOnly),
		Status: "ended", Scope: "workspace", Currency: cur, Parts: cp.Parts, Total: cp.Total, LeftOut: cp.LeftOut}
	if year != "" {
		b.Period, b.Month, b.Year = "year", "", year
	}
	if last.SoFar {
		b.Status = "so_far"
	}
	if estate {
		b.Scope = "estate"
	}
	for _, w := range wins {
		b.Days += w.Days
		b.Ended += w.Ended
	}
	return b
}

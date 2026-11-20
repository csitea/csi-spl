package hub

import (
	"context"
	"math"
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
// (13.5); the parts sum to total.priced. Human is the reader's workspace's
// approved minutes x the price in force per day (P02), not_tracked on a
// store with no such read.
// Money in no part (a customer workspace's allocated share) is named in
// left_out.
//
// The human mask (row P03, 13.6; spec 107 21.6, Q26 A and Q27 A, msg
// ce14ad70), human_mask in the answer:
//   - none:  a holder of hours.rates reads the Human part as folded.
//   - money: a holder of hours.read, or the estate reader (readsCostEstate:
//     the operator admin, product owner, accountants), without hours.rates,
//     reads the Human hours, counts and words but no money: its amounts and
//     share null.
//   - whole: every other costs.read reader ("nothing of others", Q26 A)
//     reads the Human part as its name and "not_shown" only; every other
//     field is zero or null, so a field P02 adds is hidden too.
//
// Masked either way, total.priced holds Cloud + owned hardware + AI tokens
// only and every share is of that total: a total that held the human money
// would reveal it by subtraction. Under whole, total.partial is read over
// the other parts and left_out only. Human money goes in the part's
// CostProjectMoney (the money mask clears exactly that); hours sit outside
// it (13.6).

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
	// HumanMask is what of the Human part this reader may not see (13.6):
	// none | money | whole.
	HumanMask string `json:"human_mask"`
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
	sight := costProjectSight{rates: a.Can(rbac.HoursRates), hours: a.Can(rbac.HoursRead) || estate}
	cp, mask := costProjectHumanMask(store.CostProjectParts(in), sight)
	b := costProjectAnswer(q.Get("year"), wins, estate, cur, cp)
	b.HumanMask = mask
	writeJSON(w, http.StatusOK, b)
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
	hr, human := s.o.Store.(store.CostProjectHumanRead)
	in.HumanRead = human
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
		if human {
			days, err := hr.CostProjectHumanDays(ctx, store.CostProjectHumanQuery{Tenant: k.tenant, From: win.From, To: win.To, Currency: k.cur})
			if err != nil {
				return in, err
			}
			in.Human = append(in.Human, days...)
		}
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

// The human mask levels (13.6) and the word a whole-masked Human part reads.
const (
	costProjectMaskNone  = "none"
	costProjectMaskMoney = "money"
	costProjectMaskWhole = "whole"
	costProjectNotShown  = "not_shown"
)

// costProjectSight is what a reader may see of the Human part: rates =
// hours.rates (the money), hours = hours.read or the estate read (the hours).
type costProjectSight struct {
	rates, hours bool
}

// costProjectMaskOn and costProjectWholeOn are the two masks' switches;
// package vars so the red controls can drop them (TestCostProjectHumanMask).
var costProjectMaskOn, costProjectWholeOn = true, true

// costProjectHumanMask takes out of cp what the reader may not see of the
// Human part (13.6) and answers the mask level. Masked, the Human part's
// known amounts leave total.priced and every share is re-read over the
// smaller total; money nulls the part's money and share and keeps the rest;
// whole keeps only its name and "not_shown". cp itself is not changed.
func costProjectHumanMask(cp store.CostProject, see costProjectSight) (store.CostProject, string) {
	if see.rates || !costProjectMaskOn {
		return cp, costProjectMaskNone
	}
	whole := !see.hours && costProjectWholeOn
	parts := make([]store.CostProjectPart, len(cp.Parts))
	copy(parts, cp.Parts)
	t := cp.Total.Priced
	tot := [3]*int64{costProjectCopy(t.USDMicros), costProjectCopy(t.EURMicros), costProjectCopy(t.SecondMicros)}
	partial := len(cp.LeftOut) > 0
	for i := range parts {
		p := &parts[i]
		if p.Part != store.CostProjectHuman {
			partial = partial || (p.Completeness != store.CostProjectComplete && p.Completeness != store.CostProjectHand)
			continue
		}
		for j, v := range []*int64{p.USDMicros, p.EURMicros, p.SecondMicros} {
			if v != nil && tot[j] != nil {
				*tot[j] -= *v
			}
		}
		p.CostProjectMoney, p.Share = store.CostProjectMoney{}, nil
		if whole {
			*p = store.CostProjectPart{Part: store.CostProjectHuman, Completeness: costProjectNotShown}
		}
	}
	cp.Parts = parts
	cp.Total.Priced = store.CostProjectMoney{USDMicros: tot[0], EURMicros: tot[1], SecondMicros: tot[2]}
	for i := range cp.Parts {
		p := &cp.Parts[i]
		p.Share = nil
		if p.USDMicros != nil && tot[0] != nil && *tot[0] > 0 {
			sh := math.Round(float64(*p.USDMicros)*1000/float64(*tot[0])) / 10 // store.costProjectTotal's rounding
			p.Share = &sh
		}
	}
	if !whole {
		return cp, costProjectMaskMoney
	}
	cp.Total.Partial = partial // the Human part's state is not this reader's either
	return cp, costProjectMaskWhole
}

func costProjectCopy(v *int64) *int64 {
	if v == nil {
		return nil
	}
	c := *v
	return &c
}

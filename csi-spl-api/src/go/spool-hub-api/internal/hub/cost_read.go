package hub

import (
	"context"
	"errors"
	"math"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The cost report of one calendar month (spec 123 sections 5 and 5.1, build
// lane 4b), the API of the Monitoring Costs tab (owner HUM-10, t1 dbf2f39b
// msgs 6cab186b "a tab which is for costs", a54b9e74 "both the costs from the
// infrastructure (from the GCP) and the costs of the tokens"):
//
//	GET /v1/tenant/costs?month=YYYY-MM   default: the current UTC month so far
//
// costs.read (biz_owner, admin; Q-1 = A). In the operator workspace the
// answer is the ESTATE (GCP projects, fleet tokens, agent-hours) beside the
// workspace's own rows; in any other workspace its own rows only. Parts are
// the month's live cost lines summed per (scope, source, project_or_vendor,
// kind, origin); coverage is "n of N days" per source from cost_coverage,
// where N is the days of the month that ended. Money is micros in USD and
// EUR (Q-6); pct is a part's share of the month's USD total, null while the
// total is 0 (counts only: subscription tokens and agent-seconds are units,
// never a price, Q-4). status: so_far while the month runs, ended after
// (the month close, 4.5, is not built: no month reads closed yet).
//
// The second currency (SPL-2108, owner HUM-10 t1 1b6f871f msg 44fef397):
// second_currency is the caller's own pick in this workspace (the personal
// setting second_currency, PUT /api/v1/auth/preferences; EUR when never
// picked). Every part carries second_micros (its USD converted cost day by
// cost day at the rdb 0200 rate of that day, else the last one before it),
// fx_rate and fx_rate_day (the rate of its latest cost day and that rate's
// date) and fx_rate_first_day (the rate date of its earliest cost day); all
// null when a cost day has no rate on or before it, never a guess. USD and
// EUR (what was paid) are unchanged; total.second_micros is null when any
// part's is.

// costMonthWindow is one month's days, as of now.
type costMonthWindow struct {
	Month   string // YYYY-MM
	From    string // first day
	To      string // first day of the next month (exclusive)
	Days    int    // days in the month
	Ended   int    // days of the month that ended (N of "n of N")
	SoFar   bool   // the month has not ended
	CoverTo string // exclusive end of the ended days
}

// costWindow reads month ("" = now's month) as of now: a future month or a
// bad shape is refused.
func costWindow(month string, now time.Time) (costMonthWindow, string) {
	now = now.UTC()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	if month != "" {
		m, err := time.Parse("2006-01", month)
		if err != nil || m.Format("2006-01") != month || m.Year() < 2000 {
			return costMonthWindow{}, "month must be YYYY-MM"
		}
		if m.After(first) {
			return costMonthWindow{}, "month " + month + " has not started"
		}
		first = m
	}
	next := first.AddDate(0, 1, 0)
	cover := today // the days before today ended
	if next.Before(today) {
		cover = next
	}
	w := costMonthWindow{Month: first.Format("2006-01"), From: first.Format(time.DateOnly), To: next.Format(time.DateOnly),
		Days: int(next.Sub(first).Hours() / 24), Ended: int(cover.Sub(first).Hours() / 24), SoFar: today.Before(next),
		CoverTo: cover.Format(time.DateOnly)}
	return w, ""
}

type costMoney struct {
	USDMicros    int64  `json:"usd_micros"`
	EURMicros    int64  `json:"eur_micros"`
	SecondMicros *int64 `json:"second_micros"`
}

type costPartOut struct {
	store.CostPart
	Hand bool     `json:"hand"` // entered by hand (origin hand or invoice)
	Pct  *float64 `json:"pct"`
}

type costCoverageOut struct {
	store.CostSourceDays
	Unrecorded int `json:"unrecorded"` // ended days with no coverage row
	Days       int `json:"days"`       // N
}

type costMonthBody struct {
	Month    string            `json:"month"`
	From     string            `json:"from"`
	To       string            `json:"to"` // last day, inclusive
	Status   string            `json:"status"`
	Scope    string            `json:"scope"` // estate | workspace
	Currency string            `json:"second_currency"`
	Days     int               `json:"days"`
	Ended    int               `json:"days_ended"`
	Total    costMoney         `json:"total"`
	Parts    []costPartOut     `json:"parts"`
	Coverage []costCoverageOut `json:"coverage"`
}

func (s *Server) routeCostRead(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/costs", s.handleCostRead)
	mux.HandleFunc("OPTIONS /v1/tenant/costs", s.preflight)
}

// GET /v1/tenant/costs?month=YYYY-MM
func (s *Server) handleCostRead(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.CostsRead)
	if !ok {
		return
	}
	cr, ok := s.o.Store.(store.CostRead)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost lines")
		return
	}
	win, why := costWindow(r.URL.Query().Get("month"), s.o.Now())
	if why != "" {
		writeErr(w, http.StatusBadRequest, "bad_query", why)
		return
	}
	op, err := s.operatorTenant(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return
	}
	estate := op != "" && t.ID == op
	cur, err := s.secondCurrency(r.Context(), a.HumanID, t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("cost.read_currency_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "your second currency was not read")
		return
	}
	cm, err := cr.CostMonthRead(r.Context(), store.CostMonthQuery{Tenant: t.ID, Estate: estate,
		From: win.From, To: win.To, CoverTo: win.CoverTo, Currency: cur})
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("month", win.Month).Msg("cost.read_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "cost report unavailable")
		return
	}
	writeJSON(w, http.StatusOK, costMonthAnswer(win, estate, cur, cm))
}

// secondCurrency is the member's second currency in tenant (SPL-2108): their
// own pick (rdb 0078 membership settings), else store.DefaultSecondCurrency.
func (s *Server) secondCurrency(ctx context.Context, hum, tenant string) (string, error) {
	mr, ok := s.o.Store.(auth.MembershipSettingsReader)
	if !ok || hum == "" {
		return store.DefaultSecondCurrency, nil
	}
	ms, err := mr.MembershipSettings(ctx, hum, tenant)
	if err != nil && !errors.Is(err, store.ErrNotFound) && !errors.Is(err, auth.ErrNoHuman) {
		return "", err
	}
	if ms.SecondCurrency != nil && store.IsCurrencyCode(*ms.SecondCurrency) {
		return *ms.SecondCurrency, nil
	}
	return store.DefaultSecondCurrency, nil
}

// costMonthAnswer shapes the store's month: totals, each part's share and
// each source's n of N.
func costMonthAnswer(win costMonthWindow, estate bool, cur string, cm store.CostMonth) costMonthBody {
	b := costMonthBody{Month: win.Month, From: win.From, Days: win.Days, Ended: win.Ended,
		Status: "ended", Scope: "workspace", Currency: cur, Parts: []costPartOut{}, Coverage: []costCoverageOut{}}
	last, _ := time.Parse(time.DateOnly, win.To)
	b.To = last.AddDate(0, 0, -1).Format(time.DateOnly)
	if win.SoFar {
		b.Status = "so_far"
	}
	if estate {
		b.Scope = "estate"
	}
	second, complete := int64(0), true
	for _, p := range cm.Parts {
		b.Total.USDMicros += p.USDMicros
		b.Total.EURMicros += p.EURMicros
		if p.SecondMicros == nil {
			complete = false
		} else {
			second += *p.SecondMicros
		}
	}
	if complete {
		b.Total.SecondMicros = &second
	}
	for _, p := range cm.Parts {
		o := costPartOut{CostPart: p, Hand: p.Origin == "hand" || p.Origin == "invoice"}
		if b.Total.USDMicros > 0 {
			pct := math.Round(float64(p.USDMicros)*1000/float64(b.Total.USDMicros)) / 10
			o.Pct = &pct
		}
		b.Parts = append(b.Parts, o)
	}
	for _, c := range cm.Coverage {
		b.Coverage = append(b.Coverage, costCoverageOut{CostSourceDays: c, Days: win.Ended,
			Unrecorded: max(0, win.Ended-c.OK-c.Partial-c.Missing)})
	}
	return b
}

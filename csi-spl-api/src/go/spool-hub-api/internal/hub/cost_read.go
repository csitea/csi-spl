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
// costs.read (every member role since rdb 0229, spec 140 3.10). The ESTATE
// (GCP projects, fleet tokens, agent-hours, beside the workspace's own rows,
// and workspaces: every workspace's token burn) is the operator workspace's
// ADMIN's only (owner t1 f3ed0eed msg 96d69790); any other member, there or
// in any other workspace, reads that workspace's own rows plus the token
// burn of the lanes working for it (source fleet_tokens, one part per
// vendor, the list price beside a paid 0; the operator workspace's own
// burn is its lanes that work for no other workspace). Parts are
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
//
// The AI subscriptions (spec 143 costs-redesign.md 3.3.1 and 4, SPL-3810;
// owner HUM-10 t1 1be0e370 msg 3f1c7128, answer 4 B): the estate answer adds
// source ai_paid, one part per agent type and plan, the paid items' full
// daily amounts of the ended days; a customer workspace's answer adds source
// ai_share, one part per agent type, its share of those amounts by its lanes'
// tokens (store/cost_ai_paid.go), plus ai_share_from, the first day a token
// carries a workspace. The operator workspace's other members get neither.
// Each source's coverage counts a day read when every item paying for it has
// a rate.
//
// The hand-entered costs (SPL-4824, owner csitea f7bba506 msg f987e4d5): the
// estate answer adds source cost_entry, one part per cost_entries row of the
// month (store/cost_entry_parts.go), entry_micros + entry_currency its own
// amount, unpriced when no rate turned it into USD. No coverage row: a month
// holds what was entered.
//
// The hr entries count in Human, never in Spend (SPL-4840, owner csitea
// f7bba506 poll d82c98e2, answer A "In Human; left out of Spend"): they are
// the estate answer's human list, outside parts, so neither the total nor a
// part's pct holds them. An unpriced part has no pct (SPL-4824 R7 N1): its
// USD is no amount, so it has no share of the month.

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
	// Allocation is the estate item's split in force (SPL-5291), the
	// estate answer's only; the amounts stay whole.
	Allocation []store.CostAllocShare `json:"allocation,omitempty"`
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
	// Workspaces is every workspace's token burn of the month, the estate
	// answer's only (absent from a workspace answer).
	Workspaces []costWorkspaceOut `json:"workspaces,omitempty"`
	// Human is the month's hr entries (SPL-4840), the estate answer's, and a
	// customer workspace's share of the hr entries split to it (SPL-5291):
	// Reporting -> Costs -> Human, never in Total or a part's pct.
	Human []costPartOut `json:"human,omitempty"`
	// AIShareFrom is a customer workspace's first day with a workspace-
	// stamped token (no share before it); absent elsewhere.
	AIShareFrom string `json:"ai_share_from,omitempty"`
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
	_, burns := s.o.Store.(store.WorkspaceTokens)
	if !ok && !burns {
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
	// a live act-as clone of an operator reader reads the workspace answer,
	// never the estate's (SPL-4187, c-504 W1)
	estate := s.readsOperatorEstate(r.Context(), op, t.ID, a)
	cur, err := s.secondCurrency(r.Context(), a.HumanID, t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("cost.read_currency_failed")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "your second currency was not read")
		return
	}
	cm := store.CostMonth{Parts: []store.CostPart{}, Coverage: []store.CostSourceDays{}} // no cost lines kept: none
	if ok {
		cm, err = cr.CostMonthRead(r.Context(), store.CostMonthQuery{Tenant: t.ID, Estate: estate,
			From: win.From, To: win.To, CoverTo: win.CoverTo, Currency: cur})
	}
	var burn []store.WorkspaceTokenPart
	if err == nil {
		burn, err = s.workspaceTokenParts(r.Context(), op, costBurnOf(estate, t.ID), win)
	}
	var splits []store.CostAllocation
	if err == nil {
		splits, err = s.costAllocSplits(r.Context())
	}
	var ai *store.AIPaidMonth
	if err == nil {
		ai, err = s.aiCostParts(r.Context(), op, estate, t.ID, win, cur)
	}
	var hand, human []store.CostPart
	switch {
	case err != nil:
	case estate:
		hand, human, err = s.costEntryMonthParts(r.Context(), win.Month, cur)
	case t.ID != op:
		// SPL-5291: a customer workspace's share of the items split by hand
		hand, human, err = s.costAllocatedParts(r.Context(), op, t.ID, win, cur, splits)
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("month", win.Month).Msg("cost.read_failed")
		writeErr(w, http.StatusInternalServerError, "internal", "cost report unavailable")
		return
	}
	if !estate {
		cm.Parts = append(cm.Parts, tokenCostParts(burn)...)
	}
	if ai != nil {
		cm.Parts, cm.Coverage = append(cm.Parts, ai.Parts...), append(cm.Coverage, ai.Coverage)
	}
	cm.Parts = append(cm.Parts, hand...)
	b := costMonthAnswer(win, estate, cur, cm)
	if ai != nil && !estate {
		b.AIShareFrom = ai.ShareFrom
	}
	if estate {
		b.Workspaces = costWorkspaces(burn)
	}
	if len(human) > 0 || estate {
		b.Human = costHumanParts(human)
	}
	if estate {
		costAllocAnnotate(&b, splits)
	}
	writeJSON(w, http.StatusOK, b)
}

// costBurnOf is the workspace whose burn the answer reads: every one ("")
// for the estate, else the caller's own.
func costBurnOf(estate bool, tenant string) string {
	if estate {
		return ""
	}
	return tenant
}

// costEntryMonthParts is the month's hand-entered costs (SPL-4824,
// store/cost_entry_parts.go), the estate's only; none on a store without
// the entries. The rates are the paid items' (FleetPaidFXRate). spend is
// every type but hr, human the hr ones (SPL-4840).
func (s *Server) costEntryMonthParts(ctx context.Context, month, cur string) (spend, human []store.CostPart, err error) {
	ce, ok := s.o.Store.(store.CostEntryStore)
	if !ok {
		return nil, nil, nil
	}
	entries, err := ce.ListCostEntries(ctx, "", month)
	if err != nil || len(entries) == 0 {
		return nil, nil, err
	}
	parts, err := store.CostEntryParts(ctx, entries, cur, s.costEntryRate())
	for _, p := range parts {
		if p.Kind == "hr" {
			human = append(human, p)
		} else {
			spend = append(spend, p)
		}
	}
	return spend, human, err
}

// costHumanParts is Human's rows (SPL-4840): entered by hand, no pct (the
// share is of the Spend total, which leaves them out).
func costHumanParts(parts []store.CostPart) []costPartOut {
	out := make([]costPartOut, 0, len(parts))
	for _, p := range parts {
		out = append(out, costPartOut{CostPart: p, Hand: true})
	}
	return out
}

// aiCostParts reads the month's AI parts: the estate's ai_paid, a customer
// workspace's ai_share; nil for the operator workspace's other members
// (3.3.1 point 4) and on a store without the read.
func (s *Server) aiCostParts(ctx context.Context, op string, estate bool, tenant string, win costMonthWindow, cur string) (*store.AIPaidMonth, error) {
	ar, ok := s.o.Store.(store.AIPaidRead)
	if !ok || op == "" || (!estate && tenant == op) {
		return nil, nil
	}
	q := store.AIPaidQuery{Operator: op, From: win.From, CoverTo: win.CoverTo, Currency: cur}
	if !estate {
		q.Workspace = tenant
	}
	m, err := ar.AIPaidMonthRead(ctx, q)
	if err != nil {
		return nil, err
	}
	return &m, nil
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
		switch {
		case p.SecondMicros != nil:
			second += *p.SecondMicros
		case !p.Unpriced:
			// SPL-4824: an unpriced entry is left out of the second
			// currency as of USD, never blanks the total
			complete = false
		}
	}
	if complete {
		b.Total.SecondMicros = &second
	}
	for _, p := range cm.Parts {
		o := costPartOut{CostPart: p, Hand: p.Origin == "hand" || p.Origin == "invoice"}
		if b.Total.USDMicros > 0 && !p.Unpriced {
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

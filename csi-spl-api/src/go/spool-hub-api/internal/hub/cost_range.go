package hub

import (
	"net/url"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The cost reads over a month range (SPL-6300, spec 123 5.2 and 5.5; owner
// HUM-10, workspace topic f3203933 msg 2f3e560e: "from month till month
// (including) aka start month and end month to calculate all of the
// costs"):
//
//	GET /v1/tenant/costs?from=YYYY-MM&to=YYYY-MM         both months included
//	GET /v1/tenant/costs/cloud?from=YYYY-MM&to=YYYY-MM&project=<p>
//	GET /v1/tenant/costs/project?from=YYYY-MM&to=YYYY-MM
//
// ?month=M answers as before, byte for byte, and so does from=M&to=M. from
// and to come together; neither goes with month (nor with year on the
// project read); from after to, a month not started, a bad shape or more
// than costRangeMaxMonths months is 400. Each month is read as the month
// read reads it (its own window, its own hand entries and hr lines), then
// the months are summed per part: costMergeParts says what each field
// means over a range.

// costRangeMaxMonths is the longest range one read takes: two years, the
// picker's 12 months twice. Each month is its own store read.
const costRangeMaxMonths = 24

// costRangeWindows is the windows a cost read asks for, oldest first:
// month= (default the current month) or from= and to=, both included.
func costRangeWindows(q url.Values, now time.Time) ([]costMonthWindow, string) {
	month, from, to := q.Get("month"), q.Get("from"), q.Get("to")
	if from == "" && to == "" {
		w, why := costWindow(month, now)
		return []costMonthWindow{w}, why
	}
	switch {
	case month != "":
		return nil, "month and from/to are one period: ask one"
	case from == "" || to == "":
		return nil, "from and to come together, both YYYY-MM"
	}
	f, okF := costRangeMonth(from)
	l, okT := costRangeMonth(to)
	switch {
	case !okF:
		return nil, "from must be YYYY-MM"
	case !okT:
		return nil, "to must be YYYY-MM"
	case f.After(l):
		return nil, "from " + from + " is after to " + to
	}
	n := (l.Year()-f.Year())*12 + int(l.Month()) - int(f.Month()) + 1
	if n > costRangeMaxMonths {
		return nil, "a range is at most " + strconv.Itoa(costRangeMaxMonths) + " months"
	}
	out := make([]costMonthWindow, 0, n)
	for m := f; !m.After(l); m = m.AddDate(0, 1, 0) {
		w, why := costWindow(m.Format("2006-01"), now)
		if why != "" {
			return nil, why
		}
		out = append(out, w)
	}
	return out, ""
}

// costRangeMonth parses one end of a range as costWindow does a month.
func costRangeMonth(v string) (time.Time, bool) {
	m, err := time.Parse("2006-01", v)
	return m, err == nil && m.Format("2006-01") == v && m.Year() >= 2000
}

// costSpanWindow is the windows as one: the first month's name and first
// day, the last month's end, days and ended days summed, so_far while the
// last month runs. One window is itself.
func costSpanWindow(wins []costMonthWindow) costMonthWindow {
	w := wins[0]
	for _, n := range wins[1:] {
		w.To, w.CoverTo, w.SoFar = n.To, n.CoverTo, n.SoFar
		w.Days += n.Days
		w.Ended += n.Ended
	}
	return w
}

// costRangeEnds is the first and last month of a range read, "" for one
// month (its answer stays the month read's).
func costRangeEnds(wins []costMonthWindow) (from, to string) {
	if len(wins) < 2 {
		return "", ""
	}
	return wins[0].Month, wins[len(wins)-1].Month
}

// costPartKey is what makes two months' parts one part of the range: every
// field but the amounts.
type costPartKey struct {
	source, pov, kind, origin, entryCur, allocSource, comp, group, label string
	shareBP                                                              int
	estate, unpriced                                                     bool
}

func costPartKeyOf(p store.CostPart) costPartKey {
	return costPartKey{estate: p.Estate, source: p.Source, pov: p.ProjectOrVendor, kind: p.Kind, origin: p.Origin,
		entryCur: p.EntryCurrency, allocSource: p.AllocatedSource, comp: p.Component, group: p.Group, label: p.Label,
		shareBP: p.ShareBP, unpriced: p.Unpriced}
}

// costMergeParts sums parts (the months' parts, oldest month first) per
// costPartKey, in first-seen order. Over a range: units, usd, eur, entry
// and list micros are sums (list null while every month's is); days are
// the cost days of the whole range (the months never share a day);
// second_micros is the sum, null when any month's is (a day with no rate);
// fx_rate and fx_rate_day are the latest month's that has one, and
// fx_rate_first_day the earliest's.
func costMergeParts(parts []store.CostPart) []store.CostPart {
	if parts == nil {
		return nil
	}
	out := make([]store.CostPart, 0, len(parts))
	at := map[costPartKey]int{}
	for _, p := range parts {
		k := costPartKeyOf(p)
		i, seen := at[k]
		if !seen {
			at[k] = len(out)
			p.ListValueMicros, p.SecondMicros = costProjectCopy(p.ListValueMicros), costProjectCopy(p.SecondMicros)
			out = append(out, p)
			continue
		}
		costAddPart(&out[i], p)
	}
	return out
}

// costAddPart adds a later month's p to the range's part o.
func costAddPart(o *store.CostPart, p store.CostPart) {
	o.Units += p.Units
	o.USDMicros += p.USDMicros
	o.EURMicros += p.EURMicros
	o.EntryMicros += p.EntryMicros
	o.Days += p.Days
	switch {
	case o.ListValueMicros == nil:
		o.ListValueMicros = costProjectCopy(p.ListValueMicros)
	case p.ListValueMicros != nil:
		*o.ListValueMicros += *p.ListValueMicros
	}
	if o.SecondMicros != nil && p.SecondMicros != nil {
		*o.SecondMicros += *p.SecondMicros
	} else {
		o.SecondMicros = nil
	}
	if p.FXRate != nil {
		o.FXRate, o.FXRateDay = p.FXRate, p.FXRateDay
	}
	if o.FXRateFirstDay == nil {
		o.FXRateFirstDay = p.FXRateFirstDay
	}
}

// costMergeCoverage sums each source's ok, partial and missing days over
// the months, in first-seen order.
func costMergeCoverage(cov []store.CostSourceDays) []store.CostSourceDays {
	out := make([]store.CostSourceDays, 0, len(cov))
	at := map[string]int{}
	for _, c := range cov {
		i, seen := at[c.Source]
		if !seen {
			at[c.Source] = len(out)
			out = append(out, c)
			continue
		}
		out[i].OK += c.OK
		out[i].Partial += c.Partial
		out[i].Missing += c.Missing
	}
	return out
}

// costMergeBurn sums each (workspace, vendor)'s token burn over the months.
func costMergeBurn(burn []store.WorkspaceTokenPart) []store.WorkspaceTokenPart {
	if burn == nil {
		return nil
	}
	out := make([]store.WorkspaceTokenPart, 0, len(burn))
	at := map[[2]string]int{}
	for _, b := range burn {
		k := [2]string{b.Workspace, b.Vendor}
		i, seen := at[k]
		if !seen {
			at[k] = len(out)
			out = append(out, b)
			continue
		}
		out[i].Tokens += b.Tokens
		out[i].ListUSDMicros += b.ListUSDMicros
		out[i].Days += b.Days
	}
	return out
}

// costMergeRange folds the months' store answers and gathered parts into
// the range's: every list concatenated oldest month first, then summed per
// key. The splits are not per month (costReadGather reads them whole): the
// first month's. One month is returned as it is.
func costMergeRange(cms []store.CostMonth, ds []costReadParts) (store.CostMonth, costReadParts) {
	if len(cms) == 1 {
		return cms[0], ds[0]
	}
	cm := store.CostMonth{}
	d := costReadParts{splits: ds[0].splits, costSplits: ds[0].costSplits}
	var ai []store.CostPart
	var aiCov []store.CostSourceDays
	for i := range cms {
		cm.Parts = append(cm.Parts, cms[i].Parts...)
		cm.Coverage = append(cm.Coverage, cms[i].Coverage...)
		d.burn = append(d.burn, ds[i].burn...)
		d.hand = append(d.hand, ds[i].hand...)
		d.human = append(d.human, ds[i].human...)
		if a := ds[i].ai; a != nil {
			ai, aiCov = append(ai, a.Parts...), append(aiCov, a.Coverage)
			if d.ai == nil {
				d.ai = &store.AIPaidMonth{ShareFrom: a.ShareFrom}
			}
		}
	}
	cm.Parts, cm.Coverage = costMergeParts(cm.Parts), costMergeCoverage(cm.Coverage)
	if cm.Parts == nil {
		cm.Parts = []store.CostPart{}
	}
	d.burn, d.hand, d.human = costMergeBurn(d.burn), costMergeParts(d.hand), costMergeParts(d.human)
	if d.ai != nil {
		d.ai.Parts = costMergeParts(ai)
		if cov := costMergeCoverage(aiCov); len(cov) > 0 {
			d.ai.Coverage = cov[0]
		}
	}
	return cm, d
}

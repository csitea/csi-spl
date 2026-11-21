package store

import (
	"math"
	"strings"
)

// The project's cost (spec 123 section 13, row P01; owner HUM-10, t1
// e2c0e6b4 msgs 81217a3f, d0651111, 3a190b70): the month read's parts
// (5.2) folded into four parts, Cloud, Owned hardware, AI tokens and Human,
// each with its amount, its share of the priced total and its completeness
// in words (13.5). A customer workspace gets two parts only, its AI share
// and its own Human (Q-8 A, 13.7). A part that is not known is never summed
// as 0 (13.5): it is null in the currency it has no value in, and the total
// says "partial".
//
// Three choices where spec 123 v1.6 predates the code on master (dispatch
// holder, msg de6fff9a, for the spec's next version):
//  1. Human is the approved minutes x the price in force per day (P02,
//     cost_project_human.go), not the hr cost entries (SPL-4840) the month
//     read lists under Human; not_tracked while the store has no such read.
//  2. Estate Cloud is source gcp plus the hand-entered cost entries of kind
//     cloud (SPL-4383). A customer workspace's allocated share of an estate
//     item (SPL-5291) is no part of its two (Q-8 A): it is named in LeftOut.
//  3. Owned hardware is cost_lines source hand_asset (13.12), which nothing
//     writes before P08: it reads 0 until then.
//
// The token counts (fleet_tokens, units with a list value) and agent hours
// are usage, never money (Q-4 A): they are in no part and not left out.

// CostSourceHandAsset is the daily share of an owned asset entered by hand
// (spec 123 13.12 item 1, written by P08).
const CostSourceHandAsset = "hand_asset"

// The project parts, in the order the page draws them (13.2).
const (
	CostProjectCloud    = "cloud"
	CostProjectHardware = "owned_hardware"
	CostProjectAI       = "ai_tokens"
	CostProjectHuman    = "human"
)

// The completeness words of a project part (13.5).
const (
	CostProjectComplete   = "complete"    // every day read, every line priced
	CostProjectPartial    = "partial"     // DaysRead of Days ended
	CostProjectUnpriced   = "unpriced"    // Unpriced lines have no amount
	CostProjectHand       = "hand"        // entered by hand, every line priced
	CostProjectNotTracked = "not_tracked" // no source yet
)

// CostProjectMoney is an amount in USD and EUR (what was paid, Q-6) and in
// the reader's second currency; nil = not known in that currency.
type CostProjectMoney struct {
	USDMicros    *int64 `json:"usd_micros"`
	EURMicros    *int64 `json:"eur_micros"`
	SecondMicros *int64 `json:"second_micros"`
}

// CostProjectPart is one part of the project's cost. Share is its USD share
// of the priced total in percent, nil while either is unknown or 0. Lines is
// how many month-read parts it sums; Unpriced how many of them have no
// amount in some currency (left out of that currency's sum). DaysRead and
// Days are the "n of N days read" of a part read daily (Cloud, AI tokens).
type CostProjectPart struct {
	Part string `json:"part"`
	CostProjectMoney
	Share        *float64 `json:"share"`
	Completeness string   `json:"completeness"`
	Lines        int      `json:"lines"`
	Unpriced     int      `json:"unpriced"`
	DaysRead     *int     `json:"days_read,omitempty"`
	Days         *int     `json:"days,omitempty"`
	// Human only (P02): every minute not rejected, those with no money (no
	// price on their day, or pending), and those pending approval (13.5: the
	// minutes show, the money leaves them out).
	Minutes         *int64 `json:"minutes,omitempty"`
	UnpricedMinutes *int64 `json:"unpriced_minutes,omitempty"`
	PendingMinutes  *int64 `json:"pending_minutes,omitempty"`
}

// CostProjectTotal is the sum of the parts' known amounts ("Total,
// priced"); Partial while a part is incomplete or money is left out.
type CostProjectTotal struct {
	Priced  CostProjectMoney `json:"priced"`
	Partial bool             `json:"partial"`
}

// CostProjectLeftOut is month-read money in no project part (a customer
// workspace's allocated share, a source no part reads), named, never hidden.
type CostProjectLeftOut struct {
	Source          string `json:"source"`
	ProjectOrVendor string `json:"project_or_vendor"`
	Kind            string `json:"kind"`
	USDMicros       int64  `json:"usd_micros"`
	Unpriced        bool   `json:"unpriced,omitempty"`
}

// CostProject is the project's cost of a period.
type CostProject struct {
	Parts   []CostProjectPart    `json:"parts"`
	Total   CostProjectTotal     `json:"total"`
	LeftOut []CostProjectLeftOut `json:"left_out"`
}

// CostProjectInput is the month read of one or more months of one reader:
// Parts and Coverage as the month answer holds them (5.2), DaysEnded the
// ended days of every month summed. Estate is the operator admin's estate
// read (four parts); else the workspace's two. AIRead says an AI source was
// read at all (the operator workspace's other members read none). HumanRead
// says the store read the Human days (P02), Human holds them.
type CostProjectInput struct {
	Estate    bool
	AIRead    bool
	HumanRead bool
	Human     []CostProjectHumanDay
	Parts     []CostPart
	Coverage  []CostSourceDays
	DaysEnded int
}

// costProjectOf is the project part a month-read part counts in: "" = in
// none; beside = usage that is no money. A package var so the red control
// can drop a source (TestCostProjectParts).
var costProjectOf = func(p CostPart, estate bool) (part string, beside bool) {
	switch {
	case p.Kind == "hr":
		// Human money is the Human part's alone (P02, P03's mask): an hr
		// line is never named in left_out with its amount (13.6).
		return "", true
	case p.Source == CostSourceAIPaid || p.Source == CostSourceAIShare:
		return CostProjectAI, false
	case p.Source == "fleet_tokens" || strings.HasPrefix(p.Source, "fleet_tokens.") ||
		strings.HasPrefix(p.Source, "agent_hours."):
		return "", true
	case !estate:
		return "", false
	case p.Source == "gcp" || (p.Source == CostSourceEntry && p.Kind == "cloud"):
		return CostProjectCloud, false
	case p.Source == CostSourceHandAsset:
		return CostProjectHardware, false
	}
	return "", false
}

// costProjectUnknownIsNull keeps a line with no amount out of the sum; a
// package var so the red control can sum it as 0 (TestCostProjectParts).
var costProjectUnknownIsNull = true

// costProjectSum is a part's running sum: per currency the known amount and
// whether any line had one.
type costProjectSum struct {
	usd, eur, second       int64
	hasUSD, hasEUR, hasSec bool
	lines, unpriced        int
}

func (s *costProjectSum) add(p CostPart) {
	s.lines++
	priced := !p.Unpriced || !costProjectUnknownIsNull
	if priced {
		s.usd, s.eur, s.hasUSD, s.hasEUR = s.usd+p.USDMicros, s.eur+p.EURMicros, true, true
	}
	switch {
	case p.SecondMicros != nil && priced:
		s.second, s.hasSec = s.second+*p.SecondMicros, true
	case !costProjectUnknownIsNull:
		s.hasSec = true // the red control: no rate reads 0
	}
	if (p.Unpriced || p.SecondMicros == nil) && costProjectUnknownIsNull {
		s.unpriced++
	}
}

func costProjectAmount(v int64, known bool) *int64 {
	if !known {
		return nil
	}
	return &v
}

// CostProjectParts folds in into the project's parts and their total.
func CostProjectParts(in CostProjectInput) CostProject {
	names := []string{CostProjectCloud, CostProjectHardware, CostProjectAI, CostProjectHuman}
	if !in.Estate {
		names = []string{CostProjectAI, CostProjectHuman}
	}
	sums := map[string]*costProjectSum{}
	for _, n := range names {
		sums[n] = &costProjectSum{}
	}
	out := CostProject{Parts: []CostProjectPart{}, LeftOut: []CostProjectLeftOut{}}
	for _, p := range in.Parts {
		part, beside := costProjectOf(p, in.Estate)
		if s, ok := sums[part]; ok && part != CostProjectHuman {
			s.add(p)
		} else if !beside && (p.USDMicros != 0 || p.Unpriced) {
			out.LeftOut = append(out.LeftOut, CostProjectLeftOut{Source: p.Source, ProjectOrVendor: p.ProjectOrVendor,
				Kind: p.Kind, USDMicros: p.USDMicros, Unpriced: p.Unpriced})
		}
	}
	for _, n := range names {
		out.Parts = append(out.Parts, costProjectPart(n, sums[n], in))
	}
	costProjectTotal(&out)
	return out
}

// costProjectPart is part n from its sum and the period's coverage. A part
// with no line is a known 0 (nothing to pay), unless it has no source.
func costProjectPart(n string, s *costProjectSum, in CostProjectInput) CostProjectPart {
	if n == CostProjectHuman && in.HumanRead {
		return costProjectHumanPart(in.Human)
	}
	if n == CostProjectHuman || (n == CostProjectAI && !in.AIRead && s.lines == 0) {
		// Human on a store with no human read; no AI source read at all
		return CostProjectPart{Part: n, Completeness: CostProjectNotTracked}
	}
	empty := s.lines == 0
	p := CostProjectPart{Part: n, Lines: s.lines, Unpriced: s.unpriced, Completeness: CostProjectComplete,
		CostProjectMoney: CostProjectMoney{USDMicros: costProjectAmount(s.usd, s.hasUSD || empty),
			EURMicros:    costProjectAmount(s.eur, s.hasEUR || empty),
			SecondMicros: costProjectAmount(s.second, s.hasSec || empty)}}
	if src := costProjectDailySource(n, in.Estate); src != "" {
		read := 0
		for _, c := range in.Coverage {
			if c.Source == src {
				read += c.OK
			}
		}
		days := in.DaysEnded
		p.DaysRead, p.Days = &read, &days
		if read < days {
			p.Completeness = CostProjectPartial
		}
	} else if n == CostProjectHardware {
		p.Completeness = CostProjectHand
	}
	if s.unpriced > 0 {
		p.Completeness = CostProjectUnpriced
	}
	return p
}

// costProjectDailySource is the coverage source of a part read daily.
func costProjectDailySource(n string, estate bool) string {
	switch {
	case n == CostProjectCloud:
		return "gcp"
	case n == CostProjectAI && estate:
		return CostSourceAIPaid
	case n == CostProjectAI:
		return CostSourceAIShare
	}
	return ""
}

// costProjectTotal sums the parts' known amounts, so the parts sum to
// total.priced, and sets each part's share of it.
func costProjectTotal(out *CostProject) {
	var t [3]int64
	for _, p := range out.Parts {
		for i, v := range []*int64{p.USDMicros, p.EURMicros, p.SecondMicros} {
			if v != nil {
				t[i] += *v
			}
		}
		if p.Completeness != CostProjectComplete && p.Completeness != CostProjectHand {
			out.Total.Partial = true
		}
	}
	out.Total.Partial = out.Total.Partial || len(out.LeftOut) > 0
	out.Total.Priced = CostProjectMoney{USDMicros: &t[0], EURMicros: &t[1], SecondMicros: &t[2]}
	for i := range out.Parts {
		p := &out.Parts[i]
		if p.USDMicros != nil && t[0] > 0 {
			sh := math.Round(float64(*p.USDMicros)*1000/float64(t[0])) / 10
			p.Share = &sh
		}
	}
}

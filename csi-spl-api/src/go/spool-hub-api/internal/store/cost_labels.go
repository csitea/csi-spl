package store

import (
	"context"
	"fmt"
	"maps"
	"slices"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
)

// The cost labels in every interface language (SPL-5546, rdb 0285, spec 123
// section 16.5; owner HUM-10, csitea 720fa031: "the labels in this view
// should be in the language of the interface", stored in a "language aware
// table" with "a master language"). One label per (cost entry, locale) and
// per (hr component, locale), and the estate's master locale: the language
// cost_entries.label is written in. That text stays the item's key (cost
// allocations match on it), so the master locale's label is set when the
// entry is entered and never edited through the labels. A reader's label is
// its locale's, else the master locale's, else the entry's own text.
//
// Who wrote each row (SPL-6141, rdb 0303, spec 123 section 16.6.4, row L2):
// a person's PATCH writes origin hand, the hub's API draft and agy's review
// write origin machine through SetMachineCostLabels, which never touches a
// hand row. The unit is the master text, not the entry: every entry with the
// same text gets the same rows (owner answer 5 "T — Every entry with the
// same text", msg e9f8e835).

// The origins of a label row (rdb 0303), and the mark of a reviewed machine
// row in CostEntryLabelMarks.
const (
	CostLabelHand     = "hand"
	CostLabelMachine  = "machine"
	CostLabelReviewed = "reviewed"
)

// CostLabelKey names what a machine label is for: exactly one of a cost
// entry text (every entry with it) and an hr component.
type CostLabelKey struct {
	Text      string `json:"text,omitempty"`
	Component string `json:"component,omitempty"`
}

// CostLabelWork is one text's or component's work for the translate run:
// Source is its current master text; Locales the ones to make (missing or
// stale, MissingCostLabels), Drafts the machine rows not yet reviewed,
// locale -> text (UnreviewedCostLabels).
type CostLabelWork struct {
	Key     CostLabelKey      `json:"key"`
	Source  string            `json:"source"`
	Locales []string          `json:"locales,omitempty"`
	Drafts  map[string]string `json:"drafts,omitempty"`
}

// CostLabelMark is one label row's origin (hand, machine or reviewed) and
// whether it was made from another master text than the entry's own.
type CostLabelMark struct {
	Origin string `json:"origin"`
	Stale  bool   `json:"stale,omitempty"`
}

// CostLabelStore is the store half of rdb 0285. Optional: the readers keep
// the entries' own text on a store without it.
type CostLabelStore interface {
	// CostLabelMaster is the estate's master locale ("" = none set).
	CostLabelMaster(ctx context.Context) (string, error)
	// CostEntryLabels is every entry's labels, entry id -> locale -> text.
	CostEntryLabels(ctx context.Context) (map[string]map[string]string, error)
	// CostEntryLabelMarks is every entry's label rows' marks, entry id ->
	// locale -> mark (the master row: hand, never stale).
	CostEntryLabelMarks(ctx context.Context) (map[string]map[string]CostLabelMark, error)
	// SetCostEntryLabels is a person's edit of entry id's labels (checked by
	// CheckCostEntryLabels), written on every entry with the same text: a
	// locale whose text differs from the entry's row becomes hand, one sent
	// unchanged keeps its row, one left out is deleted; the master's is never
	// touched. ErrNotFound when there is no entry id.
	SetCostEntryLabels(ctx context.Context, id string, labels map[string]string, by string) error
	// SetMachineCostLabels writes labels (never the master locale's) as
	// machine rows of key made from its current master text, reviewed or not,
	// and answers how many rows it wrote: a hand row is left as it is.
	// ErrNotFound when key names no entry text or component.
	SetMachineCostLabels(ctx context.Context, key CostLabelKey, labels map[string]string, reviewed bool, by string) (int, error)
	// MissingCostLabels is every text and component that lacks a locale on
	// any of its entries, or holds a machine row made from another text.
	MissingCostLabels(ctx context.Context) ([]CostLabelWork, error)
	// UnreviewedCostLabels is every text's and component's machine rows of
	// its current text that agy has not reviewed (a text's: its newest
	// entry's row per locale).
	UnreviewedCostLabels(ctx context.Context) ([]CostLabelWork, error)
	// CostLabelsIn maps each entry's own text to its label in locale (then
	// the master's), only where that label differs from the text.
	CostLabelsIn(ctx context.Context, locale string) (map[string]string, error)
	// HRComponentLabelsIn maps each hr component to its label in locale,
	// else the master locale's, else 'en' (rdb 0280's seed).
	HRComponentLabelsIn(ctx context.Context, locale string) (map[string]string, error)
}

// CheckCostEntryLabels names the first thing labels may not carry ("" =
// fine): rdb 0285's CHECKs. The master locale's text is the entry's own, so a
// label for it must equal that text (the WUI sends the whole set back).
func CheckCostEntryLabels(labels map[string]string, master, own string) string {
	for loc, text := range labels {
		switch {
		case !i18n.IsSupported(loc):
			return fmt.Sprintf("locale %q must be one of %s", loc, strings.Join(i18n.Supported, ","))
		case strings.TrimSpace(text) == "" || utf8.RuneCountInString(text) > 100:
			return "a label must be 1..100 characters (" + loc + ")"
		case loc == master && text != own:
			return "the master language's label (" + master + ") is the entry's own label; it is not edited here"
		}
	}
	return ""
}

// checkMachineCostLabels names the first thing a machine write may not carry
// ("" = fine): exactly one key, rdb 0285's CHECKs, no master-locale label.
func checkMachineCostLabels(key CostLabelKey, labels map[string]string, master string) string {
	if (key.Text == "") == (key.Component == "") {
		return "a machine label names exactly one of a text and a component"
	}
	if _, ok := labels[master]; ok {
		return "the master language's label (" + master + ") is never machine written"
	}
	return CheckCostEntryLabels(labels, master, "")
}

// costLabelPick is entry e's label in locale: its own, the master's, the text.
func costLabelPick(labels map[string]string, locale, master, text string) string {
	if v := labels[locale]; v != "" {
		return v
	}
	if v := labels[master]; v != "" {
		return v
	}
	return text
}

// costLabelOthers is every supported locale but master, sorted.
func costLabelOthers(master string) []string {
	out := slices.DeleteFunc(slices.Clone(i18n.Supported), func(l string) bool { return l == master })
	sort.Strings(out)
	return out
}

// MemCostLabelMaster is the Memory driver's master locale, rdb 0285's seed.
const MemCostLabelMaster = "en"

// memLabel is one label row on Memory: rdb 0285's text and rdb 0303's marks.
type memLabel struct {
	Text, Origin, Source, By string
	Reviewed                 bool
}

// mark is the row's CostLabelMark against the master text own.
func (l memLabel) mark(own string) CostLabelMark {
	m := CostLabelMark{Origin: l.Origin, Stale: l.Source != own}
	if l.Origin == CostLabelMachine && l.Reviewed {
		m.Origin = CostLabelReviewed
	}
	return m
}

// The Memory driver's labels beside the store: entry id -> locale -> row,
// and component -> locale -> row.
var (
	memCostLabelsMu sync.Mutex
	memCostLabels   = map[*Memory]map[string]map[string]memLabel{}
	memHRCompLabels = map[*Memory]map[string]map[string]memLabel{}
)

// memCostLabelSet is a new entry e's labels, set when it is entered: the
// master locale's, and the other locales' rows of the newest entry of
// siblings (the others with e's text) that has them, marks kept (16.6.2
// point 1). The caller holds memCostEntriesMu.
func memCostLabelSet(s *Memory, e CostEntry, siblings []CostEntry) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	rows := map[string]memLabel{MemCostLabelMaster: {Text: e.Label, Origin: CostLabelHand, By: e.CreatedBy}}
	sort.Slice(siblings, func(i, j int) bool { return memEntryNewer(siblings[i], siblings[j]) })
	for _, sib := range siblings {
		if len(memCostLabels[s][sib.ID]) > 1 {
			for loc, row := range memCostLabels[s][sib.ID] {
				if loc != MemCostLabelMaster {
					rows[loc] = row
				}
			}
			break
		}
	}
	maps.Copy(memEntryRows(s, e.ID), rows)
}

// memEntryRows is entry id's rows on s, made when absent. The caller holds
// memCostLabelsMu.
func memEntryRows(s *Memory, id string) map[string]memLabel {
	if memCostLabels[s] == nil {
		memCostLabels[s] = map[string]map[string]memLabel{}
	}
	if memCostLabels[s][id] == nil {
		memCostLabels[s][id] = map[string]memLabel{}
	}
	return memCostLabels[s][id]
}

// memEntryNewer is a entered after b (created_at, then id, as Postgres).
func memEntryNewer(a, b CostEntry) bool {
	if !a.CreatedAt.Equal(b.CreatedAt) {
		return a.CreatedAt.After(b.CreatedAt)
	}
	return a.ID > b.ID
}

// CostLabelMaster is CostLabelStore on Memory.
func (s *Memory) CostLabelMaster(context.Context) (string, error) { return MemCostLabelMaster, nil }

// CostEntryLabels is CostLabelStore on Memory.
func (s *Memory) CostEntryLabels(context.Context) (map[string]map[string]string, error) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	out := map[string]map[string]string{}
	for id, m := range memCostLabels[s] {
		out[id] = map[string]string{}
		for loc, row := range m {
			out[id][loc] = row.Text
		}
	}
	return out, nil
}

// CostEntryLabelMarks is CostLabelStore on Memory.
func (s *Memory) CostEntryLabelMarks(ctx context.Context) (map[string]map[string]CostLabelMark, error) {
	entries, _ := s.ListCostEntries(ctx, "", "")
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	out := map[string]map[string]CostLabelMark{}
	for _, e := range entries {
		out[e.ID] = map[string]CostLabelMark{}
		for loc, row := range memCostLabels[s][e.ID] {
			if loc == MemCostLabelMaster {
				out[e.ID][loc] = CostLabelMark{Origin: CostLabelHand}
				continue
			}
			out[e.ID][loc] = row.mark(e.Label)
		}
	}
	return out, nil
}

// memSameText is every entry of s with text, entered order.
func memSameText(ctx context.Context, s *Memory, text string) []CostEntry {
	entries, _ := s.ListCostEntries(ctx, "", "")
	return slices.DeleteFunc(entries, func(e CostEntry) bool { return e.Label != text })
}

// SetCostEntryLabels is CostLabelStore on Memory: the named entry's rows are
// worked out first (16.6.4), then every entry with its text gets them.
func (s *Memory) SetCostEntryLabels(ctx context.Context, id string, labels map[string]string, by string) error {
	e, ok := memCostEntry(s, id)
	if !ok {
		return ErrNotFound
	}
	if why := CheckCostEntryLabels(labels, MemCostLabelMaster, e.Label); why != "" {
		return fmt.Errorf("cost labels: %s", why)
	}
	same := memSameText(ctx, s, e.Label)
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	old := memEntryRows(s, id)
	next := map[string]memLabel{}
	for loc, text := range labels {
		if loc == MemCostLabelMaster {
			continue
		}
		if row, kept := old[loc]; kept && row.Text == text {
			next[loc] = row
			continue
		}
		next[loc] = memLabel{Text: text, Origin: CostLabelHand, Source: e.Label, By: by}
	}
	for _, sib := range same {
		rows := maps.Clone(next)
		if m, ok := memCostLabels[s][sib.ID][MemCostLabelMaster]; ok {
			rows[MemCostLabelMaster] = m
		}
		memCostLabels[s][sib.ID] = rows
	}
	return nil
}

// SetMachineCostLabels is CostLabelStore on Memory.
func (s *Memory) SetMachineCostLabels(ctx context.Context, key CostLabelKey, labels map[string]string, reviewed bool, by string) (int, error) {
	if why := checkMachineCostLabels(key, labels, MemCostLabelMaster); why != "" {
		return 0, fmt.Errorf("cost labels: %s", why)
	}
	var same []CostEntry
	if key.Text != "" {
		if same = memSameText(ctx, s, key.Text); len(same) == 0 {
			return 0, ErrNotFound
		}
	}
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	targets, source := []map[string]memLabel{}, key.Text
	for _, e := range same {
		targets = append(targets, memEntryRows(s, e.ID))
	}
	if key.Component != "" {
		c, ok := memHRComponent(key.Component)
		if !ok {
			return 0, ErrNotFound
		}
		targets, source = append(targets, memCompRows(s, c.Component)), memCompMaster(s, c)
	}
	n := 0
	for _, rows := range targets {
		for loc, text := range labels {
			if row, ok := rows[loc]; ok && row.Origin != CostLabelMachine {
				continue // a person's row: the guard of the Postgres upsert
			}
			rows[loc] = memLabel{Text: text, Origin: CostLabelMachine, Source: source, By: by, Reviewed: reviewed}
			n++
		}
	}
	return n, nil
}

// memHRComponent is the seed's component c, false when there is none.
func memHRComponent(component string) (HRComponent, bool) {
	i := slices.IndexFunc(DefaultHRComponents, func(c HRComponent) bool { return c.Component == component })
	if i < 0 {
		return HRComponent{}, false
	}
	return DefaultHRComponents[i], true
}

// memCompRows is component's rows on s, made when absent. The caller holds
// memCostLabelsMu.
func memCompRows(s *Memory, component string) map[string]memLabel {
	if memHRCompLabels[s] == nil {
		memHRCompLabels[s] = map[string]map[string]memLabel{}
	}
	if memHRCompLabels[s][component] == nil {
		memHRCompLabels[s][component] = map[string]memLabel{}
	}
	return memHRCompLabels[s][component]
}

// memCompMaster is c's master text: its master-locale row, else the seed's.
// The caller holds memCostLabelsMu.
func memCompMaster(s *Memory, c HRComponent) string {
	if row, ok := memHRCompLabels[s][c.Component][MemCostLabelMaster]; ok {
		return row.Text
	}
	return c.Label
}

// memMissing adds to into the locales of rows (other than the master's)
// that are absent, or machine rows made from another text than own.
func memMissing(rows map[string]memLabel, own string, into map[string]bool) {
	for _, loc := range costLabelOthers(MemCostLabelMaster) {
		row, ok := rows[loc]
		if !ok || (row.Origin == CostLabelMachine && row.Source != own) {
			into[loc] = true
		}
	}
}

// MissingCostLabels is CostLabelStore on Memory: the texts, then the
// components, each sorted.
func (s *Memory) MissingCostLabels(ctx context.Context) ([]CostLabelWork, error) {
	entries, _ := s.ListCostEntries(ctx, "", "")
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	byText := map[string]map[string]bool{}
	for _, e := range entries {
		if byText[e.Label] == nil {
			byText[e.Label] = map[string]bool{}
		}
		memMissing(memCostLabels[s][e.ID], e.Label, byText[e.Label])
	}
	out := []CostLabelWork{}
	for _, text := range slices.Sorted(maps.Keys(byText)) {
		if len(byText[text]) > 0 {
			out = append(out, CostLabelWork{Key: CostLabelKey{Text: text}, Source: text, Locales: slices.Sorted(maps.Keys(byText[text]))})
		}
	}
	for _, c := range memSortedComponents() {
		own, locs := memCompMaster(s, c), map[string]bool{}
		memMissing(memHRCompLabels[s][c.Component], own, locs)
		if len(locs) > 0 {
			out = append(out, CostLabelWork{Key: CostLabelKey{Component: c.Component}, Source: own, Locales: slices.Sorted(maps.Keys(locs))})
		}
	}
	return out, nil
}

// memSortedComponents is the seed's components by id.
func memSortedComponents() []HRComponent {
	out := slices.Clone(DefaultHRComponents)
	sort.Slice(out, func(i, j int) bool { return out[i].Component < out[j].Component })
	return out
}

// memDrafts adds rows' unreviewed machine rows of own to drafts, a locale
// already there kept.
func memDrafts(rows map[string]memLabel, own string, drafts map[string]string) {
	for loc, row := range rows {
		if _, seen := drafts[loc]; !seen && row.Origin == CostLabelMachine && !row.Reviewed && row.Source == own {
			drafts[loc] = row.Text
		}
	}
}

// UnreviewedCostLabels is CostLabelStore on Memory.
func (s *Memory) UnreviewedCostLabels(ctx context.Context) ([]CostLabelWork, error) {
	entries, _ := s.ListCostEntries(ctx, "", "")
	sort.Slice(entries, func(i, j int) bool { return memEntryNewer(entries[i], entries[j]) })
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	byText := map[string]map[string]string{}
	for _, e := range entries { // newest first: its row wins per locale
		if byText[e.Label] == nil {
			byText[e.Label] = map[string]string{}
		}
		memDrafts(memCostLabels[s][e.ID], e.Label, byText[e.Label])
	}
	out := []CostLabelWork{}
	for _, text := range slices.Sorted(maps.Keys(byText)) {
		if len(byText[text]) > 0 {
			out = append(out, CostLabelWork{Key: CostLabelKey{Text: text}, Source: text, Drafts: byText[text]})
		}
	}
	for _, c := range memSortedComponents() {
		own, drafts := memCompMaster(s, c), map[string]string{}
		memDrafts(memHRCompLabels[s][c.Component], own, drafts)
		if len(drafts) > 0 {
			out = append(out, CostLabelWork{Key: CostLabelKey{Component: c.Component}, Source: own, Drafts: drafts})
		}
	}
	return out, nil
}

// CostLabelsIn is CostLabelStore on Memory.
func (s *Memory) CostLabelsIn(ctx context.Context, locale string) (map[string]string, error) {
	entries, err := s.ListCostEntries(ctx, "", "")
	if err != nil {
		return nil, err
	}
	labels, _ := s.CostEntryLabels(ctx)
	out := map[string]string{}
	for _, e := range entries { // period then created_at: the first entry of a text wins
		if _, seen := out[e.Label]; seen {
			continue
		}
		if v := costLabelPick(labels[e.ID], locale, MemCostLabelMaster, e.Label); v != e.Label {
			out[e.Label] = v
		}
	}
	return out, nil
}

// HRComponentLabelsIn is CostLabelStore on Memory: the seed's English, and
// any label SetMemHRComponentLabel or SetMachineCostLabels set.
func (s *Memory) HRComponentLabelsIn(_ context.Context, locale string) (map[string]string, error) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	out := map[string]string{}
	for _, c := range DefaultHRComponents {
		m := map[string]string{"en": c.Label}
		for loc, row := range memHRCompLabels[s][c.Component] {
			m[loc] = row.Text
		}
		out[c.Component] = costLabelPick(m, locale, MemCostLabelMaster, m["en"])
	}
	return out, nil
}

// SetMemHRComponentLabel sets component's label in locale on Memory (the
// tests' and the mock's; a component's labels have no person's route): a
// machine row made from the seed's text, as rdb 0303 marks the migrations'
// rows, and a hand row in the master locale.
func SetMemHRComponentLabel(s *Memory, component, locale, text string) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	row := memLabel{Text: text, Origin: CostLabelMachine, By: "test"}
	if c, ok := memHRComponent(component); ok {
		row.Source = c.Label
	}
	if locale == MemCostLabelMaster {
		row = memLabel{Text: text, Origin: CostLabelHand, By: "test"}
	}
	memCompRows(s, component)[locale] = row
}

var _ CostLabelStore = (*Memory)(nil)

package store

import (
	"context"
	"fmt"
	"maps"
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

// CostLabelStore is the store half of rdb 0285. Optional: the readers keep
// the entries' own text on a store without it.
type CostLabelStore interface {
	// CostLabelMaster is the estate's master locale ("" = none set).
	CostLabelMaster(ctx context.Context) (string, error)
	// CostEntryLabels is every entry's labels, entry id -> locale -> text.
	CostEntryLabels(ctx context.Context) (map[string]map[string]string, error)
	// SetCostEntryLabels replaces entry id's labels in every locale but the
	// master's with labels (checked by CheckCostEntryLabels); ErrNotFound
	// when there is no entry id.
	SetCostEntryLabels(ctx context.Context, id string, labels map[string]string, by string) error
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

// MemCostLabelMaster is the Memory driver's master locale, rdb 0285's seed.
const MemCostLabelMaster = "bg"

// The Memory driver's labels beside the store: entry id -> locale -> text,
// and component -> locale -> text.
var (
	memCostLabelsMu sync.Mutex
	memCostLabels   = map[*Memory]map[string]map[string]string{}
	memHRCompLabels = map[*Memory]map[string]map[string]string{}
)

// memCostLabelSet is entry id's master-locale label, set when it is entered.
func memCostLabelSet(s *Memory, id, text string) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	if memCostLabels[s] == nil {
		memCostLabels[s] = map[string]map[string]string{}
	}
	memCostLabels[s][id] = map[string]string{MemCostLabelMaster: text}
}

// CostLabelMaster is CostLabelStore on Memory.
func (s *Memory) CostLabelMaster(context.Context) (string, error) { return MemCostLabelMaster, nil }

// CostEntryLabels is CostLabelStore on Memory.
func (s *Memory) CostEntryLabels(context.Context) (map[string]map[string]string, error) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	out := map[string]map[string]string{}
	for id, m := range memCostLabels[s] {
		out[id] = maps.Clone(m)
	}
	return out, nil
}

// SetCostEntryLabels is CostLabelStore on Memory.
func (s *Memory) SetCostEntryLabels(_ context.Context, id string, labels map[string]string, _ string) error {
	e, ok := memCostEntry(s, id)
	if !ok {
		return ErrNotFound
	}
	if why := CheckCostEntryLabels(labels, MemCostLabelMaster, e.Label); why != "" {
		return fmt.Errorf("cost labels: %s", why)
	}
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	if memCostLabels[s] == nil {
		memCostLabels[s] = map[string]map[string]string{}
	}
	next := map[string]string{MemCostLabelMaster: e.Label}
	for loc, text := range labels {
		next[loc] = text
	}
	memCostLabels[s][id] = next
	return nil
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
// any label SetMemHRComponentLabel set.
func (s *Memory) HRComponentLabelsIn(_ context.Context, locale string) (map[string]string, error) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	out := map[string]string{}
	for _, c := range DefaultHRComponents {
		m := map[string]string{"en": c.Label}
		maps.Copy(m, memHRCompLabels[s][c.Component])
		out[c.Component] = costLabelPick(m, locale, MemCostLabelMaster, m["en"])
	}
	return out, nil
}

// SetMemHRComponentLabel sets component's label in locale on Memory (the
// tests' and the mock's; rdb 0285's rows have no route yet).
func SetMemHRComponentLabel(s *Memory, component, locale, text string) {
	memCostLabelsMu.Lock()
	defer memCostLabelsMu.Unlock()
	if memHRCompLabels[s] == nil {
		memHRCompLabels[s] = map[string]map[string]string{}
	}
	if memHRCompLabels[s][component] == nil {
		memHRCompLabels[s][component] = map[string]string{}
	}
	memHRCompLabels[s][component][locale] = text
}

var _ CostLabelStore = (*Memory)(nil)

package hub

import (
	"context"
	"errors"
	"net/http"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The cost labels in the interface language (SPL-5546, rdb 0285, spec 123
// section 16.5; owner HUM-10, csitea 720fa031):
//
//	GET /v1/operator/cost-entries        each entry also carries labels
//	                                     {locale: text}, label_origins
//	                                     {locale: hand|machine|reviewed} and
//	                                     stale_locales [locale] (SPL-6173),
//	                                     the answer master_locale
//	PATCH /v1/operator/cost-entries/{id}/labels {labels: {locale: text}}
//	                                     -> 200 {id, labels}: every locale
//	                                     but the master's is replaced; the
//	                                     master's text is the entry's own
//	                                     label (the item's key) and is never
//	                                     edited here
//	GET /v1/tenant/costs, GET /v1/operator/hr-components
//	                                     a hand-entered item's label and a
//	                                     component's label in the reader's
//	                                     locale
//
// The reader's locale is ?locale=, else X-Locale, else Accept-Language; a
// label falls back to the master locale's, then to the entry's own text. The
// PATCH has the cost entries' write door (costEntryGate). A label is display
// text, not a booked amount, so a closed month does not refuse it.

// costLabelLocale is the reader's locale ("" = none asked: the master's).
func costLabelLocale(r *http.Request) string {
	if l := i18n.Normalize(r.URL.Query().Get("locale")); l != "" {
		return l
	}
	return i18n.FromRequest(r, "")
}

// costLabels is the store's labels half, nil on a store without it.
func (s *Server) costLabels() store.CostLabelStore {
	cl, _ := s.o.Store.(store.CostLabelStore)
	return cl
}

// costLocalizeParts sets Label on each hand-entered part (its own or a
// workspace's share of one) whose label in locale differs from its text.
func (s *Server) costLocalizeParts(ctx context.Context, locale string, parts ...[]costPartOut) error {
	cl := s.costLabels()
	if cl == nil {
		return nil
	}
	in, err := cl.CostLabelsIn(ctx, locale)
	if err != nil || len(in) == 0 {
		return err
	}
	for _, ps := range parts {
		for i := range ps {
			p := &ps[i]
			if p.Source == store.CostSourceEntry || p.AllocatedSource == store.CostSourceEntry {
				p.Label = in[p.ProjectOrVendor]
			}
		}
	}
	return nil
}

// costEntryOut is a listed entry with its labels per locale, who wrote each
// (hand, machine or reviewed: a machine row agy confirmed) and the hand rows
// made from another master text (SPL-6173, spec 123 16.6.4).
type costEntryOut struct {
	store.PricedCostEntry
	Labels       map[string]string `json:"labels"`
	LabelOrigins map[string]string `json:"label_origins"`
	StaleLocales []string          `json:"stale_locales"`
}

// costEntryMarks is marks as label_origins and stale_locales (sorted).
func costEntryMarks(marks map[string]store.CostLabelMark) (map[string]string, []string) {
	origins, stale := map[string]string{}, []string{}
	for loc, m := range marks {
		origins[loc] = m.Origin
		if m.Stale && m.Origin == store.CostLabelHand {
			stale = append(stale, loc)
		}
	}
	slices.Sort(stale)
	return origins, stale
}

// costEntriesWithLabels is priced with each entry's labels, and the master
// locale ("" on a store without labels).
func (s *Server) costEntriesWithLabels(ctx context.Context, priced []store.PricedCostEntry) ([]costEntryOut, string, error) {
	out := make([]costEntryOut, 0, len(priced))
	var all map[string]map[string]string
	var marks map[string]map[string]store.CostLabelMark
	master := ""
	if cl := s.costLabels(); cl != nil {
		var err error
		if master, err = cl.CostLabelMaster(ctx); err != nil {
			return nil, "", err
		}
		if all, err = cl.CostEntryLabels(ctx); err != nil {
			return nil, "", err
		}
		if marks, err = cl.CostEntryLabelMarks(ctx); err != nil {
			return nil, "", err
		}
	}
	for _, p := range priced {
		labels := all[p.ID]
		if labels == nil {
			labels = map[string]string{}
		}
		origins, stale := costEntryMarks(marks[p.ID])
		out = append(out, costEntryOut{PricedCostEntry: p, Labels: labels, LabelOrigins: origins, StaleLocales: stale})
	}
	return out, master, nil
}

// handleCostEntryLabels is PATCH /v1/operator/cost-entries/{id}/labels.
func (s *Server) handleCostEntryLabels(w http.ResponseWriter, r *http.Request) {
	ce, who, ok := s.costEntryCaller(w, r, s.operatorWriteCaller)
	if !ok {
		return
	}
	cl := s.costLabels()
	if cl == nil {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost labels")
		return
	}
	var body struct {
		Labels map[string]string `json:"labels"`
	}
	if !decodeStrict(w, r, &body, "{labels: {locale: text}}") {
		return
	}
	id := r.PathValue("id")
	if why, found := s.costLabelsCheck(r.Context(), ce, cl, id, body.Labels); why != "" || !found {
		if !found {
			writeErr(w, http.StatusNotFound, "not_found", "no cost entry "+id)
			return
		}
		writeErr(w, http.StatusBadRequest, "bad_cost_labels", why)
		return
	}
	err := cl.SetCostEntryLabels(r.Context(), id, body.Labels, who)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "no cost entry "+id)
		return
	}
	var all map[string]map[string]string
	if err == nil {
		all, err = cl.CostEntryLabels(r.Context())
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost entry labels")
		writeErr(w, http.StatusInternalServerError, "internal", "cost labels not stored")
		return
	}
	s.o.Log.Info().Str("id", id).Int("locales", len(body.Labels)).Str("by", who).Msg("cost entry labels set")
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "labels": all[id]})
}

// costLabelsCheck is CheckCostEntryLabels against entry id's own text and
// the master locale; found false when there is no entry id.
func (s *Server) costLabelsCheck(ctx context.Context, ce store.CostEntryStore, cl store.CostLabelStore, id string, labels map[string]string) (string, bool) {
	entries, err := ce.ListCostEntries(ctx, "", "")
	if err != nil {
		return "", true // the store's own check answers
	}
	master, err := cl.CostLabelMaster(ctx)
	if err != nil {
		return "", true
	}
	for _, e := range entries {
		if e.ID == id {
			return store.CheckCostEntryLabels(labels, master, e.Label), true
		}
	}
	return "", false
}

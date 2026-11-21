package hub

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/i18nmask"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/translate"
)

// Every new cost label in all 19 languages on save (SPL-6173, spec 123
// section 16.6, row L3; owner HUM-10, csitea 720fa031, msg e9f8e835 answer
// 1 "B — A machine translation API in the hub", msg baae5fb7 follow-ups
// 1 "A", 2 "M", 3 "G"):
//
//	POST /v1/operator/cost-entries     after the save commits, a text with
//	                                   no rows yet is drafted at once in
//	                                   every missing locale (machine,
//	                                   unreviewed); the POST answers 201
//	                                   whatever the API did
//	POST /v1/operator/cost-labels/fill -> 200 {texts, written, refused,
//	                                   failed, capped}: every missing text
//	                                   and component drafted (the night
//	                                   run's first step)
//	GET  /v1/operator/cost-labels/unreviewed -> 200 {items: [{key,
//	                                   source_sha, masked_text,
//	                                   masked_drafts: {locale: text}}]}
//	PUT  /v1/operator/cost-labels/reviewed {key, source_sha, labels:
//	                                   {locale: masked text}} -> 200
//	                                   {written, refused: {locale: why}};
//	                                   409 stale_source when the text or
//	                                   the term list changed since the read,
//	                                   or the key has nothing unreviewed
//
// What leaves the hub is the label text, masked (16.6.5): every hr person's
// name and every workspace's name, emails and phone numbers become tokens
// (internal/i18nmask, the port of do_spl_i18n_mask); never an amount, a
// period, a person or an entry id. The mask is rebuilt from the text and the
// term list on each call, so no token map is stored or sent. The log
// carries counts only, never a label.
//
// fill and unreviewed have the operator write door (the operator workspace's
// admin, or the operator service account); reviewed is the service account's
// alone (its Bearer path). An accountant's costs.write opens none of them.

// CostLabelTranslator drafts one text in one locale (translate.Client).
type CostLabelTranslator interface {
	// Translate is content (text/html) in target, from source.
	Translate(ctx context.Context, content, source, target string) (string, error)
	// Reserve takes n characters of today's cap; false = none left.
	Reserve(n int) bool
}

// costLabelMachineBy is updated_by of the hub's own drafts.
const costLabelMachineBy = "hub-translate"

// costLabelTimeoutDefault is a label's deadline when Options sets none: the
// dev measurement's max per call was 5.74 s (internal/translate/testdata).
const costLabelTimeoutDefault = 8 * time.Second

// costLabelKeepEnglish is the values of csi-spl-wui/i18n/i18n-keep-english.json
// (brand and product names): an answer equal to such a master text is kept
// (16.6.6). TestCostLabelKeepEnglishInStep keeps the copy in step.
var costLabelKeepEnglish = []string{
	"Claude", "Grok", "Antigravity", "Qwen", "Mistral", "Codex", "Thunderbird",
	"WhatsApp", "Viber", "Instagram", "Telegram", "Signal", "Microsoft Teams",
	"Markdown", "GCP", "SQL", "#general", "#alerts · {from}", "runbooks/deploy.md",
	"{size} · sha256 {hash}", "tail -f",
}

// costLabelRun is the counts of one draft or fill: never a label.
type costLabelRun struct {
	Texts   int `json:"texts"`
	Written int `json:"written"`
	Refused int `json:"refused"`
	Failed  int `json:"failed"`
	Capped  int `json:"capped"`
}

func (c *costLabelRun) add(o costLabelRun) {
	c.Texts, c.Written, c.Refused, c.Failed, c.Capped = c.Texts+o.Texts, c.Written+o.Written, c.Refused+o.Refused, c.Failed+o.Failed, c.Capped+o.Capped
}

func (s *Server) routeCostLabelsMachine(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/operator/cost-labels/fill", s.handleCostLabelsFill)
	mux.HandleFunc("GET /v1/operator/cost-labels/unreviewed", s.handleCostLabelsUnreviewed)
	mux.HandleFunc("PUT /v1/operator/cost-labels/reviewed", s.handleCostLabelsReviewed)
}

// costLabelKeyID is the opaque id of key the read hands out: a text's is a
// hash, so the id carries no label.
func costLabelKeyID(key store.CostLabelKey) string {
	if key.Component != "" {
		return "c:" + key.Component
	}
	sum := sha256.Sum256([]byte("cost-label-text\x00" + key.Text))
	return "t:" + hex.EncodeToString(sum[:16])
}

// costLabelSourceSHA is the sha256 of a master text and its masked form:
// it changes when the text or the terms that mask it change.
func costLabelSourceSHA(source, masked string) string {
	sum := sha256.Sum256([]byte(source + "\x00" + masked))
	return hex.EncodeToString(sum[:])
}

// costLabelMasker is the mask of the hub's own term list: every hr person's
// name (whole, and each part) and every workspace's name and id.
func (s *Server) costLabelMasker(ctx context.Context) (*i18nmask.Masker, error) {
	var terms []i18nmask.Term
	if hr, ok := s.o.Store.(store.HRCostStore); ok {
		people, err := hr.ListHRPeople(ctx, true)
		if err != nil {
			return nil, err
		}
		for _, p := range people {
			terms = append(terms, costLabelNameTerms(p.Name)...)
		}
	}
	if ow, ok := s.o.Store.(store.OperatorWorkspaces); ok {
		list, err := ow.ListWorkspaces(ctx)
		if err != nil {
			return nil, err
		}
		for _, w := range list {
			for _, v := range []string{w.DisplayName, w.ID} {
				if utf8.RuneCountInString(strings.TrimSpace(v)) >= 2 {
					terms = append(terms, i18nmask.Term{Class: i18nmask.Workspace, Text: strings.TrimSpace(v)})
				}
			}
		}
	}
	return i18nmask.New(terms), nil
}

// costLabelNameTerms is a person's name and each of its parts of two
// letters or more, as NAME terms.
func costLabelNameTerms(name string) []i18nmask.Term {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	out := []i18nmask.Term{{Class: i18nmask.Name, Text: name}}
	for _, part := range strings.Fields(name) {
		if part != name && utf8.RuneCountInString(part) >= 2 {
			out = append(out, i18nmask.Term{Class: i18nmask.Name, Text: part})
		}
	}
	return out
}

// costLabelAnswerWhy names why an unmasked answer for master text source may
// not be written ("" = fine): 16.6.6.
func costLabelAnswerWhy(text, source string, lost []string) string {
	switch {
	case len(lost) > 0:
		return "token_lost"
	case strings.TrimSpace(text) == "" || utf8.RuneCountInString(text) > 100:
		return "length"
	case text == source && !slices.Contains(costLabelKeepEnglish, source):
		return "same_as_master"
	case i18nmask.TokenRe.MatchString(text):
		return "token_left"
	case strings.Contains(text, "<span"):
		return "span_left"
	}
	return ""
}

// costLabelTranslate asks tr for masked in each locale, in parallel, under
// one deadline; an error or a late answer leaves its locale out.
func (s *Server) costLabelTranslate(ctx context.Context, tr CostLabelTranslator, masked, master string, locales []string) map[string]string {
	timeout := s.o.CostLabelsTranslateTimeout
	if timeout <= 0 {
		timeout = costLabelTimeoutDefault
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	content := translate.Wrap(masked)
	var (
		mu  sync.Mutex
		wg  sync.WaitGroup
		out = map[string]string{}
	)
	for _, loc := range locales {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a, err := tr.Translate(ctx, content, master, loc)
			if err != nil || ctx.Err() != nil {
				return
			}
			mu.Lock()
			out[loc] = a
			mu.Unlock()
		}()
	}
	wg.Wait()
	return out
}

// costLabelDraft drafts work's missing locales through the API and writes
// what passes the check as machine rows, unreviewed.
func (s *Server) costLabelDraft(ctx context.Context, cl store.CostLabelStore, k *i18nmask.Masker, master string, work store.CostLabelWork) costLabelRun {
	run := costLabelRun{Texts: 1}
	tr := s.o.CostLabelTranslator
	locales := slices.DeleteFunc(slices.Clone(work.Locales), func(l string) bool { return l == master })
	if tr == nil || len(locales) == 0 {
		return run
	}
	masked, m := k.Mask(work.Source)
	if !tr.Reserve(utf8.RuneCountInString(translate.Wrap(masked)) * len(locales)) {
		run.Capped = len(locales)
		return run
	}
	answers := s.costLabelTranslate(ctx, tr, masked, master, locales)
	run.Failed = len(locales) - len(answers)
	labels := map[string]string{}
	for loc, a := range answers {
		text, lost := m.Unmask(translate.Unwrap(a))
		if costLabelAnswerWhy(text, work.Source, lost) != "" {
			run.Refused++
			continue
		}
		labels[loc] = text
	}
	if len(labels) == 0 {
		return run
	}
	n, err := cl.SetMachineCostLabels(context.WithoutCancel(ctx), work.Key, labels, false, costLabelMachineBy)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost labels draft write")
		run.Failed += len(labels)
		return run
	}
	run.Written = n
	return run
}

// costLabelDraftNew drafts a just-saved entry's text when it lacks rows
// (16.6.2 point 2): a known text was copied in the save's transaction and
// needs no call. Never fails the save.
func (s *Server) costLabelDraftNew(ctx context.Context, text string) {
	cl := s.costLabels()
	if cl == nil || s.o.CostLabelTranslator == nil {
		return
	}
	run, err := s.costLabelFill(ctx, cl, func(w store.CostLabelWork) bool { return w.Key.Text == text })
	if err != nil {
		s.o.Log.Warn().Err(err).Msg("cost labels draft on save")
		return
	}
	s.o.Log.Info().Int("written", run.Written).Int("refused", run.Refused).Int("failed", run.Failed).Int("capped", run.Capped).Msg("cost labels drafted on save")
}

// costLabelFill drafts every missing text and component that pick takes.
func (s *Server) costLabelFill(ctx context.Context, cl store.CostLabelStore, pick func(store.CostLabelWork) bool) (costLabelRun, error) {
	var run costLabelRun
	works, err := cl.MissingCostLabels(ctx)
	if err != nil {
		return run, err
	}
	works = slices.DeleteFunc(works, func(w store.CostLabelWork) bool { return !pick(w) })
	if len(works) == 0 {
		return run, nil
	}
	master, err := cl.CostLabelMaster(ctx)
	if err != nil {
		return run, err
	}
	k, err := s.costLabelMasker(ctx)
	if err != nil {
		return run, err
	}
	for _, w := range works {
		run.add(s.costLabelDraft(ctx, cl, k, master, w))
	}
	return run, nil
}

// costLabelsMachineStore is the labels half for the three routes, false =
// answered (501).
func (s *Server) costLabelsMachineStore(w http.ResponseWriter) (store.CostLabelStore, bool) {
	cl := s.costLabels()
	if cl == nil {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no cost labels")
		return nil, false
	}
	return cl, true
}

// handleCostLabelsFill is POST /v1/operator/cost-labels/fill.
func (s *Server) handleCostLabelsFill(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := s.operatorWriteCaller(w, r); !ok {
		return
	}
	cl, ok := s.costLabelsMachineStore(w)
	if !ok {
		return
	}
	if s.o.CostLabelTranslator == nil {
		writeErr(w, http.StatusServiceUnavailable, "translate_unavailable", "this hub names no translate URL (SPOOL_HUB_COST_LABELS_TRANSLATE_URL)")
		return
	}
	run, err := s.costLabelFill(r.Context(), cl, func(store.CostLabelWork) bool { return true })
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost labels fill")
		writeErr(w, http.StatusInternalServerError, "internal", "cost labels not filled")
		return
	}
	s.o.Log.Info().Int("texts", run.Texts).Int("written", run.Written).Int("refused", run.Refused).Int("failed", run.Failed).Int("capped", run.Capped).Msg("cost labels filled")
	writeJSON(w, http.StatusOK, run)
}

// costLabelUnreviewedItem is one text's or component's masked work for agy:
// never an amount, a period, a person or an entry id.
type costLabelUnreviewedItem struct {
	Key          string            `json:"key"`
	SourceSHA    string            `json:"source_sha"`
	MaskedText   string            `json:"masked_text"`
	MaskedDrafts map[string]string `json:"masked_drafts"`
}

// handleCostLabelsUnreviewed is GET /v1/operator/cost-labels/unreviewed.
func (s *Server) handleCostLabelsUnreviewed(w http.ResponseWriter, r *http.Request) {
	if _, _, _, ok := s.operatorWriteCaller(w, r); !ok {
		return
	}
	cl, ok := s.costLabelsMachineStore(w)
	if !ok {
		return
	}
	works, err := cl.UnreviewedCostLabels(r.Context())
	var k *i18nmask.Masker
	if err == nil {
		k, err = s.costLabelMasker(r.Context())
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("cost labels unreviewed")
		writeErr(w, http.StatusInternalServerError, "internal", "cost labels unavailable")
		return
	}
	items := make([]costLabelUnreviewedItem, 0, len(works))
	for _, wk := range works {
		masked, m := k.Mask(wk.Source)
		drafts := make(map[string]string, len(wk.Drafts))
		for loc, d := range wk.Drafts {
			drafts[loc], _ = k.Remask(d, m)
		}
		items = append(items, costLabelUnreviewedItem{Key: costLabelKeyID(wk.Key), SourceSHA: costLabelSourceSHA(wk.Source, masked),
			MaskedText: masked, MaskedDrafts: drafts})
	}
	s.o.Log.Info().Int("texts", len(items)).Msg("cost labels unreviewed read")
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// errCostLabelKey is a reviewed key that names no unreviewed text or
// component.
var errCostLabelKey = errors.New("no unreviewed cost label for this key")

// costLabelReviewTarget is the unreviewed work whose opaque id is id.
func costLabelReviewTarget(ctx context.Context, cl store.CostLabelStore, id string) (store.CostLabelWork, error) {
	works, err := cl.UnreviewedCostLabels(ctx)
	if err != nil {
		return store.CostLabelWork{}, err
	}
	for _, w := range works {
		if costLabelKeyID(w.Key) == id {
			return w, nil
		}
	}
	return store.CostLabelWork{}, errCostLabelKey
}

// costLabelReviewedBody is PUT /v1/operator/cost-labels/reviewed's body.
type costLabelReviewedBody struct {
	Key       string            `json:"key"`
	SourceSHA string            `json:"source_sha"`
	Labels    map[string]string `json:"labels"`
}

// handleCostLabelsReviewed is PUT /v1/operator/cost-labels/reviewed: the
// operator service account only.
func (s *Server) handleCostLabelsReviewed(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ") {
		writeErr(w, http.StatusForbidden, "not_operator", "the reviewed labels are written by the operator service account only")
		return
	}
	who, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	cl, ok := s.costLabelsMachineStore(w)
	if !ok {
		return
	}
	var body costLabelReviewedBody
	if !decodeStrict(w, r, &body, "{key, source_sha, labels: {locale: masked text}}") {
		return
	}
	work, err := costLabelReviewTarget(r.Context(), cl, body.Key)
	var k *i18nmask.Masker
	if err == nil {
		k, err = s.costLabelMasker(r.Context())
	}
	switch {
	case errors.Is(err, errCostLabelKey): // the text changed (a new key) or was reviewed meanwhile
		writeErr(w, http.StatusConflict, "stale_source", errCostLabelKey.Error()+": read again")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Msg("cost labels reviewed")
		writeErr(w, http.StatusInternalServerError, "internal", "cost labels not stored")
		return
	}
	s.costLabelsReviewedWrite(w, r, cl, k, work, body, who)
}

// costLabelsReviewedWrite checks body against work's current mask and writes
// what passes as reviewed machine rows.
func (s *Server) costLabelsReviewedWrite(w http.ResponseWriter, r *http.Request, cl store.CostLabelStore, k *i18nmask.Masker, work store.CostLabelWork, body costLabelReviewedBody, who string) {
	masked, m := k.Mask(work.Source)
	if costLabelSourceSHA(work.Source, masked) != body.SourceSHA {
		writeErr(w, http.StatusConflict, "stale_source", "the master text or its terms changed since the read: read again")
		return
	}
	labels, refused := map[string]string{}, map[string]string{}
	for loc, t := range body.Labels {
		if _, asked := work.Drafts[loc]; !asked {
			refused[loc] = "not_asked"
			continue
		}
		text, lost := m.Unmask(t)
		if why := costLabelAnswerWhy(text, work.Source, lost); why != "" {
			refused[loc] = why
			continue
		}
		labels[loc] = text
	}
	n := 0
	if len(labels) > 0 {
		var err error
		if n, err = cl.SetMachineCostLabels(r.Context(), work.Key, labels, true, who); err != nil {
			s.o.Log.Error().Err(err).Msg("cost labels reviewed write")
			writeErr(w, http.StatusInternalServerError, "internal", "cost labels not stored")
			return
		}
	}
	s.o.Log.Info().Int("written", n).Int("refused", len(refused)).Msg("cost labels reviewed")
	writeJSON(w, http.StatusOK, map[string]any{"written": n, "refused": refused})
}

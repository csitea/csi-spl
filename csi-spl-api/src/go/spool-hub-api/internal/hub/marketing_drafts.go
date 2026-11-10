package hub

import (
	"context"
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A workspace's own marketing posts (spec 090 section 22, SPL-5240; owner
// HUM-10, t1 19ef7d51, 2026-11-09: "any person with either a business owner
// or admin role in a workspace to create content in that workspace and to
// post that content from the integrated posts for the particular target
// system"; poll c1d8be01 Q2 A: no approval step, the author publishes).
//
//	GET    /v1/marketing/drafts               the workspace's drafts and the
//	                                          channels a publish can go to
//	POST   /v1/marketing/drafts               {body, image_url} -> 201
//	PATCH  /v1/marketing/drafts/{id}          {body, image_url} -> 200
//	DELETE /v1/marketing/drafts/{id}          -> 204
//	POST   /v1/marketing/drafts/{id}/publish  {channels: [channel_id]} -> 200
//
// Every route sits behind marketingRoute (allow-list, switch, demo 403) and
// needs a member holding tenant.settings (admin and biz_owner by the
// default roles); anyone else gets 403. A workspace sees only its own
// drafts (the store's RLS scope). Only the draft's author edits, deletes
// and publishes it, and only until its first publish: after that its text
// is what went out (409).
//
// A publish records one marketing_posts row per channel (source draft,
// source_ref the draft id) held, approves it at once (approveHeld) and
// dispatches it through the channel's own path: LinkedIn a text post on
// the connector's profile, a Facebook Page a text or photo post, Instagram
// the picture with the text as caption (a JPEG is required), X the text
// (280 weighted characters at most). Once per channel: a second publish on
// a channel answers already_recorded for it.

// Why a draft call was refused.
var (
	errDraftNotAuthor = errors.New("only the author of a post edits, deletes or publishes it")
	errDraftBody      = errors.New("body is required, at most 3000 characters")
	errDraftImage     = errors.New("image_url must be empty or a public https address")
)

// marketingDraftStore is the store a draft route needs.
type marketingDraftStore interface {
	store.MarketingDrafts
	metaStore
}

// draftBody is the JSON of a create or an edit.
type draftBody struct {
	Body     *string `json:"body"`
	ImageURL string  `json:"image_url"`
}

// draftView is one draft as the WUI reads it: mine marks the caller's own.
type draftView struct {
	store.MarketingDraft
	Mine bool `json:"mine"`
}

// draftChannel is a connected channel a draft can be published on.
type draftChannel struct {
	ID       string `json:"channel_id"`
	Platform string `json:"platform"`
	Name     string `json:"name"`
}

// draftActor resolves the caller: a member holding tenant.settings, and the
// store. It writes the 403 or 501 itself.
func (s *Server) draftActor(w http.ResponseWriter, r *http.Request, tenant string) (marketingDraftStore, string, bool) {
	w.Header().Set("Cache-Control", "no-store")
	hum, _ := s.memberID(r, tenant)
	if hum == "" {
		writeForbidden(w, rbac.TenantSettings, "a post needs a member session")
		return nil, "", false
	}
	if !s.permit(w, r, tenant, hum, rbac.TenantSettings) {
		return nil, "", false
	}
	st, ok := s.o.Store.(marketingDraftStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no marketing posts")
		return nil, "", false
	}
	return st, hum, true
}

// GET /v1/marketing/drafts
func (s *Server) handleMarketingDrafts(w http.ResponseWriter, r *http.Request, tenant string) {
	st, hum, ok := s.draftActor(w, r, tenant)
	if !ok {
		return
	}
	ds, err := st.MarketingDrafts(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "the posts are unavailable")
		return
	}
	chs, err := st.MarketingChannels(r.Context(), tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "the channels are unavailable")
		return
	}
	out := make([]draftView, len(ds))
	for i, d := range ds {
		out[i] = draftView{MarketingDraft: d, Mine: d.AuthorID == hum}
	}
	writeJSON(w, http.StatusOK, map[string]any{"drafts": out, "channels": draftChannels(chs)})
}

// draftChannels: the active channels of a platform a draft goes to.
func draftChannels(chs []store.MarketingChannel) []draftChannel {
	out := []draftChannel{}
	for _, ch := range chs {
		if ch.Status == store.MarketingActive && draftPlatform(ch.Platform) {
			out = append(out, draftChannel{ID: ch.ID, Platform: ch.Platform, Name: ch.AccountName})
		}
	}
	return out
}

func draftPlatform(p string) bool {
	return p == store.MarketingPlatformLinkedIn || isMetaPlatform(p) || p == store.MarketingPlatformX
}

// draftMaxBody bounds a draft's JSON: 3,000 characters escaped as JSON
// (up to 12 bytes each, a surrogate pair) and the picture's address.
const draftMaxBody = 64 << 10

// decodeDraftJSON is decodeMembers with room for a draft's text: JSON only
// (a text/plain post needs no preflight), unknown fields refused.
func decodeDraftJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, draftMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body is not the expected JSON object")
		return false
	}
	return true
}

// decodeDraft reads and checks a create or edit body; it writes the 400.
func decodeDraft(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	var b draftBody
	if !decodeDraftJSON(w, r, &b) {
		return "", "", false
	}
	if b.Body == nil || strings.TrimSpace(*b.Body) == "" || utf8.RuneCountInString(*b.Body) > store.MarketingDraftMaxChars {
		writeErr(w, http.StatusBadRequest, "bad_body", errDraftBody.Error())
		return "", "", false
	}
	img := strings.TrimSpace(b.ImageURL)
	if img != "" {
		u, err := url.Parse(img)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || len(img) > 2048 {
			writeErr(w, http.StatusBadRequest, "bad_image_url", errDraftImage.Error())
			return "", "", false
		}
	}
	return *b.Body, img, true
}

// POST /v1/marketing/drafts
func (s *Server) handleCreateMarketingDraft(w http.ResponseWriter, r *http.Request, tenant string) {
	st, hum, ok := s.draftActor(w, r, tenant)
	if !ok {
		return
	}
	body, img, ok := decodeDraft(w, r)
	if !ok {
		return
	}
	d, err := st.CreateMarketingDraft(r.Context(), store.MarketingDraft{Tenant: tenant, AuthorID: hum, Body: body, ImageURL: img}, s.o.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "the post was not saved")
		return
	}
	writeJSON(w, http.StatusCreated, draftView{MarketingDraft: d, Mine: true})
}

// ownDraft reads the caller's own draft {id}; it writes the 404 or 403.
func (s *Server) ownDraft(w http.ResponseWriter, r *http.Request, st marketingDraftStore, tenant, hum string) (store.MarketingDraft, bool) {
	d, err := st.MarketingDraft(r.Context(), tenant, r.PathValue("id"))
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such post in this workspace")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "the post is unavailable")
	case d.AuthorID != hum:
		writeForbidden(w, rbac.TenantSettings, errDraftNotAuthor.Error())
	default:
		return d, true
	}
	return d, false
}

// writeDraftErr answers a refused edit or delete.
func writeDraftErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such post in this workspace")
	case errors.Is(err, store.ErrMarketingDraftPublished):
		writeErr(w, http.StatusConflict, "published", err.Error())
	default:
		writeErr(w, http.StatusInternalServerError, "internal", "the post was not changed")
	}
}

// PATCH /v1/marketing/drafts/{id}
func (s *Server) handlePatchMarketingDraft(w http.ResponseWriter, r *http.Request, tenant string) {
	st, hum, ok := s.draftActor(w, r, tenant)
	if !ok {
		return
	}
	d, ok := s.ownDraft(w, r, st, tenant, hum)
	if !ok {
		return
	}
	body, img, ok := decodeDraft(w, r)
	if !ok {
		return
	}
	d.Body, d.ImageURL = body, img
	got, err := st.UpdateMarketingDraft(r.Context(), d, s.o.Now())
	if err != nil {
		writeDraftErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, draftView{MarketingDraft: got, Mine: true})
}

// DELETE /v1/marketing/drafts/{id}
func (s *Server) handleDeleteMarketingDraft(w http.ResponseWriter, r *http.Request, tenant string) {
	st, hum, ok := s.draftActor(w, r, tenant)
	if !ok {
		return
	}
	d, ok := s.ownDraft(w, r, st, tenant, hum)
	if !ok {
		return
	}
	if err := st.DeleteMarketingDraft(r.Context(), tenant, d.ID); err != nil {
		writeDraftErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// draftResult is what a publish did on one channel. Outcome: published,
// retried (it will be retried), deferred (it waits for the channel's daily
// cap), failed, or refused (nothing recorded; Error says why).
type draftResult struct {
	ChannelID string `json:"channel_id"`
	Platform  string `json:"platform,omitempty"`
	Outcome   string `json:"outcome"`
	Error     string `json:"error,omitempty"`
}

// POST /v1/marketing/drafts/{id}/publish {channels}
func (s *Server) handlePublishMarketingDraft(w http.ResponseWriter, r *http.Request, tenant string) {
	st, hum, ok := s.draftActor(w, r, tenant)
	if !ok {
		return
	}
	d, ok := s.ownDraft(w, r, st, tenant, hum)
	if !ok {
		return
	}
	var b struct {
		Channels []string `json:"channels"`
	}
	if !decodeMembers(w, r, &b) {
		return
	}
	if len(b.Channels) == 0 || len(b.Channels) > 20 {
		writeErr(w, http.StatusBadRequest, "bad_channels", "channels: one to 20 channel ids")
		return
	}
	// detached like the blog publish (publishOn): a client that goes away
	// does not cut a platform call off mid-flight
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), marketingPublishTimeout)
	defer cancel()
	results, err := s.publishDraft(ctx, st, d, hum, b.Channels)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "the publish failed before a platform was called")
		return
	}
	got, err := st.MarketingDraft(ctx, tenant, d.ID)
	if err != nil {
		got = d
	}
	writeJSON(w, http.StatusOK, map[string]any{"draft": draftView{MarketingDraft: got, Mine: true}, "results": results})
}

// publishDraft publishes d on each channel id, once each, and marks it
// published when at least one channel recorded it. err only on a store
// failure before any channel was tried.
func (s *Server) publishDraft(ctx context.Context, st marketingDraftStore, d store.MarketingDraft, hum string, ids []string) ([]draftResult, error) {
	chs, err := st.MarketingChannels(ctx, d.Tenant)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]store.MarketingChannel, len(chs))
	for _, ch := range chs {
		byID[ch.ID] = ch
	}
	out := make([]draftResult, 0, len(ids))
	recorded := false
	seen := map[string]bool{}
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		res := s.publishDraftOn(ctx, st, d, hum, byID[id])
		res.ChannelID = id
		recorded = recorded || res.Outcome != "refused"
		out = append(out, res)
	}
	if recorded {
		if err := st.MarkMarketingDraftPublished(ctx, d.Tenant, d.ID, s.o.Now()); err != nil {
			s.o.Log.Error().Err(err).Str("draft", d.ID).Msg("marketing: draft published, published_at not set")
		}
	}
	return out, nil
}

// publishDraftOn publishes d on ch (zero when the workspace has no such
// channel): checks, the held row approved, then the channel's dispatch.
func (s *Server) publishDraftOn(ctx context.Context, st marketingDraftStore, d store.MarketingDraft, hum string, ch store.MarketingChannel) draftResult {
	refuse := func(code string) draftResult { return draftResult{Platform: ch.Platform, Outcome: "refused", Error: code} }
	if ch.ID == "" || ch.Status != store.MarketingActive || !draftPlatform(ch.Platform) {
		return refuse("not_found")
	}
	if code := s.draftUnfit(ch.Platform, d); code != "" {
		return refuse(code)
	}
	p := store.MarketingPost{Tenant: d.Tenant, ChannelID: ch.ID, SourceType: store.MarketingSourceDraft, SourceRef: d.ID,
		ContentText: d.Body, Status: store.MarketingAwaitingApproval}
	if d.ImageURL != "" {
		p.MediaAssets = []store.MarketingMediaAsset{{URL: d.ImageURL, Selected: true}}
	}
	pid, err := s.approveHeld(ctx, st, p, hum)
	switch {
	case errors.Is(err, ErrMarketingRecorded):
		return refuse("already_recorded")
	case err != nil:
		s.o.Log.Error().Err(err).Str("channel", ch.ID).Str("draft", d.ID).Msg("marketing: draft not recorded")
		return refuse("internal")
	}
	s.o.Log.Info().Str("tenant", d.Tenant).Str("channel", ch.ID).Str("platform", ch.Platform).Str("draft", d.ID).Str("by", hum).Msg("marketing: a workspace post is published by its author")
	var res MarketingShareResult
	s.dispatchDraft(ctx, st, ch, pid, &res)
	return draftResult{Platform: ch.Platform, Outcome: draftOutcome(res)}
}

// draftUnfit is why d cannot go to platform as it is, "" when it can.
func (s *Server) draftUnfit(platform string, d store.MarketingDraft) string {
	switch platform {
	case store.MarketingPlatformLinkedIn:
		if s.o.MarketingLinkedIn == nil {
			return "not_configured"
		}
	case store.MarketingPlatformX:
		if _, _, ok := s.xReady(); !ok {
			return "not_configured"
		}
		if marketing.XWeightedLength(d.Body) > marketing.XPostMaxWeight {
			return "x_too_long"
		}
	default: // Facebook Page, Instagram
		if _, _, ok := s.metaReady(); !ok {
			return "not_configured"
		}
		if platform == store.MarketingPlatformIG && !isJPEG(d.ImageURL) {
			return "instagram_needs_jpeg"
		}
		if platform == store.MarketingPlatformIG && utf8.RuneCountInString(d.Body) > marketing.InstagramCaptionMaxChars {
			return "instagram_too_long"
		}
	}
	return ""
}

// dispatchDraft claims the approved post pid on ch and sends it.
func (s *Server) dispatchDraft(ctx context.Context, st marketingDraftStore, ch store.MarketingChannel, pid string, res *MarketingShareResult) {
	switch {
	case ch.Platform == store.MarketingPlatformX:
		mx, xs, _ := s.xReady()
		if !s.xDispatchChannel(ctx, &xPass{mx: mx, st: xs, ch: ch, res: res, post: pid}).IsZero() {
			res.Deferred++
		}
	case isMetaPlatform(ch.Platform):
		mm, ms, _ := s.metaReady()
		if !s.metaDispatchChannel(ctx, &metaPass{mm: mm, st: ms, ch: ch, res: res, post: pid}).IsZero() {
			res.Deferred++
		}
	default: // LinkedIn: its claim takes every due post of the channel
		m := s.o.MarketingLinkedIn
		due, err := st.ClaimMarketingPosts(ctx, ch.Tenant, ch.ID, s.o.Now())
		if err != nil || len(due) == 0 {
			return
		}
		s.dispatchDue(ctx, m, st, ch, due, s.blogIndexFor(ctx, m, due), res)
	}
}

// blogIndexFor is the live blog index when due holds a blog post (a retry
// the draft's claim took with it), empty when it holds none, nil when the
// index could not be read (dispatchDue then retries those posts).
func (s *Server) blogIndexFor(ctx context.Context, m *MarketingLinkedIn, due []store.MarketingPost) map[string]marketing.BlogPost {
	for _, p := range due {
		if p.SourceType != store.MarketingSourceDraft {
			posts, err := marketing.FetchBlogIndex(ctx, m.httpClient(), m.AppURL)
			if err != nil {
				return nil
			}
			return blogByID(posts)
		}
	}
	return map[string]marketing.BlogPost{}
}

// draftOutcome names what one channel's dispatch did.
func draftOutcome(res MarketingShareResult) string {
	switch {
	case res.Published > 0:
		return "published"
	case res.Deferred > 0:
		return "deferred"
	case res.Retried > 0:
		return "retried"
	case res.Failed > 0:
		return "failed"
	}
	return "scheduled"
}

func (s *Server) marketingDraftsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// routeMarketingDrafts registers the draft routes (from routeMarketing).
func (s *Server) routeMarketingDrafts(mux *http.ServeMux) {
	s.marketingRoute(mux, "GET /v1/marketing/drafts", s.handleMarketingDrafts)
	s.marketingRoute(mux, "POST /v1/marketing/drafts", s.handleCreateMarketingDraft)
	s.marketingRoute(mux, "PATCH /v1/marketing/drafts/{id}", s.handlePatchMarketingDraft)
	s.marketingRoute(mux, "DELETE /v1/marketing/drafts/{id}", s.handleDeleteMarketingDraft)
	s.marketingRoute(mux, "POST /v1/marketing/drafts/{id}/publish", s.handlePublishMarketingDraft)
	mux.HandleFunc("OPTIONS /v1/marketing/drafts", s.marketingDraftsPreflight)
	mux.HandleFunc("OPTIONS /v1/marketing/drafts/{id}", s.marketingDraftsPreflight)
	mux.HandleFunc("OPTIONS /v1/marketing/drafts/{id}/publish", s.marketingDraftsPreflight)
}

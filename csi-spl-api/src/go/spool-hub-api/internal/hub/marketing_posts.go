package hub

import (
	"context"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The list of live blog posts not shared yet (SPL-1698; owner HUM-10,
// topic add4fbf4 msgs f78e3eab, 3a3f366b), so the WUI can offer a Publish
// button for each one: GET /v1/marketing/posts. Same gate as the publish
// (linkedInChannels, SPL-5196): a member holding tenant.settings; anyone
// else gets 403, the member who connected the channel included. A post is
// listed when one of those baselined channels has no row for it yet, the
// case where the publish answers 200 rather than 409. The answer names
// whose profiles a publish posts on (profiles), so the WUI's button can
// say it when they are not the caller's own.

// LinkedInProfile is one LinkedIn channel a publish goes out on: the
// connector's name, and whether the caller is the connector.
type LinkedInProfile struct {
	ChannelID string `json:"channel_id"`
	Name      string `json:"name"`
	Mine      bool   `json:"mine"`
}

// UnsharedMarketingPosts is the live posts that hum can still publish on
// one of the LinkedIn channels it may publish on, newest first.
func (s *Server) UnsharedMarketingPosts(ctx context.Context, tenant, hum string) ([]marketing.BlogPost, error) {
	posts, _, err := s.unsharedLinkedIn(ctx, tenant, hum)
	return posts, err
}

// unsharedLinkedIn is UnsharedMarketingPosts plus the profiles they go out on.
func (s *Server) unsharedLinkedIn(ctx context.Context, tenant, hum string) ([]marketing.BlogPost, []LinkedInProfile, error) {
	m := s.o.MarketingLinkedIn
	mk, ok := s.o.Store.(store.Marketing)
	if m == nil || !ok {
		return nil, nil, ErrMarketingNoLinked
	}
	if !s.marketingSweepable(ctx, tenant) {
		return nil, nil, ErrMarketingOff
	}
	chs, err := s.linkedInChannels(ctx, mk, tenant, hum)
	if err != nil {
		return nil, nil, err
	}
	profiles := make([]LinkedInProfile, len(chs))
	for i, ch := range chs {
		profiles[i] = LinkedInProfile{ChannelID: ch.ID, Name: ch.AccountName, Mine: ch.DelegatedBy == hum}
	}
	posts, err := unsharedOn(ctx, m, mk, tenant, chs)
	return posts, profiles, err
}

// unsharedOn: the live posts some baselined channel of chs has no row for.
func unsharedOn(ctx context.Context, m *MarketingLinkedIn, mk store.Marketing, tenant string, chs []store.MarketingChannel) ([]marketing.BlogPost, error) {
	var known []map[string]bool
	for _, ch := range chs {
		if ch.BaselineAt == nil { // before the first sweep: the back catalogue is not listed
			continue
		}
		refs, err := mk.MarketingPostRefs(ctx, tenant, ch.ID)
		if err != nil {
			return nil, err
		}
		known = append(known, refs)
	}
	out := []marketing.BlogPost{}
	if len(known) == 0 {
		return out, nil
	}
	posts, err := marketing.FetchBlogIndex(ctx, m.httpClient(), m.AppURL)
	if err != nil {
		return nil, err
	}
	for _, p := range posts {
		for _, refs := range known {
			if !refs[p.ID] {
				out = append(out, p)
				break
			}
		}
	}
	return out, nil
}

// UnsharedMetaPosts is the live posts that hum can still publish on the
// Facebook Page or Instagram account channelID: those with no row on it
// (spec 090 T035, SPL-4496). Same gates as the Meta publish
// (publishMetaPost, metaApprover; SPL-5196: it was the workspace owner
// only); a Meta channel has no baseline, so the whole live index counts.
func (s *Server) UnsharedMetaPosts(ctx context.Context, tenant, hum, channelID string) ([]marketing.BlogPost, error) {
	mm, st, ok := s.metaReady()
	if !ok {
		return nil, ErrMarketingNoMeta
	}
	if !s.marketingSweepable(ctx, tenant) {
		return nil, ErrMarketingOff
	}
	if _, err := s.access(ctx, hum, tenant); hum == "" || err != nil {
		return nil, ErrMarketingNotApprover
	}
	ch, err := metaChannel(ctx, st, tenant, channelID)
	if err != nil {
		return nil, err
	}
	if !s.metaApprover(ctx, tenant, hum, ch) {
		return nil, ErrMarketingNotApprover
	}
	refs, err := st.MarketingPostRefs(ctx, tenant, ch.ID)
	if err != nil {
		return nil, err
	}
	posts, err := marketing.FetchBlogIndex(ctx, metaHTTP(mm), mm.AppURL)
	if err != nil {
		return nil, err
	}
	out := []marketing.BlogPost{}
	for _, p := range posts {
		if !refs[p.ID] {
			out = append(out, p)
		}
	}
	return out, nil
}

// GET /v1/marketing/posts: the caller's unshared live blog posts and the
// LinkedIn profiles they go out on; with ?channel=<id> those of that
// Facebook Page or Instagram account.
func (s *Server) handleMarketingPosts(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	hum, _ := s.memberID(r, tenant)
	var posts []marketing.BlogPost
	var profiles []LinkedInProfile
	var err error
	if ch := r.URL.Query().Get("channel"); ch != "" {
		posts, err = s.UnsharedMetaPosts(r.Context(), tenant, hum, ch)
	} else {
		posts, profiles, err = s.unsharedLinkedIn(r.Context(), tenant, hum)
	}
	switch {
	case errors.Is(err, ErrMarketingNotOwner), errors.Is(err, ErrMarketingNotApprover):
		writeForbidden(w, rbac.TenantSettings, err.Error())
	case errors.Is(err, ErrMarketingNoChannel), errors.Is(err, ErrMarketingOff), errors.Is(err, ErrMarketingNoMetaPage):
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, ErrMarketingNoLinked):
		writeErr(w, http.StatusServiceUnavailable, "linkedin_off", err.Error())
	case errors.Is(err, ErrMarketingNoMeta):
		writeErr(w, http.StatusServiceUnavailable, "not_configured", err.Error())
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "the unshared blog posts are unavailable")
	case profiles != nil:
		writeJSON(w, http.StatusOK, map[string]any{"posts": posts, "profiles": profiles})
	default:
		writeJSON(w, http.StatusOK, map[string]any{"posts": posts})
	}
}

// marketingPostsPreflight answers the browser's CORS preflight for the list
// and the publish: the WUI calls the hub cross-origin with a bearer token.
func (s *Server) marketingPostsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// routeMarketingPosts registers the list and the preflights (from routeMarketing).
func (s *Server) routeMarketingPosts(mux *http.ServeMux) {
	s.marketingRoute(mux, "GET /v1/marketing/posts", s.handleMarketingPosts)
	mux.HandleFunc("OPTIONS /v1/marketing/posts", s.marketingPostsPreflight)
	mux.HandleFunc("OPTIONS /v1/marketing/posts/{id}/publish", s.marketingPostsPreflight)
	s.marketingRoute(mux, "GET /v1/marketing/posts/{id}/share-links", s.handleMarketingShareLinks) // spec 090 T037
	mux.HandleFunc("OPTIONS /v1/marketing/posts/{id}/share-links", s.marketingPostsPreflight)
}

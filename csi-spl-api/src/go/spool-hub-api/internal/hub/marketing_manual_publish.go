package hub

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The customer's hand-over (spec 090 T036, SPL-4804; spec.md section 17):
// a member who posted a live blog post by hand on one of the workspace's
// connected accounts records it,
//
//	POST /v1/marketing/posts/{id}/manual-publish?channel=<channel id>
//
// `{id}` is the blog post (as for /publish and /share-links); the channel is
// any active channel of the workspace (LinkedIn, a Facebook Page or an
// Instagram account). The post is recorded held and then handed over
// (HandOverMarketingPost, rdb 0236): published, platform_post_id 'manual',
// event post_handed_over by the member. Nothing is sent to the platform and
// a hand-over never counts against a channel's daily cap. Viber and
// WhatsApp have no channel row: the WUI only opens their links.
//
// Who: the member who connected the channel or one holding tenant.settings
// (metaApprover). 404 while marketing is off, for an unknown channel or a
// post not in the live index; 409 once the post is published or being sent
// on that channel.

// ErrMarketingNoHandOverChannel: the channel is not an active one of the workspace.
var ErrMarketingNoHandOverChannel = errors.New("the channel is no connected account of this workspace")

// errMarketingNoBlog: neither LinkedIn nor Meta is wired, so no blog index is known.
var errMarketingNoBlog = errors.New("the blog is not configured on this hub")

// handOverStore is the store the hand-over needs.
type handOverStore interface {
	store.Marketing
	store.MarketingMetaDispatch
}

// blogSource is the live blog's address and the client that reads its index.
func (s *Server) blogSource() (string, *http.Client) {
	if m := s.o.MarketingLinkedIn; m != nil && m.AppURL != "" {
		return m.AppURL, m.httpClient()
	}
	if mm := s.o.MarketingMeta; mm != nil && mm.AppURL != "" {
		if mm.Meta != nil {
			return mm.AppURL, metaHTTP(mm)
		}
		return mm.AppURL, &http.Client{Timeout: 30 * time.Second}
	}
	return "", nil
}

// handOverChannel is tenant's active channel channelID, any platform.
func handOverChannel(ctx context.Context, st handOverStore, tenant, channelID string) (store.MarketingChannel, error) {
	chs, err := st.MarketingChannels(ctx, tenant)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	for _, ch := range chs {
		if ch.ID == channelID && ch.Status == store.MarketingActive {
			return ch, nil
		}
	}
	return store.MarketingChannel{}, ErrMarketingNoHandOverChannel
}

// HandOverMarketingPost records that hum posted the live blog post postID by
// hand on channelID; it returns the hand-over time.
func (s *Server) HandOverMarketingPost(ctx context.Context, tenant, hum, postID, channelID string) (time.Time, error) {
	st, ok := s.o.Store.(handOverStore)
	appURL, client := s.blogSource()
	if !ok || appURL == "" {
		return time.Time{}, errMarketingNoBlog
	}
	if !s.marketingSweepable(ctx, tenant) {
		return time.Time{}, ErrMarketingOff
	}
	if _, err := s.access(ctx, hum, tenant); hum == "" || err != nil {
		return time.Time{}, ErrMarketingNotApprover
	}
	ch, err := handOverChannel(ctx, st, tenant, channelID)
	if err != nil {
		return time.Time{}, err
	}
	if !s.metaApprover(ctx, tenant, hum, ch) {
		return time.Time{}, ErrMarketingNotApprover
	}
	posts, err := marketing.FetchBlogIndex(ctx, client, appURL)
	if err != nil {
		return time.Time{}, err
	}
	bp, live := blogByID(posts)[postID]
	if !live {
		return time.Time{}, ErrMarketingNoPost
	}
	now := s.o.Now()
	if err := handOver(ctx, st, ch, bp, appURL, hum, now); err != nil {
		return time.Time{}, err
	}
	s.o.Log.Info().Str("tenant", tenant).Str("channel", ch.ID).Str("platform", ch.Platform).Str("post", postID).Str("by", hum).Msg("marketing: a blog post is handed over (posted by hand)")
	return now, nil
}

// handOver records bp on ch held, unless a row exists, then hands it over.
// A row past scheduled (being sent, published, failed) is 409.
func handOver(ctx context.Context, st handOverStore, ch store.MarketingChannel, bp marketing.BlogPost, appURL, actor string, now time.Time) error {
	if _, err := st.ScheduleMarketingPost(ctx, store.MarketingPost{Tenant: ch.Tenant, ChannelID: ch.ID,
		SourceType: store.MarketingSourceBlog, SourceRef: bp.ID, ContentText: metaCaption(appURL, ch.Platform, bp),
		Status: store.MarketingAwaitingApproval, MediaAssets: metaMedia(appURL, bp)}, now); err != nil {
		return err
	}
	p, err := st.MarketingPostByRef(ctx, ch.Tenant, ch.ID, store.MarketingSourceBlog, bp.ID)
	if err != nil {
		return err
	}
	if err := st.HandOverMarketingPost(ctx, ch.Tenant, p.ID, actor, now); errors.Is(err, store.ErrNotFound) {
		return ErrMarketingRecorded
	} else if err != nil {
		return err
	}
	return nil
}

// POST /v1/marketing/posts/{id}/manual-publish?channel=<channel id>.
func (s *Server) handleMarketingManualPublish(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	hum, _ := s.memberID(r, tenant)
	at, err := s.HandOverMarketingPost(r.Context(), tenant, hum, r.PathValue("id"), r.URL.Query().Get("channel"))
	switch {
	case errors.Is(err, ErrMarketingNotApprover):
		writeForbidden(w, rbac.TenantSettings, err.Error())
	case errors.Is(err, ErrMarketingNoPost), errors.Is(err, ErrMarketingOff), errors.Is(err, ErrMarketingNoHandOverChannel):
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, ErrMarketingRecorded):
		writeErr(w, http.StatusConflict, "already_recorded", err.Error())
	case errors.Is(err, errMarketingNoBlog):
		writeErr(w, http.StatusServiceUnavailable, "blog_off", err.Error())
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "the hand-over was not recorded")
	default:
		writeJSON(w, http.StatusOK, map[string]any{"post": r.PathValue("id"), "channel": r.URL.Query().Get("channel"),
			"status": store.MarketingPublished, "platform_post_id": store.MarketingManualPostID, "published_at": at.UTC().Format(time.RFC3339)})
	}
}

// routeMarketingManualPublish registers the hand-over (from routeMarketing).
func (s *Server) routeMarketingManualPublish(mux *http.ServeMux) {
	s.marketingRoute(mux, "POST /v1/marketing/posts/{id}/manual-publish", s.handleMarketingManualPublish)
	mux.HandleFunc("OPTIONS /v1/marketing/posts/{id}/manual-publish", s.marketingPostsPreflight)
}

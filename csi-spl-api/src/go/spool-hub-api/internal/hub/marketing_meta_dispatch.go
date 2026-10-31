package hub

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Publishing a blog post on a connected Facebook Page or Instagram account
// after a human's approval (spec 090 T034, SPL-4424; spec.md §16.3, §21).
// It reuses the LinkedIn publish route and its one queue (T015): no second
// queue.
//
//   - POST /v1/marketing/posts/{id}/publish?channel=<channel id> approves
//     the live blog post {id} for one Meta channel of the workspace: the
//     workspace owner, or an agent for them (the SPL-1855 door), every gate
//     of the LinkedIn publish holding. The post's row is made held
//     (awaiting_approval) and moved to scheduled, due now
//     (ApproveMarketingPost), then claimed and dispatched at once. A second
//     publish of the same post on the same channel is 409. Without
//     ?channel the route is the LinkedIn publish, unchanged.
//   - A Meta channel is never auto_publish (T033), so nothing reaches it
//     without that approval: the LinkedIn sweep lists only auto_publish
//     channels, and ClaimMarketingPosts selects only scheduled rows.
//   - The dispatch sweep (RunMarketingMetaDispatch, every minute) claims
//     each active Meta channel's due posts (FOR UPDATE SKIP LOCKED, so two
//     hubs never both send one), opens the sealed Page token in memory and
//     posts: a Page link post, or an Instagram container -> status ->
//     media_publish. It stores the post id, and the permalink in the
//     post_published event.
//   - Caps: at most metaDailyCap API posts per channel in a rolling 24 h
//     (spec.md FR-007), never above Instagram's 100 (§21.1). A channel at
//     its cap is not claimed; a post over it waits until the window frees.
//   - Failures (§21.2): a rate limit, a 503, a container not finished yet
//     or a connection that failed before sending is retried (at most
//     marketingMaxAttempts tries). A call that may have posted (sent, then
//     no answer, or a 500/502/504) and every other error fail at once and
//     are never sent again. A refused token (OAuthException 190) expires
//     the channel and mails the holder the re-connect link; its posts wait,
//     unsent, for the re-connect.
//   - Instagram takes only a JPEG picture: a post without one is refused
//     before anything is recorded.

const (
	marketingMetaEvery = time.Minute
	metaDailyCap       = 1   // spec.md FR-007: one post a day per channel
	metaInstagramLimit = 100 // spec.md §21.1: API posts per account in 24 h
	metaWindow         = 24 * time.Hour
	metaContainerWait  = 2 * time.Second
	metaContainerPolls = 5
)

// Why a Meta publish was refused.
var (
	ErrMarketingNoMeta      = errors.New("Facebook and Instagram are not configured on this hub")
	ErrMarketingNoMetaPage  = errors.New("the channel is no connected Facebook Page or Instagram account of this workspace")
	ErrMarketingNeedsJPEG   = errors.New("instagram takes only a JPEG picture, and this post has none")
	errMetaNoPicture        = errors.New("instagram needs a picture, and the post has none")
	errMetaTokenUnavailable = errors.New("token unavailable")
)

// metaStore is the store the Meta publish and dispatch need.
type metaStore interface {
	store.Marketing
	store.MarketingMetaDispatch
}

// metaPass is one channel's dispatch: its wiring and the result it counts.
// post, when set, is the one post a publish just approved: only it is
// claimed, waiting on a racing lock rather than skipping it (SPL-4477).
type metaPass struct {
	mm   *MarketingMeta
	st   metaStore
	ch   store.MarketingChannel
	res  *MarketingShareResult
	post string
}

func isMetaPlatform(p string) bool {
	return p == store.MarketingPlatformFacebook || p == store.MarketingPlatformIG
}

// metaReady returns the Meta wiring and store, or false while either is missing.
func (s *Server) metaReady() (*MarketingMeta, metaStore, bool) {
	mm := s.o.MarketingMeta
	st, ok := s.o.Store.(metaStore)
	if mm == nil || mm.Meta == nil || mm.Sealer == nil || !ok {
		return nil, nil, false
	}
	return mm, st, true
}

// RunMarketingMetaDispatch runs SweepMarketingMeta every marketingMetaEvery
// until ctx ends; it returns at once while Meta or the store is not set up.
func (s *Server) RunMarketingMetaDispatch(ctx context.Context) {
	if _, _, ok := s.metaReady(); !ok {
		return
	}
	t := time.NewTicker(marketingMetaEvery)
	defer t.Stop()
	for {
		s.SweepMarketingMeta(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// SweepMarketingMeta is one pass of the Meta dispatch: it fails the posts
// stuck in dispatching, then dispatches every Meta channel's due posts.
func (s *Server) SweepMarketingMeta(ctx context.Context) MarketingShareResult {
	var res MarketingShareResult
	mm, st, ok := s.metaReady()
	if !ok {
		return res
	}
	now := s.o.Now()
	stuck, err := st.StuckMarketingPosts(ctx, now.Add(-marketingStuckAfter), now)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("marketing: meta stuck sweep")
	}
	for _, p := range stuck {
		res.Failed++
		s.reportShareFailure(ctx, s.o.MarketingLinkedIn, p.Tenant, p.ChannelID, p.SourceRef, p.LastError)
	}
	chs, err := st.MetaMarketingChannels(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("marketing: meta channel list")
		return res
	}
	for _, ch := range chs {
		if s.marketingSweepable(ctx, ch.Tenant) {
			s.metaDispatchChannel(ctx, &metaPass{mm: mm, st: st, ch: ch, res: &res})
		}
	}
	if res != (MarketingShareResult{}) {
		s.o.Log.Info().Interface("result", res).Msg("marketing: meta dispatch sweep")
	}
	return res
}

// metaDispatchChannel claims and dispatches the channel's due posts, unless
// the channel is at its cap: then nothing is claimed and the time its window
// frees is returned (zero when it was not at the cap).
func (s *Server) metaDispatchChannel(ctx context.Context, ps *metaPass) time.Time {
	now := s.o.Now()
	room, freeAt, err := s.metaRoom(ctx, ps, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("channel", ps.ch.ID).Msg("marketing: meta cap unreadable, nothing dispatched")
		return time.Time{}
	}
	if room <= 0 {
		return freeAt
	}
	due, err := ps.claim(ctx, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("channel", ps.ch.ID).Msg("marketing: meta claim")
		return time.Time{}
	}
	if len(due) > 0 {
		s.dispatchMeta(ctx, ps, due, room, freeAt)
	}
	return time.Time{}
}

// claim claims the pass's one approved post, else the channel's due posts
// (FOR UPDATE SKIP LOCKED, the sweep).
func (ps *metaPass) claim(ctx context.Context, now time.Time) ([]store.MarketingPost, error) {
	if ps.post != "" {
		return ps.st.ClaimMarketingPost(ctx, ps.ch.Tenant, ps.post, now)
	}
	return ps.st.ClaimMarketingPosts(ctx, ps.ch.Tenant, ps.ch.ID, now)
}

// metaLimit is the most API posts a channel makes in a rolling metaWindow.
func (mm *MarketingMeta) metaLimit(platform string) int {
	limit := metaDailyCap
	if mm.DailyCap > 0 {
		limit = mm.DailyCap
	}
	if platform == store.MarketingPlatformIG {
		limit = min(limit, metaInstagramLimit)
	}
	return limit
}

// metaRoom is how many posts the channel may still make now, and when its
// window next frees a place (meaningful when room <= 0).
func (s *Server) metaRoom(ctx context.Context, ps *metaPass, now time.Time) (room int, freeAt time.Time, err error) {
	times, err := ps.st.MarketingPublishedTimes(ctx, ps.ch.Tenant, ps.ch.ID, now.Add(-metaWindow))
	if err != nil {
		return 0, time.Time{}, err
	}
	limit := ps.mm.metaLimit(ps.ch.Platform)
	room = limit - len(times)
	if room <= 0 {
		freeAt = times[len(times)-limit].Add(metaWindow)
	}
	return room, freeAt, nil
}

// dispatchMeta opens the Page token once and posts each claimed post; a
// post beyond the room left waits for freeAt, unsent.
func (s *Server) dispatchMeta(ctx context.Context, ps *metaPass, due []store.MarketingPost, room int, freeAt time.Time) {
	tok, terr := s.openMetaToken(ctx, ps)
	refused := false
	for _, p := range due {
		var out store.MarketingOutcome
		invalid, deferred := false, false
		switch {
		case refused: // Meta refused the token: the rest wait for the re-connect, unsent
			out = store.MarketingOutcome{Retry: true, RetryAt: s.o.Now(), Error: "waiting for the Facebook re-connect"}
		case terr != nil: // nothing was sent: a KMS or store failure is retried
			out = retryOrFail(p.Attempts, errors.Join(errMetaTokenUnavailable, terr), s.o.Now())
		case room <= 0:
			deferred = true
			out = store.MarketingOutcome{Retry: true, RetryAt: freeAt,
				Error: "the channel's cap of " + strconv.Itoa(ps.mm.metaLimit(ps.ch.Platform)) + " post(s) in 24 h is reached"}
		default:
			room--
			out, invalid = s.publishMetaOne(ctx, ps, tok, p)
		}
		s.settleMeta(ctx, ps, p, out, deferred)
		if invalid && !refused {
			refused = true
			s.metaRefused(ctx, ps)
		}
	}
}

func (s *Server) openMetaToken(ctx context.Context, ps *metaPass) (marketing.Plaintext, error) {
	sealed, err := ps.st.MarketingToken(ctx, ps.ch.Tenant, ps.ch.ID)
	if err != nil {
		return marketing.Plaintext{}, err
	}
	return ps.mm.Sealer.Open(ctx, sealed.Ciphertext)
}

// publishMetaOne makes the post public and reads its permalink (best
// effort). invalid: Meta refused the token; nothing was posted.
func (s *Server) publishMetaOne(ctx context.Context, ps *metaPass, tok marketing.Plaintext, p store.MarketingPost) (out store.MarketingOutcome, invalid bool) {
	var id, field string
	var err error
	if ps.ch.Platform == store.MarketingPlatformIG {
		field = marketing.PermalinkInstagram
		id, err = s.publishInstagram(ctx, ps, tok, p)
	} else {
		field = marketing.PermalinkFacebook
		id, err = ps.mm.Meta.PublishFacebookPagePost(ctx, tok, ps.ch.AccountRef,
			marketing.FacebookPost{Message: p.ContentText, Link: marketing.BlogPostURL(ps.mm.AppURL, p.SourceRef)})
	}
	if err != nil {
		return metaOutcome(err, p.Attempts, s.o.Now())
	}
	link, lerr := ps.mm.Meta.Permalink(ctx, tok, id, field)
	if lerr != nil {
		s.o.Log.Warn().Str("channel", ps.ch.ID).Str("post", p.SourceRef).Str("err", lerr.Error()).Msg("marketing: published, permalink unread")
	}
	return store.MarketingOutcome{Published: true, PlatformPostID: id, Permalink: link}, false
}

// publishInstagram makes a container of the post's picture, waits for Meta
// to finish it, then publishes it. A container is private until published,
// so a failed try leaves nothing public.
func (s *Server) publishInstagram(ctx context.Context, ps *metaPass, tok marketing.Plaintext, p store.MarketingPost) (string, error) {
	img := selectedMedia(p.MediaAssets)
	if img == "" {
		return "", errMetaNoPicture
	}
	m := ps.mm.Meta
	cid, err := m.CreateInstagramContainer(ctx, tok, ps.ch.AccountRef, marketing.InstagramMedia{ImageURL: img, Caption: p.ContentText})
	if err != nil {
		return "", err
	}
	wait := ps.mm.ContainerWait
	if wait <= 0 {
		wait = metaContainerWait
	}
	for i := 0; i < metaContainerPolls; i++ {
		st, err := m.PollInstagramContainer(ctx, tok, cid)
		if err != nil {
			return "", err
		}
		if st.Code != marketing.ContainerInProgress || sleepCtx(ctx, wait) != nil {
			break
		}
	}
	return m.PublishInstagramContainer(ctx, tok, ps.ch.AccountRef, cid)
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// selectedMedia is the picked picture's URL, else the first one's.
func selectedMedia(assets []store.MarketingMediaAsset) string {
	for _, a := range assets {
		if a.Selected {
			return a.URL
		}
	}
	if len(assets) > 0 {
		return assets[0].URL
	}
	return ""
}

// metaOutcome maps a failed post to its outcome (spec.md §21.2).
// invalid: the token was refused; the post waits for the re-connect.
func metaOutcome(err error, attempt int, now time.Time) (out store.MarketingOutcome, invalid bool) {
	if marketing.MetaTokenInvalid(err) {
		return store.MarketingOutcome{Retry: true, RetryAt: now, Error: err.Error()}, true
	}
	if !metaSafeToRetry(err) {
		return store.MarketingOutcome{Error: err.Error()}, false
	}
	out = retryOrFail(attempt, err, now)
	var me *marketing.MetaError
	if out.Retry && errors.As(err, &me) && me.RetryAfter > 0 {
		out.RetryAt = now.Add(me.RetryAfter)
	}
	return out, false
}

// metaSafeToRetry: a failure after which nothing can be public. A 500, 502
// or 504 on a call that posts may have posted, so it is never retried.
func metaSafeToRetry(err error) bool {
	if errors.Is(err, marketing.ErrMetaUnknownOutcome) {
		return false
	}
	if errors.Is(err, marketing.ErrContainerNotReady) {
		return true
	}
	var me *marketing.MetaError
	if errors.As(err, &me) && me.Kind == marketing.MetaErrTransient && me.Status >= 500 && me.Status != http.StatusServiceUnavailable {
		return false
	}
	return marketing.MetaRetryable(err)
}

// settleMeta records the outcome, then counts, logs and reports it.
func (s *Server) settleMeta(ctx context.Context, ps *metaPass, p store.MarketingPost, out store.MarketingOutcome, deferred bool) {
	if err := ps.st.FinishMarketingPost(ctx, ps.ch.Tenant, p.ID, out, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("post", p.SourceRef).Msg("marketing: settle meta post")
		return
	}
	lg := s.o.Log.With().Str("tenant", ps.ch.Tenant).Str("channel", ps.ch.ID).Str("platform", ps.ch.Platform).Str("post", p.SourceRef).Logger()
	switch {
	case out.Published:
		ps.res.Published++
		lg.Info().Str("platform_post_id", out.PlatformPostID).Str("permalink", out.Permalink).Msg("marketing: blog post published on Meta")
	case deferred:
		ps.res.Deferred++
		lg.Info().Time("at", out.RetryAt).Msg("marketing: meta post waits for the channel's cap")
	case out.Retry:
		ps.res.Retried++
		lg.Warn().Int("attempt", p.Attempts).Str("err", out.Error).Msg("marketing: meta post will be retried")
	default:
		ps.res.Failed++
		s.metaReportFailure(ctx, ps.mm, ps.ch, p.SourceRef, out.Error)
	}
}

// metaRefused expires the channel after Meta refused its token and asks the
// holder to connect again; its scheduled posts wait for that.
func (s *Server) metaRefused(ctx context.Context, ps *metaPass) {
	ch := ps.ch
	if err := ps.st.ExpireMarketingChannel(ctx, ch.Tenant, ch.ID, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("channel", ch.ID).Msg("marketing: expire meta channel")
	}
	s.mailMember(ctx, ps.mm.Mail, ch.Tenant, ch.DelegatedBy, "Facebook refused the spool-hub connection: connect again",
		"Meta no longer accepts the connection of "+ch.AccountName+" ("+ch.Platform+") in workspace "+ch.Tenant+
			". The posts you approved wait and are published once you connect again:\n\n"+ps.mm.ConnectLink(ch.Tenant)+"\n")
}

// metaReportFailure logs a final failure at error level and mails the holder.
func (s *Server) metaReportFailure(ctx context.Context, mm *MarketingMeta, ch store.MarketingChannel, postRef, why string) {
	s.o.Log.Error().Str("tenant", ch.Tenant).Str("channel", ch.ID).Str("platform", ch.Platform).Str("post", postRef).Str("err", why).Msg("marketing: meta post FAILED, not retried")
	if mm == nil {
		return
	}
	s.mailMember(ctx, mm.Mail, ch.Tenant, ch.DelegatedBy, "A blog post was not published on "+ch.AccountName,
		"spool-hub could not publish the blog post "+marketing.BlogPostURL(mm.AppURL, postRef)+" on "+ch.AccountName+" ("+ch.Platform+
			"), and will not retry it, so it is never posted twice.\n\nReason: "+why+"\n\nPost it by hand if you want it there.\n")
}

// PublishMetaPost is the owner's approval of the live blog post postID for
// the Meta channel channelID: publishMetaPost with no agent seat.
func (s *Server) PublishMetaPost(ctx context.Context, tenant, hum, postID, channelID string) (MarketingShareResult, error) {
	return s.publishMetaPost(ctx, tenant, hum, "", postID, channelID)
}

// publishMetaPost approves the live blog post postID for the Meta channel
// channelID and dispatches it at once (or when the channel's cap allows).
// Same gates as the LinkedIn publish: the workspace allow-listed and
// switched on, hum its owner, an agent seat only for its own member.
func (s *Server) publishMetaPost(ctx context.Context, tenant, hum, seat, postID, channelID string) (MarketingShareResult, error) {
	var res MarketingShareResult
	mm, st, ok := s.metaReady()
	if !ok {
		return res, ErrMarketingNoMeta
	}
	if !s.marketingSweepable(ctx, tenant) {
		return res, ErrMarketingOff
	}
	if a, err := s.access(ctx, hum, tenant); hum == "" || err != nil || !a.TenantOwner {
		return res, ErrMarketingNotOwner
	}
	if err := s.seatActsFor(ctx, tenant, seat, hum); err != nil {
		return res, err
	}
	ch, err := metaChannel(ctx, st, tenant, channelID)
	if err != nil {
		return res, err
	}
	posts, err := marketing.FetchBlogIndex(ctx, metaHTTP(mm), mm.AppURL)
	if err != nil {
		return res, err
	}
	bp, live := blogByID(posts)[postID]
	if !live {
		return res, ErrMarketingNoPost
	}
	pid, err := s.metaApprove(ctx, mm, st, ch, bp, hum)
	if err != nil {
		return res, err
	}
	res.Scheduled++
	s.o.Log.Info().Str("tenant", tenant).Str("channel", ch.ID).Str("platform", ch.Platform).Str("post", postID).Str("by", hum).Str("agent", seat).Msg("marketing: a blog post is approved for Meta")
	if at := s.metaDispatchChannel(ctx, &metaPass{mm: mm, st: st, ch: ch, res: &res, post: pid}); !at.IsZero() {
		res.Deferred++
		s.o.Log.Info().Str("channel", ch.ID).Time("at", at).Msg("marketing: meta post waits for the channel's cap")
	}
	return res, nil
}

// metaChannel is tenant's active Meta channel channelID.
func metaChannel(ctx context.Context, st metaStore, tenant, channelID string) (store.MarketingChannel, error) {
	chs, err := st.MarketingChannels(ctx, tenant)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	for _, ch := range chs {
		if ch.ID == channelID && isMetaPlatform(ch.Platform) && ch.Status == store.MarketingActive {
			return ch, nil
		}
	}
	return store.MarketingChannel{}, ErrMarketingNoMetaPage
}

// metaApprove records bp on ch held (awaiting_approval) and approves it:
// scheduled, due now; it returns the post's id. A row that is already past
// the hold is 409.
func (s *Server) metaApprove(ctx context.Context, mm *MarketingMeta, st metaStore, ch store.MarketingChannel, bp marketing.BlogPost, actor string) (string, error) {
	media := metaMedia(mm.AppURL, bp)
	if ch.Platform == store.MarketingPlatformIG && !isJPEG(selectedMedia(media)) {
		return "", ErrMarketingNeedsJPEG
	}
	now := s.o.Now()
	if _, err := st.ScheduleMarketingPost(ctx, store.MarketingPost{Tenant: ch.Tenant, ChannelID: ch.ID,
		SourceType: store.MarketingSourceBlog, SourceRef: bp.ID, ContentText: metaCaption(mm.AppURL, ch.Platform, bp),
		Status: store.MarketingAwaitingApproval, MediaAssets: media}, now); err != nil {
		return "", err
	}
	p, err := st.MarketingPostByRef(ctx, ch.Tenant, ch.ID, store.MarketingSourceBlog, bp.ID)
	if err != nil {
		return "", err
	}
	if p.Status != store.MarketingAwaitingApproval {
		return "", ErrMarketingRecorded
	}
	if err := st.ApproveMarketingPost(ctx, ch.Tenant, p.ID, actor, now); errors.Is(err, store.ErrNotFound) {
		return "", ErrMarketingRecorded // a racing publish approved it first
	} else if err != nil {
		return "", err
	}
	return p.ID, nil
}

func metaHTTP(mm *MarketingMeta) *http.Client {
	if mm.Meta.HTTP != nil {
		return mm.Meta.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// metaMedia is the post's picture as its one selected media asset.
func metaMedia(appURL string, bp marketing.BlogPost) []store.MarketingMediaAsset {
	if bp.Image == "" || strings.ContainsAny(bp.Image, "/\\") {
		return nil
	}
	return []store.MarketingMediaAsset{{URL: strings.TrimRight(appURL, "/") + "/blog/img/" + url.PathEscape(bp.Image), Selected: true}}
}

func isJPEG(u string) bool {
	l := strings.ToLower(u)
	return strings.HasSuffix(l, ".jpg") || strings.HasSuffix(l, ".jpeg")
}

// metaCaption is the post's text: title and summary; Instagram, which
// links nothing in a caption, also gets the post's address. Cut to the
// platform's cap by shortening the summary.
func metaCaption(appURL, platform string, bp marketing.BlogPost) string {
	head, tail, limit := strings.TrimSpace(bp.Title), "", marketing.FacebookMessageMaxChars
	if platform == store.MarketingPlatformIG {
		tail, limit = "\n\n"+marketing.BlogPostURL(appURL, bp.ID), marketing.InstagramCaptionMaxChars
	}
	summary := strings.TrimSpace(bp.Summary)
	if summary != "" {
		summary = "\n\n" + summary
	}
	if room := limit - utf8.RuneCountInString(head) - utf8.RuneCountInString(tail); utf8.RuneCountInString(summary) > room {
		summary = string([]rune(summary)[:max(room, 0)])
	}
	return head + summary + tail
}

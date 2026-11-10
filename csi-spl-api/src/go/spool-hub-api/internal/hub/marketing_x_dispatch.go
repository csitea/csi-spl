package hub

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Publishing a blog post on a connected X account on a human's press (spec
// 090 X row, SPL-5194). It is the Meta publish (marketing_meta_dispatch.go)
// on the same route and the same one queue:
//
//   - POST /v1/marketing/posts/{id}/publish?channel=<X channel id> publishes
//     the live blog post {id} on that X account: the member who connected
//     it, or a member holding tenant.settings (metaApprover; biz_owner and
//     admin by the default roles), or an agent for one of them, the
//     allow-list and the switch holding. The row is made held, approved
//     (scheduled, due now), claimed under the channel's cap and posted at
//     once. A second publish of one post on one channel is 409.
//   - The text is the title, the summary and the link (marketing.XPostText),
//     cut to X's 280 weighted characters by shortening the summary; a text
//     still over it is 422 x_too_long and nothing is recorded.
//   - The access token lives two hours: it is refreshed with the refresh
//     token a minute before it ends, and the new pair sealed back with a
//     compare-and-swap, so of two hubs refreshing at once only one pair is
//     kept and the other hub uses it (X may rotate the refresh token).
//   - Failures: a 429 (until X's reset), a 503 or a connection that failed
//     before sending is retried (at most marketingMaxAttempts tries) by the
//     dispatch sweep (RunMarketingXDispatch, every minute). A call that may
//     have posted (sent, then no answer, or another 5xx) and every other
//     error fail at once, are never sent again, and are mailed to the
//     holder. A refused token (401, or a refresh X refuses) expires the
//     channel and mails the re-connect link; its posts wait, unsent.

const (
	marketingXEvery = time.Minute
	// xRefreshBefore: an access token this close to its end is refreshed first.
	xRefreshBefore = time.Minute
)

// Why an X publish was refused.
var (
	ErrMarketingNoX        = errors.New("X is not configured on this hub")
	ErrMarketingNoXAccount = errors.New("the channel is no connected X account of this workspace")
	ErrMarketingXTooLong   = errors.New("the post is over X's 280 weighted characters")
	errXTokenUnavailable   = errors.New("token unavailable")
)

// xStore is the store the X publish and dispatch need.
type xStore interface {
	metaStore
	store.MarketingXDispatch
}

// xPass is one X channel's dispatch; post, when set, is the one post a
// publish just approved.
type xPass struct {
	mx   *MarketingX
	st   xStore
	ch   store.MarketingChannel
	res  *MarketingShareResult
	post string
}

// xReady returns the X wiring and store, or false while either is missing.
func (s *Server) xReady() (*MarketingX, xStore, bool) {
	mx := s.o.MarketingX
	st, ok := s.o.Store.(xStore)
	if mx == nil || mx.X == nil || mx.Sealer == nil || !ok {
		return nil, nil, false
	}
	return mx, st, true
}

// RunMarketingXDispatch runs SweepMarketingX every marketingXEvery until ctx
// ends; it returns at once while X or the store is not set up.
func (s *Server) RunMarketingXDispatch(ctx context.Context) {
	if _, _, ok := s.xReady(); !ok {
		return
	}
	t := time.NewTicker(marketingXEvery)
	defer t.Stop()
	for {
		s.SweepMarketingX(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// SweepMarketingX is one pass of the X dispatch: it fails the posts stuck in
// dispatching, then posts every X channel's due retries.
func (s *Server) SweepMarketingX(ctx context.Context) MarketingShareResult {
	var res MarketingShareResult
	mx, st, ok := s.xReady()
	if !ok {
		return res
	}
	now := s.o.Now()
	stuck, err := st.StuckMarketingPosts(ctx, now.Add(-marketingStuckAfter), now)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("marketing: x stuck sweep")
	}
	for _, p := range stuck {
		res.Failed++
		s.reportShareFailure(ctx, s.o.MarketingLinkedIn, p.Tenant, p.ChannelID, p.SourceRef, p.LastError)
	}
	chs, err := st.XMarketingChannels(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("marketing: x channel list")
		return res
	}
	for _, ch := range chs {
		if s.marketingSweepable(ctx, ch.Tenant) {
			s.xDispatchChannel(ctx, &xPass{mx: mx, st: st, ch: ch, res: &res})
		}
	}
	if res != (MarketingShareResult{}) {
		s.o.Log.Info().Interface("result", res).Msg("marketing: x dispatch sweep")
	}
	return res
}

// xDispatchChannel claims, under the channel's cap, the pass's one approved
// post, else the channel's due posts, and posts them. When the cap held a
// due post back it returns when the window frees a place (zero otherwise).
func (s *Server) xDispatchChannel(ctx context.Context, ps *xPass) time.Time {
	limit := metaDailyCap
	if ps.mx.DailyCap > 0 {
		limit = ps.mx.DailyCap
	}
	c, err := ps.st.ClaimMetaMarketingPosts(ctx, store.MetaClaim{Tenant: ps.ch.Tenant, ChannelID: ps.ch.ID, PostID: ps.post,
		Limit: limit, Window: metaWindow, Now: s.o.Now()})
	if err != nil {
		s.o.Log.Error().Err(err).Str("channel", ps.ch.ID).Msg("marketing: x claim, nothing dispatched")
		return time.Time{}
	}
	if len(c.Posts) > 0 {
		s.dispatchX(ctx, ps, c.Posts)
	}
	if !c.Held {
		return time.Time{}
	}
	return c.FreeAt
}

// dispatchX gets a live access token once and posts each claimed post.
func (s *Server) dispatchX(ctx context.Context, ps *xPass, due []store.MarketingPost) {
	tok, terr := s.xAccessToken(ctx, ps)
	refused := marketing.XTokenRefused(terr)
	if refused {
		s.xRefused(ctx, ps)
	}
	for _, p := range due {
		var out store.MarketingOutcome
		gone := false
		switch {
		case refused: // X refused the token: the posts wait for the re-connect, unsent
			out = store.MarketingOutcome{Retry: true, RetryAt: s.o.Now(), Error: "waiting for the X re-connect"}
		case terr != nil: // nothing was sent: a KMS, store or refresh failure is retried
			out = retryOrFail(p.Attempts, errors.Join(errXTokenUnavailable, terr), s.o.Now())
		default:
			out, gone = s.publishXOne(ctx, ps, tok, p)
		}
		s.settleX(ctx, ps, p, out)
		if gone && !refused {
			refused = true
			s.xRefused(ctx, ps)
		}
	}
}

// xAccessToken opens the channel's sealed pair and, when the access token
// is about to end, refreshes it and seals the new pair back. A refresh that
// lost the swap to another hub uses the pair that hub stored.
func (s *Server) xAccessToken(ctx context.Context, ps *xPass) (marketing.Plaintext, error) {
	sealed, tok, err := s.openXToken(ctx, ps)
	if err != nil || s.o.Now().Add(xRefreshBefore).Before(tok.ExpiresAt) {
		return tok.Access, err
	}
	fresh, err := ps.mx.X.Refresh(ctx, tok.Refresh, s.o.Now())
	if err != nil {
		return marketing.Plaintext{}, err
	}
	ct, keyID, err := ps.mx.Sealer.Seal(ctx, fresh.Bundle())
	if err != nil {
		return marketing.Plaintext{}, err
	}
	won, err := ps.st.SwapMarketingToken(ctx, ps.ch.Tenant, ps.ch.ID, sealed, store.MarketingToken{Ciphertext: ct, KMSKeyID: keyID}, s.o.Now())
	if err != nil {
		return marketing.Plaintext{}, err
	}
	if won {
		return fresh.Access, nil
	}
	_, tok, err = s.openXToken(ctx, ps)
	return tok.Access, err
}

func (s *Server) openXToken(ctx context.Context, ps *xPass) (store.MarketingToken, marketing.XToken, error) {
	sealed, err := ps.st.MarketingToken(ctx, ps.ch.Tenant, ps.ch.ID)
	if err != nil {
		return sealed, marketing.XToken{}, err
	}
	p, err := ps.mx.Sealer.Open(ctx, sealed.Ciphertext)
	if err != nil {
		return sealed, marketing.XToken{}, err
	}
	tok, err := marketing.ParseXToken(p)
	return sealed, tok, err
}

// publishXOne posts p. refused: X refused the token; nothing was posted.
func (s *Server) publishXOne(ctx context.Context, ps *xPass, tok marketing.Plaintext, p store.MarketingPost) (out store.MarketingOutcome, refused bool) {
	id, err := ps.mx.X.Post(ctx, tok, p.ContentText)
	if err == nil {
		return store.MarketingOutcome{Published: true, PlatformPostID: id, Permalink: xPermalink(ps.ch, id)}, false
	}
	if marketing.XTokenRefused(err) {
		return store.MarketingOutcome{Retry: true, RetryAt: s.o.Now(), Error: err.Error()}, true
	}
	if !marketing.XRetryable(err) {
		return store.MarketingOutcome{Error: err.Error()}, false
	}
	out = retryOrFail(p.Attempts, err, s.o.Now())
	var xe *marketing.XError
	if out.Retry && errors.As(err, &xe) && xe.RetryAfter > 0 {
		out.RetryAt = s.o.Now().Add(xe.RetryAfter)
	}
	return out, false
}

// xPermalink is the post's public address: x.com/<username>/status/<id>.
func xPermalink(ch store.MarketingChannel, id string) string {
	username, _ := ch.Metadata["username"].(string)
	if username == "" {
		username = "i"
	}
	return marketing.XAuthBase + "/" + username + "/status/" + id
}

// settleX records the outcome, then counts, logs and reports it.
func (s *Server) settleX(ctx context.Context, ps *xPass, p store.MarketingPost, out store.MarketingOutcome) {
	if err := ps.st.FinishMarketingPost(ctx, ps.ch.Tenant, p.ID, out, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("post", p.SourceRef).Msg("marketing: settle x post")
		return
	}
	lg := s.o.Log.With().Str("tenant", ps.ch.Tenant).Str("channel", ps.ch.ID).Str("post", p.SourceRef).Logger()
	switch {
	case out.Published:
		ps.res.Published++
		lg.Info().Str("platform_post_id", out.PlatformPostID).Str("permalink", out.Permalink).Msg("marketing: blog post published on X")
	case out.Retry:
		ps.res.Retried++
		lg.Warn().Int("attempt", p.Attempts).Str("err", out.Error).Msg("marketing: x post will be retried")
	default:
		ps.res.Failed++
		s.xReportFailure(ctx, ps.mx, ps.ch, p.SourceRef, out.Error)
	}
}

// xRefused expires the channel after X refused its token and asks the holder
// to connect again; its scheduled posts wait for that.
func (s *Server) xRefused(ctx context.Context, ps *xPass) {
	ch := ps.ch
	if err := ps.st.ExpireMarketingChannel(ctx, ch.Tenant, ch.ID, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("channel", ch.ID).Msg("marketing: expire x channel")
	}
	s.mailMember(ctx, ps.mx.Mail, ch.Tenant, ch.DelegatedBy, "X refused the spool-hub connection: connect again",
		"X no longer accepts the connection of "+ch.AccountName+" in workspace "+ch.Tenant+
			". The posts you published wait and go out once you connect again:\n\n"+ps.mx.ConnectLink(ch.Tenant)+"\n")
}

// xReportFailure logs a final failure at error level and mails the holder.
func (s *Server) xReportFailure(ctx context.Context, mx *MarketingX, ch store.MarketingChannel, postRef, why string) {
	s.o.Log.Error().Str("tenant", ch.Tenant).Str("channel", ch.ID).Str("post", postRef).Str("err", why).Msg("marketing: x post FAILED, not retried")
	if mx == nil {
		return
	}
	s.mailMember(ctx, mx.Mail, ch.Tenant, ch.DelegatedBy, "A post was not published on "+ch.AccountName,
		"spool-hub could not publish "+marketingPostLabel(mx.AppURL, postRef)+" on X ("+ch.AccountName+
			"), and will not retry it, so it is never posted twice.\n\nReason: "+why+"\n\nPost it by hand if you want it there.\n")
}

// PublishXPost is a member's publish of the live blog post postID on the X
// channel channelID: publishXPost with no agent seat.
func (s *Server) PublishXPost(ctx context.Context, tenant, hum, postID, channelID string) (MarketingShareResult, error) {
	return s.publishXPost(ctx, tenant, hum, "", postID, channelID)
}

// publishXPost approves the live blog post postID for the X channel
// channelID and posts it at once (or when the channel's cap allows).
func (s *Server) publishXPost(ctx context.Context, tenant, hum, seat, postID, channelID string) (MarketingShareResult, error) {
	var res MarketingShareResult
	mx, st, ok := s.xReady()
	if !ok {
		return res, ErrMarketingNoX
	}
	if !s.marketingSweepable(ctx, tenant) {
		return res, ErrMarketingOff
	}
	if _, err := s.access(ctx, hum, tenant); hum == "" || err != nil {
		return res, ErrMarketingNotApprover
	}
	if err := s.seatActsFor(ctx, tenant, seat, hum); err != nil {
		return res, err
	}
	ch, err := xChannel(ctx, st, tenant, channelID)
	if err != nil {
		return res, err
	}
	if !s.metaApprover(ctx, tenant, hum, ch) {
		return res, ErrMarketingNotApprover
	}
	bp, err := xLivePost(ctx, mx, postID)
	if err != nil {
		return res, err
	}
	text := marketing.XPostText(mx.AppURL, bp)
	if marketing.XWeightedLength(text) > marketing.XPostMaxWeight {
		return res, ErrMarketingXTooLong
	}
	pid, err := s.approveHeld(ctx, st, store.MarketingPost{Tenant: ch.Tenant, ChannelID: ch.ID, SourceType: store.MarketingSourceBlog,
		SourceRef: bp.ID, ContentText: text, Status: store.MarketingAwaitingApproval}, hum)
	if err != nil {
		return res, err
	}
	res.Scheduled++
	s.o.Log.Info().Str("tenant", tenant).Str("channel", ch.ID).Str("post", postID).Str("by", hum).Str("agent", seat).Msg("marketing: a blog post is approved for X")
	if at := s.xDispatchChannel(ctx, &xPass{mx: mx, st: st, ch: ch, res: &res, post: pid}); !at.IsZero() {
		res.Deferred++
		s.o.Log.Info().Str("channel", ch.ID).Time("at", at).Msg("marketing: x post waits for the channel's cap")
	}
	return res, nil
}

// xLivePost is the live blog post postID, or ErrMarketingNoPost.
func xLivePost(ctx context.Context, mx *MarketingX, postID string) (marketing.BlogPost, error) {
	posts, err := marketing.FetchBlogIndex(ctx, xHTTP(mx), mx.AppURL)
	if err != nil {
		return marketing.BlogPost{}, err
	}
	bp, live := blogByID(posts)[postID]
	if !live {
		return marketing.BlogPost{}, ErrMarketingNoPost
	}
	return bp, nil
}

func xHTTP(mx *MarketingX) *http.Client {
	if mx.X.HTTP != nil {
		return mx.X.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// xChannel is tenant's active X channel channelID.
func xChannel(ctx context.Context, st store.Marketing, tenant, channelID string) (store.MarketingChannel, error) {
	chs, err := st.MarketingChannels(ctx, tenant)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	for _, ch := range chs {
		if ch.ID == channelID && ch.Platform == store.MarketingPlatformX && ch.Status == store.MarketingActive {
			return ch, nil
		}
	}
	return store.MarketingChannel{}, ErrMarketingNoXAccount
}

// isXChannel: channelID is one of tenant's X channels (any status), so a
// publish or a list naming it takes the X path.
func (s *Server) isXChannel(ctx context.Context, tenant, channelID string) bool {
	mk, ok := s.o.Store.(store.Marketing)
	if !ok {
		return false
	}
	chs, err := mk.MarketingChannels(ctx, tenant)
	if err != nil {
		return false
	}
	for _, ch := range chs {
		if ch.ID == channelID {
			return ch.Platform == store.MarketingPlatformX
		}
	}
	return false
}

// UnsharedXPosts is the live posts hum can still publish on the X channel
// channelID: those with no row on it. The publish's gates (metaApprover).
func (s *Server) UnsharedXPosts(ctx context.Context, tenant, hum, channelID string) ([]marketing.BlogPost, error) {
	mx, st, ok := s.xReady()
	if !ok {
		return nil, ErrMarketingNoX
	}
	if !s.marketingSweepable(ctx, tenant) {
		return nil, ErrMarketingOff
	}
	if _, err := s.access(ctx, hum, tenant); hum == "" || err != nil {
		return nil, ErrMarketingNotApprover
	}
	ch, err := xChannel(ctx, st, tenant, channelID)
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
	posts, err := marketing.FetchBlogIndex(ctx, xHTTP(mx), mx.AppURL)
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

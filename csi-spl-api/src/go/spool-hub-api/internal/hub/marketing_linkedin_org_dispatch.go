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

// Publishing a blog post on a connected LinkedIn Company Page on a human's
// press (spec 090 phase 4, T041, SPL-5258; linkedin-company-page.md
// sections 5-7). The X publish (marketing_x_dispatch.go) on the same route
// and the same one queue:
//
//   - POST /v1/marketing/posts/{id}/publish?channel=<Page channel id>
//     publishes the live blog post {id} as the Page (author
//     urn:li:organization:<id>), never on the caller's own profile. Who may:
//     any member holding tenant.settings (biz_owner and admin by the default
//     roles; SPL-5196), even one who did not connect the Page, or an agent
//     for one of them. Having connected the Page is not enough: a connector
//     who lost both roles is refused (SPL-5196 R7 W1). The row is made held,
//     approved (scheduled, due now), claimed under the Page's cap (one post
//     in 24 h, FR-007) and posted at once. A second publish of one post on
//     one Page is 409.
//   - The access token lives 60 days: within linkedInOrgRefreshBefore of
//     its end it is refreshed with the refresh token (365 days from the
//     first consent) and the new bundle sealed back with a compare-and-swap,
//     so of two hubs refreshing at once only one bundle is kept and the
//     other hub uses it.
//   - Failures: a 429, a 503 or a connection that failed before sending is
//     retried (at most marketingMaxAttempts tries) by the dispatch sweep
//     (RunMarketingLinkedInOrgDispatch, every minute). A call that may have
//     posted (sent, then no answer, or another 5xx) and every other error
//     fail at once, are never sent again, and are mailed to the member who
//     connected the Page. A refused connection (401, 403 when the member
//     lost the Page role, or a refresh LinkedIn refuses) expires the channel
//     and mails the re-connect link; its posts wait, unsent.
//   - 7 days before the connection ends the member who connected the Page
//     gets one mail with the re-connect link; at the end the channel is
//     expired and its posts wait for the re-connect.

const (
	marketingLinkedInOrgEvery = time.Minute
	// linkedInOrgRefreshBefore: an access token this close to its end is
	// refreshed first (section 5.3).
	linkedInOrgRefreshBefore = 5 * time.Minute
)

// Why a Company Page publish was refused.
var (
	ErrMarketingNoLinkedInOrg  = errors.New("LinkedIn company page publishing is not configured on this hub")
	ErrMarketingNoLinkedInPage = errors.New("the channel is no connected LinkedIn company page of this workspace")
	ErrMarketingPageNotOwner   = errors.New("only a member holding tenant.settings (an admin or business owner) publishes as the LinkedIn company page, or an agent for them")
	errOrgTokenEnded           = &marketing.HTTPError{Status: http.StatusUnauthorized, Message: "the LinkedIn company page connection has ended"}
)

// linkedInOrgStore is the store the Company Page publish and dispatch need.
type linkedInOrgStore interface {
	metaStore
	store.MarketingXDispatch // SwapMarketingToken
	store.MarketingLinkedInPageDispatch
}

// orgPass is one Page channel's dispatch; post, when set, is the one post a
// publish just approved.
type orgPass struct {
	mo   *MarketingLinkedInOrg
	st   linkedInOrgStore
	ch   store.MarketingChannel
	res  *MarketingShareResult
	post string
}

// linkedInOrgReady returns the Company Page wiring and store, or false
// while either is missing.
func (s *Server) linkedInOrgReady() (*MarketingLinkedInOrg, linkedInOrgStore, bool) {
	mo := s.o.MarketingLinkedInOrg
	st, ok := s.o.Store.(linkedInOrgStore)
	if mo == nil || mo.Org == nil || mo.Sealer == nil || !ok {
		return nil, nil, false
	}
	return mo, st, true
}

// RunMarketingLinkedInOrgDispatch runs SweepMarketingLinkedInOrg every
// marketingLinkedInOrgEvery until ctx ends; it returns at once while the
// Company Page app or the store is not set up.
func (s *Server) RunMarketingLinkedInOrgDispatch(ctx context.Context) {
	if _, _, ok := s.linkedInOrgReady(); !ok {
		return
	}
	t := time.NewTicker(marketingLinkedInOrgEvery)
	defer t.Stop()
	for {
		s.SweepMarketingLinkedInOrg(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// SweepMarketingLinkedInOrg is one pass of the Company Page dispatch: it
// fails the posts stuck in dispatching, then per Page channel sends the
// end-of-connection reminder or expires it, else posts its due retries.
func (s *Server) SweepMarketingLinkedInOrg(ctx context.Context) MarketingShareResult {
	var res MarketingShareResult
	mo, st, ok := s.linkedInOrgReady()
	if !ok {
		return res
	}
	now := s.o.Now()
	stuck, err := st.StuckMarketingPosts(ctx, now.Add(-marketingStuckAfter), now)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("marketing: linkedin page stuck sweep")
	}
	for _, p := range stuck {
		res.Failed++
		s.reportShareFailure(ctx, s.o.MarketingLinkedIn, p.Tenant, p.ChannelID, p.SourceRef, p.LastError)
	}
	chs, err := st.LinkedInPageChannels(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("marketing: linkedin page channel list")
		return res
	}
	for _, ch := range chs {
		ps := &orgPass{mo: mo, st: st, ch: ch, res: &res}
		if s.marketingSweepable(ctx, ch.Tenant) && !s.orgChannelExpiry(ctx, ps, now) {
			s.orgDispatchChannel(ctx, ps)
		}
	}
	if res != (MarketingShareResult{}) {
		s.o.Log.Info().Interface("result", res).Msg("marketing: linkedin page dispatch sweep")
	}
	return res
}

// orgChannelExpiry sends the re-connect reminder once inside the last week
// and expires the channel at the end; true = do not post with it now.
func (s *Server) orgChannelExpiry(ctx context.Context, ps *orgPass, now time.Time) bool {
	ch := ps.ch
	if ch.ExpiresAt == nil {
		return false
	}
	end := ch.ExpiresAt.UTC().Format("2006-01-02")
	if !now.Before(*ch.ExpiresAt) {
		if err := ps.st.ExpireMarketingChannel(ctx, ch.Tenant, ch.ID, now); err != nil {
			s.o.Log.Error().Err(err).Str("channel", ch.ID).Msg("marketing: expire linkedin page channel")
			return true
		}
		ps.res.Expired++
		s.mailMember(ctx, ps.mo.Mail, ch.Tenant, ch.DelegatedBy, "The LinkedIn company page connection has ended: posts wait",
			"The connection of the LinkedIn company page "+ch.AccountName+" in workspace "+ch.Tenant+" ended on "+end+
				". The posts that are waiting go out as soon as you connect again:\n\n"+ps.mo.ConnectLink(ch.Tenant)+"\n")
		return true
	}
	if now.Add(marketingRemindBefore).Before(*ch.ExpiresAt) || ch.RemindedAt != nil {
		return false
	}
	if won, err := ps.st.MarkMarketingReminded(ctx, ch.Tenant, ch.ID, now); err != nil || !won {
		return false
	}
	ps.res.Reminded++
	s.mailMember(ctx, ps.mo.Mail, ch.Tenant, ch.DelegatedBy, "Renew the LinkedIn company page connection of spool-hub (one click)",
		"LinkedIn ends the connection of the company page "+ch.AccountName+" in workspace "+ch.Tenant+" on "+end+
			". Renew it with one click; sign in to spool-hub first if it asks:\n\n"+ps.mo.ConnectLink(ch.Tenant)+"\n")
	return false
}

// orgDispatchChannel claims, under the Page's cap, the pass's one approved
// post, else the Page's due posts, and posts them. When the cap held a due
// post back it returns when the window frees a place (zero otherwise).
func (s *Server) orgDispatchChannel(ctx context.Context, ps *orgPass) time.Time {
	limit := metaDailyCap
	if ps.mo.DailyCap > 0 {
		limit = ps.mo.DailyCap
	}
	c, err := ps.st.ClaimMetaMarketingPosts(ctx, store.MetaClaim{Tenant: ps.ch.Tenant, ChannelID: ps.ch.ID, PostID: ps.post,
		Limit: limit, Window: metaWindow, Now: s.o.Now()})
	if err != nil {
		s.o.Log.Error().Err(err).Str("channel", ps.ch.ID).Msg("marketing: linkedin page claim, nothing dispatched")
		return time.Time{}
	}
	if len(c.Posts) > 0 {
		s.dispatchOrg(ctx, ps, c.Posts)
	}
	if !c.Held {
		return time.Time{}
	}
	return c.FreeAt
}

// dispatchOrg gets a live access token and the blog index once, then posts
// each claimed post.
func (s *Server) dispatchOrg(ctx context.Context, ps *orgPass, due []store.MarketingPost) {
	tok, terr := s.orgAccessToken(ctx, ps)
	refused := marketing.OrgRefreshRefused(terr)
	if refused {
		s.orgRefused(ctx, ps)
	}
	var byID map[string]marketing.BlogPost
	posts, ierr := marketing.FetchBlogIndex(ctx, orgHTTP(ps.mo), ps.mo.AppURL)
	if ierr == nil {
		byID = blogByID(posts)
	}
	for _, p := range due {
		var out store.MarketingOutcome
		gone := false
		bp, live := byID[p.SourceRef]
		switch {
		case refused: // LinkedIn refused the connection: the posts wait for the re-connect, unsent
			out = store.MarketingOutcome{Retry: true, RetryAt: s.o.Now(), Error: "waiting for the LinkedIn company page re-connect"}
		case terr != nil: // nothing was sent: a KMS, store or refresh failure is retried
			out = retryOrFail(p.Attempts, errors.Join(errXTokenUnavailable, terr), s.o.Now())
		case ierr != nil: // nothing was sent: the blog index was not read
			out = retryOrFail(p.Attempts, errors.New("the blog index was not read"), s.o.Now())
		case !live:
			out = store.MarketingOutcome{Error: "the post is no longer in the live blog index"}
		default:
			out, gone = s.publishOrgOne(ctx, ps, tok, bp, p.Attempts)
		}
		s.settleOrg(ctx, ps, p, out)
		if gone && !refused {
			refused = true
			s.orgRefused(ctx, ps)
		}
	}
}

// orgAccessToken opens the channel's sealed bundle and, when the access
// token is about to end, refreshes it and seals the new bundle back. A
// refresh that lost the swap to another hub uses the bundle that hub
// stored. An ended token with no refresh token is refused (errOrgTokenEnded).
func (s *Server) orgAccessToken(ctx context.Context, ps *orgPass) (marketing.Plaintext, error) {
	now := s.o.Now()
	sealed, tok, err := s.openOrgToken(ctx, ps)
	if err != nil || now.Add(linkedInOrgRefreshBefore).Before(tok.ExpiresAt) {
		return tok.Access, err
	}
	if tok.Refresh.Reveal() == "" || !now.Before(tok.RefreshExpiresAt) {
		if now.Before(tok.ExpiresAt) {
			return tok.Access, nil // no refresh possible: use it to its end
		}
		return marketing.Plaintext{}, errOrgTokenEnded
	}
	fresh, err := ps.mo.Org.Refresh(ctx, tok, now)
	if err != nil {
		return marketing.Plaintext{}, err
	}
	ct, keyID, err := ps.mo.Sealer.Seal(ctx, fresh.Bundle())
	if err != nil {
		return marketing.Plaintext{}, err
	}
	won, err := ps.st.SwapMarketingToken(ctx, ps.ch.Tenant, ps.ch.ID, sealed, store.MarketingToken{Ciphertext: ct, KMSKeyID: keyID}, now)
	if err != nil {
		return marketing.Plaintext{}, err
	}
	if won {
		return fresh.Access, nil
	}
	_, tok, err = s.openOrgToken(ctx, ps)
	return tok.Access, err
}

func (s *Server) openOrgToken(ctx context.Context, ps *orgPass) (store.MarketingToken, marketing.OrgToken, error) {
	sealed, err := ps.st.MarketingToken(ctx, ps.ch.Tenant, ps.ch.ID)
	if err != nil {
		return sealed, marketing.OrgToken{}, err
	}
	p, err := ps.mo.Sealer.Open(ctx, sealed.Ciphertext)
	if err != nil {
		return sealed, marketing.OrgToken{}, err
	}
	tok, err := marketing.ParseOrgToken(p)
	return sealed, tok, err
}

// publishOrgOne uploads the picture (best effort, owned by the Page) and
// posts the article as the Page. refused: LinkedIn refused the connection;
// nothing was posted.
func (s *Server) publishOrgOne(ctx context.Context, ps *orgPass, tok marketing.Plaintext, bp marketing.BlogPost, attempt int) (out store.MarketingOutcome, refused bool) {
	org := ps.mo.Org
	thumb := ""
	if pic, err := marketing.FetchBlogPicture(ctx, orgHTTP(ps.mo), ps.mo.AppURL, bp); err != nil {
		s.o.Log.Warn().Str("post", bp.ID).Str("err", err.Error()).Msg("marketing: no picture for the linkedin page post")
	} else if pic != nil {
		if thumb, err = org.UploadImage(ctx, tok, ps.ch.AccountRef, pic); err != nil {
			s.o.Log.Warn().Str("post", bp.ID).Str("err", err.Error()).Msg("marketing: linkedin page picture upload failed, posting without it")
			thumb = ""
		}
	}
	id, err := org.Post(ctx, tok, ps.ch.AccountRef, marketing.BlogArticle(ps.mo.AppURL, bp, nil), thumb)
	switch {
	case err == nil:
		return store.MarketingOutcome{Published: true, PlatformPostID: id, Permalink: marketing.LinkedInPostPermalink(id)}, false
	case marketing.OrgTokenRefused(err): // nothing was posted: it waits for the re-connect
		return store.MarketingOutcome{Retry: true, RetryAt: s.o.Now(), Error: err.Error()}, true
	case !marketing.Retryable(err):
		return store.MarketingOutcome{Error: err.Error()}, false
	}
	return retryOrFail(attempt, err, s.o.Now()), false
}

// settleOrg records the outcome, then counts, logs and reports it.
func (s *Server) settleOrg(ctx context.Context, ps *orgPass, p store.MarketingPost, out store.MarketingOutcome) {
	if err := ps.st.FinishMarketingPost(ctx, ps.ch.Tenant, p.ID, out, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("post", p.SourceRef).Msg("marketing: settle linkedin page post")
		return
	}
	lg := s.o.Log.With().Str("tenant", ps.ch.Tenant).Str("channel", ps.ch.ID).Str("post", p.SourceRef).Logger()
	switch {
	case out.Published:
		ps.res.Published++
		lg.Info().Str("platform_post_id", out.PlatformPostID).Str("permalink", out.Permalink).Msg("marketing: blog post published on the LinkedIn company page")
	case out.Retry:
		ps.res.Retried++
		lg.Warn().Int("attempt", p.Attempts).Str("err", out.Error).Msg("marketing: linkedin page post will be retried")
	default:
		ps.res.Failed++
		s.orgReportFailure(ctx, ps.mo, ps.ch, p.SourceRef, out.Error)
	}
}

// orgRefused expires the channel after LinkedIn refused its connection and
// asks the member who connected it to connect again; its posts wait.
func (s *Server) orgRefused(ctx context.Context, ps *orgPass) {
	ch := ps.ch
	if err := ps.st.ExpireMarketingChannel(ctx, ch.Tenant, ch.ID, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("channel", ch.ID).Msg("marketing: expire linkedin page channel")
	}
	s.mailMember(ctx, ps.mo.Mail, ch.Tenant, ch.DelegatedBy, "LinkedIn refused the spool-hub company page connection: connect again",
		"LinkedIn no longer accepts the connection of the company page "+ch.AccountName+" in workspace "+ch.Tenant+
			" (the connection was revoked, or you are no longer a Super admin or Content admin of the page)."+
			" The posts that were published wait and go out once you connect again:\n\n"+ps.mo.ConnectLink(ch.Tenant)+"\n")
}

// orgReportFailure logs a final failure at error level and mails the member
// who connected the Page.
func (s *Server) orgReportFailure(ctx context.Context, mo *MarketingLinkedInOrg, ch store.MarketingChannel, postRef, why string) {
	s.o.Log.Error().Str("tenant", ch.Tenant).Str("channel", ch.ID).Str("post", postRef).Str("err", why).Msg("marketing: linkedin page post FAILED, not retried")
	if mo == nil {
		return
	}
	s.mailMember(ctx, mo.Mail, ch.Tenant, ch.DelegatedBy, "A blog post was not published on the LinkedIn company page "+ch.AccountName,
		"spool-hub could not publish the blog post "+marketing.BlogPostURL(mo.AppURL, postRef)+" on the LinkedIn company page "+
			ch.AccountName+", and will not retry it, so it is never posted twice.\n\nReason: "+why+"\n\nPost it by hand if you want it there.\n")
}

// linkedInPageGate is the publish and list gate: the Company Page app
// configured, the workspace swept, hum a member holding tenant.settings now
// (an agent's seat acting for hum), and channelID an active Page channel.
func (s *Server) linkedInPageGate(ctx context.Context, tenant, hum, seat, channelID string) (*MarketingLinkedInOrg, linkedInOrgStore, store.MarketingChannel, error) {
	mo, st, ok := s.linkedInOrgReady()
	if !ok {
		return nil, nil, store.MarketingChannel{}, ErrMarketingNoLinkedInOrg
	}
	if !s.marketingSweepable(ctx, tenant) {
		return nil, nil, store.MarketingChannel{}, ErrMarketingOff
	}
	if _, err := s.access(ctx, hum, tenant); hum == "" || err != nil || !s.allowed(ctx, hum, tenant, rbac.TenantSettings) {
		return nil, nil, store.MarketingChannel{}, ErrMarketingPageNotOwner
	}
	if err := s.seatActsFor(ctx, tenant, seat, hum); err != nil {
		return nil, nil, store.MarketingChannel{}, err
	}
	ch, err := linkedInPageChannel(ctx, st, tenant, channelID)
	return mo, st, ch, err
}

// PublishLinkedInPagePost is a member's publish of the live blog post
// postID on the Page channel channelID: publishLinkedInPagePost with no
// agent seat.
func (s *Server) PublishLinkedInPagePost(ctx context.Context, tenant, hum, postID, channelID string) (MarketingShareResult, error) {
	return s.publishLinkedInPagePost(ctx, tenant, hum, "", postID, channelID)
}

// publishLinkedInPagePost approves the live blog post postID for the Page
// channel channelID and posts it at once (or when the Page's cap allows).
func (s *Server) publishLinkedInPagePost(ctx context.Context, tenant, hum, seat, postID, channelID string) (MarketingShareResult, error) {
	var res MarketingShareResult
	mo, st, ch, err := s.linkedInPageGate(ctx, tenant, hum, seat, channelID)
	if err != nil {
		return res, err
	}
	bp, err := orgLivePost(ctx, mo, postID)
	if err != nil {
		return res, err
	}
	pid, err := s.approveHeld(ctx, st, store.MarketingPost{Tenant: ch.Tenant, ChannelID: ch.ID, SourceType: store.MarketingSourceBlog,
		SourceRef: bp.ID, ContentText: marketing.BlogArticle(mo.AppURL, bp, nil).Commentary, Status: store.MarketingAwaitingApproval}, hum)
	if err != nil {
		return res, err
	}
	res.Scheduled++
	s.o.Log.Info().Str("tenant", tenant).Str("channel", ch.ID).Str("post", postID).Str("by", hum).Str("agent", seat).Msg("marketing: a blog post is approved for the LinkedIn company page")
	if at := s.orgDispatchChannel(ctx, &orgPass{mo: mo, st: st, ch: ch, res: &res, post: pid}); !at.IsZero() {
		res.Deferred++
		s.o.Log.Info().Str("channel", ch.ID).Time("at", at).Msg("marketing: linkedin page post waits for the page's cap")
	}
	return res, nil
}

// orgLivePost is the live blog post postID, or ErrMarketingNoPost.
func orgLivePost(ctx context.Context, mo *MarketingLinkedInOrg, postID string) (marketing.BlogPost, error) {
	posts, err := marketing.FetchBlogIndex(ctx, orgHTTP(mo), mo.AppURL)
	if err != nil {
		return marketing.BlogPost{}, err
	}
	bp, live := blogByID(posts)[postID]
	if !live {
		return marketing.BlogPost{}, ErrMarketingNoPost
	}
	return bp, nil
}

func orgHTTP(mo *MarketingLinkedInOrg) *http.Client {
	if mo.Org.HTTP != nil {
		return mo.Org.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// linkedInPageChannel is tenant's active Page channel channelID.
func linkedInPageChannel(ctx context.Context, st store.Marketing, tenant, channelID string) (store.MarketingChannel, error) {
	chs, err := st.MarketingChannels(ctx, tenant)
	if err != nil {
		return store.MarketingChannel{}, err
	}
	for _, ch := range chs {
		if ch.ID == channelID && ch.Platform == store.MarketingPlatformLinkedInPage && ch.Status == store.MarketingActive {
			return ch, nil
		}
	}
	return store.MarketingChannel{}, ErrMarketingNoLinkedInPage
}

// isLinkedInPageChannel: channelID is one of tenant's Page channels (any
// status), so a publish or a list naming it takes the Company Page path.
func (s *Server) isLinkedInPageChannel(ctx context.Context, tenant, channelID string) bool {
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
			return ch.Platform == store.MarketingPlatformLinkedInPage
		}
	}
	return false
}

// UnsharedLinkedInPagePosts is the live posts hum can still publish on the
// Page channel channelID: those with no row on it. The publish's gates.
func (s *Server) UnsharedLinkedInPagePosts(ctx context.Context, tenant, hum, channelID string) ([]marketing.BlogPost, error) {
	mo, st, ch, err := s.linkedInPageGate(ctx, tenant, hum, "", channelID)
	if err != nil {
		return nil, err
	}
	refs, err := st.MarketingPostRefs(ctx, tenant, ch.ID)
	if err != nil {
		return nil, err
	}
	posts, err := marketing.FetchBlogIndex(ctx, orgHTTP(mo), mo.AppURL)
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

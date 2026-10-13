package hub

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The blog share sweep (spec 090 T015, SPL-1634; owner HUM-10, topic
// add4fbf4 msgs 06f5fd99, 489d18e6) and the owner's publish (SPL-40; owner
// HUM-10, topic add4fbf4 msg 3a3f366b: only they can post to LinkedIn).
//
//   - The sweep never starts a share. A new English post in the live blog
//     index goes to LinkedIn only when the workspace owner who connected
//     the channel publishes it: POST /v1/marketing/posts/{id}/publish
//     (PublishMarketingPost). An agent, any other member and the sweep
//     cannot.
//   - The publish uses the one publisher there is: it schedules the post's
//     row, claims it and shares it (dispatchDue, shareOne). The sweep only
//     finishes what the owner started: the retries below.
//   - The first sweep after a connect records every post already live as
//     skipped (the baseline): the back catalogue cannot be published.
//   - Once: the row is UNIQUE per (channel, post); a claim moves it to
//     dispatching in one guarded UPDATE, so two hub instances never both
//     call LinkedIn for it, and a second publish of one post is refused.
//   - A 429 or 503, or a connection that failed before sending, is retried
//     with a growing delay, at most marketingMaxAttempts times. Any other
//     failure, and a call whose outcome is unknown (sent, then no answer),
//     is failed at once and never retried: a post is never shared twice.
//     A failure is logged at error level and mailed to the account holder.
//   - The token lives 60 days with no refresh token: 7 days before, the
//     holder gets one mail with the one-click re-connect link; at the end
//     the channel is expired and its posts wait for the re-connect.
//   - A workspace is swept, and published to, only while allow-listed AND
//     switched on (T014).

const (
	marketingShareEvery   = 5 * time.Minute
	marketingMaxAttempts  = 3
	marketingRetryBase    = 10 * time.Minute
	marketingStuckAfter   = 15 * time.Minute
	marketingRemindBefore = 7 * 24 * time.Hour
)

// MarketingShareResult counts what one sweep did.
type MarketingShareResult struct {
	Baselined, Scheduled, Published, Retried, Failed, Reminded, Expired int
}

// RunMarketingShare runs SweepMarketingShare every marketingShareEvery until
// ctx ends; it returns at once while LinkedIn or the store is not set up.
func (s *Server) RunMarketingShare(ctx context.Context) {
	if s.o.MarketingLinkedIn == nil {
		return
	}
	if _, ok := s.o.Store.(store.Marketing); !ok {
		return
	}
	t := time.NewTicker(marketingShareEvery)
	defer t.Stop()
	for {
		s.SweepMarketingShare(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// SweepMarketingShare is one pass of the share sweep.
func (s *Server) SweepMarketingShare(ctx context.Context) MarketingShareResult {
	var res MarketingShareResult
	m := s.o.MarketingLinkedIn
	mk, ok := s.o.Store.(store.Marketing)
	if m == nil || !ok {
		return res
	}
	now := s.o.Now()
	stuck, err := mk.StuckMarketingPosts(ctx, now.Add(-marketingStuckAfter), now)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("marketing: stuck share sweep")
	}
	for _, p := range stuck {
		res.Failed++
		s.reportShareFailure(ctx, m, p.Tenant, p.ChannelID, p.SourceRef, p.LastError)
	}
	chs, err := mk.AutoMarketingChannels(ctx)
	if err != nil || len(chs) == 0 {
		if err != nil {
			s.o.Log.Error().Err(err).Msg("marketing: channel list")
		}
		return res
	}
	posts, ierr := marketing.FetchBlogIndex(ctx, m.httpClient(), m.AppURL)
	if ierr != nil {
		s.o.Log.Error().Str("err", ierr.Error()).Msg("marketing: blog index unreadable, nothing shared this pass")
	}
	for _, ch := range chs {
		if !s.marketingSweepable(ctx, ch.Tenant) || s.channelExpiry(ctx, m, mk, ch, now, &res) || ierr != nil {
			continue
		}
		s.shareChannel(ctx, m, mk, ch, posts, &res)
	}
	if res != (MarketingShareResult{}) {
		s.o.Log.Info().Interface("result", res).Msg("marketing: blog share sweep")
	}
	return res
}

func (m *MarketingLinkedIn) httpClient() *http.Client {
	if m.LinkedIn != nil && m.LinkedIn.HTTP != nil {
		return m.LinkedIn.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// marketingSweepable: the allow-list AND the workspace switch (T014 rule
// for sweeps), read again on every pass.
func (s *Server) marketingSweepable(ctx context.Context, tenant string) bool {
	if !s.marketingListed(tenant) || (s.o.DemoWorkspace != "" && tenant == s.o.DemoWorkspace) {
		return false
	}
	on, err := s.marketingEnabled(ctx, tenant)
	return err == nil && on
}

// channelExpiry sends the re-connect reminder once inside the last week and
// expires the channel at the end; true = do not share with it now.
func (s *Server) channelExpiry(ctx context.Context, m *MarketingLinkedIn, mk store.Marketing, ch store.MarketingChannel, now time.Time, res *MarketingShareResult) bool {
	if ch.ExpiresAt == nil {
		return false
	}
	if !now.Before(*ch.ExpiresAt) {
		if err := mk.ExpireMarketingChannel(ctx, ch.Tenant, ch.ID, now); err != nil {
			s.o.Log.Error().Err(err).Str("channel", ch.ID).Msg("marketing: expire channel")
			return true
		}
		res.Expired++
		s.mailHolder(ctx, m, ch.Tenant, ch.DelegatedBy, "Your LinkedIn connection has ended: blog posts wait",
			"The LinkedIn connection of workspace "+ch.Tenant+" ended on "+ch.ExpiresAt.UTC().Format("2006-01-02")+
				". The blog posts you published that are waiting are shared as soon as you connect again:\n\n"+m.ConnectLink(ch.Tenant)+"\n")
		return true
	}
	if now.Add(marketingRemindBefore).Before(*ch.ExpiresAt) || ch.RemindedAt != nil {
		return false
	}
	won, err := mk.MarkMarketingReminded(ctx, ch.Tenant, ch.ID, now)
	if err != nil || !won {
		return false
	}
	res.Reminded++
	s.mailHolder(ctx, m, ch.Tenant, ch.DelegatedBy, "Renew the LinkedIn connection of spool-hub (one click)",
		"LinkedIn ends the connection of workspace "+ch.Tenant+" on "+ch.ExpiresAt.UTC().Format("2006-01-02")+
			" (LinkedIn allows 60 days). Renew it with one click; sign in to spool-hub first if it asks:\n\n"+
			m.ConnectLink(ch.Tenant)+"\n\nUntil then, the blog posts you publish are still shared on your profile.\n")
	return false
}

// shareChannel baselines a fresh channel, then claims and dispatches the
// due posts: only rows the owner's publish made, waiting for a retry. It
// never schedules a post (SPL-40).
func (s *Server) shareChannel(ctx context.Context, m *MarketingLinkedIn, mk store.Marketing, ch store.MarketingChannel, posts []marketing.BlogPost, res *MarketingShareResult) {
	now := s.o.Now()
	if ch.BaselineAt == nil {
		refs := make([]string, len(posts))
		for i, p := range posts {
			refs[i] = p.ID
		}
		if err := mk.BaselineMarketingPosts(ctx, ch.Tenant, ch.ID, refs, now); err != nil {
			s.o.Log.Error().Err(err).Str("channel", ch.ID).Msg("marketing: baseline")
			return
		}
		res.Baselined += len(refs)
		return
	}
	due, err := mk.ClaimMarketingPosts(ctx, ch.Tenant, ch.ID, now)
	if err != nil || len(due) == 0 {
		return
	}
	s.dispatchDue(ctx, m, mk, ch, due, blogByID(posts), res)
}

func blogByID(posts []marketing.BlogPost) map[string]marketing.BlogPost {
	byID := make(map[string]marketing.BlogPost, len(posts))
	for _, p := range posts {
		byID[p.ID] = p
	}
	return byID
}

// Why an owner's publish was refused (PublishMarketingPost).
var (
	ErrMarketingNotOwner  = errors.New("only the workspace owner publishes to LinkedIn")
	ErrMarketingNoChannel = errors.New("the workspace owner has no connected LinkedIn account")
	ErrMarketingNoPost    = errors.New("the post is not in the live blog index")
	ErrMarketingRecorded  = errors.New("the post is already published, or recorded for LinkedIn")
	ErrMarketingOff       = errors.New("marketing is not on in this workspace")
	ErrMarketingNoLinked  = errors.New("LinkedIn is not configured on this hub")
)

// PublishMarketingPost shares the live blog post postID on every active
// LinkedIn channel of tenant that hum connected, once each; only the
// workspace owner (rbac TenantOwner) may. The share goes through the same
// claim and dispatch as the sweep's retries.
func (s *Server) PublishMarketingPost(ctx context.Context, tenant, hum, postID string) (MarketingShareResult, error) {
	var res MarketingShareResult
	m := s.o.MarketingLinkedIn
	mk, ok := s.o.Store.(store.Marketing)
	if m == nil || !ok {
		return res, ErrMarketingNoLinked
	}
	if !s.marketingSweepable(ctx, tenant) {
		return res, ErrMarketingOff
	}
	if a, err := s.access(ctx, hum, tenant); hum == "" || err != nil || !a.TenantOwner {
		return res, ErrMarketingNotOwner
	}
	chs, err := s.ownerChannels(ctx, mk, tenant, hum)
	if err != nil {
		return res, err
	}
	if len(chs) == 0 {
		return res, ErrMarketingNoChannel
	}
	posts, err := marketing.FetchBlogIndex(ctx, m.httpClient(), m.AppURL)
	if err != nil {
		return res, err
	}
	byID := blogByID(posts)
	bp, live := byID[postID]
	if !live {
		return res, ErrMarketingNoPost
	}
	recorded := 0
	for _, ch := range chs {
		now := s.o.Now()
		made, err := mk.ScheduleMarketingPost(ctx, store.MarketingPost{Tenant: tenant, ChannelID: ch.ID,
			SourceType: store.MarketingSourceBlog, SourceRef: postID, ContentText: marketing.BlogArticle(m.AppURL, bp, nil).Commentary}, now)
		if err != nil {
			return res, err
		}
		if !made {
			recorded++
			continue
		}
		res.Scheduled++
		s.o.Log.Info().Str("tenant", tenant).Str("channel", ch.ID).Str("post", postID).Str("by", hum).Msg("marketing: the owner publishes a blog post on LinkedIn")
		if due, err := mk.ClaimMarketingPosts(ctx, tenant, ch.ID, now); err == nil && len(due) > 0 {
			s.dispatchDue(ctx, m, mk, ch, due, byID, &res)
		}
	}
	if recorded == len(chs) {
		return res, ErrMarketingRecorded
	}
	return res, nil
}

// ownerChannels: tenant's active LinkedIn channels that hum connected.
func (s *Server) ownerChannels(ctx context.Context, mk store.Marketing, tenant, hum string) ([]store.MarketingChannel, error) {
	all, err := mk.MarketingChannels(ctx, tenant)
	if err != nil {
		return nil, err
	}
	var out []store.MarketingChannel
	for _, ch := range all {
		if ch.Platform == "linkedin" && ch.Status == store.MarketingActive && ch.DelegatedBy == hum {
			out = append(out, ch)
		}
	}
	return out, nil
}

// POST /v1/marketing/posts/{id}/publish: the owner shares one live blog post.
func (s *Server) handleMarketingPublish(w http.ResponseWriter, r *http.Request, tenant string) {
	w.Header().Set("Cache-Control", "no-store")
	hum, _ := s.memberID(r, tenant)
	res, err := s.PublishMarketingPost(r.Context(), tenant, hum, r.PathValue("id"))
	switch {
	case errors.Is(err, ErrMarketingNotOwner):
		writeForbidden(w, permTenantOwner, err.Error())
	case errors.Is(err, ErrMarketingNoChannel), errors.Is(err, ErrMarketingNoPost), errors.Is(err, ErrMarketingOff):
		writeErr(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, ErrMarketingRecorded):
		writeErr(w, http.StatusConflict, "already_recorded", err.Error())
	case errors.Is(err, ErrMarketingNoLinked):
		writeErr(w, http.StatusServiceUnavailable, "linkedin_off", err.Error())
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "the publish failed before LinkedIn was called")
	default:
		writeJSON(w, http.StatusOK, map[string]any{"post": r.PathValue("id"), "scheduled": res.Scheduled,
			"published": res.Published, "retried": res.Retried, "failed": res.Failed})
	}
}

// routeMarketingShare registers the owner's publish (from routeMarketing).
func (s *Server) routeMarketingShare(mux *http.ServeMux) {
	s.marketingRoute(mux, "POST /v1/marketing/posts/{id}/publish", s.handleMarketingPublish)
}

// dispatchDue opens the token once and shares each claimed post.
func (s *Server) dispatchDue(ctx context.Context, m *MarketingLinkedIn, mk store.Marketing, ch store.MarketingChannel, due []store.MarketingPost, byID map[string]marketing.BlogPost, res *MarketingShareResult) {
	tok, err := s.openChannelToken(ctx, m, mk, ch)
	refused := false
	for _, p := range due {
		var out store.MarketingOutcome
		unauthorized := false
		bp, live := byID[p.SourceRef]
		switch {
		case refused: // LinkedIn refused the token: the rest wait for the re-connect, unsent
			out = store.MarketingOutcome{Retry: true, RetryAt: s.o.Now(), Error: "waiting for the LinkedIn re-connect"}
		case err != nil: // nothing was sent: a KMS or store failure is retried
			out = retryOrFail(p.Attempts, errors.New("token unavailable: "+err.Error()), s.o.Now())
		case !live:
			out = store.MarketingOutcome{Error: "the post is no longer in the live blog index"}
		default:
			out, unauthorized = s.shareOne(ctx, m, ch, tok, bp, p.Attempts)
		}
		s.settleShare(ctx, mk, ch, p, out, res)
		if unauthorized && !refused {
			refused = true
			s.linkedInRefused(ctx, m, mk, ch)
		}
	}
}

func (s *Server) openChannelToken(ctx context.Context, m *MarketingLinkedIn, mk store.Marketing, ch store.MarketingChannel) (marketing.Plaintext, error) {
	sealed, err := mk.MarketingToken(ctx, ch.Tenant, ch.ID)
	if err != nil {
		return marketing.Plaintext{}, err
	}
	return m.Sealer.Open(ctx, sealed.Ciphertext)
}

// shareOne uploads the picture (best effort) and posts the article.
// unauthorized: LinkedIn answered 401 (revoked, or expired early); the post
// waits for the re-connect and the channel is expired.
func (s *Server) shareOne(ctx context.Context, m *MarketingLinkedIn, ch store.MarketingChannel, tok marketing.Plaintext, bp marketing.BlogPost, attempt int) (out store.MarketingOutcome, unauthorized bool) {
	thumb := ""
	if pic, err := marketing.FetchBlogPicture(ctx, m.httpClient(), m.AppURL, bp); err != nil {
		s.o.Log.Warn().Str("post", bp.ID).Str("err", err.Error()).Msg("marketing: no picture for the share")
	} else if pic != nil {
		if thumb, err = m.LinkedIn.UploadImage(ctx, tok, ch.AccountRef, pic); err != nil {
			s.o.Log.Warn().Str("post", bp.ID).Str("err", err.Error()).Msg("marketing: picture upload failed, sharing without it")
			thumb = ""
		}
	}
	id, err := m.LinkedIn.Share(ctx, tok, ch.AccountRef, marketing.BlogArticle(m.AppURL, bp, nil), thumb)
	switch {
	case err == nil:
		return store.MarketingOutcome{Published: true, PlatformPostID: id}, false
	case marketing.Unauthorized(err): // nothing was posted: it waits for the re-connect
		return store.MarketingOutcome{Retry: true, RetryAt: s.o.Now(), Error: err.Error()}, true
	case !marketing.Retryable(err):
		return store.MarketingOutcome{Error: err.Error()}, false
	}
	return retryOrFail(attempt, err, s.o.Now()), false
}

// linkedInRefused expires the channel after a 401 and asks the holder to
// connect again; its scheduled posts wait for that.
func (s *Server) linkedInRefused(ctx context.Context, m *MarketingLinkedIn, mk store.Marketing, ch store.MarketingChannel) {
	if err := mk.ExpireMarketingChannel(ctx, ch.Tenant, ch.ID, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("channel", ch.ID).Msg("marketing: expire channel after 401")
	}
	s.mailHolder(ctx, m, ch.Tenant, ch.DelegatedBy, "LinkedIn refused the spool-hub connection: connect again",
		"LinkedIn no longer accepts the connection of workspace "+ch.Tenant+". The blog posts you published wait and are shared once you connect again:\n\n"+m.ConnectLink(ch.Tenant)+"\n")
}

func retryOrFail(attempt int, err error, now time.Time) store.MarketingOutcome {
	if attempt >= marketingMaxAttempts {
		return store.MarketingOutcome{Error: err.Error() + " (after " + strconv.Itoa(attempt) + " attempts)"}
	}
	return store.MarketingOutcome{Retry: true, RetryAt: now.Add(time.Duration(attempt) * marketingRetryBase), Error: err.Error()}
}

// settleShare records the outcome, then counts, logs and reports it.
func (s *Server) settleShare(ctx context.Context, mk store.Marketing, ch store.MarketingChannel, p store.MarketingPost, out store.MarketingOutcome, res *MarketingShareResult) {
	if err := mk.FinishMarketingPost(ctx, ch.Tenant, p.ID, out, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("post", p.SourceRef).Msg("marketing: settle share")
		return
	}
	switch {
	case out.Published:
		res.Published++
		s.o.Log.Info().Str("tenant", ch.Tenant).Str("channel", ch.ID).Str("post", p.SourceRef).Str("linkedin", out.PlatformPostID).Msg("marketing: blog post shared on LinkedIn")
	case out.Retry:
		res.Retried++
		s.o.Log.Warn().Str("channel", ch.ID).Str("post", p.SourceRef).Int("attempt", p.Attempts).Str("err", out.Error).Msg("marketing: share will be retried")
	default:
		res.Failed++
		s.reportShareFailure(ctx, s.o.MarketingLinkedIn, ch.Tenant, ch.ID, p.SourceRef, out.Error)
	}
}

// reportShareFailure logs a final failure at error level and mails the holder.
func (s *Server) reportShareFailure(ctx context.Context, m *MarketingLinkedIn, tenant, channelID, postRef, why string) {
	s.o.Log.Error().Str("tenant", tenant).Str("channel", channelID).Str("post", postRef).Str("err", why).Msg("marketing: blog share FAILED, not retried")
	mk, ok := s.o.Store.(store.Marketing)
	if !ok {
		return
	}
	chs, err := mk.MarketingChannels(ctx, tenant)
	if err != nil {
		return
	}
	for _, ch := range chs {
		if ch.ID == channelID {
			s.mailHolder(ctx, m, tenant, ch.DelegatedBy, "A blog post was not shared on LinkedIn",
				"spool-hub could not share the blog post "+marketing.BlogPostURL(m.AppURL, postRef)+" on LinkedIn, and will not retry it, so it is never posted twice.\n\nReason: "+why+"\n\nShare it by hand if you want it on your profile.\n")
		}
	}
}

// mailHolder mails the member who connected the channel; a missing relay or
// address is a log line, never a failure of the sweep.
func (s *Server) mailHolder(ctx context.Context, m *MarketingLinkedIn, tenant, hum, subject, body string) {
	if m.Mail == nil {
		s.o.Log.Warn().Str("tenant", tenant).Str("member", hum).Str("subject", subject).Msg("marketing: no mail relay, holder not mailed")
		return
	}
	dir, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		return
	}
	members, err := dir.ListMembers(ctx, tenant)
	if err != nil {
		return
	}
	for _, mem := range members {
		if mem.HumanID == hum && mem.Email != "" {
			if err := m.Mail(ctx, mem.Email, subject, body); err != nil {
				s.o.Log.Error().Err(err).Str("member", hum).Msg("marketing: holder mail failed")
			}
			return
		}
	}
}

package hub

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The embed's abuse limits (specs/121 section 6, T105). Each limit is a
// counter in quota_counts (rdb 0127), taken BEFORE the work it guards, so a
// refused unit writes no visitor and no message:
//
//	new visitors per client IP   an hour, a UTC day   429 embed_visitors
//	posts per visitor            a minute, a UTC day  429 embed_quota
//	message size                 (embed_visitor.go)   413 too_large
//	agent turns per visitor      a UTC day            429 embed_quota
//	live visitors per embed      at once              503 embed_full
//
// The client IP is 017 FR-SEC-006's (the edge guard's TrustedProxyHops); the
// hub keeps only its salted hash (embedIPHash). A refused request on a
// limit, a failed challenge or a filled honeypot is a hit of that address:
// ChallengeAfterHits hits in HitsWindow make every post solve the challenge
// (embed_pow.go), BanAfterHits ban the address for BanFor (demo_bans, rdb
// 0130, banned_by store.EmbedAutoBanBy). A banned visitor or address is
// refused 403 embed_banned. Not here: the spend cap (T305).

// EmbedLimits are cnf env.hub.embed's limits (config.Hub Embed*). A field
// <= 0 is its spec default, never unlimited.
type EmbedLimits struct {
	VisitorsPerIPHour, VisitorsPerIPDay int
	PostsPerMinute, PostsPerDay         int
	TurnsPerDay                         int
	LiveVisitorsMax                     int
	ChallengeAfterHits, BanAfterHits    int
	HitsWindow, BanFor                  time.Duration
	// PowBits is the proof-of-work's leading zero bits (embed_pow.go).
	PowBits int
}

// The refusal tokens of section 6.
const (
	TokenEmbedVisitors = "embed_visitors"
	TokenEmbedQuota    = "embed_quota"
	TokenEmbedFull     = "embed_full"
	TokenEmbedBanned   = "embed_banned"
)

// The embed counter kinds (rdb 0127 kind; store.EmbedQuotaKindPrefix). A day
// and an hour (or minute) window both start at 00:00, so each window has its
// own kind: one shared kind would make the two one counter at midnight.
const (
	embedKindVisitorDay  = "embed_visitor"
	embedKindVisitorHour = "embed_visitor_hour"
	embedKindPostDay     = "embed_post"
	embedKindPostMinute  = "embed_post_min"
	embedKindTurnDay     = "embed_turn"
)

// embedIPPeriod is how long one ip_hash salt lives: rotated weekly, so a
// stored hash links one address's visits for a week at most.
const embedIPPeriod = 7 * 24 * time.Hour

// embedLimits is s.o.EmbedLimits with every unset field at its default.
func (s *Server) embedLimits() EmbedLimits {
	l := s.o.EmbedLimits
	for _, f := range []struct {
		v   *int
		def int
	}{{&l.VisitorsPerIPHour, 5}, {&l.VisitorsPerIPDay, 20}, {&l.PostsPerMinute, 6}, {&l.PostsPerDay, 100},
		{&l.TurnsPerDay, 10}, {&l.LiveVisitorsMax, 200}, {&l.ChallengeAfterHits, 3}, {&l.BanAfterHits, 5},
		{&l.PowBits, DefaultEmbedPowBits}} {
		if *f.v <= 0 {
			*f.v = f.def
		}
	}
	if l.HitsWindow <= 0 {
		l.HitsWindow = 24 * time.Hour
	}
	if l.BanFor <= 0 {
		l.BanFor = 24 * time.Hour
	}
	return l
}

// embedIPHash is the salted sha256 of the request's client IP in tenant for
// the salt period back periods before now's (0 = the current one). The salt
// is the workspace and the period: one address hashes differently in each
// workspace and each week, and no raw address is ever stored or logged.
func (s *Server) embedIPHash(r *http.Request, tenant string, now time.Time, back int) []byte {
	period := now.Unix()/int64(embedIPPeriod/time.Second) - int64(back)
	salt := sha256.Sum256([]byte("spool-embed-ip|v1|" + tenant + "|" + strconv.FormatInt(period, 10)))
	sum := sha256.Sum256(append(salt[:], s.edge.ClientIP(r)...))
	return sum[:]
}

// embedIPBanKeys are the ban keys of the request's address, this salt period
// and the last, so a ban outlives a salt rotation.
func (s *Server) embedIPBanKeys(r *http.Request, tenant string, now time.Time) []string {
	return []string{store.EmbedBanKey("ip", hex.EncodeToString(s.embedIPHash(r, tenant, now, 0))),
		store.EmbedBanKey("ip", hex.EncodeToString(s.embedIPHash(r, tenant, now, 1)))}
}

// embedAbuse is the store's abuse side; false after a 500 (fails closed: a
// store that cannot count admits nobody).
func embedAbuse(w http.ResponseWriter, es store.EmbedVisitors) (store.EmbedAbuse, bool) {
	ab, ok := es.(store.EmbedAbuse)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "this store cannot count embed limits")
	}
	return ab, ok
}

// embedAdmit gates a mint of embed in tenant, before anything is written:
// a banned address (403), a full embed (503), then one unit of the address's
// hour and day (429, all or none). It returns the address's ip_hash for the
// new visitor row; false after answering.
func (s *Server) embedAdmit(w http.ResponseWriter, r *http.Request, es store.EmbedVisitors, tenant, embed string) ([]byte, bool) {
	ab, ok := embedAbuse(w, es)
	if !ok {
		return nil, false
	}
	ctx, now, lim := r.Context(), s.o.Now().UTC(), s.embedLimits()
	sc := store.EmbedScope{TenantID: tenant}
	if !s.embedNotBanned(w, r, ab, sc, nil, now) {
		return nil, false
	}
	live, err := ab.EmbedLiveVisitors(ctx, tenant, embed, now)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed visitors not counted", err)
		return nil, false
	}
	if live >= lim.LiveVisitorsMax {
		writeErr(w, http.StatusServiceUnavailable, TokenEmbedFull, "this chat is full, try again later")
		return nil, false
	}
	ip := s.embedIPHash(r, tenant, now, 0)
	key := store.EmbedIPKey(ip)
	refused, err := ab.TakeEmbedQuotas(ctx, sc, []store.EmbedTake{
		{Key: key, Kind: embedKindVisitorHour, Window: now.Truncate(time.Hour), Limit: lim.VisitorsPerIPHour},
		{Key: key, Kind: embedKindVisitorDay, Window: now.Truncate(24 * time.Hour), Limit: lim.VisitorsPerIPDay}})
	switch {
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed limits unavailable", err)
		return nil, false
	case refused >= 0:
		s.embedHit(ctx, ab, sc, ip, now)
		writeErr(w, http.StatusTooManyRequests, TokenEmbedVisitors, "this address starts at most "+
			strconv.Itoa(lim.VisitorsPerIPHour)+" chats an hour and "+strconv.Itoa(lim.VisitorsPerIPDay)+" a day")
		return nil, false
	}
	return ip, true
}

// embedNotBanned refuses 403 embed_banned when the request's address, or
// the visitor (v non-nil), is banned in sc's workspace.
func (s *Server) embedNotBanned(w http.ResponseWriter, r *http.Request, ab store.EmbedAbuse, sc store.EmbedScope,
	v *store.EmbedVisitor, now time.Time) bool {
	keys := s.embedIPBanKeys(r, sc.TenantID, now)
	if v != nil {
		keys = append(keys, store.EmbedBanKey("visitor", v.VisitorID))
	}
	banned, err := ab.EmbedBanned(r.Context(), sc, keys, now.Add(-s.embedLimits().BanFor))
	switch {
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed ban list unavailable", err)
		return false
	case banned:
		writeErr(w, http.StatusForbidden, TokenEmbedBanned, "this chat is closed to you")
		return false
	}
	return true
}

// embedHit records one hit of the address ip and bans it once it holds
// BanAfterHits in HitsWindow. Best effort: a store error is logged, the
// request was refused anyway.
func (s *Server) embedHit(ctx context.Context, ab store.EmbedAbuse, sc store.EmbedScope, ip []byte, now time.Time) {
	lim := s.embedLimits()
	n, err := ab.EmbedHit(ctx, sc, store.EmbedIPKey(ip), now, now.Add(-lim.HitsWindow))
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", sc.TenantID).Msg("embed hit not recorded")
		return
	}
	if n < lim.BanAfterHits {
		return
	}
	if err := ab.BanEmbedKey(ctx, sc, store.EmbedBanKey("ip", hex.EncodeToString(ip)), store.EmbedAutoBanBy, now); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", sc.TenantID).Msg("embed ban not stored")
		return
	}
	s.o.Log.Info().Str("tenant", sc.TenantID).Int("hits", n).Msg("embed address banned")
}

// embedPostGate gates one visitor post, before it is built or stored: a
// banned visitor or address (403), the honeypot and the challenge
// (embed_pow.go), then one unit of the visitor's minute and day (429, all
// or none). false after answering.
func (s *Server) embedPostGate(w http.ResponseWriter, r *http.Request, es store.EmbedVisitors, v store.EmbedVisitor, in embedPostIn) bool {
	ab, ok := embedAbuse(w, es)
	if !ok {
		return false
	}
	ctx, now, lim := r.Context(), s.o.Now().UTC(), s.embedLimits()
	sc := store.EmbedScope{TenantID: v.TenantID, ChannelID: v.ChannelID}
	if !s.embedNotBanned(w, r, ab, sc, &v, now) || !s.embedChallenge(w, r, ab, sc, v, in, now) {
		return false
	}
	refused, err := ab.TakeEmbedQuotas(ctx, sc, []store.EmbedTake{
		{Key: v.HumanID, Kind: embedKindPostMinute, Window: now.Truncate(time.Minute), Limit: lim.PostsPerMinute},
		{Key: v.HumanID, Kind: embedKindPostDay, Window: now.Truncate(24 * time.Hour), Limit: lim.PostsPerDay}})
	switch {
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed limits unavailable", err)
		return false
	case refused >= 0:
		s.embedHit(ctx, ab, sc, s.embedIPHash(r, v.TenantID, now, 0), now)
		writeErr(w, http.StatusTooManyRequests, TokenEmbedQuota, "a visitor posts at most "+
			strconv.Itoa(lim.PostsPerMinute)+" messages a minute and "+strconv.Itoa(lim.PostsPerDay)+" a day")
		return false
	}
	return true
}

// EmbedTurn takes one agent turn of v's UTC day, before the turn is built,
// as the (token, status, detail) triple of the hub's checks: "" = go on. The
// sales agent's dispatch (T306) calls it; a refused turn leaves the post
// stored, for the owner to answer. Fails closed like demoAgentTurn.
func (s *Server) EmbedTurn(ctx context.Context, v store.EmbedVisitor) (string, int, string) {
	ab, ok := s.o.Store.(store.EmbedAbuse)
	if !ok {
		return "internal", http.StatusInternalServerError, "this store cannot count embed limits"
	}
	lim := s.embedLimits()
	refused, err := ab.TakeEmbedQuotas(ctx, store.EmbedScope{TenantID: v.TenantID, ChannelID: v.ChannelID},
		[]store.EmbedTake{{Key: v.HumanID, Kind: embedKindTurnDay, Window: s.o.Now().UTC().Truncate(24 * time.Hour), Limit: lim.TurnsPerDay}})
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", v.TenantID).Msg("embed turn quota")
		return "internal", http.StatusInternalServerError, "embed limits unavailable"
	case refused >= 0:
		return TokenEmbedQuota, http.StatusTooManyRequests, "a visitor gets at most " + strconv.Itoa(lim.TurnsPerDay) + " agent answers a day"
	}
	return "", 0, ""
}

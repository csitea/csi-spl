package hub

import (
	"crypto/sha256"
	"encoding/hex"
	"math/bits"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The embed's bot gate (specs/121 section 6, T105): a self-hosted
// proof-of-work plus a honeypot field, on the visitor's FIRST post (not on
// the page load), and on every post of a repeat offender (ChallengeAfterHits
// hits of its address in HitsWindow). A signed-in customer's user (T205)
// never needs the proof. No outside service sees the visitor (Q-T1 = A).
//
//	GET /v1/embed/{embed_id}/challenge   {"challenge", "bits", "required"}
//
// The iframe finds a nonce such that
//
//	sha256(challenge + "." + hex(sha256(body)) + "." + nonce)
//
// starts with bits zero bits, and sends it with the post as
// {"body", "pow": {"challenge", "nonce"}}. The challenge is
// "v1.<visitor_id>.<unix minute>", accepted for embedPowTTL: it binds the
// proof to the visitor, the body and the time, so one proof buys one post of
// one text, and the post limits cap a replay of it. The honeypot is the
// "website" field: hidden from a person by the iframe, filled by a form bot.
// A filled honeypot or a wrong proof is a hit of the address (embed_abuse.go).

// DefaultEmbedPowBits is the work of one proof: 2^16 hashes on average,
// well under a second in a browser.
const DefaultEmbedPowBits = 16

const (
	// embedPowTTL is how long a challenge is accepted.
	EmbedPowTTL = 10 * time.Minute  // Time-to-live for embed proof-of-work challenges
	// embedNonceMax is the longest nonce the hub hashes.
	embedNonceMax = 64
	// TokenEmbedChallenge: the post needs a (new) proof of work (428), or
	// its honeypot was filled (403).
	TokenEmbedChallenge = "embed_challenge"
)

// embedPow is a post's proof of work.
type embedPow struct {
	Challenge string `json:"challenge"`
	Nonce     string `json:"nonce"`
}

// embedPostIn is the body of a visitor post (embed_visitor.go).
type embedPostIn struct {
	Body    string    `json:"body"`
	Pow     *embedPow `json:"pow,omitempty"`
	Website string    `json:"website,omitempty"`
}

func (s *Server) routeEmbedPow(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/embed/{embed_id}/challenge", s.handleEmbedChallenge)
}

// embedChallengeFor is v's challenge at now.
func embedChallengeFor(v store.EmbedVisitor, now time.Time) string {
	return "v1." + v.VisitorID + "." + strconv.FormatInt(now.Unix()/60, 10)
}

// embedPowValid reports whether p is a live proof of v's for body: its
// challenge is v's, at most embedPowTTL old and not ahead of now, and its
// hash starts with bits zero bits.
func embedPowValid(p *embedPow, v store.EmbedVisitor, body string, bitsWant int, now time.Time) bool {
	if p == nil || p.Nonce == "" || len(p.Nonce) > embedNonceMax {
		return false
	}
	rest, ok := strings.CutPrefix(p.Challenge, "v1."+v.VisitorID+".")
	if !ok {
		return false
	}
	minute, err := strconv.ParseInt(rest, 10, 64)
	nowMin := now.Unix() / 60
	if err != nil || minute > nowMin || nowMin-minute > int64(EmbedPowTTL/time.Minute) {
		return false
	}
	bodySum := sha256.Sum256([]byte(body))
	sum := sha256.Sum256([]byte(p.Challenge + "." + hex.EncodeToString(bodySum[:]) + "." + p.Nonce))
	return leadingZeroBits(sum[:]) >= bitsWant
}

// leadingZeroBits counts b's leading zero bits.
func leadingZeroBits(b []byte) int {
	n := 0
	for _, c := range b {
		if c != 0 {
			return n + bits.LeadingZeros8(c)
		}
		n += 8
	}
	return n
}

// embedSignedIn reports whether v is a signed-in customer's user (T205):
// store.SignInEmbedVisitor derives those visitor ids as uuid v5, while an
// anonymous visitor's is gen_random_uuid's v4. The hub assigns every id, so
// a visitor cannot pick its version.
func embedSignedIn(v store.EmbedVisitor) bool {
	id, err := uuid.Parse(v.VisitorID)
	return err == nil && id.Version() == 5
}

// embedChallengeNeeded reports whether v's next post must carry a proof:
// its first post, or any post once its address is a repeat offender. Never
// for a signed-in customer's user (owner, msg 62a2aac3): the customer's
// server vouched for it; the honeypot, bans and limits still apply.
func (s *Server) embedChallengeNeeded(r *http.Request, ab store.EmbedAbuse, sc store.EmbedScope, v store.EmbedVisitor,
	now time.Time) (bool, error) {
	if embedSignedIn(v) {
		return false, nil
	}
	posted, err := ab.EmbedVisitorPosted(r.Context(), v)
	if err != nil || !posted {
		return true, err
	}
	lim := s.embedLimits()
	hits, err := ab.EmbedHits(r.Context(), sc, store.EmbedIPKey(s.embedIPHash(r, v.TenantID, now, 0)), now.Add(-lim.HitsWindow))
	return hits >= lim.ChallengeAfterHits, err
}

// embedChallenge is the bot gate of one post: the honeypot (403), then the
// proof when one is needed (428 with a fresh challenge). false after
// answering.
func (s *Server) embedChallenge(w http.ResponseWriter, r *http.Request, ab store.EmbedAbuse, sc store.EmbedScope,
	v store.EmbedVisitor, in embedPostIn, now time.Time) bool {
	if in.Website != "" {
		s.embedHit(r.Context(), ab, sc, s.embedIPHash(r, v.TenantID, now, 0), now)
		writeErr(w, http.StatusForbidden, TokenEmbedChallenge, "this post was refused")
		return false
	}
	need, err := s.embedChallengeNeeded(r, ab, sc, v, now)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed challenge unavailable", err)
		return false
	}
	bitsWant := s.embedLimits().PowBits
	if !need || embedPowValid(in.Pow, v, in.Body, bitsWant, now) {
		return true
	}
	if in.Pow != nil {
		s.embedHit(r.Context(), ab, sc, s.embedIPHash(r, v.TenantID, now, 0), now)
	}
	writeJSON(w, http.StatusPreconditionRequired, map[string]any{"error": TokenEmbedChallenge,
		"detail": "solve the challenge and send the post again", "challenge": embedChallengeFor(v, now), "bits": bitsWant})
	return false
}

// handleEmbedChallenge hands the visitor a challenge, and whether its next
// post needs it.
func (s *Server) handleEmbedChallenge(w http.ResponseWriter, r *http.Request) {
	es, v, ok := s.embedVisitor(w, r)
	if !ok {
		return
	}
	ab, ok := embedAbuse(w, es)
	if !ok {
		return
	}
	now := s.o.Now().UTC()
	need, err := s.embedChallengeNeeded(r, ab, store.EmbedScope{TenantID: v.TenantID, ChannelID: v.ChannelID}, v, now)
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "embed challenge unavailable", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge": embedChallengeFor(v, now), "bits": s.embedLimits().PowBits, "required": need})
}

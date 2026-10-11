package hub

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"net/http"
	"net/mail"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/invitemail"
	spoolmail "github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The e-mail relink of an embed visitor (specs/121 4.1, T206). After the
// first answer in its channel the visitor may leave an e-mail, whose purpose
// the chat page shows beside the field (T202); from a new device, or after
// its storage was cleared, it asks for a link, and the hub mails one that
// binds a NEW token to the same visitor and channel:
//
//	PUT  /v1/embed/{embed_id}/visitor/email   bearer: set ("" clears) the address (204)
//	POST /v1/embed/{embed_id}/relink          no token: mail a link to that address (202)
//	POST /v1/embed/{embed_id}/relink/redeem   no token: the link's code -> a new token (201)
//	GET  /v1/tenant/embeds/{embed_id}/visitor-emails   the workspace OWNER reads the addresses
//
// The link is <return_url or the embed's first allowed origin>#spool-relink=<code>:
// it opens the customer's page, whose loader hands the code to the iframe
// (T202), and a fragment never reaches a server log. The code is
// v1 | visitor id | expiry | HMAC-SHA256 keyed by the visitor's CURRENT
// token_hash, so nothing is stored for it: the redeem swaps the token_hash
// (store.RelinkEmbedVisitor, compare-and-set), after which the same code no
// longer verifies. Used, expired, forged or unknown: one answer, 410. A
// blocked or swept visitor (token expired) gets no link and no new token.
// One token per visitor (rdb 0169): the relink signs the old device out.
//
// The ask answers 202 whether or not the address is known, so it tells no
// one which addresses left a chat; at most embedRelinkPerHour mails per
// visitor per hour (quota_counts). The address is in no visitor answer and
// in no member list: only the owner route shows it. Logs carry
// mail.Digest(address), never the address or the link.
// Off (cnf env.hub.embed.enabled) the visitor routes answer as an unknown
// path, as T104's; the owner route answers as T203's.

const (
	// embedRelinkTTL is the link's life (spec 4.1: 15 minutes).
	embedRelinkTTL = 15 * time.Minute
	// embedRelinkPerHour caps the mails per visitor per hour.
	embedRelinkPerHour = 3
	// quotaEmbedRelink is the quota_counts kind of those mails.
	quotaEmbedRelink = "embed_relink"
	// embedRelinkFragment names the code in the link's fragment.
	embedRelinkFragment = "spool-relink"
	// embedEmailMax is rdb 0169's email length check.
	embedEmailMax = 320
	// ErrEmbedRelinkGone: the link is used, expired, forged or unknown (410).
	ErrEmbedRelinkGone = "embed_relink"
	// ErrEmbedNoAnswer: the address is offered after the first answer (409).
	ErrEmbedNoAnswer = "embed_no_answer"
)

// relinkV1 is the code's version byte; relinkLen its length in bytes:
// version, visitor uuid, expiry (unix seconds), mac.
const (
	relinkV1  = 1
	relinkLen = 1 + 16 + 8 + sha256.Size
)

// EmbedRelinkMailer sends the relink mail with link to the address to
// (invitemail.SendEmbedRelink), in invitemail.RelinkLocale(ctx). nil = no relay: the ask still answers 202
// and mails nothing (logged).
type EmbedRelinkMailer func(ctx context.Context, to, link string, ttl time.Duration) error

func (s *Server) routeEmbedRelink(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/embed/{embed_id}/visitor/email", s.handleEmbedEmail)
	mux.HandleFunc("POST /v1/embed/{embed_id}/relink", s.handleEmbedRelinkAsk)
	mux.HandleFunc("POST /v1/embed/{embed_id}/relink/redeem", s.handleEmbedRelinkRedeem)
	mux.HandleFunc("GET /v1/tenant/embeds/{embed_id}/visitor-emails", s.handleEmbedVisitorEmails)
}

// relinkStore is the relink store when the embed is on for this request's
// embed id, else nil after answering 404 as an unknown path does.
func (s *Server) relinkStore(w http.ResponseWriter, r *http.Request) (store.EmbedVisitors, store.EmbedRelinks) {
	rs, ok := s.o.Store.(store.EmbedRelinks)
	if !ok {
		http.NotFound(w, r)
		return nil, nil
	}
	es := s.embedStore(w, r)
	if es == nil {
		return nil, nil
	}
	return es, rs
}

// normalizeEmbedEmail is the address as stored: trimmed, lower case, one
// bare addr-spec (no display name) of at most 320 bytes; "" stays "".
func normalizeEmbedEmail(raw string) (string, error) {
	e := strings.ToLower(strings.TrimSpace(raw))
	if e == "" {
		return "", nil
	}
	a, err := mail.ParseAddress(e)
	if err != nil || a.Address != e || len(e) > embedEmailMax || !strings.Contains(e, "@") {
		return "", errors.New("email must be one address like name@example.com")
	}
	return e, nil
}

// handleEmbedEmail sets the visitor's relink address, once its channel holds
// an answer (a line it did not write); "" clears it at any time.
func (s *Server) handleEmbedEmail(w http.ResponseWriter, r *http.Request) {
	_, rs := s.relinkStore(w, r)
	if rs == nil {
		return
	}
	es, v, ok := s.embedVisitor(w, r)
	if !ok {
		return
	}
	var in struct {
		Email string `json:"email"`
	}
	if !readJSONStrict(w, r, &in, 1024, "invalid JSON body (only email)") {
		return
	}
	email, err := normalizeEmbedEmail(in.Email)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if email != "" {
		lines, err := es.EmbedVisitorMessages(r.Context(), v, embedReadMax)
		if err != nil {
			writeErrCause(w, http.StatusInternalServerError, "internal", "messages not read", err)
			return
		}
		if !slices.ContainsFunc(lines, func(m store.EmbedMessage) bool { return !m.Mine }) {
			writeErr(w, http.StatusConflict, ErrEmbedNoAnswer, "the e-mail is offered after the first answer")
			return
		}
	}
	err = rs.SetEmbedVisitorEmail(r.Context(), v, email, s.o.Now().UTC())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusUnauthorized, TokenEmbedToken, "no live visitor token for this embed")
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "email not stored", err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// relinkBase is the page the link opens: return_url when its origin is one
// of the embed's allowed origins (its fragment dropped), else the first
// allowed origin. An error for a return_url that is not such a URL; "" when
// the embed allows no origin.
func relinkBase(ec store.EmbedCustomer, returnURL string) (string, error) {
	if returnURL == "" {
		if len(ec.AllowedOrigins) == 0 {
			return "", nil
		}
		return ec.AllowedOrigins[0] + "/", nil
	}
	u, err := url.Parse(returnURL)
	if err != nil || u.User != nil || u.Host == "" {
		return "", errors.New("return_url must be a page of one of the embed's allowed origins")
	}
	if !slices.Contains(ec.AllowedOrigins, strings.ToLower(u.Scheme+"://"+u.Host)) {
		return "", errors.New("return_url must be a page of one of the embed's allowed origins")
	}
	u.Fragment, u.RawFragment = "", ""
	if u.Path == "" {
		u.Path = "/"
	}
	return u.String(), nil
}

// handleEmbedRelinkAsk mails a link to the address when it is a live
// visitor's of this embed; 202 either way (see the file comment).
func (s *Server) handleEmbedRelinkAsk(w http.ResponseWriter, r *http.Request) {
	es, rs := s.relinkStore(w, r)
	if rs == nil {
		return
	}
	var in struct {
		Email     string `json:"email"`
		ReturnURL string `json:"return_url"`
		Locale    string `json:"locale"`
	}
	if !readJSONStrict(w, r, &in, 4096, "invalid JSON body (only email, return_url, locale)") {
		return
	}
	email, err := normalizeEmbedEmail(in.Email)
	if err != nil || email == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "email must be one address like name@example.com")
		return
	}
	ec, err := es.EmbedCustomer(r.Context(), r.PathValue("embed_id"))
	if err != nil || !ec.Enabled {
		http.NotFound(w, r)
		return
	}
	base, err := relinkBase(ec, in.ReturnURL)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	s.mailEmbedRelink(invitemail.WithRelinkLocale(r.Context(), s.relinkLocale(in.Locale)), rs, ec.EmbedID, email, base)
	writeJSON(w, http.StatusAccepted, map[string]any{"outcome": "accepted"})
}

// relinkLocale is the relink mail's locale: the chat page's, when the hub
// ships it, else the hub's default (SPOOL_HUB_DEFAULT_LOCALE); "" past that,
// which mail.Render renders in mail.FallbackLocale. Never an error.
func (s *Server) relinkLocale(asked string) string {
	if l := i18n.Normalize(asked); l != "" {
		return l
	}
	if s.o.Auth != nil {
		return i18n.Normalize(s.o.Auth.DefaultLocale())
	}
	return ""
}

// mailEmbedRelink mails the link to email when it names a live visitor of
// embedID and that visitor's hourly mails allow one more; every other case
// is logged and mails nothing.
func (s *Server) mailEmbedRelink(ctx context.Context, rs store.EmbedRelinks, embedID, email, base string) {
	log := s.o.Log.With().Str("component", "embed_relink").Str("embed", embedID).Str("to", spoolmail.Digest(email)).Logger()
	now := s.o.Now().UTC()
	v, hash, err := rs.EmbedRelinkVisitor(ctx, embedID, store.EmbedRelinkKey{Email: email}, now)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			log.Error().Err(err).Msg("embed.relink_lookup_failed")
		}
		return
	}
	qc, ok := s.o.Store.(store.QuotaCounter)
	if !ok || base == "" || s.o.EmbedRelinkMail == nil {
		log.Warn().Bool("quota", ok).Bool("origin", base != "").Bool("mailer", s.o.EmbedRelinkMail != nil).Msg("embed.relink_not_mailed")
		return
	}
	if _, ok, err := qc.TakeQuota(ctx, v.TenantID, v.HumanID, quotaEmbedRelink, now.Truncate(time.Hour), embedRelinkPerHour); err != nil || !ok {
		log.Info().Err(err).Str("visitor", v.VisitorID).Msg("embed.relink_rate_limited")
		return
	}
	code, err := relinkCode(embedID, v.VisitorID, hash, now.Add(embedRelinkTTL))
	if err == nil {
		err = s.o.EmbedRelinkMail(ctx, email, base+"#"+embedRelinkFragment+"="+code, embedRelinkTTL)
	}
	if err != nil {
		log.Error().Err(err).Str("visitor", v.VisitorID).Msg("embed.relink_mail_failed")
		return
	}
	log.Info().Str("visitor", v.VisitorID).Msg("embed.relink_mailed")
}

// relinkMAC is the code's mac over the embed id and the code's first bytes,
// keyed by the visitor's current token_hash.
func relinkMAC(tokenHash []byte, embedID string, head []byte) []byte {
	m := hmac.New(sha256.New, tokenHash)
	m.Write([]byte("spool-embed-relink-v1\x00" + embedID + "\x00"))
	m.Write(head)
	return m.Sum(nil)
}

// relinkCode is the link's code: unpadded base64url of version, visitor id,
// expiry and mac.
func relinkCode(embedID, visitorID string, tokenHash []byte, exp time.Time) (string, error) {
	id, err := hex.DecodeString(strings.ReplaceAll(visitorID, "-", ""))
	if err != nil || len(id) != 16 {
		return "", errors.New("relink: the visitor id is not a uuid")
	}
	head, err := binary.Append(append([]byte{relinkV1}, id...), binary.BigEndian, exp.Unix())
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(append(head, relinkMAC(tokenHash, embedID, head)...)), nil
}

// relinkParsed is a code split into its parts; head is what the mac covers.
type relinkParsed struct {
	visitorID string
	exp       time.Time
	head, mac []byte
}

// parseRelinkCode splits a code; false for anything not of its shape.
func parseRelinkCode(code string) (relinkParsed, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(code)
	if err != nil || len(raw) != relinkLen || raw[0] != relinkV1 {
		return relinkParsed{}, false
	}
	var unix int64
	if _, err := binary.Decode(raw[17:25], binary.BigEndian, &unix); err != nil {
		return relinkParsed{}, false
	}
	h := hex.EncodeToString(raw[1:17])
	id := h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
	return relinkParsed{visitorID: id, exp: time.Unix(unix, 0).UTC(), head: raw[:25], mac: raw[25:]}, true
}

// handleEmbedRelinkRedeem binds a new token to the link's visitor: 201 with
// the token, as the mint answers; 410 for a used, expired, forged or unknown
// link, one answer for all.
func (s *Server) handleEmbedRelinkRedeem(w http.ResponseWriter, r *http.Request) {
	_, rs := s.relinkStore(w, r)
	if rs == nil {
		return
	}
	var in struct {
		Code string `json:"code"`
	}
	if !readJSONStrict(w, r, &in, 512, "invalid JSON body (only code)") {
		return
	}
	gone := func() { writeErr(w, http.StatusGone, ErrEmbedRelinkGone, "the link is used, expired or unknown") }
	now, embedID := s.o.Now().UTC(), r.PathValue("embed_id")
	p, ok := parseRelinkCode(in.Code)
	if !ok || !now.Before(p.exp) {
		gone()
		return
	}
	v, hash, err := rs.EmbedRelinkVisitor(r.Context(), embedID, store.EmbedRelinkKey{VisitorID: p.visitorID}, now)
	if err == nil && !hmac.Equal(p.mac, relinkMAC(hash, embedID, p.head)) {
		err = store.ErrNotFound
	}
	var tok string
	if err == nil {
		var newHash []byte
		if tok, newHash, err = auth.NewEmbedToken(); err == nil {
			v, err = rs.RelinkEmbedVisitor(r.Context(), v, hash, newHash, s.embedLife(), now)
		}
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		gone()
	case err != nil:
		writeErrCause(w, http.StatusInternalServerError, "internal", "relink failed", err)
	default:
		writeJSON(w, http.StatusCreated, map[string]any{"token": tok, "visitor_id": v.VisitorID,
			"channel": v.ChannelID, "expires_at": rfc(v.ExpiresAt)})
	}
}

// embedVisitorEmail is one row of the owner's list.
type embedVisitorEmail struct {
	VisitorID  string `json:"visitor_id"`
	Channel    string `json:"channel"`
	Email      string `json:"email"`
	LastSeenAt string `json:"last_seen_at"`
}

// handleEmbedVisitorEmails lists the relink addresses of one embed's
// visitors: the workspace owner only (embedAdminActor: any other member 403).
func (s *Server) handleEmbedVisitorEmails(w http.ResponseWriter, r *http.Request) {
	_, tenant, ok := s.embedAdminActor(w, r)
	if !ok {
		return
	}
	rs, ok := s.o.Store.(store.EmbedRelinks)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no embeds")
		return
	}
	if !embedIDRe.MatchString(r.PathValue("embed_id")) {
		writeErr(w, http.StatusNotFound, "not_found", "no such embed in this workspace")
		return
	}
	got, err := rs.EmbedVisitorEmails(r.Context(), tenant, r.PathValue("embed_id"))
	if err != nil {
		writeErrCause(w, http.StatusInternalServerError, "internal", "visitor emails not read", err)
		return
	}
	out := make([]embedVisitorEmail, 0, len(got))
	for _, e := range got {
		out = append(out, embedVisitorEmail{e.VisitorID, e.ChannelID, e.Email, rfc(e.LastSeenAt)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"visitors": out})
}

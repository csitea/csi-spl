package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/rs/zerolog"
)

// A member's first name, last name and phone number (rdb 0287, SPL-5707,
// spec 154 section 12.5; owner HUM-10, t1 028ac340: "every member should be
// able to see the email and the phone number of the other member [...] In
// the T1 workspace only the first name and the last name"). The person edits
// them in Settings -> Profile through PUT preferences (first_name, last_name,
// phone) and reads their own back on GET profile. Other members see them on
// the member card (hub/member_card.go), never on the roster.
//
// One source of truth: first + last name. display_name is their join,
// written in the same statement whenever the two are saved; a display_name
// written alone (an admin's rename, the old single field) is split back
// into the two by SplitDisplayName, the rule rdb 0287 backfilled with.

// Profile is one human's own first name, last name and phone ("" = none).
type Profile struct {
	FirstName, LastName, Phone string
}

// ProfileStore is the optional store side of Profile; AuthHooks has it.
type ProfileStore interface {
	// Profile is the human's own; unknown human = ErrNoHuman.
	Profile(ctx context.Context, humanID string) (Profile, error)
	// SetProfileName stores first and last ("" = none) and display_name =
	// JoinName(first, last). A demo visitor = ErrPseudonymFixed.
	SetProfileName(ctx context.Context, humanID, first, last string) error
	// SetPhone stores an E.164 number ValidPhone admitted, "" clears it. A
	// demo visitor = ErrPseudonymFixed.
	SetPhone(ctx context.Context, humanID, phone string) error
}

// MaxNamePartLen bounds first_name and last_name (rdb 0287's CHECKs).
const MaxNamePartLen = 100

const (
	// ErrCodeInvalidName: a first_name / last_name the form must fix.
	ErrCodeInvalidName = "invalid_name"
	// ErrCodeInvalidPhone: a phone that is not +<country code><number>.
	ErrCodeInvalidPhone = "invalid_phone"
)

// ValidNamePart is ValidDisplayName's rule at MaxNamePartLen characters.
func ValidNamePart(raw string) (string, bool) {
	s, ok := ValidDisplayName(raw)
	if !ok || utf8.RuneCountInString(s) > MaxNamePartLen {
		return "", false
	}
	return s, true
}

// ValidPhone admits a number in the international form only: spaces, '-',
// '.', '(' and ')' are dropped, then it must be '+', a first digit 1..9 and
// 7..15 digits in all (E.164). The answer is the normalised number,
// "+358401234567"; a national form ("040 123 4567") is refused, since the
// country cannot be guessed.
func ValidPhone(raw string) (string, bool) {
	var b strings.Builder
	for _, c := range strings.TrimSpace(raw) {
		if unicode.IsSpace(c) || strings.ContainsRune("-.()", c) {
			continue
		}
		b.WriteRune(c)
	}
	s := b.String()
	if len(s) < 8 || len(s) > 16 || s[0] != '+' || s[1] < '1' || s[1] > '9' {
		return "", false
	}
	for _, c := range s[1:] {
		if c < '0' || c > '9' {
			return "", false
		}
	}
	return s, true
}

// SplitDisplayName splits a name at its FIRST run of whitespace: the first
// word is the first name, the rest (trimmed) the last name; each cut to
// MaxNamePartLen characters. "Mary Ann Smith" -> "Mary", "Ann Smith"; one
// word -> that word, "". The same rule as rdb 0287's backfill.
func SplitDisplayName(name string) (first, last string) {
	name = strings.TrimSpace(name)
	i := strings.IndexFunc(name, unicode.IsSpace)
	if i < 0 {
		return cutRunes(name), ""
	}
	return cutRunes(name[:i]), cutRunes(strings.TrimSpace(name[i:]))
}

func cutRunes(s string) string {
	if r := []rune(s); len(r) > MaxNamePartLen {
		return strings.TrimSpace(string(r[:MaxNamePartLen]))
	}
	return s
}

// JoinName is the display_name of first + last: "First Last", or the first
// alone when there is no last name.
func JoinName(first, last string) string {
	return strings.TrimSpace(first + " " + last)
}

// profileIn is the validated profile part of a PUT preferences body.
type profileIn struct {
	first, last, phone string
	hasName, hasPhone  bool
}

func (p profileIn) any() bool { return p.hasName || p.hasPhone }

// parseProfile: first_name and last_name are saved together (both keys, or
// neither); first_name is required, last_name may be null or "". phone null
// or "" clears it, else it must be ValidPhone.
func parseProfile(req preferencesReq) (p profileIn, code, detail string) {
	rf, rl := present(req.FirstName), present(req.LastName)
	if rf != "" || rl != "" {
		if rf == "" || rl == "" {
			return p, ErrCodeInvalidName, "first_name and last_name are saved together"
		}
		var first, last string
		ok := rf != "null" && json.Unmarshal(req.FirstName, &first) == nil
		if ok {
			p.first, ok = ValidNamePart(first)
		}
		if ok && rl != "null" {
			ok = json.Unmarshal(req.LastName, &last) == nil
			if last = strings.TrimSpace(last); ok && last != "" {
				p.last, ok = ValidNamePart(last)
			}
		}
		if !ok || utf8.RuneCountInString(JoinName(p.first, p.last)) > MaxDisplayNameLen {
			return p, ErrCodeInvalidName, "first_name (required) and last_name must each be at most 100 characters on one line, without control characters"
		}
		p.hasName = true
	}
	if rp := present(req.Phone); rp != "" {
		p.hasPhone = true
		var raw string
		if rp != "null" && (json.Unmarshal(req.Phone, &raw) != nil || strings.TrimSpace(raw) != "") {
			var ok bool
			if p.phone, ok = ValidPhone(raw); !ok {
				return p, ErrCodeInvalidPhone, "phone must be in the international form: + and the country code, then the number, e.g. +358 40 123 4567"
			}
		}
	}
	return p, "", ""
}

// storeProfile writes the profile keys of a PUT preferences body and adds
// them to out. The number and the names are never logged, only that they
// were set. false = an error was answered.
func (h *Handler) storeProfile(w http.ResponseWriter, r *http.Request, hum string, p profileIn, out map[string]any) bool {
	if !p.any() {
		return true
	}
	ps, ok := h.prefs.(ProfileStore)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "this hub's store keeps no profile")
		return false
	}
	logged := func(e *zerolog.Event) { e.Str("human_id", hum).Msg("auth.preferences_set") }
	if p.hasName {
		if !h.storePref(w, ps.SetProfileName(r.Context(), hum, p.first, p.last)) {
			return false
		}
		logged(h.log.Info().Bool("profile_name", true))
		out["first_name"], out["last_name"], out["display_name"] = p.first, nullable(p.last), JoinName(p.first, p.last)
	}
	if p.hasPhone {
		if !h.storePref(w, ps.SetPhone(r.Context(), hum, p.phone)) {
			return false
		}
		logged(h.log.Info().Bool("phone_set", p.phone != ""))
		out["phone"] = nullable(p.phone)
	}
	return true
}

// profileBody is GET profile's answer; null = none on file.
type profileBody struct {
	FirstName *string `json:"first_name"`
	LastName  *string `json:"last_name"`
	Phone     *string `json:"phone"`
}

func strOrNil(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// getProfile answers the signed-in human's OWN first name, last name and
// phone, for the Settings form. Same door as the session read; no-store.
func (h *Handler) getProfile(w http.ResponseWriter, r *http.Request) {
	s, ok := h.SessionFromRequest(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return
	}
	ps, ok := h.prefs.(ProfileStore)
	if s.HumanID == "" || !ok {
		writeErr(w, http.StatusConflict, "no_human", "this session has no registered human to keep a profile on")
		return
	}
	v, err := ps.Profile(r.Context(), s.HumanID)
	if !h.storePref(w, err) {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, profileBody{FirstName: strOrNil(v.FirstName), LastName: strOrNil(v.LastName), Phone: strOrNil(v.Phone)})
}

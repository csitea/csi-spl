package auth

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
)

// A person's time zone, PER TENANT (CLE-77908, topic 07b84fd7). Owner, verbatim:
// "default shuold be browser zone , but the uesrs should be able to overwrite
// it by their personal settings , PER TENANT". Kept ONLY in the membership
// override (rdb 0078, like pane_sizes): no humans column, no DDL. Null / never
// picked = the browser's zone. The WUI prints every message / topic time in
// this zone; the hub never converts a time with it (ts stays RFC 3339 UTC).

// timeZoneRe is the shape of an IANA zone name ("Europe/Helsinki",
// "America/Argentina/Buenos_Aires", "UTC", "Etc/GMT+3"). The hub carries no
// tzdata, so it checks the shape only; the browser (Intl) decides whether the
// zone exists and falls back to its own zone when it does not.
var timeZoneRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+){0,2}$`)

// TimeZoneMaxLen bounds a stored zone name; the longest IANA name is ~30.
const TimeZoneMaxLen = 64

// IsTimeZone reports whether v is shaped like an IANA zone name.
func IsTimeZone(v string) bool {
	return len(v) <= TimeZoneMaxLen && timeZoneRe.MatchString(v)
}

// parseTimeZone reads PUT preferences' time_zone: present = has, null or ""
// clears it (back to the browser's zone). A refusal is (code, detail).
func parseTimeZone(raw json.RawMessage) (v string, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return "", false, "", ""
	}
	if s == "null" {
		return "", true, "", ""
	}
	if json.Unmarshal(raw, &v) != nil {
		return "", true, "unsupported_time_zone", "time_zone must be an IANA zone name (e.g. Europe/Helsinki) or null"
	}
	v = strings.TrimSpace(v)
	if v != "" && !IsTimeZone(v) {
		return "", true, "unsupported_time_zone", "time_zone must be an IANA zone name (e.g. Europe/Helsinki) or null"
	}
	return v, true, "", ""
}

// timeZone is the session human's zone for the active tenant, nil when unset
// (the WUI then follows the browser). Like paneSizes it reads the overlaid
// snapshot, so it costs no store round trip.
func (h *Handler) timeZone(ctx context.Context, s Session) *string {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok && snap.TimeZone != "" {
		tz := snap.TimeZone
		return &tz
	}
	return nil
}

package auth

import (
	"context"
	"encoding/json"
	"strings"
)

// A person's "Count my reading time" switch, PER TENANT (spec 107 section
// 1.2, owner Q1 = A): on, the WUI sends active-tab minutes for the hours
// suggestions; off, it sends none and that member's suggestions come from
// posts and meetings only. Kept ONLY in the membership override (rdb 0078,
// like keyboard_shortcuts): no humans column, no DDL. Null / never picked =
// ON (the spec's default).

// parseHoursReading reads PUT preferences' hours_reading: true or false sets
// it, null clears it (back to the default, on). A refusal is (code, detail).
func parseHoursReading(raw json.RawMessage) (v *bool, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return nil, false, "", ""
	}
	if s == "null" {
		return nil, true, "", ""
	}
	var b bool
	if json.Unmarshal(raw, &b) != nil {
		return nil, true, "unsupported_hours_reading", "hours_reading must be true, false or null"
	}
	return &b, true, "", ""
}

// hoursReading is the session human's switch for the active tenant, nil when
// never picked (the WUI then treats it as on). Like keyboardShortcuts it reads
// the overlaid snapshot, so it costs no store round trip.
func (h *Handler) hoursReading(ctx context.Context, s Session) *bool {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok && snap.HoursReading != nil {
		v := *snap.HoursReading
		return &v
	}
	return nil
}

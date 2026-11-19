package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"regexp"
	"strings"
)

// A member's remembered Calendar filter, PER WORKSPACE (spec 097 section
// 11.8.2, owner O5 = B, msg cde26d3f; row T16): the event tags and the To-do
// issue labels last chosen with the filter control, applied when the member
// opens Calendar again on any device. A tag id or a label id only means
// something inside its workspace, so the value is kept ONLY in the membership
// override (rdb 0078, like time_zone): no humans column, no DDL, and outside
// a workspace it is not stored. Null / never chosen = no filter. The hub
// checks the shape only; an id that no longer exists is pruned by the WUI.

// CalendarFilter is the stored value: tags is ["none"] alone or up to
// CalendarFilterMax tag ids (spec 097 section 11.4.3), labels up to
// CalendarFilterMax issue label ids (section 11.8.3). Both are always
// present, possibly empty.
type CalendarFilter struct {
	Tags   []string `json:"tags"`
	Labels []string `json:"labels"`
}

// CalendarFilterMax bounds each list (section 11.4.3: at most 20 ids).
const CalendarFilterMax = 20

// calendarTagNone is the pseudo tag id for untagged events, valid only alone.
const calendarTagNone = "none"

var (
	// calendarTagIDRe is calendar_tags.tag_id's CHECK (spec 097 section 11.3).
	calendarTagIDRe = regexp.MustCompile(`^[0-9a-f]{8}$`)
	// calendarLabelIDRe is issue_labels.label_id's CHECK (rdb 0047).
	calendarLabelIDRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,39}$`)
)

const calendarFilterBad = `calendar_filter must be {"tags": up to 20 tag ids or ["none"] alone, "labels": up to 20 issue label ids} or null`

// parseCalendarFilter reads PUT preferences' calendar_filter: an object of
// tags and labels sets it (a missing list is empty), null clears it. Unknown
// keys, duplicates, a malformed id, more than 20 of either and "none" with a
// tag are refused. A refusal is (code, detail).
func parseCalendarFilter(raw json.RawMessage) (v *CalendarFilter, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return nil, false, "", ""
	}
	if s == "null" {
		return nil, true, "", ""
	}
	var f CalendarFilter
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if !strings.HasPrefix(s, "{") || dec.Decode(&f) != nil || dec.More() {
		return nil, true, "unsupported_calendar_filter", calendarFilterBad
	}
	if f.Tags == nil {
		f.Tags = []string{}
	}
	if f.Labels == nil {
		f.Labels = []string{}
	}
	if !calendarIDs(f.Tags, calendarTagIDRe, true) || !calendarIDs(f.Labels, calendarLabelIDRe, false) {
		return nil, true, "unsupported_calendar_filter", calendarFilterBad
	}
	return &f, true, "", ""
}

// calendarIDs checks one list: at most CalendarFilterMax distinct ids of re;
// with none, the pseudo id "none" is admitted, but only alone.
func calendarIDs(ids []string, re *regexp.Regexp, none bool) bool {
	if len(ids) > CalendarFilterMax {
		return false
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		ok := re.MatchString(id) || (none && id == calendarTagNone && len(ids) == 1)
		if !ok || seen[id] {
			return false
		}
		seen[id] = true
	}
	return true
}

// calendarFilter is the session human's remembered filter for the active
// workspace, nil when never chosen. Like awaitAnims it reads the overlaid
// snapshot, so it costs no store round trip.
func (h *Handler) calendarFilter(ctx context.Context, s Session) *CalendarFilter {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok && snap.CalendarFilter != nil {
		f := *snap.CalendarFilter
		return &f
	}
	return nil
}

// nilCalendarFilter answers a cleared filter as JSON null (the SQL merge
// strips it).
func nilCalendarFilter(v *CalendarFilter) any {
	if v == nil {
		return nil
	}
	return v
}

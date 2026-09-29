package auth

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
)

// The two vertical dividers' widths (CLE-35099, SPL-1182, spec 023 addendum).
// Owner, prd t1 topic 3a589b54: "save also the sizes of the 2 vertical lines in
// the UI between the vertical panes". Kept PER TENANT in the membership override
// (rdb 0078) as FRACTIONS of the window width (screen-independent), so the same
// account draws the right layout on any monitor. Written once on drag end
// (pointerup), debounced, one PUT per gesture. Null / never dragged = the
// default layout. Phones (one pane, < 820 px) never send these.

// PaneSizeKeys are the two dividers a width is kept for: the sidebar (channels)
// pane and the topic (middle) pane; the third pane fills the rest.
var PaneSizeKeys = []string{"sidebar", "topic"}

// PaneSizeMin and PaneSizeMax bound one stored fraction. A pane narrower than
// PaneSizeMin or wider than PaneSizeMax is not a layout a person drags to; the
// WUI clamps to each pane's own min/max on top.
const (
	PaneSizeMin = 0.05
	PaneSizeMax = 0.90
)

// IsPaneSizes reports whether v holds only PaneSizeKeys, each a fraction inside
// [PaneSizeMin, PaneSizeMax], and the two together leave room for the third
// pane (their sum < PaneSizeMax). An empty map is valid.
func IsPaneSizes(v map[string]float64) bool {
	sum := 0.0
	for k, f := range v {
		if !inList(k, PaneSizeKeys) || f < PaneSizeMin || f > PaneSizeMax {
			return false
		}
		sum += f
	}
	return sum < PaneSizeMax
}

// parsePaneSizes reads PUT preferences' pane_sizes: present = has, a null or an
// empty object clears (nil). A refusal is (code, detail).
func parsePaneSizes(raw json.RawMessage) (v map[string]float64, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return nil, false, "", ""
	}
	if s == "null" {
		return nil, true, "", ""
	}
	if json.Unmarshal(raw, &v) != nil || v == nil || !IsPaneSizes(v) {
		return nil, true, "unsupported_pane_sizes", "pane_sizes must be an object of " +
			strings.Join(PaneSizeKeys, ",") + " -> a fraction of the window, or null"
	}
	if len(v) == 0 {
		v = nil
	}
	return v, true, "", ""
}

// sortedFloatKeys is v's keys sorted, for a stable log / echo.
func sortedFloatKeys(v map[string]float64) []string {
	ks := make([]string, 0, len(v))
	for k := range v {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// paneSizes is the session human's stored divider widths for the active
// tenant, nil when unset. Like issuesSort it reads the overlaid snapshot.
func (h *Handler) paneSizes(ctx context.Context, s Session) map[string]float64 {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok && len(snap.PaneSizes) > 0 {
		return snap.PaneSizes
	}
	return nil
}

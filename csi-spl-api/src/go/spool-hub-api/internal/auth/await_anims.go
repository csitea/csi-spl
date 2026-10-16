package auth

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
)

// A person's "Thinking animation" pick, PER TENANT (SPL-2113, owner HUM-10,
// t1 3aa9fac2 msgs d45ec26e, c33a028e): the ids of the animations ticked in
// Settings -> Appearance, which take turns on a post that waits for an agent.
// Kept ONLY in the membership override (rdb 0078, like keyboard_shortcuts):
// no humans column, no DDL. The WUI owns the catalogue of drawings, so the
// hub checks the shape only (1..AwaitAnimsMax distinct short ids); an id the
// WUI no longer knows is dropped there. Null / never picked = the WUI's
// default set.

// AwaitAnimsMax bounds the stored list (the WUI ships far fewer).
const AwaitAnimsMax = 64

var awaitAnimIDRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// parseAwaitAnims reads PUT preferences' await_anims: an array of 1..64
// distinct ids sets it, null clears it (back to the WUI's default). A refusal
// is (code, detail).
func parseAwaitAnims(raw json.RawMessage) (v []string, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return nil, false, "", ""
	}
	if s == "null" {
		return nil, true, "", ""
	}
	const bad = "await_anims must be an array of 1 to 64 distinct animation ids (a-z, 0-9, -) or null"
	var ids []string
	if json.Unmarshal(raw, &ids) != nil || len(ids) == 0 || len(ids) > AwaitAnimsMax {
		return nil, true, "unsupported_await_anims", bad
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if !awaitAnimIDRe.MatchString(id) || seen[id] {
			return nil, true, "unsupported_await_anims", bad
		}
		seen[id] = true
	}
	return ids, true, "", ""
}

// awaitAnims is the session human's ticked animations for the active tenant,
// nil when never picked. Like keyboardShortcuts it reads the overlaid
// snapshot, so it costs no store round trip.
func (h *Handler) awaitAnims(ctx context.Context, s Session) []string {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok && snap.AwaitAnims != nil {
		return append([]string(nil), snap.AwaitAnims...)
	}
	return nil
}

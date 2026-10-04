package auth

import (
	"context"
	"encoding/json"
	"strings"
)

// A person's "Keyboard shortcuts" switch, PER TENANT (Settings -> Behaviour,
// HUM-10 topic ae2e5093): Shift + a letter acts on the selected message. Kept
// ONLY in the membership override (rdb 0078, like time_zone): no humans
// column, no DDL. Null / never picked = ON (the product default); false turns
// every message shortcut and its menu hint off in this workspace.

// parseKeyboardShortcuts reads PUT preferences' keyboard_shortcuts: true or
// false sets it, null clears it (back to the default, on). A refusal is
// (code, detail).
func parseKeyboardShortcuts(raw json.RawMessage) (v *bool, has bool, code, detail string) {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return nil, false, "", ""
	}
	if s == "null" {
		return nil, true, "", ""
	}
	var b bool
	if json.Unmarshal(raw, &b) != nil {
		return nil, true, "unsupported_keyboard_shortcuts", "keyboard_shortcuts must be true, false or null"
	}
	return &b, true, "", ""
}

// keyboardShortcuts is the session human's switch for the active tenant, nil
// when never picked (the WUI then treats it as on). Like timeZone it reads the
// overlaid snapshot, so it costs no store round trip.
func (h *Handler) keyboardShortcuts(ctx context.Context, s Session) *bool {
	if s.HumanID == "" || h.prefs == nil {
		return nil
	}
	if snap, ok := h.settingsSnap(ctx, s.HumanID); ok && snap.KeyboardShortcuts != nil {
		v := *snap.KeyboardShortcuts
		return &v
	}
	return nil
}

// nilBool answers a cleared switch as JSON null (the SQL merge strips it).
func nilBool(v *bool) any {
	if v == nil {
		return nil
	}
	return *v
}

package hub

import "testing"

func TestValidEmoji(t *testing.T) {
	if n := len(emojiChoices); n != 39 {
		t.Fatalf("picker offers %d glyphs, want 39", n)
	}
	for _, e := range emojiChoices {
		if !validEmoji(e) {
			t.Fatalf("picker glyph %q rejected", e)
		}
	}
	for _, bad := range []string{"", " ", "hello", "👍👍", "👍 ", "👍🎉", "not-an-emoji"} {
		if validEmoji(bad) {
			t.Fatalf("accepted %q", bad)
		}
	}
}

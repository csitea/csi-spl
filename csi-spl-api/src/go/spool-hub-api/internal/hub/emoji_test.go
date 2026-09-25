package hub

import "testing"

func TestValidEmoji(t *testing.T) {
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

package hub

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestValidEmoji(t *testing.T) {
	if n := len(emojiChoices); n != 48 || n%8 != 0 {
		t.Fatalf("picker offers %d glyphs, want 48 (six full rows of eight)", n)
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

// SPL-1002: no glyph twice, not even as two spellings of one glyph.
func TestEmojiChoicesHaveNoDuplicate(t *testing.T) {
	seen := map[string]string{}
	for _, e := range emojiChoices {
		key := strings.ReplaceAll(e, vs16, "")
		if prev, ok := seen[key]; ok {
			t.Fatalf("%q and %q are the same glyph", prev, e)
		}
		seen[key] = e
		if got := canonicalEmoji(e); got != e {
			t.Fatalf("canonicalEmoji(%q) = %q, want itself", e, got)
		}
	}
}

func TestCanonicalEmoji(t *testing.T) {
	cases := map[string]string{
		"❤️":    "❤️",
		"❤":     "❤️", // the bare heart becomes the picker's spelling
		"👍️":    "👍",  // a stray selector is dropped
		"⭐️":    "⭐",
		"🤯":     "🤯",
		"😠":     "", // angry, not offered (the picker has 😡 pouting)
		"hello": "",
		"":      "",
		"👍👍":    "",
		"⏸️":    "⏸️", // CLE-77895: on hold
		"⏸":     "⏸️",
		"😆":     "😆", // retired from the picker, still accepted
		"️":     "",
	}
	for in, want := range cases {
		if got := canonicalEmoji(in); got != want {
			t.Fatalf("canonicalEmoji(%q) = %q, want %q", in, got, want)
		}
	}
}

// The hub list and the WUI picker are one list: same glyphs, same order.
func TestEmojiChoicesMatchWUI(t *testing.T) {
	path := filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-wui", "src", "utils", "emoji.mjs")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the WUI picker list %s: %v", path, err)
	}
	block := regexp.MustCompile(`(?s)export const EMOJI_CHOICES = \[(.*?)\]`).FindSubmatch(src)
	if block == nil {
		t.Fatalf("EMOJI_CHOICES not found in %s", path)
	}
	var wui []string
	for _, m := range regexp.MustCompile(`'([^']+)'`).FindAllSubmatch(block[1], -1) {
		wui = append(wui, string(m[1]))
	}
	if strings.Join(wui, " ") != strings.Join(emojiChoices, " ") {
		t.Fatalf("hub and WUI lists differ:\nhub %v\nwui %v", emojiChoices, wui)
	}
}

package hub

import "strings"

// emojiChoices is the picker the WUI shows (csi-spl-wui/src/utils/emoji.mjs
// EMOJI_CHOICES). The hub accepts only these, so a reaction is one glyph the
// product actually offers and not an arbitrary string. TestEmojiChoicesMatchWUI
// fails when the two lists differ. Six full rows of eight, each glyph once
// (SPL-1002).
var emojiChoices = []string{
	"😀", "😁", "😂", "🤣", "😆", "😅", "🙂", "😉",
	"😊", "😇", "😍", "😎", "😜", "🥳", "🤗", "🤔",
	"😐", "😕", "😬", "🙄", "😴", "😢", "😭", "😱",
	"😡", "🤯", "👍", "👎", "👏", "🙌", "🙏", "👋",
	"💪", "👌", "🤝", "👀", "🔥", "❤️", "🎉", "✨",
	"✅", "❌", "⭐", "💯", "🚀", "💡", "🎯", "🐛",
}

const vs16 = "\uFE0F"

var emojiSet = func() map[string]struct{} {
	m := make(map[string]struct{}, len(emojiChoices))
	for _, e := range emojiChoices {
		m[e] = struct{}{}
	}
	return m
}()

// validEmoji reports whether s is one picker glyph, spelled exactly as the
// picker spells it. Two glyphs, a sentence, or an emoji the picker does not
// offer are false.
func validEmoji(s string) bool {
	_, ok := emojiSet[s]
	return ok
}

// canonicalEmoji maps a picker glyph written with or without the emoji
// variation selector (U+FE0F) onto the one spelling the picker uses, so the
// same heart never becomes two chips. "" when s is not a picker glyph.
func canonicalEmoji(s string) string {
	if validEmoji(s) {
		return s
	}
	bare := strings.ReplaceAll(s, vs16, "")
	if validEmoji(bare) {
		return bare
	}
	if validEmoji(bare + vs16) {
		return bare + vs16
	}
	return ""
}

package hub

// emojiChoices is the picker the WUI shows (csi-spl-wui/src/utils/emoji.mjs
// EMOJI_CHOICES). The hub accepts only these, so a reaction is one glyph the
// product actually offers and not an arbitrary string. Keep the two lists
// the same.
var emojiChoices = []string{
	"😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "😉", "😊", "😍",
	"😘", "😜", "🤔", "😐", "😴", "😎", "😢", "😭", "😤", "😡", "🤯", "😱",
	"🤗", "🙄",
	"👍", "👎", "👏", "🙌", "🙏", "🤝", "👋", "💪", "👀", "🔥", "✨", "💯",
	"🎉", "✅", "❌", "⭐", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "💔",
	"🚀", "📌", "📝", "💡", "🐛", "⏰", "🎯", "💬", "☕", "🏁",
}

var emojiSet = func() map[string]struct{} {
	m := make(map[string]struct{}, len(emojiChoices))
	for _, e := range emojiChoices {
		m[e] = struct{}{}
	}
	return m
}()

// validEmoji reports whether s is one picker glyph. Two glyphs, a sentence,
// or an emoji the picker does not offer are false.
func validEmoji(s string) bool {
	_, ok := emojiSet[s]
	return ok
}

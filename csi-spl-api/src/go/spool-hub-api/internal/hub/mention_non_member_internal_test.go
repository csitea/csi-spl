package hub

import "testing"

// SPL-2419: the note words and who it names.
func TestMentionNonMemberBody(t *testing.T) {
	if got, want := mentionNonMemberBody([]string{"HUM-2"}), "@HUM-2 does not belong to this channel and cannot see these messages."; got != want {
		t.Errorf("one: %q, want %q", got, want)
	}
	if got := mentionedOutside("@c-002 @GST-4 @HUM-1 @HUM-5", "HUM-1", []string{"HUM-5"}); len(got) != 1 || got[0] != "GST-4" {
		t.Errorf("mentionedOutside: %v, want [GST-4] (agents, author, members left out)", got)
	}
}

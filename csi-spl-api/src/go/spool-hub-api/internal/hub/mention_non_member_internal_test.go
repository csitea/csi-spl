package hub

import "testing"

// SPL-2419: the note words and who it names; SPL-2426: by name, not id.
func TestMentionNonMemberBody(t *testing.T) {
	for _, c := range []struct {
		names []string
		want  string
	}{
		{[]string{"FirstName LastName"}, "FirstName LastName does not belong to this channel and cannot see these messages."},
		{[]string{"FirstName LastName", "nameless"}, "FirstName LastName and nameless do not belong to this channel and cannot see these messages."},
		{[]string{"A B", "C D", "E F"}, "A B, C D and E F do not belong to this channel and cannot see these messages."},
	} {
		if got := mentionNonMemberBody(c.names); got != c.want {
			t.Errorf("%v: %q, want %q", c.names, got, c.want)
		}
	}
	for _, c := range [][3]string{
		{" FirstName LastName ", "x@example.com", "FirstName LastName"}, // the name on file
		{"", "nameless@example.com", "nameless"},                        // the name they sign in with
		{"  ", "", ""},                                                  // nothing: the caller says unnamedPerson
	} {
		if got := personName(c[0], c[1]); got != c[2] {
			t.Errorf("personName(%q, %q) = %q, want %q", c[0], c[1], got, c[2])
		}
	}
	if got := mentionedOutside("@c-002 @GST-4 @HUM-1 @HUM-5", "HUM-1", []string{"HUM-5"}); len(got) != 1 || got[0] != "GST-4" {
		t.Errorf("mentionedOutside: %v, want [GST-4] (agents, author, members left out)", got)
	}
}

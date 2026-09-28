package search

import (
	"reflect"
	"testing"
	"time"
)

// Grammar 1.1 (the smart omnibox): tenant and event types, the
// kind: / channel: / thread / person aliases, as-you-type prefixes and the
// language-neutral fold.

func TestFold(t *testing.T) {
	for in, want := range map[string]string{
		"Café": "cafe", "Straße": "strasse", "RÉSUMÉ": "resume", "Ærø": "aero", "Łódź": "lodz",
		"ΆΘΗΝΑ": "αθηνα", "ёлка": "елка", "йод": "йод", "deploy": "deploy", "東京": "東京",
	} {
		if got := Fold(in); got != want {
			t.Errorf("Fold(%q) = %q, want %q", in, got, want)
		}
	}
	// A decomposed é is one word, not "cafe" + a stray mark.
	if got := Words("café ok"); !reflect.DeepEqual(got, []string{"cafe", "ok"}) {
		t.Errorf("Words(decomposed) = %q", got)
	}
}

func TestSmartGrammar(t *testing.T) {
	ev := Entity{Type: TypeEvent, Name: "hub_unreachable", Text: []string{"ERR-20260925-101010-ABCD", "hub_unreachable", "the hub did not answer", "/v1/view/topics"},
		At: now.Add(-3 * 24 * time.Hour)}
	ten := Entity{Type: TypeTenant, Name: "Acme Café", Text: []string{"t7", "Acme Café"}}
	cases := []struct {
		q                                string
		types                            []Type
		tMsg, thr, robot, chanE, ev, ten bool
	}{
		// as you type: the last bare word is a prefix
		{"deplo", nil, true, false, false, false, false, false},
		{"deplo ", nil, false, false, false, false, false, false},
		{"migr hub", nil, false, false, false, false, false, false}, // not last: exact
		{"hub migr", nil, false, true, false, false, false, false},
		{"deplo*", nil, true, false, false, false, false, false},
		{`"deplo"`, nil, false, false, false, false, false, false},
		{"-deplo", nil, true, true, true, true, true, true}, // a negation is never a prefix
		// accents and case fold both ways
		{"type:tenant CAFÉ", nil, false, false, false, false, false, true},
		{"type:tenant cafe", nil, false, false, false, false, false, true},
		// aliases
		{"kind:thread", []Type{TypeTopic}, false, true, false, false, false, false},
		{"type:person", []Type{TypeUser}, false, false, false, false, false, false},
		{"channel:#tasks", []Type{TypeMessage, TypeTopic, TypeFile}, true, true, false, false, false, false},
		{"type:workspace", []Type{TypeTenant}, false, false, false, false, false, true},
		{"type:log", []Type{TypeEvent}, false, false, false, false, true, false},
		// name: is the name, never the content
		{"type:topic name:migrate", []Type{TypeTopic}, false, true, false, false, false, false},
		{"type:topic name:make", []Type{TypeTopic}, false, false, false, false, false, false},
		{"kind:errors", []Type{TypeEvent}, false, false, false, false, true, false},
		{"type:tenant name:acme", []Type{TypeTenant}, false, false, false, false, false, true},
		{"type:event name:unreachable", []Type{TypeEvent}, false, false, false, false, true, false},
		{"type:event answer", []Type{TypeEvent}, false, false, false, false, true, false},
		{"type:event after:7d", []Type{TypeEvent}, false, false, false, false, true, false},
		{"type:event after:1d", []Type{TypeEvent}, false, false, false, false, false, false},
	}
	for _, c := range cases {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Errorf("%q: %v", c.q, err)
			continue
		}
		if c.types != nil && !reflect.DeepEqual(q.Types, c.types) {
			t.Errorf("%q: types %v, want %v", c.q, q.Types, c.types)
		}
		sel := map[Type]bool{}
		for _, ty := range q.Types {
			sel[ty] = true
		}
		check := func(ty Type, got, want bool, what string) {
			if sel[ty] && got != want {
				t.Errorf("%q: %s = %v, want %v", c.q, what, got, want)
			}
		}
		check(TypeMessage, MatchMsg(q.Root, mTask), c.tMsg, "message")
		check(TypeTopic, MatchTopic(q.Root, thr), c.thr, "topic")
		check(TypeRobot, MatchEntity(q.Root, robot), c.robot, "robot")
		check(TypeChannel, MatchEntity(q.Root, chanE), c.chanE, "channel")
		e := ev
		check(TypeEvent, MatchEntity(q.Root, e), c.ev, "event")
		check(TypeTenant, MatchEntity(q.Root, ten), c.ten, "tenant")
	}
}

func TestPrefixHighlight(t *testing.T) {
	q, err := Parse("hub deplo", now)
	if err != nil {
		t.Fatal(err)
	}
	if !q.Positive[1].Prefix || q.Positive[0].Prefix {
		t.Fatalf("prefix flags: %v %v", q.Positive[0].Prefix, q.Positive[1].Prefix)
	}
	if got := q.HighlightWords("Deployed the Hub"); !reflect.DeepEqual(got, []Span{{0, 8}, {13, 16}}) {
		t.Errorf("highlights %v", got)
	}
	if got := q.HighlightWords("résumé DÉPLOYÉ"); !reflect.DeepEqual(got, []Span{{7, 14}}) {
		t.Errorf("folded highlights %v", got)
	}
}

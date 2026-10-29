package search

import (
	"slices"
	"testing"
	"time"
)

// Spec 154 row B5 (C11): type:contact, the reader's own contacts. Its
// spellings name it, a plain search includes it (spec 2.3), the free text
// filters a contact entity, and an operator no contact has leaves it out.
// CONTROL: from: (a message party) and name: never select contact.
func TestContactGrammar(t *testing.T) {
	now := time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		q     string
		types []Type
	}{
		{"type:contact", []Type{TypeContact}},
		{"type:contacts FirstName", []Type{TypeContact}},
		{"kind:contact 5550100000", []Type{TypeContact}},
		{"type:user,contact FirstName", []Type{TypeUser, TypeContact}},
		{"from:HUM-3 FirstName", []Type{TypeMessage, TypeTopic, TypeFile}},                                  // CONTROL
		{"name:FirstName", []Type{TypeTopic, TypeFile, TypeRobot, TypeUser, TypeChannel, TypeBox, TypeDoc}}, // CONTROL
	}
	for _, c := range cases {
		q, err := Parse(c.q, now)
		if err != nil {
			t.Errorf("%q: %v", c.q, err)
			continue
		}
		if !slices.Equal(q.Types, c.types) {
			t.Errorf("%q: types %v, want %v", c.q, q.Types, c.types)
		}
	}
	if q, _ := Parse("FirstName", now); !slices.Contains(q.Types, TypeContact) {
		t.Errorf("a plain search: types %v, want contact among them", q.Types)
	}
	if TypeContact.Group() != "contacts" || !slices.Equal(Aliases(TypeContact), []string{"contacts"}) {
		t.Errorf("group %q aliases %v, want contacts / [contacts]", TypeContact.Group(), Aliases(TypeContact))
	}
	e := Entity{Type: TypeContact, Name: "FirstName LastName",
		Text: []string{"FirstName", "LastName", "FirstName LastName", "first.last@example.com", "+1 555 010 0000", "15550100000"}}
	for q, want := range map[string]bool{
		"firstname": true, "5550100000": true, `"FirstName LastName"`: true, "first.last@example": true,
		"FirstName -LastName": false, "nobody": false,
	} {
		p, err := Parse("type:contact "+q, now)
		if err != nil || MatchEntity(p.Root, e) != want {
			t.Errorf("type:contact %s: match %v (err %v), want %v", q, !want, err, want)
		}
	}
}

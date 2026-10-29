package hub_test

import (
	"context"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 154 B5: the contact section of GET /v1/view/search (cases C9-C11),
// on B3's contacts rig (contacts_test.go). Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full). Fixtures are FirstName LastName
// and example.com only (spec 154 section 6).

// The search reads the rig's store as a store.Searcher: B3's wrapper
// (contactsCloneStore) passes those reads to the real store.

func (s *contactsCloneStore) searcher() store.Searcher { return s.Store.(store.Searcher) }

func (s *contactsCloneStore) SearchMessages(ctx context.Context, tenant string, q store.SearchQuery) ([]store.SearchMsgRow, error) {
	return s.searcher().SearchMessages(ctx, tenant, q)
}

func (s *contactsCloneStore) SearchFiles(ctx context.Context, tenant string, q store.SearchQuery) ([]store.SearchFileRow, error) {
	return s.searcher().SearchFiles(ctx, tenant, q)
}

func (s *contactsCloneStore) SearchTopics(ctx context.Context, tenant string, q store.SearchQuery) ([]store.SearchTopicRow, error) {
	return s.searcher().SearchTopics(ctx, tenant, q)
}

func (s *contactsCloneStore) TenantHumans(ctx context.Context, tenant string) ([]store.HumanEntry, error) {
	return s.searcher().TenantHumans(ctx, tenant)
}

// searchAs runs q from browser b and answers the status, the answer's types
// and its contacts group (nil when the answer has none).
func (c *contactsRig) searchAs(t *testing.T, b *http.Client, q, extra string) (int, []string, map[string]any) {
	t.Helper()
	code, raw, out := c.do(t, b, http.MethodGet, "/v1/view/search?q="+url.QueryEscape(q)+extra, nil, nil)
	if code != http.StatusOK {
		return code, nil, map[string]any{"body": string(raw)}
	}
	var types []string
	for _, x := range out["types"].([]any) {
		types = append(types, x.(string))
	}
	groups, _ := out["groups"].(map[string]any)
	sec, _ := groups["contacts"].(map[string]any)
	return code, types, sec
}

// contactHits is the contact ids of a contacts group.
func contactHits(sec map[string]any) []string {
	var ids []string
	rs, _ := sec["results"].([]any)
	for _, r := range rs {
		ids = append(ids, r.(map[string]any)["contact_id"].(string))
	}
	return ids
}

// C9 and C12: P1's plain search finds P1's contact beside the members, with
// the four values and the name highlighted; no log line carries a value.
func TestSearchContactsFindsOwn(t *testing.T) {
	c := newContactsRig(t, onAll)
	id := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone})
	code, types, sec := c.searchAs(t, c.b1, ctFirst, "")
	if code != http.StatusOK || !slices.Contains(types, "contact") || !slices.Contains(types, "user") {
		t.Fatalf("C9: search = %d types %v, want contact searched by default with user", code, types)
	}
	if got := contactHits(sec); !slices.Equal(got, []string{id}) {
		t.Fatalf("C9: contacts %v, want [%s]", got, id)
	}
	hit := sec["results"].([]any)[0].(map[string]any)
	want := map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone, "google": false}
	for k, v := range want {
		if hit[k] != v {
			t.Errorf("C9: hit %s = %v, want %v", k, hit[k], v)
		}
	}
	name, _ := hit["name"].(map[string]any)
	if name["text"] != ctFirst+" "+ctLast || len(name["highlights"].([]any)) == 0 {
		t.Errorf("C9: hit name = %v, want %q highlighted", name, ctFirst+" "+ctLast)
	}
	if code, _, sec := c.searchAs(t, c.b1, "nomatchword", ""); code != http.StatusOK || len(contactHits(sec)) != 0 {
		t.Errorf("CONTROL: a word no contact holds = %d %v, want no hit", code, contactHits(sec))
	}
	logs := realmLogs(c.logs)
	for _, banned := range []string{ctFirst, ctLast, ctEmail, ctPhone, "5550100000"} {
		if strings.Contains(logs, banned) {
			t.Errorf("C12: a log line carries the contact value %q", banned)
		}
	}
}

// C10: another person, an admin of P1's own workspace or a stranger, finds
// none of P1's contacts; twin: P1's own search finds it.
func TestSearchContactsOtherPersonSeesNone(t *testing.T) {
	c := newContactsRig(t, onAll)
	id := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "email": ctEmail})
	if _, _, sec := c.searchAs(t, c.b1, ctFirst, ""); !slices.Equal(contactHits(sec), []string{id}) {
		t.Fatalf("twin: P1's own search = %v, want [%s]", contactHits(sec), id)
	}
	admin, _ := c.other(t, "admin")
	stranger, _ := c.other(t, "")
	for name, b := range map[string]*http.Client{"admin of W1": admin, "stranger": stranger} {
		for _, q := range []string{ctFirst, "type:contact " + ctFirst, "type:contact"} {
			code, _, sec := c.searchAs(t, b, q, "")
			if code != http.StatusOK || len(contactHits(sec)) != 0 {
				t.Errorf("C10: %s searching %q = %d %v, want none of P1's", name, q, code, contactHits(sec))
			}
		}
	}
}

// C10b and C10c: a query of digits finds the phone with its spaces and
// punctuation; the email's prefix finds it; P1 finds from W2 a contact
// added in W1 (one list per person).
func TestSearchContactsPhoneDigitsAndOtherWorkspace(t *testing.T) {
	c := newContactsRig(t, onAll)
	id := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone})
	cases := []struct {
		b    *http.Client
		name string
		q    string
	}{
		{c.b1, "C10b digits", "5550100000"},
		{c.b1, "a digit run", "0100"},
		{c.b1, "the email's prefix", "first.last@"},
		{c.b1, "the last name, any case", strings.ToLower(ctLast)},
		{c.b2, "C10c from W2", ctFirst},
		{c.b2, "C10c from W2, digits", "5550100000"},
	}
	for _, k := range cases {
		if code, _, sec := c.searchAs(t, k.b, k.q, ""); code != http.StatusOK || !slices.Equal(contactHits(sec), []string{id}) {
			t.Errorf("%s: %q = %d %v, want [%s]", k.name, k.q, code, contactHits(sec), id)
		}
	}
	if _, _, sec := c.searchAs(t, c.b1, "5550199999", ""); len(contactHits(sec)) != 0 {
		t.Errorf("CONTROL: other digits = %v, want none", contactHits(sec))
	}
}

// C11: type:contact (and type:contacts) answers the contact section only;
// OR and - filter it as every section; a page of one carries next.
func TestSearchContactsTypeContact(t *testing.T) {
	c := newContactsRig(t, onAll)
	a := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "last_name": ctLast})
	b := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "last_name": "Other"})
	for _, q := range []string{"type:contact " + ctFirst, "kind:contacts " + ctFirst} {
		code, types, sec := c.searchAs(t, c.b1, q, "")
		if code != http.StatusOK || !slices.Equal(types, []string{"contact"}) || !slices.Equal(contactHits(sec), []string{a, b}) {
			t.Errorf("C11: %q = %d types %v %v, want contact only, [%s %s]", q, code, types, contactHits(sec), a, b)
		}
	}
	for q, want := range map[string][]string{
		ctFirst + " -other":       {a},
		"other OR " + ctLast:      {a, b},
		ctFirst + " " + ctLast:    {a},
		`"` + ctFirst + ` other"`: {b},
	} {
		if _, _, sec := c.searchAs(t, c.b1, "type:contact "+q, ""); !slices.Equal(contactHits(sec), want) {
			t.Errorf("type:contact %s = %v, want %v", q, contactHits(sec), want)
		}
	}
	_, _, sec := c.searchAs(t, c.b1, "type:contact "+ctFirst, "&limit=1")
	next, _ := sec["next"].(string)
	if !slices.Equal(contactHits(sec), []string{a}) || next == "" {
		t.Fatalf("page 1 of 1 = %v next %q, want [%s] and a cursor", contactHits(sec), next, a)
	}
	_, _, sec = c.searchAs(t, c.b1, "type:contact "+ctFirst, "&limit=1&cursor="+url.QueryEscape(next))
	if !slices.Equal(contactHits(sec), []string{b}) || sec["next"] != nil {
		t.Errorf("page 2 = %v next %v, want [%s] and no cursor", contactHits(sec), sec["next"], b)
	}
	if code, types, _ := c.searchAs(t, c.b1, "from:HUM-1 "+ctFirst, ""); code != http.StatusOK || slices.Contains(types, "contact") {
		t.Errorf("from: (no contact field) = %d types %v, want no contact section", code, types)
	}
}

// Spec 2.9 and the person gate: outside contacts.workspaces the answer has
// no contact section (type:contact answers none); an act-as clone session
// and a box token get none; twin: inside the switch P1 finds it.
func TestSearchContactsKillSwitchAndPersonGate(t *testing.T) {
	c := newContactsRig(t, func(_, w2 string) []string { return []string{w2} })
	id := c.create(t, c.b2, map[string]any{"first_name": ctFirst})
	if _, types, sec := c.searchAs(t, c.b2, ctFirst, ""); !slices.Contains(types, "contact") || !slices.Equal(contactHits(sec), []string{id}) {
		t.Fatalf("twin: W2 (on) = types %v %v, want [%s]", types, contactHits(sec), id)
	}
	for _, q := range []string{ctFirst, "type:contact " + ctFirst} {
		code, types, sec := c.searchAs(t, c.b1, q, "")
		if code != http.StatusOK || slices.Contains(types, "contact") || sec != nil {
			t.Errorf("W1 (off) %q = %d types %v section %v, want no contact section", q, code, types, sec)
		}
	}
	code, _, out := c.do(t, c.b2, http.MethodGet, "/v1/view/search?q="+ctFirst, nil, map[string]string{"Authorization": "Bearer box-agent-token"})
	if groups, _ := out["groups"].(map[string]any); code == http.StatusOK && groups["contacts"] != nil {
		t.Errorf("a box token = %d %v, want no contact section", code, groups["contacts"])
	}
	c.cs.setClone(c.p1)
	if _, types, sec := c.searchAs(t, c.b2, ctFirst, ""); slices.Contains(types, "contact") || len(contactHits(sec)) != 0 {
		t.Errorf("act-as clone = types %v %v, want no contact section", types, contactHits(sec))
	}
}

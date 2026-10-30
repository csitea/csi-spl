package hub_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 154 B6 (section 2.4, cases C13-C13e): member_id on the list and
// the card. Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full). The rig's P1 owns W1 and is a developer in W2;
// every member below is seated in W1 only. Fixtures are example.com.

// countingMatch counts the hub's member-match store calls (C13e).
type countingMatch struct {
	store.ContactMembers
	mu    sync.Mutex
	calls int
}

func (c *countingMatch) MembersByVerifiedEmail(ctx context.Context, tenant string, emails []string) (map[string]string, error) {
	c.mu.Lock()
	c.calls++
	c.mu.Unlock()
	return c.ContactMembers.MembersByVerifiedEmail(ctx, tenant, emails)
}

func (c *countingMatch) n() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls
}

// memberOf seats a fresh address in tid through a verified Google identity
// (join) and answers the address and its human.
func (c *contactsRig) memberOf(t *testing.T, tid string) (string, string) {
	t.Helper()
	email := freshEmail()
	return email, join(t, c.r.e, email, tid)
}

// memberIDs is the list from browser b, member_id by contact id ("" = null).
func (c *contactsRig) memberIDs(t *testing.T, b *http.Client, query string) map[string]string {
	t.Helper()
	code, raw, out := c.do(t, b, http.MethodGet, contactsBase+query, nil, nil)
	if code != http.StatusOK {
		t.Fatalf("GET contacts = %d %s", code, raw)
	}
	got := map[string]string{}
	for _, ct := range contactsOf(t, out) {
		m, _ := ct["member_id"].(string)
		got[ct["contact_id"].(string)] = m
	}
	return got
}

// cardMemberID is the card's member_id from browser b ("" = null); the
// key must be in the body, null or not.
func (c *contactsRig) cardMemberID(t *testing.T, b *http.Client, id string) string {
	t.Helper()
	code, raw, out := c.do(t, b, http.MethodGet, contactsBase+"/"+id, nil, nil)
	if code != http.StatusOK {
		t.Fatalf("GET contact = %d %s", code, raw)
	}
	v, has := out["member_id"]
	if !has {
		t.Fatalf("card has no member_id key: %s", raw)
	}
	m, _ := v.(string)
	return m
}

// C13 and C13c: a verified member of W1 matches on the list and the card
// while P1 reads from W1; read from W2, where that human is no member, the
// contact answers exactly what an address of no human answers.
func TestContactsMatchMember(t *testing.T) {
	c := newContactsRig(t, onAll)
	email, hum := c.memberOf(t, c.w1)
	matched := c.create(t, c.b1, map[string]any{"first_name": "FirstName", "email": strings.ToUpper(email)})
	nobody := c.create(t, c.b1, map[string]any{"first_name": "FirstName", "email": freshEmail()})
	noEmail := c.create(t, c.b1, map[string]any{"first_name": "FirstName", "phone": ctPhone})

	w1 := c.memberIDs(t, c.b1, "")
	if w1[matched] != hum || w1[nobody] != "" || w1[noEmail] != "" {
		t.Errorf("C13 list from W1 = %v, want %s on %s only", w1, hum, matched)
	}
	if got := c.cardMemberID(t, c.b1, matched); got != hum {
		t.Errorf("C13 card from W1 = %q, want %s", got, hum)
	}

	w2 := c.memberIDs(t, c.b2, "")
	if w2[matched] != "" || w2[nobody] != "" {
		t.Errorf("C13c list from W2 = %v, want every member_id null", w2)
	}
	if got := c.cardMemberID(t, c.b2, matched); got != "" {
		t.Errorf("C13c card from W2 = %q, want null", got)
	}
	// The same body as an address of no human: only the values differ.
	_, a, _ := c.do(t, c.b2, http.MethodGet, contactsBase+"/"+matched, nil, nil)
	_, b, _ := c.do(t, c.b2, http.MethodGet, contactsBase+"/"+nobody, nil, nil)
	if !strings.Contains(string(a), `"member_id":null`) || !strings.Contains(string(b), `"member_id":null`) {
		t.Errorf("C13c bodies:\n%s\n%s\nwant member_id null in both", a, b)
	}
}

// C13b: the address is the human's humans.email (a member of W1), but no
// verified identity carries it any more: no match. Twin: a member whose
// identity is verified matches on the same list.
func TestContactsMatchVerifiedOnly(t *testing.T) {
	c := newContactsRig(t, onAll)
	unverified, _ := c.memberOf(t, c.w1)
	if err := c.r.e.st.(store.Humans).UnlinkIdentity(context.Background(), "google", "s-"+unverified); err != nil {
		t.Fatal(err)
	}
	verified, hum := c.memberOf(t, c.w1)
	u := c.create(t, c.b1, map[string]any{"email": unverified})
	v := c.create(t, c.b1, map[string]any{"email": verified})
	got := c.memberIDs(t, c.b1, "")
	if got[u] != "" {
		t.Errorf("C13b: humans.email only = %q, want null", got[u])
	}
	if got[v] != hum {
		t.Errorf("C13b twin: verified = %q, want %s", got[v], hum)
	}
}

// C13d: a suspended member of W1 does not match; the twin is the same
// member, matched before the suspension.
func TestContactsMatchDisabledMember(t *testing.T) {
	c := newContactsRig(t, onAll)
	email, hum := c.memberOf(t, c.w1)
	id := c.create(t, c.b1, map[string]any{"email": email})
	if got := c.cardMemberID(t, c.b1, id); got != hum {
		t.Fatalf("C13d twin: before the suspension = %q, want %s", got, hum)
	}
	if err := c.r.e.st.(store.TenantSettings).SetMemberDisabled(context.Background(), c.w1, hum, true, time.Now()); err != nil {
		t.Fatal(err)
	}
	if got := c.cardMemberID(t, c.b1, id); got != "" {
		t.Errorf("C13d card: disabled member = %q, want null", got)
	}
	if got := c.memberIDs(t, c.b1, ""); got[id] != "" {
		t.Errorf("C13d list: disabled member = %q, want null", got[id])
	}
}

// C13e: a full page of 100 contacts is one match call, not one per
// contact; the twins, a page with no contact and a page whose contacts
// have no email, make none.
func TestContactsMatchOneCallPerPage(t *testing.T) {
	c := newContactsRig(t, onAll)
	cm := &countingMatch{ContactMembers: c.cs.ContactMembers}
	c.cs.ContactMembers = cm
	email, hum := c.memberOf(t, c.w1)
	first := c.create(t, c.b1, map[string]any{"email": email})
	for i := 1; i < store.ContactsPageMax; i++ {
		c.create(t, c.b1, map[string]any{"last_name": fmt.Sprintf("Page%03d", i), "email": freshEmail()})
	}
	before := cm.n()
	got := c.memberIDs(t, c.b1, "")
	if len(got) != store.ContactsPageMax {
		t.Fatalf("page = %d contacts, want %d", len(got), store.ContactsPageMax)
	}
	if calls := cm.n() - before; calls != 1 {
		t.Errorf("C13e: a page of %d = %d match calls, want 1", len(got), calls)
	}
	if got[first] != hum {
		t.Errorf("C13e: the member on the page = %q, want %s", got[first], hum)
	}
	before = cm.n()
	if empty := c.memberIDs(t, c.b1, "?q=nomatchatall"); len(empty) != 0 {
		t.Fatalf("twin: q page = %v, want empty", empty)
	}
	if calls := cm.n() - before; calls != 0 {
		t.Errorf("C13e twin: an empty page = %d match calls, want 0", calls)
	}
	c.create(t, c.b1, map[string]any{"last_name": "Nomail", "phone": ctPhone})
	before = cm.n()
	if page := c.memberIDs(t, c.b1, "?q=nomail"); len(page) != 1 {
		t.Fatalf("twin: q=nomail page = %v, want the one contact with no email", page)
	}
	if calls := cm.n() - before; calls != 0 {
		t.Errorf("C13e twin: a page with no email = %d match calls, want 0", calls)
	}
}

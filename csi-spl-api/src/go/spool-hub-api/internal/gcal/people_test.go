package gcal_test

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// Spec 154 row B8 (SPL-6253): the People API side, against fakegcal only.

func ffPerson() gcal.Person {
	return gcal.Person{
		Names:          []gcal.Name{{GivenName: "FirstName", FamilyName: "LastName"}},
		EmailAddresses: []gcal.EmailAddress{{Value: "first.last@example.com"}},
		PhoneNumbers:   []gcal.PhoneNumber{{Value: "+1 555 010 0000", Metadata: gcal.FieldMetadata{Primary: true}}, {Value: "+1 555 010 0001"}},
	}
}

// TestPeopleListSync: a full list in pages with a sync token on the last
// page, then only the changes, a deleted person marked deleted, and an
// expired token as ErrSyncTokenGone.
func TestPeopleListSync(t *testing.T) {
	g, f := newClient(t)
	now := t0
	f.Now = func() time.Time { return now }
	ctx := context.Background()
	tok := connect(t, g, f, "m1@example.com", now)
	a := f.AddPerson("m1@example.com", ffPerson())
	b := f.AddPerson("m1@example.com", ffPerson())
	f.AddPerson("m2@example.com", ffPerson()) // another account's book

	p1, err := g.ListConnections(ctx, tok.Access, gcal.PeopleListOptions{PageSize: 1})
	if err != nil || len(p1.Connections) != 1 || p1.NextPageToken == "" || p1.NextSyncToken != "" {
		t.Fatalf("page 1: %+v %v", p1, err)
	}
	p2, err := g.ListConnections(ctx, tok.Access, gcal.PeopleListOptions{PageSize: 1, PageToken: p1.NextPageToken})
	if err != nil || len(p2.Connections) != 1 || p2.NextSyncToken == "" {
		t.Fatalf("page 2: %+v %v", p2, err)
	}
	if p1.Connections[0].UpdatedAt().IsZero() || p1.Connections[0].ETag == "" {
		t.Errorf("a person carries no update time or etag: %+v", p1.Connections[0])
	}
	now = now.Add(time.Minute)
	if err := f.RemovePerson("m1@example.com", a.ResourceName); err != nil {
		t.Fatal(err)
	}
	ch, err := g.ListConnections(ctx, tok.Access, gcal.PeopleListOptions{SyncToken: p2.NextSyncToken})
	if err != nil || len(ch.Connections) != 1 || ch.Connections[0].ResourceName != a.ResourceName || !ch.Connections[0].Metadata.Deleted {
		t.Fatalf("changes: %+v %v, want only %s, deleted", ch, err, a.ResourceName)
	}
	f.ExpirePeopleSyncTokens("m1@example.com")
	_, err = g.ListConnections(ctx, tok.Access, gcal.PeopleListOptions{SyncToken: ch.NextSyncToken})
	if !errors.Is(err, gcal.ErrSyncTokenGone) {
		t.Errorf("expired token: %v, want ErrSyncTokenGone", err)
	}
	if got, err := g.GetPerson(ctx, tok.Access, b.ResourceName); err != nil || got.ETag != b.ETag {
		t.Errorf("get: %+v %v", got, err)
	}
}

// TestPeopleWrites: create, update with the etag (a stale one is
// ErrETagMismatch), delete (twice is done), and a 429 with Retry-After.
func TestPeopleWrites(t *testing.T) {
	g, f := newClient(t)
	f.Now = func() time.Time { return t0 }
	ctx := context.Background()
	tok := connect(t, g, f, "m1@example.com", t0)
	made, err := g.CreateContact(ctx, tok.Access, ffPerson())
	if err != nil || made.ResourceName == "" || made.ETag == "" || f.Calls("people.createContact") != 1 {
		t.Fatalf("create: %+v %v", made, err)
	}
	edit := made
	edit.Names = []gcal.Name{{GivenName: "Other", FamilyName: "LastName"}}
	upd, err := g.UpdateContact(ctx, tok.Access, edit, "names")
	if err != nil || upd.Names[0].GivenName != "Other" || upd.ETag == made.ETag || len(upd.PhoneNumbers) != 2 {
		t.Fatalf("update: %+v %v, want the name changed and both phones kept", upd, err)
	}
	if _, err := g.UpdateContact(ctx, tok.Access, edit, "names"); !errors.Is(err, gcal.ErrETagMismatch) {
		t.Errorf("stale etag: %v, want ErrETagMismatch", err)
	}
	if err := g.DeleteContact(ctx, tok.Access, made.ResourceName); err != nil {
		t.Fatal(err)
	}
	if err := g.DeleteContact(ctx, tok.Access, made.ResourceName); err != nil {
		t.Errorf("delete of a gone person: %v, want done", err)
	}
	f.FailPeople(http.StatusTooManyRequests, 1, 30)
	_, err = g.ListConnections(ctx, tok.Access, gcal.PeopleListOptions{})
	var he *gcal.HTTPError
	if !errors.Is(err, gcal.ErrRateLimited) || !errors.As(err, &he) || he.RetryAfter != 30*time.Second {
		t.Errorf("429: %v, want ErrRateLimited with Retry-After 30 s", err)
	}
	if errors.Is(err, gcal.ErrETagMismatch) || errors.Is(err, gcal.ErrSyncTokenGone) {
		t.Errorf("429 read as another error: %v", err)
	}
}

// TestPeopleNotConfigured: a client with no People root calls nothing.
func TestPeopleNotConfigured(t *testing.T) {
	_, f := newClient(t)
	cfg := f.Config(testRedirect, testScopes)
	cfg.PeopleBase = ""
	g, err := gcal.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if g.PeopleConfigured() {
		t.Error("PeopleConfigured with no root")
	}
	if _, err := g.ListConnections(context.Background(), marketing.NewPlaintext("x"), gcal.PeopleListOptions{}); !errors.Is(err, gcal.ErrPeopleNotConfigured) {
		t.Errorf("list: %v, want ErrPeopleNotConfigured", err)
	}
}

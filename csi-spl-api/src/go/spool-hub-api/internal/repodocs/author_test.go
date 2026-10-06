package repodocs

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

const tenant = "acme"

type noticeKey struct{ human, name, email string }

// fakeDir is a Directory over maps.
type fakeDir struct {
	people   map[string]Person
	mappings map[string]Mapping
	known    map[string][2]string // lower(email) -> {name, email}
	notices  map[noticeKey]bool
	perms    map[string]bool // human -> holds docs.write
	seats    map[string]string
	err      error
}

func newDir() *fakeDir {
	return &fakeDir{
		people: map[string]Person{
			"HUM-1": {HumanID: "HUM-1", Member: true, DisplayName: "FirstName LastName", Email: "first@example.com", EmailVerified: true},
			"HUM-2": {HumanID: "HUM-2", Member: true, DisplayName: "Other Name", Email: "other@example.com"},
		},
		mappings: map[string]Mapping{},
		known:    map[string][2]string{},
		notices:  map[noticeKey]bool{},
		perms:    map[string]bool{"HUM-1": true, "HUM-2": true},
		seats:    map[string]string{},
	}
}

func (f *fakeDir) Person(_ context.Context, _, h string) (Person, error) {
	return f.people[h], f.err
}
func (f *fakeDir) Mapping(_ context.Context, _, h string) (Mapping, bool, error) {
	m, ok := f.mappings[h]
	return m, ok, f.err
}
func (f *fakeDir) KnownAuthor(_ context.Context, email string) (string, string, bool, error) {
	k, ok := f.known[strings.ToLower(email)]
	return k[0], k[1], ok, f.err
}
func (f *fakeDir) HasNotice(_ context.Context, _, h, n, e string) (bool, error) {
	return f.notices[noticeKey{h, n, e}], f.err
}
func (f *fakeDir) Can(_ context.Context, _, h, perm string) (bool, error) {
	return perm == DocsWrite && f.perms[h], f.err
}
func (f *fakeDir) SeatHuman(_ context.Context, _, seat string) (string, error) {
	return f.seats[seat], f.err
}

func wantRefusal(t *testing.T, err error, status int, reason, detail string) {
	t.Helper()
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("err = %v, want a Refusal %s", err, reason)
	}
	if r.Status != status || r.Reason != reason || r.Detail != detail {
		t.Fatalf("refusal = %+v, want %d %s (%s)", *r, status, reason, detail)
	}
}

func TestDocsWriteMatchesRBAC(t *testing.T) {
	if DocsWrite != rbac.DocsWrite {
		t.Fatalf("DocsWrite = %q, rbac has %q", DocsWrite, rbac.DocsWrite)
	}
}

func TestResolveAuthorSignin(t *testing.T) {
	a, err := ResolveAuthor(context.Background(), newDir(), tenant, "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	if a != (Author{"FirstName LastName", "first@example.com", SourceSignin}) {
		t.Fatalf("author = %+v", a)
	}
}

func TestResolveAuthorHistory(t *testing.T) {
	d := newDir()
	d.known["first@example.com"] = [2]string{"FirstName History", "First@Example.com"}
	a, err := ResolveAuthor(context.Background(), d, tenant, "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	if a != (Author{"FirstName History", "First@Example.com", SourceHistory}) {
		t.Fatalf("author = %+v, want the history's spelling", a)
	}
}

func TestResolveAuthorMappingWins(t *testing.T) {
	d := newDir()
	d.known["first@example.com"] = [2]string{"FirstName History", "first@example.com"}
	d.mappings["HUM-1"] = Mapping{GitName: "FirstName Mapped", GitEmail: "mapped@example.com", Verified: true, AllowAgents: true}
	a, err := ResolveAuthor(context.Background(), d, tenant, "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	if a != (Author{"FirstName Mapped", "mapped@example.com", SourceMapping}) {
		t.Fatalf("author = %+v", a)
	}
}

func TestResolveAuthorMappingUnverified(t *testing.T) {
	d := newDir()
	d.mappings["HUM-1"] = Mapping{GitName: "FirstName Mapped", GitEmail: "mapped@example.com", AllowAgents: true}
	_, err := ResolveAuthor(context.Background(), d, tenant, "HUM-1")
	wantRefusal(t, err, http.StatusForbidden, ReasonEmailUnverified, SourceMapping)
}

// An opt-out-only row (agents off, no identity) is no mapping: rule 3 applies.
func TestResolveAuthorOptOutRowFallsThrough(t *testing.T) {
	d := newDir()
	d.mappings["HUM-1"] = Mapping{AllowAgents: false}
	a, err := ResolveAuthor(context.Background(), d, tenant, "HUM-1")
	if err != nil || a.Source != SourceSignin {
		t.Fatalf("author = %+v, err = %v, want signin", a, err)
	}
}

func TestResolveAuthorUnverifiedSignin(t *testing.T) {
	d := newDir()
	_, err := ResolveAuthor(context.Background(), d, tenant, "HUM-2")
	wantRefusal(t, err, http.StatusForbidden, ReasonEmailUnverified, SourceSignin)
	// Even when the unverified address is in the history.
	d.known["other@example.com"] = [2]string{"Other Name", "other@example.com"}
	_, err = ResolveAuthor(context.Background(), d, tenant, "HUM-2")
	wantRefusal(t, err, http.StatusForbidden, ReasonEmailUnverified, SourceSignin)
	// A verified flag on no address is no address.
	d.people["HUM-3"] = Person{HumanID: "HUM-3", Member: true, EmailVerified: true}
	_, err = ResolveAuthor(context.Background(), d, tenant, "HUM-3")
	wantRefusal(t, err, http.StatusForbidden, ReasonEmailUnverified, SourceSignin)
}

// A display name cannot break the commit header or add a line.
func TestResolveAuthorCleansName(t *testing.T) {
	d := newDir()
	p := d.people["HUM-1"]
	p.DisplayName = "  First <x@y.z>\nCo-Authored-By: z  "
	d.people["HUM-1"] = p
	a, _ := ResolveAuthor(context.Background(), d, tenant, "HUM-1")
	if strings.ContainsAny(a.Name, "<>\n") || a.Name != "First x@y.z Co-Authored-By: z" {
		t.Fatalf("name = %q", a.Name)
	}
	p.DisplayName = " "
	d.people["HUM-1"] = p
	if a, _ = ResolveAuthor(context.Background(), d, tenant, "HUM-1"); a.Name != "first" {
		t.Fatalf("empty display name -> %q, want the address's local part", a.Name)
	}
}

func TestResolveAuthorStoreError(t *testing.T) {
	d := newDir()
	d.err = errors.New("db down")
	_, err := ResolveAuthor(context.Background(), d, tenant, "HUM-1")
	var r *Refusal
	if err == nil || errors.As(err, &r) {
		t.Fatalf("err = %v, want the store error, not a refusal", err)
	}
}

func TestNeedsNotice(t *testing.T) {
	ctx := context.Background()
	d := newDir()
	a, _ := ResolveAuthor(ctx, d, tenant, "HUM-1")
	if need, err := NeedsNotice(ctx, d, tenant, "HUM-1", a); err != nil || !need {
		t.Fatalf("no consent: need = %v, err = %v", need, err)
	}
	d.notices[noticeKey{"HUM-1", a.Name, a.Email}] = true
	if need, _ := NeedsNotice(ctx, d, tenant, "HUM-1", a); need {
		t.Fatal("consent given: still needs the notice")
	}
	// A changed identity (a new mapping row) asks again.
	d.mappings["HUM-1"] = Mapping{GitName: "FirstName Mapped", GitEmail: "mapped@example.com", Verified: true}
	b, _ := ResolveAuthor(ctx, d, tenant, "HUM-1")
	if need, _ := NeedsNotice(ctx, d, tenant, "HUM-1", b); !need {
		t.Fatal("changed identity: no notice")
	}
	r := NoticeRequired()
	if r.Status != http.StatusPreconditionRequired || r.Reason != ReasonAuthorNoticeRequired {
		t.Fatalf("NoticeRequired = %+v", *r)
	}
}

func TestCheckRequester(t *testing.T) {
	ctx := context.Background()
	d := newDir()
	d.seats["box-free"] = ""
	d.seats["box-hum1"] = "HUM-1"
	d.seats["box-hum9"] = "HUM-9"
	d.people["HUM-4"] = Person{HumanID: "HUM-4", Member: false, Email: "gone@example.com", EmailVerified: true}
	d.people["HUM-5"] = Person{HumanID: "HUM-5", Member: true, Email: "demo@example.com", EmailVerified: true}
	d.people["HUM-6"] = Person{HumanID: "HUM-6", Member: true, Email: "off@example.com", EmailVerified: true}
	d.perms["HUM-6"] = true
	d.mappings["HUM-6"] = Mapping{AllowAgents: false}

	for _, seat := range []string{"box-free", "box-hum1"} {
		if h, err := CheckRequester(ctx, d, tenant, seat, " HUM-1 "); err != nil || h != "HUM-1" {
			t.Fatalf("%s: valid requester -> %q, %v", seat, h, err)
		}
	}
	// allow_agents true on a mapping row lets the agent through.
	d.mappings["HUM-1"] = Mapping{AllowAgents: true}
	if _, err := CheckRequester(ctx, d, tenant, "box-free", "HUM-1"); err != nil {
		t.Fatal(err)
	}

	_, err := CheckRequester(ctx, d, tenant, "box-free", "")
	wantRefusal(t, err, http.StatusForbidden, ReasonRequesterRequired, "")
	for _, c := range []struct{ seat, req, detail string }{
		{"box-free", "HUM-404", RequesterNotMember},  // a: unknown
		{"box-free", "HUM-4", RequesterNotMember},    // a: left the workspace
		{"box-free", "HUM-5", RequesterNoDocsWrite},  // b: e.g. demo_user
		{"box-free", "HUM-2", RequesterUnverified},   // c
		{"box-free", "HUM-6", RequesterAgentsOff},    // d
		{"box-hum9", "HUM-1", RequesterNotSeatHuman}, // e
	} {
		_, err := CheckRequester(ctx, d, tenant, c.seat, c.req)
		wantRefusal(t, err, http.StatusForbidden, ReasonRequesterInvalid, c.detail)
	}
}

var trailerRe = regexp.MustCompile(`(?im)^(Co-Authored-By:|Claude-Session:)`)

func TestCommitMessage(t *testing.T) {
	a := Author{Name: "FirstName LastName", Email: "first@example.com", Source: SourceSignin}
	e := Edit{Env: "prd", Workspace: "acme", Path: "csi-spl-doc/doc/md/x.md", EditID: "e-1", Author: a}
	s, b := CommitMessage(e)
	if s != "docs: edit csi-spl-doc/doc/md/x.md" {
		t.Fatalf("prd subject = %q", s)
	}
	if b != "Edited in the Docs section of workspace acme (prd). Edit e-1." {
		t.Fatalf("body = %q", b)
	}
	e.Env = "dev"
	if s, _ = CommitMessage(e); s != "docs(dev): edit csi-spl-doc/doc/md/x.md" {
		t.Fatalf("dev subject = %q", s)
	}
	e.AgentID = "c-419"
	_, b = CommitMessage(e)
	if !strings.HasSuffix(b, "\n\nEdited by agent c-419 for FirstName LastName.") {
		t.Fatalf("agent body = %q", b)
	}
}

// The anchored grep of the leak gate over every generated message is 0, even
// when a value tries to open a trailer line of its own.
func TestCommitMessageNoTrailer(t *testing.T) {
	evil := "x\nCo-Authored-By: Claude <noreply@example.com>\nClaude-Session: https://example.com/s"
	for _, e := range []Edit{
		{Env: "prd", Workspace: "acme", Path: "a.md", EditID: "e-1", Author: Author{Name: "FirstName LastName"}},
		{Env: "dev", Workspace: "acme", Path: "a.md", EditID: "e-2", AgentID: "c-1", Author: Author{Name: "FirstName LastName"}},
		{Env: evil, Workspace: evil, Path: evil, EditID: evil, AgentID: evil, Author: Author{Name: evil}},
	} {
		s, b := CommitMessage(e)
		msg := s + "\n\n" + b
		if n := len(trailerRe.FindAllString(msg, -1)); n != 0 {
			t.Fatalf("%d trailer lines in %q", n, msg)
		}
		if strings.Contains(msg, "[skip ci]") || strings.Contains(strings.ToLower(msg), "generated with") {
			t.Fatalf("message %q", msg)
		}
		if strings.Contains(s, "\n") {
			t.Fatalf("subject spans lines: %q", s)
		}
	}
}

package hub_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal/fakegcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 154 B16 (SPL-6260): the pictures of Google contacts, section 11.4,
// cases C44-C46 of 11.7, against fakegcal's TLS photo server (photos.go);
// no test reaches Google. Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full). Fixtures are FirstName LastName and example.com.

type cpEnv struct {
	*csEnv
	photoHook *gcalHookRT // every picture request, before it is sent
	sent      *sentRT     // counts what the hub sends, as the fake may never see it
}

// sentRT counts every request the hub's picture client sends, redirects
// included: an off-list host or plain http to the TLS fake fails before the
// fake's handler, so only the client side proves "0 fetches".
type sentRT struct {
	base http.RoundTripper
	n    atomic.Int32
}

func (s *sentRT) RoundTrip(r *http.Request) (*http.Response, error) {
	s.n.Add(1)
	return s.base.RoundTrip(r)
}

// contactsPhotoEnvOf is contactsSyncEnvOf with the photo server on the
// host list and at most max pictures a person.
func contactsPhotoEnvOf(t *testing.T, max int) *cpEnv {
	t.Helper()
	ids := mktIDs(1)
	tid := ids[0]
	clock := &gcalClock{t: gcalSyncT0}
	f := fakegcal.New(t)
	f.Now = clock.now
	sent := &sentRT{base: f.ServePhotos(t).Transport}
	photoHook := &gcalHookRT{base: sent}
	cfg := f.Config(gcalApp+hub.GcalCallbackPath, gcalTestScopes)
	hook := &gcalHookRT{base: cfg.HTTP.Transport}
	cfg.HTTP = &http.Client{Transport: hook}
	google, err := gcal.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	sealer, err := marketing.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k",
		marketing.WithPurpose(hub.GcalPurpose))
	if err != nil {
		t.Fatal(err)
	}
	gc := &hub.GcalConnect{Google: google, Sealer: sealer, Workspaces: ids, CookieName: gcalCookie,
		WorkspaceURL: hub.GcalWorkspaceURL("{tenant}."+gcalApexDom, tid, gcalApp), ContactsScopes: gcalContactsTestScope}
	buf := &syncBuf{}
	e := mktEnvWith(t, nil, func(o *hub.Options) {
		o.Gcal = gc
		o.Log = zerolog.New(buf)
		o.Now = clock.now
		o.ContactsWorkspaces = ids
		o.ContactsPhotos = hub.ContactsPhotoConfig{Hosts: []string{"127.0.0.1"}, MaxPerPerson: max,
			HTTP: &http.Client{Transport: photoHook}}
	}, ids...)
	te := &gcalTestEnv{env: e, fake: f, gc: gc, clock: clock, log: buf, apex: tid}
	ce := &csEnv{gcalSyncEnv: &gcalSyncEnv{gcalTestEnv: te, tid: tid, hook: hook}}
	ce.hum = ce.bound(t)
	return &cpEnv{csEnv: ce, photoHook: photoHook, sent: sent}
}

// photoPNG is n bytes that start as a PNG; seed varies the bytes.
func photoPNG(n int, seed byte) []byte {
	b := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{seed}, n)...)
	return b[:n]
}

// photoPerson is a Google person i with one photo.
func photoPerson(i int, url string, def bool) gcal.Person {
	return gcal.Person{
		Names:          []gcal.Name{{GivenName: "FirstName", FamilyName: fmt.Sprintf("LastName%d", i)}},
		EmailAddresses: []gcal.EmailAddress{{Value: fmt.Sprintf("first.last.%d@example.com", i)}},
		Photos:         []gcal.Photo{{URL: url, Default: def, Metadata: gcal.FieldMetadata{Primary: true}}},
	}
}

// byResource is the member's live contact linked to resource.
func (pe *cpEnv) byResource(t *testing.T, resource string) store.Contact {
	t.Helper()
	for _, c := range pe.list(t) {
		if c.GoogleResource == resource {
			return c
		}
	}
	t.Fatalf("no contact linked to %s", resource)
	return store.Contact{}
}

func (pe *cpEnv) photos() int { return pe.fake.Calls("people.photo") }

// pictured counts the member's live contacts with a picture.
func (pe *cpEnv) pictured(t *testing.T) int {
	t.Helper()
	n := 0
	for _, c := range pe.list(t) {
		if c.PhotoSHA256 != "" {
			n++
		}
	}
	return n
}

func urlHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// C44: a primary user photo is fetched once with sz=128 and stored; a
// cycle that lists the person again (a name edit at Google) fetches 0; a
// new URL fetches once and replaces it; no user photo any more deletes it.
func TestContactsPhotoFetchOnce(t *testing.T) {
	pe := contactsPhotoEnvOf(t, 2000)
	body := photoPNG(10<<10, 1)
	u := pe.fake.PutPhoto("p1", body)
	g := pe.fake.AddPerson(fakegcal.DefaultEmail, photoPerson(1, u, false))
	pe.sync(t)
	if n, sz := pe.photos(), pe.fake.Calls("people.photo sz=128"); n != 1 || sz != 1 {
		t.Fatalf("C44: %d fetches (%d with sz=128), want 1 and 1", n, sz)
	}
	c := pe.byResource(t, g.ResourceName)
	p, err := pe.pc().ContactPhoto(context.Background(), pe.hum, c.ID)
	if err != nil || p.Mime != "image/png" || !bytes.Equal(p.Bytes, body) || p.SourceURLHash != urlHash(u) || c.PhotoSHA256 != p.SHA256 {
		t.Fatalf("C44: picture %s %d bytes hash %s (err %v), contact sha %q", p.Mime, len(p.Bytes), p.SourceURLHash, err, c.PhotoSHA256)
	}
	_ = pe.fake.EditPerson(fakegcal.DefaultEmail, g.ResourceName, func(p *gcal.Person) { p.Names[0].GivenName = "Edited" })
	pe.sync(t)
	if pe.byResource(t, g.ResourceName).FirstName != "Edited" {
		t.Fatal("CONTROL: the second cycle did not list the person again")
	}
	if n := pe.photos(); n != 1 {
		t.Errorf("C44: the next cycle fetched %d more, want 0", n-1)
	}
	u2 := pe.fake.PutPhoto("p1b", photoPNG(2<<10, 2))
	_ = pe.fake.EditPerson(fakegcal.DefaultEmail, g.ResourceName, func(p *gcal.Person) { p.Photos[0].URL = u2 })
	pe.sync(t)
	p2, err := pe.pc().ContactPhoto(context.Background(), pe.hum, c.ID)
	if pe.photos() != 2 || err != nil || p2.SourceURLHash != urlHash(u2) {
		t.Errorf("C44: a new URL: %d fetches in all (want 2), hash ok %v, err %v", pe.photos(), p2.SourceURLHash == urlHash(u2), err)
	}
	_ = pe.fake.EditPerson(fakegcal.DefaultEmail, g.ResourceName, func(p *gcal.Person) { p.Photos[0].Default = true })
	pe.sync(t)
	if c := pe.byResource(t, g.ResourceName); c.PhotoSHA256 != "" || pe.photos() != 2 {
		t.Errorf("C44: a default photo left sha %q after %d fetches, want none after 2", c.PhotoSHA256, pe.photos())
	}
}

// C45: a host off contacts.photo_hosts, plain http, a redirect off the list,
// four redirects, 70 KiB, GIF bytes and a default photo give no picture,
// and the off-list, http and default ones 0 fetches. Twins: an on-list PNG
// of 10 KiB, and one behind three redirects, are stored.
func TestContactsPhotoRefused(t *testing.T) {
	pe := contactsPhotoEnvOf(t, 2000)
	base := pe.fake.PhotoBase()
	offList := strings.Replace(base, "127.0.0.1", "localhost", 1)
	chain := func(name string, hops int) string {
		to := pe.fake.PutPhoto(name, photoPNG(1<<10, 3))
		for i := hops; i > 0; i-- {
			to = pe.fake.PutPhotoRedirect(fmt.Sprintf("%s-r%d", name, i), to)
		}
		return to
	}
	refused := map[string]string{
		"off-list":       offList + "/" + strings.TrimPrefix(pe.fake.PutPhoto("ok-off", photoPNG(1<<10, 4)), base+"/"),
		"http":           strings.Replace(pe.fake.PutPhoto("ok-http", photoPNG(1<<10, 5)), "https://", "http://", 1),
		"redirect off":   pe.fake.PutPhotoRedirect("redir-off", offList+"/ok-off"),
		"four redirects": chain("four", 4),
		"70 KiB":         pe.fake.PutPhoto("big", photoPNG(70<<10, 6)),
		"GIF":            pe.fake.PutPhoto("gif", append([]byte("GIF89a"), bytes.Repeat([]byte{7}, 1<<10)...)),
		"default":        pe.fake.PutPhoto("default", photoPNG(1<<10, 8)),
	}
	stored := map[string]string{"10 KiB PNG": pe.fake.PutPhoto("good", photoPNG(10<<10, 9)), "three redirects": chain("three", 3)}
	res := map[string]string{}
	i := 0
	for name, u := range refused {
		i++
		res[name] = pe.fake.AddPerson(fakegcal.DefaultEmail, photoPerson(i, u, name == "default")).ResourceName
	}
	for name, u := range stored {
		i++
		res[name] = pe.fake.AddPerson(fakegcal.DefaultEmail, photoPerson(i, u, false)).ResourceName
	}
	pe.sync(t)
	for name := range refused {
		if c := pe.byResource(t, res[name]); c.PhotoSHA256 != "" {
			t.Errorf("C45 %s: a picture was stored", name)
		}
	}
	for name := range stored {
		if c := pe.byResource(t, res[name]); c.PhotoSHA256 == "" {
			t.Errorf("C45 twin %s: no picture", name)
		}
	}
	// requests: redirect off 1, four redirects 4, 70 KiB 1, GIF 1, the 10 KiB
	// twin 1, three redirects 4; the off-list, http and default ones 0
	if n, got := pe.sent.n.Load(), pe.photos(); n != 12 || got != 12 {
		t.Errorf("C45: the hub sent %d photo requests, the fake got %d; want 12 and 12 (0 for off-list, http and default)", n, got)
	}
}

// The per-person cap (11.4, contacts.photo_max_per_person): past it a
// contact gets no picture and no fetch.
func TestContactsPhotoPerPersonCap(t *testing.T) {
	pe := contactsPhotoEnvOf(t, 2)
	for i := range 3 {
		pe.fake.AddPerson(fakegcal.DefaultEmail, photoPerson(i, pe.fake.PutPhoto(fmt.Sprintf("c%d", i), photoPNG(1<<10, byte(i))), false))
	}
	pe.sync(t)
	if got, n := pe.pictured(t), pe.photos(); got != 2 || n != 2 {
		t.Errorf("cap 2: %d pictures after %d fetches, want 2 and 2", got, n)
	}
	// W1 of the R7 review: the sync's status_detail says so, counts only
	const want = "Google contacts sync: pictures: 1 contact(s) have no picture: past contacts.photo_max_per_person (2 a person)"
	if d := pe.detail(t); d != want {
		t.Errorf("cap 2: status_detail %q, want %q", d, want)
	}
	pe.sync(t) // no one changed at Google: the line stays
	if d := pe.detail(t); d != want {
		t.Errorf("cap 2, a cycle with no change: status_detail %q, want %q", d, want)
	}
	// c0 loses its photo at Google and c2 is edited: c2 gets the free place
	var res []string
	for _, p := range pe.fake.People(fakegcal.DefaultEmail) {
		res = append(res, p.ResourceName)
	}
	sort.Strings(res)
	if err := pe.fake.EditPerson(fakegcal.DefaultEmail, res[0], func(p *gcal.Person) { p.Photos[0].Default = true }); err != nil {
		t.Fatal(err)
	}
	if err := pe.fake.EditPerson(fakegcal.DefaultEmail, res[2], func(p *gcal.Person) { p.Names[0].GivenName = "FirstNameB" }); err != nil {
		t.Fatal(err)
	}
	pe.sync(t)
	if got, d := pe.pictured(t), pe.detail(t); got != 2 || d != "" {
		t.Errorf("cap 2, a place freed: %d pictures, status_detail %q; want 2 and \"\"", got, d)
	}
}

// detail is the member's contacts sync status_detail.
func (pe *cpEnv) detail(t *testing.T) string {
	t.Helper()
	b, err := pe.st.(store.ContactsSyncs).ContactsSyncIn(context.Background(), pe.tid, pe.hum)
	if err != nil {
		t.Fatal(err)
	}
	return b.StatusDetail
}

// C46: 300 contacts with photos: 200 fetched this cycle, 100 the next, 0
// the one after; no pool connection held (no transaction open) during any
// picture fetch on Postgres.
func TestContactsPhotoPerCycleCap(t *testing.T) {
	pe := contactsPhotoEnvOf(t, 2000)
	for i := range 300 {
		u := pe.fake.PutPhoto(fmt.Sprintf("m%d", i), photoPNG(1<<10, byte(i)))
		pe.fake.AddPerson(fakegcal.DefaultEmail, photoPerson(i, u, false))
	}
	pg, _ := pe.st.(*store.Postgres)
	var held, seen atomic.Int32
	pe.photoHook.set(func(*http.Request) {
		seen.Add(1)
		if pg != nil && pg.Pool().Stat().AcquiredConns() != 0 {
			held.Add(1)
		}
	})
	pe.sync(t)
	if got, n := pe.pictured(t), pe.photos(); got != 200 || n != 200 {
		t.Fatalf("C46 first cycle: %d pictures after %d fetches, want 200 and 200", got, n)
	}
	pe.sync(t)
	if got, n, all := pe.pictured(t), pe.photos(), len(pe.list(t)); got != 300 || n != 300 || all != 300 {
		t.Fatalf("C46 second cycle: %d pictures after %d fetches, %d contacts; want 300, 300, 300", got, n, all)
	}
	pe.sync(t)
	if n := pe.photos(); n != 300 {
		t.Errorf("C46 third cycle: %d fetches in all, want 300", n)
	}
	if seen.Load() != 300 {
		t.Fatalf("CONTROL: the hook saw %d picture requests, want 300", seen.Load())
	}
	if n := held.Load(); n != 0 {
		t.Errorf("C46: %d picture fetch(es) made holding a pool connection, want 0", n)
	}
}

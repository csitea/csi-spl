package hub

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The pictures of Google contacts (spec 154 section 11.4, build row B16).
// The In half notes, for each person of each page, the primary photo whose
// default is false (a default is Google's lettered placeholder: no
// picture). After the cycle's writes, run calls photos: one short inPerson
// read of the person's contacts, then, outside every transaction, one fetch
// per contact whose URL is new (source_url_hash = SHA-256 of the URL as
// Google gave it), each stored by its own short write.
//
// A fetch is https only, to a host of cnf contacts.photo_hosts (no literal
// host here, developer guide 2.3.2), with at most 3 redirects each also on
// that list, a 10 s timeout, sz=128 appended, at most store.ContactPhotoMax
// bytes, and PNG, JPEG or WebP by the magic bytes (Content-Type is never
// trusted). At most contactsPhotoPerCycle fetches a cycle: when more are
// due, the cycle keeps the sync token it started from, so the next cycle
// lists the same people again and fetches the rest (the ones done skip by
// their hash). No primary user photo any more: the picture row is deleted.
// No contact value or URL is logged (C12).

const (
	contactsPhotoPerCycle   = 200 // the write cap of 2.5
	contactsPhotoTimeout    = 10 * time.Second
	contactsPhotoRedirects  = 3
	contactsPhotoSize       = "128" // Google's sz= (11.5)
	contactsPhotoRenewEvery = 20    // fetches between two lease renewals
)

// ContactsPhotoConfig is the picture fetch (cnf contacts.photo_hosts and
// contacts.photo_max_per_person). No Hosts = nothing is fetched. HTTP nil =
// a plain client; a test passes one that trusts its TLS server.
type ContactsPhotoConfig struct {
	Hosts        []string
	MaxPerPerson int
	HTTP         *http.Client
}

var (
	errPhotoOffList   = errors.New("contacts photo: host not on contacts.photo_hosts")
	errPhotoRedirects = errors.New("contacts photo: too many redirects")
	errPhotoTooBig    = errors.New("contacts photo: above the size cap")
	errPhotoType      = errors.New("contacts photo: not PNG, JPEG or WebP")
)

// contactsPhotoPass is what the In half saw of the cycle's pictures.
type contactsPhotoPass struct {
	started bool
	token   string            // the sync token the cycle started from
	want    map[string]string // Google resource -> its user photo URL, "" = none
}

// contactsPhotoCount is what one pass did, for the cycle's log line.
type contactsPhotoCount struct {
	fetched, stored, deleted, dropped, overCap int
	more                                       bool // fetches left for the next cycle
}

// notePhotos records one page's people; inPages calls it before the page
// is applied.
func (cy *contactsCycle) notePhotos(people []gcal.Person) {
	p := &cy.photo
	if !p.started {
		p.started, p.token, p.want = true, cy.b.SyncToken, map[string]string{}
	}
	for _, g := range people {
		if g.ResourceName != "" && !g.Metadata.Deleted {
			p.want[g.ResourceName] = contactPhotoURL(g.Photos)
		}
	}
}

// contactPhotoURL is the primary photo's URL (else the first's), "" when
// it is Google's default or there is none.
func contactPhotoURL(ps []gcal.Photo) string {
	i := primaryIndex(len(ps), func(i int) bool { return ps[i].Metadata.IsPrimary() })
	if i < 0 || ps[i].Default {
		return ""
	}
	return ps[i].URL
}

// photos is the cycle's picture pass, after its writes. Only a lease it
// cannot renew fails the cycle; that or a store error keeps the starting
// sync token, so the next cycle tries again.
func (cy *contactsCycle) photos(ctx context.Context) error {
	pc, ok := cy.s.o.Store.(store.PersonalContacts)
	if !ok || len(cy.photo.want) == 0 {
		return nil
	}
	var n contactsPhotoCount
	err := cy.photoRows(ctx, pc, &n)
	if n.more || err != nil {
		cy.b.SyncToken = cy.photo.token
	}
	cy.s.o.Log.Info().Str("tenant", cy.b.Tenant).Str("person", cy.b.Human).Int("fetched", n.fetched).
		Int("stored", n.stored).Int("deleted", n.deleted).Int("dropped", n.dropped).Int("over_cap", n.overCap).
		Bool("more", n.more).Msg("contacts: pictures")
	if errors.Is(err, errContactsLease) {
		return err
	}
	if err != nil {
		cy.s.o.Log.Warn().Str("err", contactsDetail(err)).Msg("contacts: pictures")
	}
	return nil
}

// errContactsLease wraps a lease the picture pass could not renew.
var errContactsLease = errors.New("contacts photo: lease")

// photoRows walks the noted people that are the person's linked contacts,
// in resource order.
func (cy *contactsCycle) photoRows(ctx context.Context, pc store.PersonalContacts, n *contactsPhotoCount) error {
	cs, err := pc.ExportContacts(ctx, cy.b.Human)
	if err != nil {
		return err
	}
	held, err := pc.CountContactPhotos(ctx, cy.b.Human)
	if err != nil {
		return err
	}
	byRes := map[string]store.Contact{}
	for _, c := range cs {
		if c.GoogleAccount == cy.account && c.GoogleResource != "" {
			byRes[c.GoogleResource] = c
		}
	}
	res := make([]string, 0, len(cy.photo.want))
	for r := range cy.photo.want {
		res = append(res, r)
	}
	sort.Strings(res)
	for _, r := range res {
		c, ok := byRes[r]
		if !ok {
			continue
		}
		if err := cy.photoRow(ctx, pc, c, cy.photo.want[r], &held, n); err != nil {
			return err
		}
	}
	return nil
}

// photoRow brings one contact's picture in line with its Google URL.
func (cy *contactsCycle) photoRow(ctx context.Context, pc store.PersonalContacts, c store.Contact, raw string, held *int, n *contactsPhotoCount) error {
	cfg := cy.s.o.ContactsPhotos
	if raw == "" {
		return cy.photoDrop(ctx, pc, c, n)
	}
	u, ok := cfg.photoURL(raw)
	if !ok {
		return nil
	}
	hash := contactsURLHash(raw)
	if c.PhotoSHA256 != "" {
		old, err := pc.ContactPhoto(ctx, cy.b.Human, c.ID)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return err
		}
		if old.SourceURLHash == hash {
			return nil
		}
	} else if *held >= cfg.MaxPerPerson {
		n.overCap++
		return nil
	}
	if n.fetched >= contactsPhotoPerCycle {
		n.more = true
		return nil
	}
	return cy.photoFetchPut(ctx, pc, c, u, hash, held, n)
}

// photoFetchPut fetches one picture (no transaction open) and stores it.
func (cy *contactsCycle) photoFetchPut(ctx context.Context, pc store.PersonalContacts, c store.Contact, u *url.URL, hash string, held *int, n *contactsPhotoCount) error {
	n.fetched++
	mime, body, err := cy.s.o.ContactsPhotos.fetch(ctx, u)
	if n.fetched%contactsPhotoRenewEvery == 0 {
		if lerr := cy.renew(ctx); lerr != nil {
			return fmt.Errorf("%w: %w", errContactsLease, lerr)
		}
	}
	if err != nil {
		n.dropped++
		return nil
	}
	_, err = pc.PutContactPhoto(ctx, cy.b.Human, c.ID, store.ContactPhoto{Mime: mime, Bytes: body, SourceURLHash: hash}, cy.now())
	if errors.Is(err, store.ErrNotFound) || errors.Is(err, store.ErrContactPhotoBad) {
		n.dropped++
		return nil
	}
	if err != nil {
		return err
	}
	if c.PhotoSHA256 == "" {
		*held++
	}
	n.stored++
	return nil
}

// photoDrop deletes the picture of a contact Google has no user photo for.
func (cy *contactsCycle) photoDrop(ctx context.Context, pc store.PersonalContacts, c store.Contact, n *contactsPhotoCount) error {
	if c.PhotoSHA256 == "" {
		return nil
	}
	err := pc.DeleteContactPhoto(ctx, cy.b.Human, c.ID)
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err == nil {
		n.deleted++
	}
	return err
}

// contactsURLHash is source_url_hash: SHA-256 of the URL as Google gave it.
func contactsURLHash(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

// allowed: an https URL whose host is on the list.
func (c ContactsPhotoConfig) allowed(u *url.URL) bool {
	return u.Scheme == "https" && u.User == nil && slices.Contains(c.Hosts, strings.ToLower(u.Hostname()))
}

// photoURL is the URL to fetch, sz= set; false when it is not allowed.
func (c ContactsPhotoConfig) photoURL(raw string) (*url.URL, bool) {
	u, err := url.Parse(raw)
	if err != nil || !c.allowed(u) {
		return nil, false
	}
	q := u.Query()
	q.Set("sz", contactsPhotoSize)
	u.RawQuery = q.Encode()
	return u, true
}

// client is the configured client with the fetch's timeout and redirect rule.
func (c ContactsPhotoConfig) client() *http.Client {
	cl := http.Client{}
	if c.HTTP != nil {
		cl = *c.HTTP
	}
	cl.Jar = nil
	cl.Timeout = contactsPhotoTimeout
	cl.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) > contactsPhotoRedirects {
			return errPhotoRedirects
		}
		if !c.allowed(req.URL) {
			return errPhotoOffList
		}
		return nil
	}
	return &cl
}

// fetch GETs u and answers the picture's type by its magic bytes.
func (c ContactsPhotoConfig) fetch(ctx context.Context, u *url.URL) (string, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return "", nil, err
	}
	resp, err := c.client().Do(req)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only body
	if resp.StatusCode != http.StatusOK {
		return "", nil, fmt.Errorf("contacts photo: status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, store.ContactPhotoMax+1))
	if err != nil {
		return "", nil, err
	}
	if len(body) > store.ContactPhotoMax {
		return "", nil, errPhotoTooBig
	}
	mime := contactPhotoMime(body)
	if mime == "" {
		return "", nil, errPhotoType
	}
	return mime, body, nil
}

// contactPhotoMime is PNG, JPEG or WebP by the magic bytes, "" otherwise.
func contactPhotoMime(b []byte) string {
	switch {
	case bytes.HasPrefix(b, []byte("\x89PNG\r\n\x1a\n")):
		return "image/png"
	case bytes.HasPrefix(b, []byte{0xff, 0xd8, 0xff}):
		return "image/jpeg"
	case len(b) >= 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return "image/webp"
	}
	return ""
}

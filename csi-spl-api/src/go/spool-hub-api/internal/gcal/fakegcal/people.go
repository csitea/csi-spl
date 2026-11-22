package fakegcal

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// people.go is the fake's People API (spec 154 2.8 and 11.5, build row B8):
// people/me connections (a full list, a sync-token list with deleted people,
// an expired token), get, createContact, updateContact with an etag check,
// deleteContact, and a 429 on demand. Each Google account has its own book.
// The answers Google's pages do not state (the expired token's 400
// FAILED_PRECONDITION with reason EXPIRED_SYNC_TOKEN, an etag mismatch's 400
// FAILED_PRECONDITION, a gone person's 404) are this fake's guess, the same
// one gcal reads: "unchecked, I believe" (spec 154 2.5, 11.5).

// peoplePath is the fake's People API root.
const peoplePath = "/people/v1"

type fperson struct {
	p       gcal.Person
	seq     int
	deleted bool
}

type peopleBook struct {
	seq     int
	minSync int // a sync token below this is expired
	persons map[string]*fperson
}

type peopleState struct {
	books map[string]*peopleBook // Google account -> its contacts
	fail  []peopleFail           // the next People calls' answers, in order
}

type peopleFail struct {
	status     int
	retryAfter int // seconds, 0 = no header
}

func newPeopleState() *peopleState { return &peopleState{books: map[string]*peopleBook{}} }

func (f *Fake) peopleRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET "+peoplePath+"/people/me/connections", f.connectionsList)
	mux.HandleFunc("POST "+peoplePath+"/people:createContact", f.peopleCreate)
	mux.HandleFunc("GET "+peoplePath+"/people/{id}", f.peopleGet)
	mux.HandleFunc("PATCH "+peoplePath+"/people/{id}", f.peopleUpdate)
	mux.HandleFunc("DELETE "+peoplePath+"/people/{id}", f.peopleDelete)
}

// book is email's book; f.mu is held.
func (f *Fake) book(email string) *peopleBook {
	b := f.ppl.books[email]
	if b == nil {
		b = &peopleBook{persons: map[string]*fperson{}}
		f.ppl.books[email] = b
	}
	return b
}

// touch gives p a new etag and update time; f.mu is held.
func (f *Fake) touchPerson(b *peopleBook, fp *fperson) {
	b.seq++
	fp.seq = b.seq
	fp.p.ETag = "%p" + strconv.Itoa(b.seq)
	fp.p.Metadata.Sources = []gcal.PersonSource{{Type: "CONTACT", ID: strings.TrimPrefix(fp.p.ResourceName, "people/"),
		UpdateTime: f.now().UTC().Truncate(time.Millisecond)}}
}

// ---- test controls ----

// AddPerson writes p as a new contact of email on the Google side (one the
// member made in Google) and returns the stored copy.
func (f *Fake) AddPerson(email string, p gcal.Person) gcal.Person {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.addPerson(f.book(email), p)
}

func (f *Fake) addPerson(b *peopleBook, p gcal.Person) gcal.Person {
	p.ResourceName = f.next("people/c")
	p.Metadata = gcal.PersonMetadata{}
	fp := &fperson{p: p}
	b.persons[p.ResourceName] = fp
	f.touchPerson(b, fp)
	return fp.p
}

// EditPerson edits a contact of email on the Google side.
func (f *Fake) EditPerson(email, resource string, edit func(*gcal.Person)) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	b := f.book(email)
	fp := b.persons[resource]
	if fp == nil || fp.deleted {
		return fmt.Errorf("fakegcal: no person %q", resource)
	}
	edit(&fp.p)
	f.touchPerson(b, fp)
	return nil
}

// RemovePerson deletes a contact of email on the Google side: a sync-token
// list then answers it with metadata.deleted.
func (f *Fake) RemovePerson(email, resource string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	b := f.book(email)
	fp := b.persons[resource]
	if fp == nil || fp.deleted {
		return fmt.Errorf("fakegcal: no person %q", resource)
	}
	fp.deleted = true
	f.touchPerson(b, fp)
	return nil
}

// Person reads one live contact of email.
func (f *Fake) Person(email, resource string) (gcal.Person, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fp := f.book(email).persons[resource]
	if fp == nil || fp.deleted {
		return gcal.Person{}, false
	}
	return fp.p, true
}

// People lists the live contacts of email, oldest change first.
func (f *Fake) People(email string) []gcal.Person {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []gcal.Person
	for _, fp := range f.sortedPersons(f.book(email)) {
		if !fp.deleted {
			out = append(out, fp.p)
		}
	}
	return out
}

// ExpirePeopleSyncTokens makes every sync token of email issued so far expired.
func (f *Fake) ExpirePeopleSyncTokens(email string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	b := f.book(email)
	b.seq++
	b.minSync = b.seq
}

// FailPeople makes the next n People calls answer status (429, 503, ...),
// with Retry-After seconds when retryAfter > 0.
func (f *Fake) FailPeople(status, n, retryAfter int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for range n {
		f.ppl.fail = append(f.ppl.fail, peopleFail{status: status, retryAfter: retryAfter})
	}
}

// ---- HTTP ----

// peopleAuthed is authed plus a queued failure; it answers the account.
func (f *Fake) peopleAuthed(w http.ResponseWriter, r *http.Request, name string) (string, bool) {
	f.count(name)
	email, ok := f.authed(w, r)
	if !ok {
		return "", false
	}
	f.mu.Lock()
	var fail *peopleFail
	if len(f.ppl.fail) > 0 {
		fail = &f.ppl.fail[0]
		f.ppl.fail = f.ppl.fail[1:]
	}
	f.mu.Unlock()
	if fail != nil {
		if fail.retryAfter > 0 {
			w.Header().Set("Retry-After", strconv.Itoa(fail.retryAfter))
		}
		apiErr(w, fail.status, "rateLimitExceeded")
		return "", false
	}
	return email, true
}

// precondition is the People API's 400 FAILED_PRECONDITION with a reason.
func precondition(w http.ResponseWriter, reason string) {
	wire.WriteJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{
		"code": http.StatusBadRequest, "message": "fakegcal: " + reason, "status": "FAILED_PRECONDITION",
		"details": []map[string]string{{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason}},
	}})
}

func (f *Fake) sortedPersons(b *peopleBook) []*fperson {
	out := make([]*fperson, 0, len(b.persons))
	for _, fp := range b.persons {
		out = append(out, fp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].seq < out[j].seq })
	return out
}

func (f *Fake) connectionsList(w http.ResponseWriter, r *http.Request) {
	email, ok := f.peopleAuthed(w, r, "people.connections.list")
	if !ok {
		return
	}
	q := r.URL.Query()
	if q.Get("personFields") == "" {
		apiErr(w, http.StatusBadRequest, "personFields required")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	b := f.book(email)
	since := -1
	if tok := q.Get("syncToken"); tok != "" {
		n, err := strconv.Atoi(strings.TrimPrefix(tok, "psync-"))
		if err != nil || n < b.minSync {
			precondition(w, "EXPIRED_SYNC_TOKEN")
			return
		}
		since = n
	}
	var items []gcal.Person
	for _, fp := range f.sortedPersons(b) {
		switch {
		case since < 0 && !fp.deleted:
			items = append(items, fp.p)
		case since >= 0 && fp.seq > since && fp.deleted:
			items = append(items, gcal.Person{ResourceName: fp.p.ResourceName, ETag: fp.p.ETag,
				Metadata: gcal.PersonMetadata{Deleted: true, Sources: fp.p.Metadata.Sources}})
		case since >= 0 && fp.seq > since:
			items = append(items, fp.p)
		}
	}
	size, _ := strconv.Atoi(q.Get("pageSize"))
	if size <= 0 {
		size = 100
	}
	start, _ := strconv.Atoi(q.Get("pageToken"))
	end := min(start+size, len(items))
	if start > len(items) {
		start = len(items)
	}
	out := gcal.ConnectionsPage{Connections: items[start:end]}
	if end < len(items) {
		out.NextPageToken = strconv.Itoa(end)
	} else if q.Get("requestSyncToken") == "true" {
		out.NextSyncToken = "psync-" + strconv.Itoa(b.seq)
	}
	wire.WriteJSON(w, http.StatusOK, out)
}

// personOf is the live person of a {id} path segment ("c1" or
// "c1:<verb>" with verb as given), or writes 404.
func (f *Fake) personOf(w http.ResponseWriter, r *http.Request, email, verb string) (*peopleBook, *fperson, bool) {
	id := r.PathValue("id")
	if verb != "" {
		var ok bool
		if id, ok = strings.CutSuffix(id, ":"+verb); !ok {
			apiErr(w, http.StatusBadRequest, "badRequest")
			return nil, nil, false
		}
	}
	b := f.book(email)
	fp := b.persons["people/"+id]
	if fp == nil || fp.deleted {
		apiErr(w, http.StatusNotFound, "notFound")
		return nil, nil, false
	}
	return b, fp, true
}

func (f *Fake) peopleGet(w http.ResponseWriter, r *http.Request) {
	email, ok := f.peopleAuthed(w, r, "people.get")
	if !ok {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, fp, ok := f.personOf(w, r, email, ""); ok {
		wire.WriteJSON(w, http.StatusOK, fp.p)
	}
}

func (f *Fake) peopleCreate(w http.ResponseWriter, r *http.Request) {
	email, ok := f.peopleAuthed(w, r, "people.createContact")
	if !ok {
		return
	}
	var p gcal.Person
	if json.NewDecoder(r.Body).Decode(&p) != nil {
		apiErr(w, http.StatusBadRequest, "badRequest")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	wire.WriteJSON(w, http.StatusOK, f.addPerson(f.book(email), p))
}

func (f *Fake) peopleUpdate(w http.ResponseWriter, r *http.Request) {
	email, ok := f.peopleAuthed(w, r, "people.updateContact")
	if !ok {
		return
	}
	var p gcal.Person
	if json.NewDecoder(r.Body).Decode(&p) != nil {
		apiErr(w, http.StatusBadRequest, "badRequest")
		return
	}
	fields := strings.Split(r.URL.Query().Get("updatePersonFields"), ",")
	f.mu.Lock()
	defer f.mu.Unlock()
	b, fp, ok := f.personOf(w, r, email, "updateContact")
	if !ok {
		return
	}
	if p.ETag != fp.p.ETag {
		precondition(w, "FAILED_PRECONDITION")
		return
	}
	for _, fl := range fields {
		applyPersonField(&fp.p, p, fl)
	}
	f.touchPerson(b, fp)
	wire.WriteJSON(w, http.StatusOK, fp.p)
}

// applyPersonField replaces one updatePersonFields list of to with from's.
func applyPersonField(to *gcal.Person, from gcal.Person, field string) {
	switch field {
	case "names":
		to.Names = from.Names
	case "emailAddresses":
		to.EmailAddresses = from.EmailAddresses
	case "phoneNumbers":
		to.PhoneNumbers = from.PhoneNumbers
	case "organizations":
		to.Organizations = from.Organizations
	case "birthdays":
		to.Birthdays = from.Birthdays
	case "biographies":
		to.Biographies = from.Biographies
	}
}

func (f *Fake) peopleDelete(w http.ResponseWriter, r *http.Request) {
	email, ok := f.peopleAuthed(w, r, "people.deleteContact")
	if !ok {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	b, fp, ok := f.personOf(w, r, email, "deleteContact")
	if !ok {
		return
	}
	fp.deleted = true
	f.touchPerson(b, fp)
	w.WriteHeader(http.StatusOK)
}

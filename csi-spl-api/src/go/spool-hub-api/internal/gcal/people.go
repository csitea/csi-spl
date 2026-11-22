package gcal

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// people.go is the slice of the People API v1 the contacts sync uses (spec
// 154 sections 2.5 and 11.5, build row B8): the person's connections (list
// with a sync token), one person, and createContact, updateContact and
// deleteContact. Every call takes the member's access token, as client.go's.
// The shapes are those of the public reference
// (https://developers.google.com/people/api/rest/v1/people), read
// 2026-11-05; no call was made to Google, so every status and reason below
// that page does not state is "unchecked, I believe" and lives only in the
// fake (fakegcal/people.go).

var (
	// ErrPeopleNotConfigured is a hub without cnf contacts.people_base.
	ErrPeopleNotConfigured = errors.New("gcal: the People API root is not configured")
	// ErrRateLimited is a 429 or 503 (spec 154 2.5 "Rate limits"); the
	// HTTPError's RetryAfter holds Google's Retry-After, if it sent one.
	ErrRateLimited = errors.New("gcal: rate limited")
	// ErrETagMismatch is an updateContact whose etag is no longer the
	// person's (400 FAILED_PRECONDITION, unchecked, I believe): re-read and
	// decide again on the next cycle (spec 154 2.5 "Conflicts").
	ErrETagMismatch = errors.New("gcal: the person changed at google")
)

// PeoplePersonFields is what the sync reads of each person (spec 154 11.5,
// v1.3): the four of 2.5, the attributes of 11.3, the photos of 11.4 and
// the metadata (deleted, update time).
const PeoplePersonFields = "names,emailAddresses,phoneNumbers,organizations,birthdays,biographies,photos,metadata"

// PeopleUpdateFields is what an update may change (spec 154 11.3
// "Write-back"); birthdays is left out while Spool holds none, so Google's
// own value (a free-form text, say) is kept.
const PeopleUpdateFields = "names,emailAddresses,phoneNumbers,organizations,birthdays,biographies"

// PeoplePageSize is one connections page: the API's maximum (11.5).
const PeoplePageSize = 1000

// FieldMetadata is a field's metadata: which entry is the primary one.
type FieldMetadata struct {
	Primary       bool `json:"primary,omitempty"`
	SourcePrimary bool `json:"sourcePrimary,omitempty"`
}

// IsPrimary reports either primary flag.
func (m FieldMetadata) IsPrimary() bool { return m.Primary || m.SourcePrimary }

// PersonSource is one source of a person; UpdateTime is when it changed.
type PersonSource struct {
	Type       string    `json:"type,omitempty"`
	ID         string    `json:"id,omitempty"`
	ETag       string    `json:"etag,omitempty"`
	UpdateTime time.Time `json:"updateTime,omitzero"`
}

// PersonMetadata is a person's metadata: its sources, and Deleted on a
// person a sync-token list answers as gone.
type PersonMetadata struct {
	Sources []PersonSource `json:"sources,omitempty"`
	Deleted bool           `json:"deleted,omitempty"`
}

// Name is a person's name.
type Name struct {
	Metadata   FieldMetadata `json:"metadata,omitzero"`
	GivenName  string        `json:"givenName,omitempty"`
	FamilyName string        `json:"familyName,omitempty"`
	MiddleName string        `json:"middleName,omitempty"`
}

// EmailAddress is one email of a person.
type EmailAddress struct {
	Metadata FieldMetadata `json:"metadata,omitzero"`
	Value    string        `json:"value,omitempty"`
	Type     string        `json:"type,omitempty"`
}

// PhoneNumber is one phone of a person, as Google stores it.
type PhoneNumber struct {
	Metadata FieldMetadata `json:"metadata,omitzero"`
	Value    string        `json:"value,omitempty"`
	Type     string        `json:"type,omitempty"`
}

// Organization is one organization of a person.
type Organization struct {
	Metadata   FieldMetadata `json:"metadata,omitzero"`
	Name       string        `json:"name,omitempty"`
	Title      string        `json:"title,omitempty"`
	Department string        `json:"department,omitempty"`
	Type       string        `json:"type,omitempty"`
}

// Date is a birthday's date; Year 0 = none.
type Date struct {
	Year  int `json:"year,omitempty"`
	Month int `json:"month,omitempty"`
	Day   int `json:"day,omitempty"`
}

// Birthday is a person's birthday: a Date, or only the deprecated free-form
// Text.
type Birthday struct {
	Metadata FieldMetadata `json:"metadata,omitzero"`
	Date     *Date         `json:"date,omitempty"`
	Text     string        `json:"text,omitempty"`
}

// Biography is a person's notes; ContentType TEXT_PLAIN or TEXT_HTML.
type Biography struct {
	Metadata    FieldMetadata `json:"metadata,omitzero"`
	Value       string        `json:"value,omitempty"`
	ContentType string        `json:"contentType,omitempty"`
}

// Photo is a person's picture; Default = Google's lettered placeholder.
type Photo struct {
	Metadata FieldMetadata `json:"metadata,omitzero"`
	URL      string        `json:"url,omitempty"`
	Default  bool          `json:"default,omitempty"`
}

// Person is a People API person with the fields the sync maps.
type Person struct {
	ResourceName   string         `json:"resourceName,omitempty"`
	ETag           string         `json:"etag,omitempty"`
	Metadata       PersonMetadata `json:"metadata,omitzero"`
	Names          []Name         `json:"names,omitempty"`
	EmailAddresses []EmailAddress `json:"emailAddresses,omitempty"`
	PhoneNumbers   []PhoneNumber  `json:"phoneNumbers,omitempty"`
	Organizations  []Organization `json:"organizations,omitempty"`
	Birthdays      []Birthday     `json:"birthdays,omitempty"`
	Biographies    []Biography    `json:"biographies,omitempty"`
	Photos         []Photo        `json:"photos,omitempty"`
}

// UpdatedAt is the newest update time of the person's sources, zero when
// Google gave none (spec 154 2.5: metadata.sources[].updateTime, unchecked).
func (p Person) UpdatedAt() time.Time {
	var t time.Time
	for _, s := range p.Metadata.Sources {
		if s.UpdateTime.After(t) {
			t = s.UpdateTime
		}
	}
	return t
}

// PeopleListOptions is one connections.list call: with SyncToken, only the
// changes since (deleted people included); without it, the full list.
// PageToken continues a page.
type PeopleListOptions struct {
	SyncToken string
	PageToken string
	PageSize  int
}

// ConnectionsPage is one page of connections.list. NextSyncToken comes on
// the last page only.
type ConnectionsPage struct {
	Connections   []Person `json:"connections"`
	NextPageToken string   `json:"nextPageToken"`
	NextSyncToken string   `json:"nextSyncToken"`
}

// PeopleConfigured reports whether the client has a People API root.
func (g *Google) PeopleConfigured() bool { return g != nil && g.cfg.PeopleBase != "" }

// ListConnections is one page of people.connections.list on people/me, with
// requestSyncToken. A refused sync token is ErrSyncTokenGone.
func (g *Google) ListConnections(ctx context.Context, access marketing.Plaintext, o PeopleListOptions) (ConnectionsPage, error) {
	q := url.Values{"personFields": {PeoplePersonFields}, "requestSyncToken": {"true"}}
	size := o.PageSize
	if size <= 0 || size > PeoplePageSize {
		size = PeoplePageSize
	}
	q.Set("pageSize", strconv.Itoa(size))
	if o.SyncToken != "" {
		q.Set("syncToken", o.SyncToken)
	}
	if o.PageToken != "" {
		q.Set("pageToken", o.PageToken)
	}
	var out ConnectionsPage
	if err := g.peopleCall(ctx, access, http.MethodGet, "/people/me/connections", q, nil, &out); err != nil {
		return ConnectionsPage{}, fmt.Errorf("people connections.list: %w", err)
	}
	return out, nil
}

// GetPerson reads one person (its current etag and every entry of its
// lists, so an update keeps what Spool does not hold).
func (g *Google) GetPerson(ctx context.Context, access marketing.Plaintext, resourceName string) (Person, error) {
	var out Person
	q := url.Values{"personFields": {PeoplePersonFields}}
	if err := g.peopleCall(ctx, access, http.MethodGet, "/"+resourcePath(resourceName), q, nil, &out); err != nil {
		return Person{}, fmt.Errorf("people get: %w", err)
	}
	return out, nil
}

// CreateContact creates p and returns Google's copy (its resourceName and
// etag go on the contact).
func (g *Google) CreateContact(ctx context.Context, access marketing.Plaintext, p Person) (Person, error) {
	p.ResourceName, p.ETag, p.Metadata = "", "", PersonMetadata{}
	var out Person
	q := url.Values{"personFields": {PeoplePersonFields}}
	if err := g.peopleCall(ctx, access, http.MethodPost, "/people:createContact", q, p, &out); err != nil {
		return Person{}, fmt.Errorf("people createContact: %w", err)
	}
	return out, nil
}

// UpdateContact sends p (with the etag it was read with) for the fields
// named in fields; a changed etag is ErrETagMismatch.
func (g *Google) UpdateContact(ctx context.Context, access marketing.Plaintext, p Person, fields string) (Person, error) {
	var out Person
	q := url.Values{"updatePersonFields": {fields}, "personFields": {PeoplePersonFields}}
	if err := g.peopleCall(ctx, access, http.MethodPatch, "/"+resourcePath(p.ResourceName)+":updateContact", q, p, &out); err != nil {
		return Person{}, fmt.Errorf("people updateContact: %w", err)
	}
	return out, nil
}

// DeleteContact deletes a person; one already gone (404) is done (spec 154
// 2.5 "Conflicts", unchecked, I believe, that the answer is 404).
func (g *Google) DeleteContact(ctx context.Context, access marketing.Plaintext, resourceName string) error {
	err := g.peopleCall(ctx, access, http.MethodDelete, "/"+resourcePath(resourceName)+":deleteContact", nil, nil, nil)
	if err != nil && !isGone(err) {
		return fmt.Errorf("people deleteContact: %w", err)
	}
	return nil
}

// resourcePath is a resourceName ("people/c123") with its id escaped.
func resourcePath(resourceName string) string {
	kind, id, _ := strings.Cut(resourceName, "/")
	return url.PathEscape(kind) + "/" + url.PathEscape(id)
}

func (g *Google) peopleCall(ctx context.Context, access marketing.Plaintext, method, path string, q url.Values, in, out any) error {
	if !g.PeopleConfigured() {
		return ErrPeopleNotConfigured
	}
	return g.callURL(ctx, access, method, apiURL(g.cfg.PeopleBase, path, q), in, out)
}

package hub

import (
	"context"
	"encoding/csv"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The contacts routes (spec 154 v1.2 sections 2.6, 2.9 and 4, build row B3):
// a person's own contact list, one list in every workspace they belong to
// (O5 = B), kept by B2's store in the personal realm.
//
//	GET    /v1/me/contacts?q=&cursor=   a page of the list, {contacts, next}
//	POST   /v1/me/contacts              a new contact, 201
//	DELETE /v1/me/contacts?scope=spool  erase the whole list (C8e)
//	GET    /v1/me/contacts/export       the list as CSV (C7, C40)
//	POST   /v1/me/contacts/import       a CSV file, ?dry_run=1 first (contacts_import.go)
//	GET    /v1/me/contacts/{id}         one contact
//	PATCH  /v1/me/contacts/{id}         change its values
//	DELETE /v1/me/contacts/{id}         erase it: soft while a Google delete is due (C7b)
//	GET    /v1/me/contacts/{id}/photo   its picture's bytes, 404 for none (spec 11.4)
//	PUT    /v1/me/contacts/sync         the Contacts switch {enabled} (C7d)
//	POST   /v1/me/contacts/sync         "Sync now", 202
//
// Who: a signed-in person in a workspace session. The person is the
// session's HUM-*, never a path, query or body value; realmRefuses answers
// 403 person_only for an act-as clone, an agent and a seat that is not a
// person's (C4b), and a box token is 403 person_only too. Unlike the realm
// routes the session's workspace is kept: it decides the kill switch, and
// later the member match (B6) and the invite target; it never decides which
// contacts are read. Another person's contact id is 404 (C4).
//
// Kill switch (2.9): Options.ContactsWorkspaces (cnf contacts.workspaces);
// outside it every route answers 404 not_found and GET /v1/view/me says
// contacts: false (C6, C6b). The list itself is untouched.
//
// Privacy (2.6, C12): no contact value (name, email, phone) in a log line or
// an error body; a log line carries the op, the person and the contact id.

const (
	// contactsBodyMax is the sync switch's small body.
	contactsBodyMax = 4 << 10
	// contactsValuesMax is a create or a patch: every value at its CHECK limit,
	// the 8000 characters of notes at up to 12 bytes each as JSON escapes,
	// plus the JSON around them (spec 11.2.1).
	contactsValuesMax = 128 << 10
	// contactsPurgeAfter is how long a member's soft delete waits for its
	// Google delete before the purge door removes it (2.6, C7c).
	contactsPurgeAfter = 30 * 24 * time.Hour
	// contactsCSVHeaderV12 is the export before B15, which the import still reads.
	contactsCSVHeaderV12 = "first_name,last_name,email,phone,google_resource"
	contactsCSVHeader    = contactsCSVHeaderV12 + ",company,job_title,birthday,notes"
)

// contactsMe is the caller of a contacts route: the person, the session's
// workspace and the store.
type contactsMe struct {
	person string
	tenant string
	st     store.PersonalContacts
}

// contactsListed is the kill switch: the workspace is on the list, or the
// list is the one entry "all".
func (s *Server) contactsListed(tenant string) bool {
	ws := s.o.ContactsWorkspaces
	return slices.Equal(ws, []string{"all"}) || slices.Contains(ws, tenant)
}

func writeContactsOff(w http.ResponseWriter) {
	writeErr(w, http.StatusNotFound, "not_found", "contacts are not available in this workspace")
}

func writeContactsNotPerson(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, realmPersonly, "contacts are the signed-in person's own")
}

// contactsCaller resolves the person and the workspace of a contacts
// request, or answers: the person gate first, then the kill switch, so a
// caller that is not a person is refused wherever it asks.
func (s *Server) contactsCaller(w http.ResponseWriter, r *http.Request) (contactsMe, bool) {
	t, hum, ok := s.personCaller(w, r, "contacts_caller")
	if !ok {
		return contactsMe{}, false
	}
	pc, has := s.o.Store.(store.PersonalContacts)
	if !s.contactsListed(t.ID) || !has {
		writeContactsOff(w)
		return contactsMe{}, false
	}
	return contactsMe{person: hum, tenant: t.ID, st: pc}, true
}

// personCaller is the person gate of the contacts routes and of the member
// card (spec 154 sections 4 and 12): a signed-in human's own cookie session
// in its workspace, never a Bearer token, an act-as session, a live clone or
// an agent seat (realmRefuses); those answer 403 person_only. It answers
// the session's workspace and the person's HUM-*.
func (s *Server) personCaller(w http.ResponseWriter, r *http.Request, op string) (store.Tenant, string, bool) {
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		writeContactsNotPerson(w)
		return store.Tenant{}, "", false
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return store.Tenant{}, "", false
	}
	if hum == "" || s.o.Auth == nil {
		writeContactsNotPerson(w)
		return store.Tenant{}, "", false
	}
	sess, ok := s.o.Auth.SessionFromRequest(r)
	if !ok || sess.HumanID != hum {
		writeContactsNotPerson(w)
		return store.Tenant{}, "", false
	}
	sess.Tenant = t.ID
	refuse, err := s.realmRefuses(r.Context(), sess)
	if err != nil {
		s.o.Log.Error().Err(err).Str("op", op).Msg("contacts")
		writeErr(w, http.StatusServiceUnavailable, "contacts_unavailable", "contacts are unavailable")
		return store.Tenant{}, "", false
	}
	if refuse {
		writeContactsNotPerson(w)
		return store.Tenant{}, "", false
	}
	return t, hum, true
}

// contactsLog is the one log line of a contacts write: ids and the outcome.
func (s *Server) contactsLog(op string, c contactsMe, contactID, outcome string) {
	s.o.Log.Info().Str("op", op).Str("person", c.person).Str("contact", contactID).Str("outcome", outcome).Msg("contacts")
}

// contactsFail answers a store error; the log line carries the op, the ids
// and the error, which names a field and never its value (store B2).
func (s *Server) contactsFail(w http.ResponseWriter, op string, c contactsMe, contactID string, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such contact")
	case errors.Is(err, store.ErrContactEmpty):
		writeErr(w, http.StatusBadRequest, "contact_empty", "a contact needs a name, an email or a phone")
	case errors.Is(err, store.ErrContactBadEmail):
		writeErr(w, http.StatusBadRequest, "bad_email", "the email is not an address")
	case errors.Is(err, store.ErrContactBadPhone):
		writeErr(w, http.StatusBadRequest, "bad_phone", "the phone is not a phone number")
	case errors.Is(err, store.ErrContactTooLong):
		writeErr(w, http.StatusBadRequest, "too_long", "a value is over its limit")
	case errors.Is(err, store.ErrContactBadBirthday):
		writeErr(w, http.StatusBadRequest, "bad_birthday", "the birthday is not a date")
	case errors.Is(err, store.ErrRealmBad):
		writeErr(w, http.StatusBadRequest, "bad_contact", strings.TrimPrefix(err.Error(), "store: "))
	case errors.Is(err, store.ErrNoPerson):
		writeContactsNotPerson(w)
	default:
		s.o.Log.Error().Err(err).Str("op", op).Str("person", c.person).Str("contact", contactID).Msg("contacts")
		writeErrCause(w, http.StatusInternalServerError, "internal", "contacts are unavailable", err)
	}
}

// contactOut is one contact as every route answers it. Email, phone and
// birthday are null when unset; google = linked to Google; member_id is the
// member match of the session's workspace (B6, contacts_match.go) on the list
// and the card, null on the other routes and when nothing matches; in_only =
// too long to sync back (spec 11.3); photo is its picture's sha256, or null.
type contactOut struct {
	ID        string  `json:"contact_id"`
	FirstName string  `json:"first_name"`
	LastName  string  `json:"last_name"`
	Email     *string `json:"email"`
	Phone     *string `json:"phone"`
	Google    bool    `json:"google"`
	MemberID  *string `json:"member_id"`
	CreatedAt string  `json:"created_at"`
	UpdatedAt string  `json:"updated_at"`
	Company   string  `json:"company"`
	JobTitle  string  `json:"job_title"`
	Birthday  *string `json:"birthday"`
	Notes     string  `json:"notes"`
	InOnly    bool    `json:"in_only"`
	Photo     *string `json:"photo"`
}

func contactJSON(c store.Contact) contactOut {
	opt := func(v string) *string {
		if v == "" {
			return nil
		}
		return &v
	}
	return contactOut{ID: c.ID, FirstName: c.FirstName, LastName: c.LastName, Email: opt(c.Email), Phone: opt(c.Phone),
		Google: c.GoogleResource != "", CreatedAt: c.CreatedAt.UTC().Format(time.RFC3339Nano),
		UpdatedAt: c.UpdatedAt.UTC().Format(time.RFC3339Nano), Company: c.Company, JobTitle: c.JobTitle,
		Birthday: opt(c.Birthday), Notes: c.Notes, InOnly: c.InOnly, Photo: opt(c.PhotoSHA256)}
}

// contactIn is the body of a create (every field) and of a patch (the
// fields sent); an unknown field, a person_id among them, is 400.
type contactIn struct {
	FirstName *string `json:"first_name"`
	LastName  *string `json:"last_name"`
	Email     *string `json:"email"`
	Phone     *string `json:"phone"`
	Company   *string `json:"company"`
	JobTitle  *string `json:"job_title"`
	Birthday  *string `json:"birthday"`
	Notes     *string `json:"notes"`
}

func readContactJSON(w http.ResponseWriter, r *http.Request, v *contactIn) bool {
	return readJSONStrict(w, r, v, contactsValuesMax, "invalid JSON body for a contact")
}

// GET /v1/me/contacts?q=&cursor=: a page of the person's list.
func (s *Server) handleListContacts(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	page, err := c.st.ListContacts(r.Context(), c.person, store.ContactQuery{Q: q.Get("q"), After: q.Get("cursor")})
	if err != nil {
		s.contactsFail(w, "contacts_list", c, "", err)
		return
	}
	out := make([]contactOut, 0, len(page.Contacts))
	for _, ct := range page.Contacts {
		out = append(out, contactJSON(ct))
	}
	if err := s.contactsMatch(r.Context(), c.tenant, out); err != nil {
		s.contactsFail(w, "contacts_match", c, "", err)
		return
	}
	var next *string
	if page.Next != "" {
		next = &page.Next
	}
	writeJSON(w, http.StatusOK, map[string]any{"contacts": out, "next": next})
}

// POST /v1/me/contacts: 201 and the contact.
func (s *Server) handleCreateContact(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	var in contactIn
	if !readContactJSON(w, r, &in) {
		return
	}
	val := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	ct, err := c.st.CreateContact(r.Context(), c.person, store.Contact{FirstName: val(in.FirstName), LastName: val(in.LastName),
		Email: val(in.Email), Phone: val(in.Phone), Company: val(in.Company), JobTitle: val(in.JobTitle),
		Birthday: val(in.Birthday), Notes: val(in.Notes)}, s.o.Now())
	if err != nil {
		s.contactsFail(w, "contacts_create", c, "", err)
		return
	}
	s.contactsLog("contacts_create", c, ct.ID, "created")
	writeJSON(w, http.StatusCreated, contactJSON(ct))
}

// GET /v1/me/contacts/{id}: one contact; another person's is 404.
func (s *Server) handleGetContact(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	ct, err := c.st.ContactOf(r.Context(), c.person, id)
	if err != nil {
		s.contactsFail(w, "contacts_get", c, id, err)
		return
	}
	out := []contactOut{contactJSON(ct)}
	if err := s.contactsMatch(r.Context(), c.tenant, out); err != nil {
		s.contactsFail(w, "contacts_match", c, id, err)
		return
	}
	writeJSON(w, http.StatusOK, out[0])
}

// PATCH /v1/me/contacts/{id}: the fields sent; "" clears one.
func (s *Server) handlePatchContact(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	var in contactIn
	if !readContactJSON(w, r, &in) {
		return
	}
	id := r.PathValue("id")
	ct, err := c.st.PatchContact(r.Context(), c.person, id,
		store.ContactPatch{FirstName: in.FirstName, LastName: in.LastName, Email: in.Email, Phone: in.Phone,
			Company: in.Company, JobTitle: in.JobTitle, Birthday: in.Birthday, Notes: in.Notes}, s.o.Now())
	if err != nil {
		s.contactsFail(w, "contacts_patch", c, id, err)
		return
	}
	s.contactsLog("contacts_patch", c, id, "patched")
	writeJSON(w, http.StatusOK, contactJSON(ct))
}

// DELETE /v1/me/contacts/{id}: 204. A contact linked under the account of
// the person's enabled binding is soft-deleted, so the sync cycle sends its
// Google delete; any other is deleted at once (2.6 "Erase one", C7b).
func (s *Server) handleDeleteContact(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	ct, err := c.st.ContactOf(r.Context(), c.person, id)
	if err != nil {
		s.contactsFail(w, "contacts_delete", c, id, err)
		return
	}
	by, outcome := "", "deleted"
	if ct.GoogleResource != "" {
		pending, err := s.contactGoogleDeleteDue(r.Context(), c.person, ct)
		if err != nil {
			s.contactsFail(w, "contacts_delete", c, id, err)
			return
		}
		if pending {
			by, outcome = store.ContactDeletedByMember, "soft_deleted"
		}
	}
	if err := c.st.DeleteContact(r.Context(), c.person, id, by, s.o.Now()); err != nil {
		s.contactsFail(w, "contacts_delete", c, id, err)
		return
	}
	s.contactsLog("contacts_delete", c, id, outcome)
	w.WriteHeader(http.StatusNoContent)
}

// contactGoogleDeleteDue: the person's binding is enabled and its Google
// connection's account is the one ct is linked under. The binding may be in
// another workspace, so it is read by the person alone (B2's ContactsSyncOf,
// operator scope, seat note N4), and its connection in that workspace.
func (s *Server) contactGoogleDeleteDue(ctx context.Context, person string, ct store.Contact) (bool, error) {
	cs, ok := s.o.Store.(store.ContactsSyncs)
	gs, okG := s.o.Store.(store.Gcal)
	if !ok || !okG {
		return false, nil
	}
	b, err := cs.ContactsSyncOf(ctx, person)
	if errors.Is(err, store.ErrNotFound) || (err == nil && !b.Enabled) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	conn, err := gs.GcalConnection(ctx, b.Tenant, person)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return strings.EqualFold(conn.GoogleEmail, ct.GoogleAccount), nil
}

// DELETE /v1/me/contacts?scope=spool: the person's whole list, in Spool
// only (C8e). The binding is switched off first, so a later full list from
// Google cannot import the contacts again; a stop in between leaves the sync
// off and the list whole, and the erase can be repeated.
func (s *Server) handleEraseContacts(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	if r.URL.Query().Get("scope") != "spool" {
		writeErr(w, http.StatusBadRequest, "scope_required", "erase the whole list with ?scope=spool")
		return
	}
	if err := s.contactsSyncOff(r.Context(), c.person); err != nil {
		s.contactsFail(w, "contacts_erase", c, "", err)
		return
	}
	n, err := c.st.EraseContacts(r.Context(), c.person)
	if err != nil {
		s.contactsFail(w, "contacts_erase", c, "", err)
		return
	}
	s.o.Log.Info().Str("op", "contacts_erase").Str("person", c.person).Int("erased", n).Msg("contacts")
	w.WriteHeader(http.StatusNoContent)
}

// contactsSyncOff switches the person's one binding off in the workspace
// where it is (one binding per person, 2.2 step 3); none is nothing to do.
func (s *Server) contactsSyncOff(ctx context.Context, person string) error {
	cs, ok := s.o.Store.(store.ContactsSyncs)
	if !ok {
		return nil
	}
	b, err := cs.ContactsSyncOf(ctx, person)
	if errors.Is(err, store.ErrNotFound) || (err == nil && !b.Enabled) {
		return nil
	}
	if err != nil {
		return err
	}
	_, err = cs.SetContactsSync(ctx, b.Tenant, person, false, s.o.Now())
	if errors.Is(err, store.ErrNotFound) { // the binding ended meanwhile (a leave)
		return nil
	}
	return err
}

// GET /v1/me/contacts/{id}/photo: the contact's picture, 404 for none or for
// another person's id (spec 11.4). As the person's own avatar route: revalidated
// each time, so an erased picture is not kept in the browser's cache.
func (s *Server) handleContactPhoto(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	p, err := c.st.ContactPhoto(r.Context(), c.person, id)
	if err != nil {
		s.contactsFail(w, "contacts_photo", c, id, err)
		return
	}
	etag := `"` + p.SHA256 + `"`
	w.Header().Set("Cache-Control", "private, no-cache")
	w.Header().Set("ETag", etag)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", p.Mime)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(p.Bytes)
}

// GET /v1/me/contacts/export: the person's list as CSV, the four values, the
// Google link and the attributes of 11.3 (2.6 "Export", C7, C40); no picture.
func (s *Server) handleExportContacts(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	all, err := c.st.ExportContacts(r.Context(), c.person)
	if err != nil {
		s.contactsFail(w, "contacts_export", c, "", err)
		return
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="contacts.csv"`)
	w.WriteHeader(http.StatusOK)
	cw := csv.NewWriter(w)
	_ = cw.Write(strings.Split(contactsCSVHeader, ","))
	// csvSafe (hours_export.go): a cell that starts with = + - @ is quoted, so a
	// spreadsheet never runs it as a formula; a +phone reads back with a leading '.
	for _, ct := range all {
		_ = cw.Write([]string{csvSafe(ct.FirstName), csvSafe(ct.LastName), csvSafe(ct.Email), csvSafe(ct.Phone), csvSafe(ct.GoogleResource),
			csvSafe(ct.Company), csvSafe(ct.JobTitle), csvSafe(ct.Birthday), csvSafe(ct.Notes)})
	}
	cw.Flush()
	s.o.Log.Info().Str("op", "contacts_export").Str("person", c.person).Int("rows", len(all)).Msg("contacts")
}

// contactsSyncStore is the binding store, or 503.
func (s *Server) contactsSyncStore(w http.ResponseWriter) (store.ContactsSyncs, bool) {
	cs, ok := s.o.Store.(store.ContactsSyncs)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "contacts_unavailable", "the contacts sync is not kept by this hub")
	}
	return cs, ok
}

// PUT /v1/me/contacts/sync {enabled}: the Contacts switch of the Google
// connection in the session's workspace (2.2 step 3): 204; 409
// gcal_not_connected without a connection there, 409
// contacts_sync_elsewhere while the binding is in another workspace (C7d).
// Off where no binding is is 204: nothing to switch off.
func (s *Server) handlePutContactsSync(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	var in struct {
		Enabled *bool `json:"enabled"`
	}
	if !readJSONStrict(w, r, &in, contactsBodyMax, "invalid JSON body: {enabled}") {
		return
	}
	if in.Enabled == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "enabled is required")
		return
	}
	cs, ok := s.contactsSyncStore(w)
	if !ok {
		return
	}
	_, err := cs.SetContactsSync(r.Context(), c.tenant, c.person, *in.Enabled, s.o.Now())
	switch {
	case errors.Is(err, store.ErrContactsSyncElsewhere):
		writeErr(w, http.StatusConflict, "contacts_sync_elsewhere", "contacts sync is on in another of your workspaces: turn it off there first")
	case errors.Is(err, store.ErrNotFound) && *in.Enabled:
		writeErr(w, http.StatusConflict, "gcal_not_connected", "connect Google in this workspace first")
	case err != nil && !errors.Is(err, store.ErrNotFound):
		s.contactsFail(w, "contacts_sync_set", c, "", err)
	default:
		s.o.Log.Info().Str("op", "contacts_sync_set").Str("person", c.person).Str("tenant", c.tenant).Bool("enabled", *in.Enabled).Msg("contacts")
		w.WriteHeader(http.StatusNoContent)
	}
}

// POST /v1/me/contacts/sync: "Sync now", the binding in this workspace is
// due now: 202; 409 gcal_not_connected with no enabled binding here, 409
// sync_in_progress while a cycle holds its lease.
func (s *Server) handleContactsSyncNow(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	cs, ok := s.contactsSyncStore(w)
	if !ok {
		return
	}
	err := cs.MarkContactsSyncDue(r.Context(), c.tenant, c.person, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusConflict, "gcal_not_connected", "contacts sync is not on in this workspace")
	case errors.Is(err, store.ErrContactsSyncBusy):
		writeErr(w, http.StatusConflict, "sync_in_progress", "a contacts sync is running")
	case err != nil:
		s.contactsFail(w, "contacts_sync_now", c, "", err)
	default:
		w.WriteHeader(http.StatusAccepted)
	}
}

// SweepContacts is the 30-day purge of soft-deleted contacts (2.6, C7c):
// B2's door over every person, then the status line on the binding of each
// person whose purged rows held a Google delete that never went out. It
// needs no Google connection; RunSweeper calls it on the retention tick.
func (s *Server) SweepContacts(ctx context.Context) {
	pc, ok := s.o.Store.(store.PersonalContacts)
	if !ok {
		return
	}
	now := s.o.Now()
	purged, err := pc.PurgeDeletedContacts(ctx, now.Add(-contactsPurgeAfter))
	if err != nil {
		s.o.Log.Error().Err(err).Str("op", "contacts_purge").Msg("contacts")
		return
	}
	var pending []string
	for _, p := range purged {
		if p.PendingGoogle {
			pending = append(pending, p.Person)
		}
	}
	marked := 0
	if cs, ok := s.o.Store.(store.ContactsSyncs); ok && len(pending) > 0 {
		if marked, err = cs.MarkContactsPurgePending(ctx, pending, now); err != nil {
			s.o.Log.Error().Err(err).Str("op", "contacts_purge_pending").Msg("contacts")
		}
	}
	if len(purged) > 0 {
		s.o.Log.Info().Str("op", "contacts_purge").Int("persons", len(purged)).Int("pending_google", marked).Msg("contacts")
	}
}

// routeContacts registers spec 154's contacts routes (row B3); the
// preflights are every /v1/me browser route's (gcalPreflight).
func (s *Server) routeContacts(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/me/contacts", s.handleListContacts)
	mux.HandleFunc("POST /v1/me/contacts", s.handleCreateContact)
	mux.HandleFunc("DELETE /v1/me/contacts", s.handleEraseContacts)
	mux.HandleFunc("OPTIONS /v1/me/contacts", s.gcalPreflight("GET, POST, DELETE"))
	mux.HandleFunc("GET /v1/me/contacts/export", s.handleExportContacts)
	mux.HandleFunc("OPTIONS /v1/me/contacts/export", s.gcalPreflight("GET"))
	mux.HandleFunc("POST /v1/me/contacts/import", s.handleImportContacts)
	mux.HandleFunc("OPTIONS /v1/me/contacts/import", s.gcalPreflight("POST"))
	mux.HandleFunc("GET /v1/me/contacts/{id}/photo", s.handleContactPhoto)
	mux.HandleFunc("OPTIONS /v1/me/contacts/{id}/photo", s.gcalPreflight("GET"))
	mux.HandleFunc("PUT /v1/me/contacts/sync", s.handlePutContactsSync)
	mux.HandleFunc("POST /v1/me/contacts/sync", s.handleContactsSyncNow)
	mux.HandleFunc("OPTIONS /v1/me/contacts/sync", s.gcalPreflight("PUT, POST"))
	mux.HandleFunc("GET /v1/me/contacts/{id}", s.handleGetContact)
	mux.HandleFunc("PATCH /v1/me/contacts/{id}", s.handlePatchContact)
	mux.HandleFunc("DELETE /v1/me/contacts/{id}", s.handleDeleteContact)
	mux.HandleFunc("OPTIONS /v1/me/contacts/{id}", s.gcalPreflight("GET, PATCH, DELETE"))
	s.routeMemberCard(mux) // spec 154 section 12: GET /v1/view/members/{id}/card, member_card.go
}

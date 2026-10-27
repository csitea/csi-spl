// Package fakegcal is an in-memory Google for tests of the spec 149 Google
// Calendar connect: an httptest server for the consent redirect, token
// (code and refresh), revoke, userinfo, calendars, events (list with
// syncToken and 410, insert, patch, delete), watch and channels.stop.
//
// It is a test double, not an emulator: it answers the shapes gcal reads,
// keeps every calendar apart per Google account, and counts each call by its
// API method name ("events.insert", "token", ...) so a sync test can assert
// how many calls a cycle made. Nothing here reaches the network.
package fakegcal

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The OAuth client the fake accepts; Config hands them to gcal. They are
// test values, not credentials.
const (
	ClientID  = "fakegcal-client-id"
	ClientKey = "fakegcal-client-key-test-value"
)

// DefaultEmail is the Google account the consent page signs in as.
const DefaultEmail = "member@example.com"

// accessTTL is how long an access token lives, in fake time.
const accessTTL = time.Hour

// channelTTL is the longest a push channel lives (about 7 days at Google).
const channelTTL = 7 * 24 * time.Hour

type grant struct {
	email   string
	scope   string // what the token answers carry
	revoked bool
}

type access struct {
	g   *grant
	exp time.Time
}

type event struct {
	ev  gcal.Event
	seq int
}

type calendar struct {
	cal     gcal.Calendar
	owner   string
	primary bool
	hidden  bool // not selected in the member's Google Calendar
	seq     int
	minSync int // a syncToken below this answers 410
	order   []string
	events  map[string]*event
}

type channel struct {
	calID, resourceID, address, token string
	exp                               time.Time
}

// Fake is the fake Google. Now is its clock (time.Now when nil); set it
// before the first call.
type Fake struct {
	Now func() time.Time

	srv      *httptest.Server
	mu       sync.Mutex
	n        int
	codes    map[string]*grant // code -> the grant it opens
	scopes   string            // the scopes Config was given: what IssueCode grants
	denied   []string          // scopes the member unticks on the consent page
	refresh  map[string]*grant
	access   map[string]access
	cals     map[string]*calendar
	channels map[string]*channel
	calls    map[string]int
	redirect []string // registered redirect URIs, as on a Google OAuth client
}

// New starts a fake Google for t; it closes with the test.
func New(t testing.TB) *Fake {
	t.Helper()
	f := &Fake{
		codes: map[string]*grant{}, refresh: map[string]*grant{}, access: map[string]access{},
		cals: map[string]*calendar{}, channels: map[string]*channel{}, calls: map[string]int{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /o/oauth2/v2/auth", f.consent)
	mux.HandleFunc("POST /token", f.token)
	mux.HandleFunc("POST /revoke", f.revoke)
	mux.HandleFunc("GET /oauth2/v3/userinfo", f.userinfo)
	mux.HandleFunc("POST /calendar/v3/calendars", f.calendarInsert)
	mux.HandleFunc("GET /calendar/v3/calendars/{cal}", f.calendarGet)
	mux.HandleFunc("GET /calendar/v3/calendars/{cal}/events", f.eventsList)
	mux.HandleFunc("POST /calendar/v3/calendars/{cal}/events", f.eventsInsert)
	mux.HandleFunc("POST /calendar/v3/calendars/{cal}/events/watch", f.eventsWatch)
	mux.HandleFunc("PATCH /calendar/v3/calendars/{cal}/events/{ev}", f.eventsPatch)
	mux.HandleFunc("DELETE /calendar/v3/calendars/{cal}/events/{ev}", f.eventsDelete)
	mux.HandleFunc("POST /calendar/v3/channels/stop", f.channelsStop)
	mux.HandleFunc("GET /calendar/v3/users/me/calendarList", f.calendarList)
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

// URL is the fake's base URL.
func (f *Fake) URL() string { return f.srv.URL }

// Config is a gcal.Config pointed at the fake, with redirectURI and scopes.
// It registers redirectURI: the consent page redirects to registered URIs
// only, as Google does.
func (f *Fake) Config(redirectURI, scopes string) gcal.Config {
	f.mu.Lock()
	if !slices.Contains(f.redirect, redirectURI) {
		f.redirect = append(f.redirect, redirectURI)
	}
	f.scopes = scopes
	f.mu.Unlock()
	return gcal.Config{
		ClientID: ClientID, ClientSecret: marketing.NewPlaintext(ClientKey),
		RedirectURI: redirectURI, Scopes: scopes,
		AuthURL: f.srv.URL + "/o/oauth2/v2/auth", TokenURL: f.srv.URL + "/token",
		RevokeURL: f.srv.URL + "/revoke", UserinfoURL: f.srv.URL + "/oauth2/v3/userinfo",
		CalendarBase: f.srv.URL + "/calendar/v3",
		HTTP:         f.srv.Client(),
	}
}

func (f *Fake) now() time.Time {
	if f.Now != nil {
		return f.Now()
	}
	return time.Now()
}

func (f *Fake) next(prefix string) string {
	f.n++
	return prefix + strconv.Itoa(f.n)
}

// ---- test controls ----

// IssueCode returns a one-time authorization code for email, as the consent
// page would, granting the scopes Config was given less the denied ones.
func (f *Fake) IssueCode(email string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.issue(email, f.scopes)
}

// DenyScope makes every later consent leave scope out of the grant, as a
// member who unticks that box on Google's granular consent page.
func (f *Fake) DenyScope(scope string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.denied = append(f.denied, scope)
}

// issue mints a code for email granting requested less the denied scopes.
// The caller holds f.mu.
func (f *Fake) issue(email, requested string) string {
	var granted []string
	for _, s := range strings.Fields(requested) {
		if !slices.Contains(f.denied, s) {
			granted = append(granted, s)
		}
	}
	c := f.next("code-")
	f.codes[c] = &grant{email: email, scope: strings.Join(granted, " ")}
	return c
}

// Calls answers how many times the API method name was called.
func (f *Fake) Calls(name string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[name]
}

// ResetCalls zeroes every call count.
func (f *Fake) ResetCalls() {
	f.mu.Lock()
	defer f.mu.Unlock()
	clear(f.calls)
}

// RevokeGrant revokes every token of email, as the member removing the app
// in their Google account would: a refresh then answers invalid_grant.
func (f *Fake) RevokeGrant(email string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, g := range f.refresh {
		if g.email == email {
			g.revoked = true
		}
	}
}

// Revoked answers whether the grant behind tok (access or refresh) is revoked.
func (f *Fake) Revoked(tok string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if g, ok := f.refresh[tok]; ok {
		return g.revoked
	}
	a, ok := f.access[tok]
	return ok && a.g.revoked
}

// ExpireAccessTokens makes every access token issued so far answer 401.
func (f *Fake) ExpireAccessTokens() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for k, a := range f.access {
		a.exp = time.Time{}
		f.access[k] = a
	}
}

// ExpireSyncTokens makes every syncToken of calendarID issued so far answer 410.
func (f *Fake) ExpireSyncTokens(calendarID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c := f.cals[calendarID]; c != nil {
		c.seq++
		c.minSync = c.seq
	}
}

// DeleteCalendar removes a calendar, as the member deleting it in Google would.
func (f *Fake) DeleteCalendar(calendarID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.cals, calendarID)
}

// Calendars lists the calendars of email.
func (f *Fake) Calendars(email string) []gcal.Calendar {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []gcal.Calendar
	for _, c := range f.cals {
		if c.owner == email {
			out = append(out, c.cal)
		}
	}
	slices.SortFunc(out, func(a, b gcal.Calendar) int { return strings.Compare(a.ID, b.ID) })
	return out
}

// AddCalendar gives email a calendar of its own on the Google side (their
// primary one, or one they made in Google), shown (selected) in their
// calendar list, and answers its id.
func (f *Fake) AddCalendar(email, summary string, primary bool) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	id := f.next("own-") + "@calendar.example.com"
	if primary {
		id = email
	}
	f.cals[id] = &calendar{cal: gcal.Calendar{ID: id, Summary: summary}, owner: email, primary: primary,
		events: map[string]*event{}}
	return id
}

// SelectCalendar shows or hides a calendar in its owner's Google Calendar
// (calendarList selected).
func (f *Fake) SelectCalendar(calendarID string, selected bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c := f.cals[calendarID]; c != nil {
		c.hidden = !selected
	}
}

// AddEvent writes ev on the Google side (a change the member made in
// Google) and returns the stored copy.
func (f *Fake) AddEvent(calendarID string, ev gcal.Event) (gcal.Event, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	c := f.cals[calendarID]
	if c == nil {
		return gcal.Event{}, fmt.Errorf("fakegcal: no calendar %q", calendarID)
	}
	return f.insert(c, ev), nil
}

// UpdateEvent edits an event on the Google side.
func (f *Fake) UpdateEvent(calendarID, eventID string, edit func(*gcal.Event)) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	e := f.lookup(calendarID, eventID)
	if e == nil {
		return fmt.Errorf("fakegcal: no event %q", eventID)
	}
	edit(&e.ev)
	f.touch(f.cals[calendarID], e)
	return nil
}

// CancelEvent deletes an event on the Google side (it lists as cancelled).
func (f *Fake) CancelEvent(calendarID, eventID string) error {
	return f.UpdateEvent(calendarID, eventID, func(e *gcal.Event) { e.Status = "cancelled" })
}

// Event reads one event, cancelled ones included.
func (f *Fake) Event(calendarID, eventID string) (gcal.Event, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if e := f.lookup(calendarID, eventID); e != nil {
		return e.ev, true
	}
	return gcal.Event{}, false
}

// Events lists a calendar's live (not cancelled) events in insert order.
func (f *Fake) Events(calendarID string) []gcal.Event {
	f.mu.Lock()
	defer f.mu.Unlock()
	c := f.cals[calendarID]
	if c == nil {
		return nil
	}
	var out []gcal.Event
	for _, id := range c.order {
		if e := c.events[id]; e.ev.Status != "cancelled" {
			out = append(out, e.ev)
		}
	}
	return out
}

// Channel reports a live push channel: its calendar, token and expiry.
func (f *Fake) Channel(id string) (calendarID, token string, exp time.Time, ok bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ch := f.channels[id]
	if ch == nil {
		return "", "", time.Time{}, false
	}
	return ch.calID, ch.token, ch.exp, true
}

func (f *Fake) lookup(calendarID, eventID string) *event {
	if c := f.cals[calendarID]; c != nil {
		return c.events[eventID]
	}
	return nil
}

func (f *Fake) insert(c *calendar, ev gcal.Event) gcal.Event {
	if ev.ID == "" {
		ev.ID = f.next("ev")
	}
	if ev.Status == "" {
		ev.Status = "confirmed"
	}
	e := &event{ev: ev}
	c.events[ev.ID] = e
	c.order = append(c.order, ev.ID)
	f.touch(c, e)
	return e.ev
}

func (f *Fake) touch(c *calendar, e *event) {
	c.seq++
	e.seq = c.seq
	e.ev.Etag = `"` + strconv.Itoa(c.seq) + `"`
	e.ev.Updated = f.now().UTC().Truncate(time.Millisecond)
}

// ---- HTTP ----

func oauthErr(w http.ResponseWriter, status int, code string) {
	wire.WriteJSON(w, status, map[string]string{"error": code, "error_description": "fakegcal: " + code})
}

func apiErr(w http.ResponseWriter, status int, reason string) {
	wire.WriteJSON(w, status, map[string]any{"error": map[string]any{
		"code": status, "message": "fakegcal: " + reason, "errors": []map[string]string{{"reason": reason}},
	}})
}

func (f *Fake) count(name string) {
	f.mu.Lock()
	f.calls[name]++
	f.mu.Unlock()
}

// consent signs DefaultEmail in at once and redirects back with a code, to
// a registered redirect URI only (redirect_uri_mismatch otherwise).
func (f *Fake) consent(w http.ResponseWriter, r *http.Request) {
	f.count("consent")
	q := r.URL.Query()
	f.mu.Lock()
	i := slices.Index(f.redirect, q.Get("redirect_uri"))
	registered := ""
	if i >= 0 {
		registered = f.redirect[i]
	}
	f.mu.Unlock()
	if q.Get("client_id") != ClientID || registered == "" {
		oauthErr(w, http.StatusBadRequest, "redirect_uri_mismatch")
		return
	}
	back, err := url.Parse(registered)
	if err != nil {
		oauthErr(w, http.StatusBadRequest, "invalid_request")
		return
	}
	bq := back.Query()
	f.mu.Lock()
	code := f.issue(DefaultEmail, q.Get("scope"))
	f.mu.Unlock()
	bq.Set("code", code)
	bq.Set("state", q.Get("state"))
	back.RawQuery = bq.Encode()
	w.Header().Set("Location", back.String())
	w.WriteHeader(http.StatusFound)
}

func (f *Fake) token(w http.ResponseWriter, r *http.Request) {
	f.count("token")
	if r.ParseForm() != nil || r.PostForm.Get("client_id") != ClientID || r.PostForm.Get("client_secret") != ClientKey {
		oauthErr(w, http.StatusUnauthorized, "invalid_client")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	var g *grant
	newRefresh := ""
	switch r.PostForm.Get("grant_type") {
	case "authorization_code":
		cg, ok := f.codes[r.PostForm.Get("code")]
		if !ok || r.PostForm.Get("redirect_uri") == "" {
			oauthErr(w, http.StatusBadRequest, "invalid_grant")
			return
		}
		delete(f.codes, r.PostForm.Get("code"))
		g = cg
		newRefresh = f.next("fake-refresh-")
		f.refresh[newRefresh] = g
	case "refresh_token":
		g = f.refresh[r.PostForm.Get("refresh_token")]
		if g == nil || g.revoked {
			oauthErr(w, http.StatusBadRequest, "invalid_grant")
			return
		}
	default:
		oauthErr(w, http.StatusBadRequest, "unsupported_grant_type")
		return
	}
	acc := f.next("fake-access-")
	f.access[acc] = access{g: g, exp: f.now().Add(accessTTL)}
	out := map[string]any{"access_token": acc, "expires_in": int(accessTTL.Seconds()), "token_type": "Bearer",
		"scope": g.scope}
	if newRefresh != "" {
		out["refresh_token"] = newRefresh
	}
	wire.WriteJSON(w, http.StatusOK, out)
}

func (f *Fake) revoke(w http.ResponseWriter, r *http.Request) {
	f.count("revoke")
	_ = r.ParseForm()
	tok := r.PostForm.Get("token")
	f.mu.Lock()
	defer f.mu.Unlock()
	g := f.refresh[tok]
	if a, ok := f.access[tok]; ok {
		g = a.g
	}
	if g == nil || g.revoked {
		oauthErr(w, http.StatusBadRequest, "invalid_token")
		return
	}
	g.revoked = true
	w.WriteHeader(http.StatusOK)
}

// authed answers the Google account behind the bearer token, or writes 401.
func (f *Fake) authed(w http.ResponseWriter, r *http.Request) (string, bool) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	f.mu.Lock()
	a, found := f.access[tok]
	f.mu.Unlock()
	if !ok || !found || a.g.revoked || !f.now().Before(a.exp) {
		apiErr(w, http.StatusUnauthorized, "authError")
		return "", false
	}
	return a.g.email, true
}

func (f *Fake) userinfo(w http.ResponseWriter, r *http.Request) {
	f.count("userinfo")
	email, ok := f.authed(w, r)
	if !ok {
		return
	}
	wire.WriteJSON(w, http.StatusOK, map[string]any{"sub": "sub-" + email, "email": email, "email_verified": true})
}

// ownCal answers the caller's calendar, or writes 401 / 404.
func (f *Fake) ownCal(w http.ResponseWriter, r *http.Request) (*calendar, bool) {
	email, ok := f.authed(w, r)
	if !ok {
		return nil, false
	}
	f.mu.Lock()
	c := f.cals[r.PathValue("cal")]
	f.mu.Unlock()
	if c == nil || c.owner != email {
		apiErr(w, http.StatusNotFound, "notFound")
		return nil, false
	}
	return c, true
}

func (f *Fake) calendarInsert(w http.ResponseWriter, r *http.Request) {
	f.count("calendars.insert")
	email, ok := f.authed(w, r)
	if !ok {
		return
	}
	var in gcal.Calendar
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.Summary == "" {
		apiErr(w, http.StatusBadRequest, "required")
		return
	}
	f.mu.Lock()
	in.ID = f.next("cal-") + "@group.calendar.example.com"
	f.cals[in.ID] = &calendar{cal: in, owner: email, events: map[string]*event{}}
	f.mu.Unlock()
	wire.WriteJSON(w, http.StatusOK, in)
}

func (f *Fake) calendarGet(w http.ResponseWriter, r *http.Request) {
	f.count("calendars.get")
	if c, ok := f.ownCal(w, r); ok {
		wire.WriteJSON(w, http.StatusOK, c.cal)
	}
}

// calendarList answers the caller's calendars, by id, in one page.
func (f *Fake) calendarList(w http.ResponseWriter, r *http.Request) {
	f.count("calendarList.list")
	email, ok := f.authed(w, r)
	if !ok {
		return
	}
	f.mu.Lock()
	page := gcal.CalendarListPage{Items: []gcal.CalendarListEntry{}}
	for _, c := range f.cals {
		if c.owner == email {
			page.Items = append(page.Items, gcal.CalendarListEntry{ID: c.cal.ID, Summary: c.cal.Summary,
				Primary: c.primary, Selected: !c.hidden, AccessRole: "owner"})
		}
	}
	f.mu.Unlock()
	slices.SortFunc(page.Items, func(a, b gcal.CalendarListEntry) int { return strings.Compare(a.ID, b.ID) })
	wire.WriteJSON(w, http.StatusOK, page)
}

const defaultPage = 250

func (f *Fake) eventsList(w http.ResponseWriter, r *http.Request) {
	f.count("events.list")
	c, ok := f.ownCal(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	f.mu.Lock()
	defer f.mu.Unlock()
	since := -1
	if st := q.Get("syncToken"); st != "" {
		n, err := strconv.Atoi(strings.TrimPrefix(st, "sync-"))
		if err != nil || !strings.HasPrefix(st, "sync-") || n < c.minSync || n > c.seq {
			apiErr(w, http.StatusGone, "fullSyncRequired")
			return
		}
		since = n
	}
	var timeMin time.Time
	if tm := q.Get("timeMin"); tm != "" && since < 0 {
		var err error
		if timeMin, err = time.Parse(time.RFC3339, tm); err != nil {
			apiErr(w, http.StatusBadRequest, "invalid")
			return
		}
	}
	var all []gcal.Event
	for _, id := range c.order {
		e := c.events[id]
		switch {
		case since >= 0 && e.seq <= since:
		case since < 0 && e.ev.Status == "cancelled":
		case since < 0 && !timeMin.IsZero() && ends(e.ev).Before(timeMin):
		default:
			all = append(all, e.ev)
		}
	}
	size := defaultPage
	if m, err := strconv.Atoi(q.Get("maxResults")); err == nil && m > 0 {
		size = m
	}
	off := 0
	if pt := q.Get("pageToken"); pt != "" {
		n, err := strconv.Atoi(strings.TrimPrefix(pt, "page-"))
		if err != nil || n < 0 || n > len(all) {
			apiErr(w, http.StatusBadRequest, "invalid")
			return
		}
		off = n
	}
	end := min(off+size, len(all))
	page := gcal.EventsPage{Items: all[off:end]}
	if end < len(all) {
		page.NextPageToken = "page-" + strconv.Itoa(end)
	} else {
		page.NextSyncToken = "sync-" + strconv.Itoa(c.seq)
	}
	wire.WriteJSON(w, http.StatusOK, page)
}

// ends is an event's end as an instant: an all-day end date is midnight UTC.
func ends(e gcal.Event) time.Time {
	if !e.End.DateTime.IsZero() {
		return e.End.DateTime
	}
	t, _ := time.Parse(time.DateOnly, e.End.Date)
	return t
}

func (f *Fake) eventsInsert(w http.ResponseWriter, r *http.Request) {
	f.count("events.insert")
	c, ok := f.ownCal(w, r)
	if !ok {
		return
	}
	var in gcal.Event
	if json.NewDecoder(r.Body).Decode(&in) != nil || (in.Start.Date == "" && in.Start.DateTime.IsZero()) {
		apiErr(w, http.StatusBadRequest, "required")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if in.ID != "" && c.events[in.ID] != nil {
		apiErr(w, http.StatusConflict, "duplicate")
		return
	}
	wire.WriteJSON(w, http.StatusOK, f.insert(c, in))
}

// eventsPatch applies only the fields the body names, as Google's PATCH does.
func (f *Fake) eventsPatch(w http.ResponseWriter, r *http.Request) {
	f.count("events.patch")
	c, ok := f.ownCal(w, r)
	if !ok {
		return
	}
	var fields map[string]json.RawMessage
	if json.NewDecoder(r.Body).Decode(&fields) != nil {
		apiErr(w, http.StatusBadRequest, "invalid")
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	e := c.events[r.PathValue("ev")]
	if e == nil {
		apiErr(w, http.StatusNotFound, "notFound")
		return
	}
	cur, _ := json.Marshal(e.ev) //nolint:errchkjson // plain fields
	var merged map[string]json.RawMessage
	_ = json.Unmarshal(cur, &merged)
	for k, v := range fields {
		switch k {
		case "id", "etag", "updated", "recurringEventId":
		default:
			merged[k] = v
		}
	}
	b, _ := json.Marshal(merged) //nolint:errchkjson // raw messages
	var next gcal.Event
	if json.Unmarshal(b, &next) != nil {
		apiErr(w, http.StatusBadRequest, "invalid")
		return
	}
	e.ev = next
	f.touch(c, e)
	wire.WriteJSON(w, http.StatusOK, e.ev)
}

func (f *Fake) eventsDelete(w http.ResponseWriter, r *http.Request) {
	f.count("events.delete")
	c, ok := f.ownCal(w, r)
	if !ok {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	e := c.events[r.PathValue("ev")]
	switch {
	case e == nil:
		apiErr(w, http.StatusNotFound, "notFound")
	case e.ev.Status == "cancelled":
		apiErr(w, http.StatusGone, "deleted")
	default:
		e.ev.Status = "cancelled"
		f.touch(c, e)
		w.WriteHeader(http.StatusNoContent)
	}
}

func (f *Fake) eventsWatch(w http.ResponseWriter, r *http.Request) {
	f.count("events.watch")
	c, ok := f.ownCal(w, r)
	if !ok {
		return
	}
	var in struct {
		ID, Type, Address, Token string
		Expiration               string
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.ID == "" || in.Type != "web_hook" || in.Address == "" {
		apiErr(w, http.StatusBadRequest, "required")
		return
	}
	exp := f.now().Add(channelTTL)
	if ms, err := strconv.ParseInt(in.Expiration, 10, 64); err == nil && time.UnixMilli(ms).Before(exp) {
		exp = time.UnixMilli(ms)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.channels[in.ID] != nil {
		apiErr(w, http.StatusBadRequest, "channelIdNotUnique")
		return
	}
	ch := &channel{calID: c.cal.ID, resourceID: f.next("res-"), address: in.Address, token: in.Token, exp: exp}
	f.channels[in.ID] = ch
	wire.WriteJSON(w, http.StatusOK, map[string]string{"kind": "api#channel", "id": in.ID, "resourceId": ch.resourceID,
		"expiration": strconv.FormatInt(exp.UnixMilli(), 10)})
}

func (f *Fake) channelsStop(w http.ResponseWriter, r *http.Request) {
	f.count("channels.stop")
	if _, ok := f.authed(w, r); !ok {
		return
	}
	var in struct{ ID, ResourceID string }
	_ = json.NewDecoder(r.Body).Decode(&in)
	f.mu.Lock()
	defer f.mu.Unlock()
	ch := f.channels[in.ID]
	if ch == nil || ch.resourceID != in.ResourceID {
		apiErr(w, http.StatusNotFound, "notFound")
		return
	}
	delete(f.channels, in.ID)
	w.WriteHeader(http.StatusNoContent)
}

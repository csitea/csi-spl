package gcal

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// client.go is the slice of the Calendar API v3 the sync uses (spec 149
// sections 2.3, 2.5, 2.6): the target calendar, events (list, insert, patch,
// delete) and the push channel (watch, stop). Every call takes the member's
// access token; refreshing it is the caller's (oauth.go Refresh).

// Calendar is the target calendar the hub creates (spec 149 section 2.3).
type Calendar struct {
	ID       string `json:"id,omitempty"`
	Summary  string `json:"summary"`
	TimeZone string `json:"timeZone,omitempty"`
}

// EventTime is a start or an end: Date (YYYY-MM-DD) for an all-day event,
// else DateTime.
type EventTime struct {
	Date     string    `json:"date,omitempty"`
	DateTime time.Time `json:"dateTime,omitzero"`
	TimeZone string    `json:"timeZone,omitempty"`
}

// Event is a Google event, with the fields the sync maps (section 2.5).
// Summary, Description and Recurrence are always sent, so a patch clears
// them when Spool did; the read-only fields are never sent.
type Event struct {
	ID               string    `json:"id,omitempty"`
	Status           string    `json:"status,omitempty"` // confirmed, tentative, cancelled
	Summary          string    `json:"summary"`
	Description      string    `json:"description"`
	Start            EventTime `json:"start,omitzero"`
	End              EventTime `json:"end,omitzero"`
	Recurrence       []string  `json:"recurrence"`
	RecurringEventID string    `json:"recurringEventId,omitempty"`
	Visibility       string    `json:"visibility,omitempty"` // default, private
	Etag             string    `json:"etag,omitempty"`
	Updated          time.Time `json:"updated,omitzero"`
}

// ListOptions is one events.list call. With SyncToken set it lists what
// changed since (cancelled items included); without it, a full list from
// TimeMin. PageToken continues a page; MaxResults 0 is Google's default.
type ListOptions struct {
	SyncToken  string
	TimeMin    time.Time
	PageToken  string
	MaxResults int
}

// EventsPage is one page of events.list. NextSyncToken comes on the last
// page only; the caller stores it for the next cycle.
type EventsPage struct {
	Items         []Event `json:"items"`
	NextPageToken string  `json:"nextPageToken"`
	NextSyncToken string  `json:"nextSyncToken"`
}

// CalendarListEntry is one calendar of the member's calendar list (owner
// poll d93654e1 B, SPL-3852): their primary calendar, the ones they made or
// subscribed to. Selected = shown in the member's Google Calendar.
type CalendarListEntry struct {
	ID         string `json:"id"`
	Summary    string `json:"summary"`
	Primary    bool   `json:"primary,omitempty"`
	Selected   bool   `json:"selected,omitempty"`
	Hidden     bool   `json:"hidden,omitempty"`
	Deleted    bool   `json:"deleted,omitempty"`
	AccessRole string `json:"accessRole,omitempty"` // freeBusyReader, reader, writer, owner
}

// CalendarListPage is one page of calendarList.list.
type CalendarListPage struct {
	Items         []CalendarListEntry `json:"items"`
	NextPageToken string              `json:"nextPageToken"`
}

// Channel is a push channel on a calendar's events (section 2.6). Token is
// echoed by Google in X-Goog-Channel-Token on every push.
type Channel struct {
	ID         string              `json:"id"`
	ResourceID string              `json:"resourceId,omitempty"`
	Type       string              `json:"type,omitempty"`
	Address    string              `json:"address,omitempty"`
	Token      marketing.Plaintext `json:"-"`
	Expiration time.Time           `json:"-"`
}

// CreateCalendar creates a secondary calendar for the member.
func (g *Google) CreateCalendar(ctx context.Context, access marketing.Plaintext, c Calendar) (Calendar, error) {
	var out Calendar
	err := g.call(ctx, access, http.MethodPost, "/calendars", nil, c, &out)
	if err != nil {
		return Calendar{}, fmt.Errorf("gcal calendars.insert: %w", err)
	}
	return out, nil
}

// GetCalendar reads a calendar; ErrNotFound when the member deleted it.
func (g *Google) GetCalendar(ctx context.Context, access marketing.Plaintext, calendarID string) (Calendar, error) {
	var out Calendar
	err := g.call(ctx, access, http.MethodGet, "/calendars/"+url.PathEscape(calendarID), nil, nil, &out)
	if err != nil {
		return Calendar{}, fmt.Errorf("gcal calendars.get: %w", err)
	}
	return out, nil
}

// ListCalendars is one page of the member's calendar list (calendarList.list:
// a read scope, calendar.readonly or wider; without it Google answers 403).
func (g *Google) ListCalendars(ctx context.Context, access marketing.Plaintext, pageToken string) (CalendarListPage, error) {
	q := url.Values{}
	if pageToken != "" {
		q.Set("pageToken", pageToken)
	}
	var out CalendarListPage
	if err := g.call(ctx, access, http.MethodGet, "/users/me/calendarList", q, nil, &out); err != nil {
		return CalendarListPage{}, fmt.Errorf("gcal calendarList.list: %w", err)
	}
	return out, nil
}

// ListEvents is one page of events.list. A refused SyncToken is
// ErrSyncTokenGone.
func (g *Google) ListEvents(ctx context.Context, access marketing.Plaintext, calendarID string, o ListOptions) (EventsPage, error) {
	q := url.Values{}
	if o.SyncToken != "" {
		q.Set("syncToken", o.SyncToken)
	} else if !o.TimeMin.IsZero() {
		q.Set("timeMin", o.TimeMin.UTC().Format(time.RFC3339))
	}
	if o.PageToken != "" {
		q.Set("pageToken", o.PageToken)
	}
	if o.MaxResults > 0 {
		q.Set("maxResults", strconv.Itoa(o.MaxResults))
	}
	var out EventsPage
	err := g.call(ctx, access, http.MethodGet, eventsPath(calendarID, ""), q, nil, &out)
	if err != nil {
		return EventsPage{}, fmt.Errorf("gcal events.list: %w", err)
	}
	return out, nil
}

// InsertEvent creates ev on the calendar and returns Google's copy (its id
// and etag go to the map row).
func (g *Google) InsertEvent(ctx context.Context, access marketing.Plaintext, calendarID string, ev Event) (Event, error) {
	var out Event
	if err := g.call(ctx, access, http.MethodPost, eventsPath(calendarID, ""), nil, ev, &out); err != nil {
		return Event{}, fmt.Errorf("gcal events.insert: %w", err)
	}
	return out, nil
}

// PatchEvent sends ev's mapped fields to an existing event.
func (g *Google) PatchEvent(ctx context.Context, access marketing.Plaintext, calendarID, eventID string, ev Event) (Event, error) {
	ev.ID, ev.Etag, ev.Updated, ev.RecurringEventID = "", "", time.Time{}, ""
	var out Event
	if err := g.call(ctx, access, http.MethodPatch, eventsPath(calendarID, eventID), nil, ev, &out); err != nil {
		return Event{}, fmt.Errorf("gcal events.patch: %w", err)
	}
	return out, nil
}

// DeleteEvent deletes an event. One already gone (404, 410) is done.
func (g *Google) DeleteEvent(ctx context.Context, access marketing.Plaintext, calendarID, eventID string) error {
	err := g.call(ctx, access, http.MethodDelete, eventsPath(calendarID, eventID), nil, nil, nil)
	if err != nil && !isGone(err) {
		return fmt.Errorf("gcal events.delete: %w", err)
	}
	return nil
}

// Watch opens a push channel on the calendar's events to address.
func (g *Google) Watch(ctx context.Context, access marketing.Plaintext, calendarID string, ch Channel) (Channel, error) {
	in := map[string]any{"id": ch.ID, "type": "web_hook", "address": ch.Address, "token": ch.Token.Reveal()}
	if !ch.Expiration.IsZero() {
		in["expiration"] = strconv.FormatInt(ch.Expiration.UnixMilli(), 10)
	}
	var out struct {
		ID         string `json:"id"`
		ResourceID string `json:"resourceId"`
		Expiration string `json:"expiration"` // ms since the epoch, as a string
	}
	if err := g.call(ctx, access, http.MethodPost, eventsPath(calendarID, "watch"), nil, in, &out); err != nil {
		return Channel{}, fmt.Errorf("gcal events.watch: %w", err)
	}
	ms, err := strconv.ParseInt(out.Expiration, 10, 64)
	if err != nil {
		return Channel{}, fmt.Errorf("gcal events.watch: expiration %q", out.Expiration)
	}
	return Channel{ID: out.ID, ResourceID: out.ResourceID, Type: "web_hook", Address: ch.Address,
		Token: ch.Token, Expiration: time.UnixMilli(ms).UTC()}, nil
}

// StopChannel stops a push channel. One already gone is done.
func (g *Google) StopChannel(ctx context.Context, access marketing.Plaintext, channelID, resourceID string) error {
	in := map[string]string{"id": channelID, "resourceId": resourceID}
	err := g.call(ctx, access, http.MethodPost, "/channels/stop", nil, in, nil)
	if err != nil && !isGone(err) {
		return fmt.Errorf("gcal channels.stop: %w", err)
	}
	return nil
}

func eventsPath(calendarID, eventID string) string {
	p := "/calendars/" + url.PathEscape(calendarID) + "/events"
	if eventID != "" {
		p += "/" + url.PathEscape(eventID)
	}
	return p
}

func isGone(err error) bool {
	he, ok := err.(*HTTPError) //nolint:errorlint // call returns it unwrapped
	return ok && (he.Status == http.StatusNotFound || he.Status == http.StatusGone)
}

func (g *Google) call(ctx context.Context, access marketing.Plaintext, method, path string, q url.Values, in, out any) error {
	u := g.cfg.CalendarBase + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+access.Reveal())
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return g.doJSON(req, out)
}

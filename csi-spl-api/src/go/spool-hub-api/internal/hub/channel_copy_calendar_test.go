package hub_test

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/channelmove"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 169 row T11, C16: a calendar copy sends nothing. A real copy runs, and
// what leaves the hub is counted at the two places a calendar event can leave:
// the Google Out half (fakegcal counts its writes) and the reminder read. The
// calendar handlers hold no mail or notify call, so there is no third seam to
// count. Postgres only: the copy is.

// copySource makes a channel in a second workspace with one post and, on its
// topic, an event with a guest and a reminder.
func copySource(t *testing.T, se *gcalSyncEnv, hum string) (src, channel string) {
	t.Helper()
	ctx, now := context.Background(), se.clock.now()
	src, channel = syncWorkspace(t, se.env), "copied-"+uuidV4()[:8]
	if err := se.st.CreateChannel(ctx, store.Channel{TenantID: src, ChannelID: channel, Name: channel, CreatedBy: hum, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	id, task := uuidV4(), uuidV4()
	inner := fmt.Sprintf(`{"v":1,"msg_id":%q,"task_id":%q,"ts":%q,"from":%q,"to":"ALL-0","kind":"note","body":"x","files":[]}`, id, task, now.Format(time.RFC3339), hum)
	m := store.Message{TenantID: src, MsgID: id, TaskID: task, Channel: channel, IsParent: 1, TS: now, FromBox: hub.WUIBox, FromID: hum, ToBox: hub.WUIBox, ToID: "ALL-0",
		Kind: "note", Body: "x", Files: []byte(`[]`), Msg: []byte(inner), Env: []byte(`{"from_box":"box-wui","channel":"` + channel + `","msg":` + inner + `}`),
		ReceivedAt: now, ExpiresAt: now.Add(30 * 24 * time.Hour)}
	if _, err := se.st.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	_, err := se.st.(store.Calendar).CreateCalendarEvent(ctx, src, store.CalendarEvent{Title: "copied", Kind: "other", Audience: store.CalendarWorkspace,
		CreatorType: "human", CreatorID: hum, TopicID: task, StartsAt: now.Add(24 * time.Hour), EndsAt: now.Add(25 * time.Hour), RemindAt: now.Add(23 * time.Hour),
		Guests: []store.CalendarGuest{{Type: "human", ID: hum, InvitedBy: hum}}}, now)
	if err != nil {
		t.Fatal(err)
	}
	return src, channel
}

func TestChannelCopyCalendarSendsNothing(t *testing.T) {
	se := gcalSyncEnvOf(t)
	pg, ok := se.st.(*store.Postgres)
	if !ok {
		t.Skip("the copy needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	ctx, hum := context.Background(), se.member(t)
	src, channel := copySource(t, se, hum)
	req := store.ChannelCopyRequest{MoveID: uuidV4(), GoMsgID: uuidV4(), StartedBy: hum}
	req.Src, req.Channel, req.Dst, req.BindTypes = src, channel, se.tid, channelmove.Binds
	for _, e := range channelmove.Catalogue {
		req.Tables = append(req.Tables, store.MoveTable{Table: e.Table, Class: string(e.Class), Set: e.Set, Refs: e.Refs})
	}
	res, err := pg.ApplyChannelCopy(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if res.Copied["calendar_events"] != 1 || res.Copied["calendar_guests"] != 1 {
		t.Fatalf("seed: the copy carried %v, want the event and its guest", res.Copied)
	}
	se.fake.ResetCalls()
	se.next()
	se.cycle(t)
	if n := se.calls("events.insert", "events.patch", "events.delete"); n != 0 {
		t.Errorf("a copied event made %d Google event write(s), want 0", n)
	}
	if m := se.maps(t, hum); len(m) != 0 {
		t.Errorf("a copied event has map rows %+v", m)
	}
	now := se.clock.now()
	q := fmt.Sprintf("/v1/calendar/reminders?from=%s&to=%s", now.Format(time.RFC3339), now.Add(48*time.Hour).Format(time.RFC3339))
	code, out := call(t, se.env, se.tid, http.MethodGet, q, hum, nil)
	if rows, _ := out["reminders"].([]any); code != http.StatusOK || len(rows) != 0 {
		t.Errorf("a copied event's reminders: %d %v, want none", code, out)
	}

	// CONTROL: an ordinary event of the same member writes to Google and fires.
	se.event(t, hum, "control", func(e *store.CalendarEvent) { e.RemindAt = now.Add(23 * time.Hour) })
	se.fake.ResetCalls()
	se.next()
	se.cycle(t)
	if n := se.fake.Calls("events.insert"); n != 1 {
		t.Errorf("control: events.insert %d times, want 1 (the counter sees a send)", n)
	}
	code, out = call(t, se.env, se.tid, http.MethodGet, q, hum, nil)
	if rows, _ := out["reminders"].([]any); code != http.StatusOK || len(rows) != 1 {
		t.Errorf("control: reminders %d %v, want the one", code, out)
	}
}

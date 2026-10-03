package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Perf round 4 G7: two reads that ride the batch already in flight. Each is
// tested against the two separate reads it replaces, and the clone gate
// against a walk that WOULD return a row: a clone that is an end of a DM.

// TestViewTopicsUnlessCloneGate: a live act-as clone gets clone=true and no
// rows, though the walk in the same batch matched its DM (CONTROL: plain
// ViewTopics returns that row). A non-clone and a stopped clone get exactly
// ViewTopics' rows.
func TestViewTopicsUnlessCloneGate(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	admin := seatMember(t, pg, tid, "admin")
	target := seatMember(t, pg, tid, "developer")
	now := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := pg.StartClone(ctx, CloneStart{TenantID: tid, TargetHum: target, CreatedBy: admin,
		ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	for _, from := range []string{cl.CloneHum, target} { // one DM each, with an agent
		m := msgFor(tid, uuid4(), "box-wui", now, now, "env-"+uuid4())
		m.Channel, m.FromID, m.FromBox, m.ToID = "", from, "box-wui", "CLE-07"
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	dmList := func(reader string) TopicQuery {
		return TopicQuery{DM: true, Viewer: reader, Reader: reader, Roots: true, Limit: 51, Now: now.Add(time.Second)}
	}

	if rows, err := pg.ViewTopics(ctx, tid, dmList(cl.CloneHum)); err != nil || len(rows) != 1 {
		t.Fatalf("CONTROL: the walk matches the clone's own DM: %v %d row(s), want 1", err, len(rows))
	}
	rows, clone, err := pg.ViewTopicsUnlessClone(ctx, tid, cl.CloneHum, dmList(cl.CloneHum))
	if err != nil || !clone || rows != nil {
		t.Fatalf("live clone: clone=%v rows=%d err=%v, want clone=true and no rows (the walk's result leaked)", clone, len(rows), err)
	}

	same := func(who, reader string) {
		t.Helper()
		want, err := pg.ViewTopics(ctx, tid, dmList(reader))
		if err != nil {
			t.Fatal(err)
		}
		got, clone, err := pg.ViewTopicsUnlessClone(ctx, tid, reader, dmList(reader))
		if err != nil || clone || len(got) != 1 || len(got) != len(want) || got[0].TaskID != want[0].TaskID {
			t.Fatalf("%s: clone=%v err=%v got %+v, want ViewTopics' %+v", who, clone, err, got, want)
		}
	}
	same("non-clone", target)
	if err := pg.StopClone(ctx, tid, cl.CloneHum, "stop", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	same("stopped clone (as Clone: ended_at set = not live)", cl.CloneHum)
}

// TestViewTopicDoor: the door's aggregate equals TopicAccess, the page equals
// ViewTopic, a refusal returns no rows, and a topic with no message is never
// put to the verdict.
func TestViewTopicDoor(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid, task := newTenant(t, pg), uuid4()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for i := 0; i < 3; i++ {
		at := now.Add(time.Duration(i-3) * time.Second)
		m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
		m.Channel, m.FromID, m.ToID = ChannelLobby, "CLE-01", "ALL-0"
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	q := TopicMsgQuery{TaskID: task, Limit: 51, Now: now, Reader: "HUM-1"}
	wantA, err := pg.TopicAccess(ctx, tid, task, now)
	if err != nil {
		t.Fatal(err)
	}
	wantRows, err := pg.ViewTopic(ctx, tid, q)
	if err != nil || len(wantRows) != 3 {
		t.Fatalf("CONTROL: ViewTopic %v %d row(s)", err, len(wantRows))
	}

	var asked TopicAccess
	a, ok, rows, err := pg.ViewTopicDoor(ctx, tid, q, func(a TopicAccess) (bool, error) { asked = a; return true, nil })
	if err != nil || !ok || len(rows) != len(wantRows) {
		t.Fatalf("admitted: ok=%v err=%v %d row(s), want %d", ok, err, len(rows), len(wantRows))
	}
	for i := range rows {
		if rows[i].MsgID != wantRows[i].MsgID || len(rows[i].Deliveries) != len(wantRows[i].Deliveries) {
			t.Fatalf("row %d: %+v, want %+v", i, rows[i], wantRows[i])
		}
	}
	if !a.Found || asked.Found != a.Found || len(a.Channels) != len(wantA.Channels) || a.Channels[0] != wantA.Channels[0] {
		t.Fatalf("aggregate %+v (asked %+v), want TopicAccess' %+v", a, asked, wantA)
	}

	if _, ok, rows, err := pg.ViewTopicDoor(ctx, tid, q, func(TopicAccess) (bool, error) { return false, nil }); err != nil || ok || rows != nil {
		t.Fatalf("refused: ok=%v err=%v rows=%d, want ok=false and no rows", ok, err, len(rows))
	}
	boom := errors.New("verdict failed")
	if _, ok, rows, err := pg.ViewTopicDoor(ctx, tid, q, func(TopicAccess) (bool, error) { return true, boom }); !errors.Is(err, boom) || ok || rows != nil {
		t.Fatalf("verdict error: ok=%v err=%v rows=%d", ok, err, len(rows))
	}

	none := q
	none.TaskID = uuid4()
	called := false
	if a, ok, rows, err := pg.ViewTopicDoor(ctx, tid, none, func(TopicAccess) (bool, error) { called = true; return false, nil }); err != nil || !ok || a.Found || len(rows) != 0 || called {
		t.Fatalf("no such topic: found=%v ok=%v rows=%d err=%v asked=%v", a.Found, ok, len(rows), err, called)
	}
}

package store

import (
	"context"
	"testing"
	"time"
)

// spec 062 (rdb 0104): the per-member Flow is written by the insert and read
// as one page plus counts. Memory and, with SPOOL_TEST_PG_DSN, Postgres.
func TestFlowEvents(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe, ok := s.(FlowEvents)
			if !ok {
				t.Fatalf("%s store has no FlowEvents", name)
			}
			rm := s.(ReadMarks)
			ctx := context.Background()
			base := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			if err := s.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: "sec", Name: "sec", CreatedBy: "HUM-1", CreatedAt: base}); err != nil {
				t.Fatal(err)
			}
			if err := s.AddChannelHumans(ctx, tid, "sec", []string{"HUM-1"}, "HUM-1", base); err != nil {
				t.Fatal(err)
			}
			n := 0
			post := func(from, to, channel, task, body string) Message {
				t.Helper()
				n++
				at := base.Add(time.Duration(n) * time.Second)
				m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
				m.FromID, m.ToID, m.Channel, m.Body = from, to, channel, body
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			now := base.Add(time.Hour)
			read := func(member, kind string, limit int) FlowPage {
				t.Helper()
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: member, Limit: limit, Kind: kind, Now: now})
				if err != nil {
					t.Fatal(err)
				}
				return p
			}
			kinds := func(p FlowPage) string {
				out := ""
				for _, e := range p.Events {
					out += e.Kind + ":" + e.Body + "|"
				}
				return out
			}

			task, other := uuid4(), uuid4()
			post("HUM-1", "", "lobby", task, "root by one")                                        // HUM-1 watches task
			post("HUM-2", "", "lobby", task, "@HUM-1 look, and @c-001 too")                        // mention for 1; 2 watches
			post("CLE-07", "", "lobby", task, "agent reply")                                       // reply for 1 and 2
			post("HUM-1", "", "lobby", task, "my own @HUM-1 line")                                 // own: nothing for 1; reply for 2
			dm := post("CLE-07", "HUM-1", "", other, "dm to one, cc @HUM-3")                       // dm for 1; 3 cannot read it
			post("HUM-2", "HUM-1", "", uuid4(), "HUM-2 needs you in https://x/t/"+task+`: "look"`) // poke folds into the mention
			poke := post("HUM-2", "HUM-3", "", uuid4(), "HUM-2 needs you in https://x/t/"+task+`: "look"`)
			post("HUM-2", "", "sec", uuid4(), "@HUM-3 @HUM-1 private") // 3 is no member of #sec
			// A resend of a stored line writes nothing new.
			if _, err := s.InsertMessage(ctx, dm); err != nil {
				t.Fatal(err)
			}

			p1 := read("HUM-1", "", 30)
			if got, want := kinds(p1), "mention:@HUM-3 @HUM-1 private|dm:dm to one, cc @HUM-3|reply:agent reply|mention:@HUM-1 look, and @c-001 too|"; got != want {
				t.Fatalf("HUM-1 flow\n got %s\nwant %s", got, want)
			}
			if want := (FlowCounts{Mention: 2, Reply: 1, DM: 1, Total: 4, Channels: 3, DMs: 1}); p1.Counts != want || p1.Unread != want {
				t.Fatalf("HUM-1 counts %+v unread %+v, want %+v", p1.Counts, p1.Unread, want)
			}
			if got, want := kinds(read("HUM-2", "", 30)), "reply:my own @HUM-1 line|reply:agent reply|"; got != want {
				t.Fatalf("HUM-2 flow\n got %s\nwant %s", got, want)
			}
			p3 := read("HUM-3", "", 30)
			if len(p3.Events) != 1 || p3.Events[0].Kind != FlowPoke || p3.Events[0].MsgID != poke.MsgID {
				t.Fatalf("HUM-3 flow = %s, want the one poke", kinds(p3))
			}
			if p3.Counts.Mention != 1 || p3.Counts.Total != 1 || p3.Counts.DMs != 1 || p3.Counts.Channels != 0 {
				t.Fatalf("HUM-3 counts = %+v, want the poke under mention", p3.Counts)
			}
			if got := kinds(read("HUM-3", FlowMention, 30)); got != kinds(p3) {
				t.Fatalf("kind=mention must take pokes: %s", got)
			}
			if got := read("CLE-07", "", 30); len(got.Events) != 0 {
				t.Fatalf("an agent got flow events: %s", kinds(got))
			}

			// Paging: two per page, the cursor of the last one starts the next.
			pg := read("HUM-1", "", 2)
			if len(pg.Events) != 2 || !pg.More {
				t.Fatalf("page 1 = %s more=%v", kinds(pg), pg.More)
			}
			last := pg.Events[1]
			pg2, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Limit: 2, BeforeAt: last.At, BeforeID: last.MsgID, Now: now})
			if err != nil {
				t.Fatal(err)
			}
			if len(pg2.Events) != 2 || pg2.More || pg2.Events[0].Body != "agent reply" {
				t.Fatalf("page 2 = %s more=%v", kinds(pg2), pg2.More)
			}
			if got := kinds(read("HUM-1", FlowReply, 30)); got != "reply:agent reply|" {
				t.Fatalf("kind=reply = %s", got)
			}

			// Opening the pane (f:seen) zeroes the badge, not the chips.
			if err := rm.SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{FlowSeenKey: {At: base.Add(30 * time.Second)}}, now); err != nil {
				t.Fatal(err)
			}
			p1 = read("HUM-1", "", 30)
			if p1.Counts.Total != 0 || p1.Unread.Total != 4 {
				t.Fatalf("after f:seen counts %+v unread %+v, want 0 and 4", p1.Counts, p1.Unread)
			}
			// Opening an entry (f:<msg_id>) and reading a thread (t:) cover them.
			if err := rm.SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{
				FlowMarkKey(dm.MsgID): {At: now}, ThreadMarkKey(task): {At: now},
			}, now); err != nil {
				t.Fatal(err)
			}
			p1 = read("HUM-1", "", 30)
			if want := (FlowCounts{Mention: 1, Total: 1, Channels: 1}); p1.Unread != want {
				t.Fatalf("after f:<dm> + t:<task> unread = %+v, want %+v", p1.Unread, want)
			}
			for _, e := range p1.Events {
				if e.Unread != (e.Channel == "sec") {
					t.Fatalf("event %q unread=%v", e.Body, e.Unread)
				}
			}

			// The live fan-out: the event and fresh counts of the members who got one.
			pushes, err := fe.FlowFanout(ctx, tid, poke.MsgID, []string{"HUM-1", "HUM-3", "HUM-9"}, now)
			if err != nil {
				t.Fatal(err)
			}
			if len(pushes) != 1 || pushes["HUM-3"].Event.Kind != FlowPoke || pushes["HUM-3"].Counts.Total != 1 {
				t.Fatalf("fan-out = %+v, want HUM-3's poke only", pushes)
			}

			// Retention: an expired line leaves the flow; its f: mark is swept.
			later := dm.ExpiresAt.Add(time.Second)
			if _, err := s.Sweep(ctx, later); err != nil {
				t.Fatal(err)
			}
			marks, err := rm.ReadMarksOf(ctx, tid, "HUM-1")
			if err != nil {
				t.Fatal(err)
			}
			if _, ok := marks[FlowMarkKey(dm.MsgID)]; ok {
				t.Fatal("the f:<msg_id> mark of a swept line survived the sweep")
			}
			if _, ok := marks[FlowSeenKey]; !ok {
				t.Fatal("the sweep removed f:seen")
			}
		})
	}
}

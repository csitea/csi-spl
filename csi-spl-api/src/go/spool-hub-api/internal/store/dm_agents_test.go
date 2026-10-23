package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"
)

// Spec 151 row T001 (SPL-3039): the agents added to a DM. Memory always,
// Postgres with a DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full).

var (
	dmHum1  = DMEnd{"HUM-1", "box-wui"}
	dmHum2  = DMEnd{"HUM-2", "box-wui"}
	dmAgent = DMEnd{"c-9", "box-a"}
)

func dmPair12(t *testing.T) DMPair {
	t.Helper()
	p, err := NewDMPair(dmHum2, dmHum1)
	if err != nil || p.A != dmHum1 || p.B != dmHum2 {
		t.Fatalf("NewDMPair sorts: %+v %v", p, err)
	}
	return p
}

// TestDMAgentsStore is case C1: AddDMAgent, then DMAgents(pair) returns the
// agent; RemoveDMAgent marks it removed. Red on origin/master before T001:
// no such store method, the package does not compile.
func TestDMAgentsStore(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ds := context.Background(), s.(DMAgentStore)
			tid, pair := newTenant(t, s), dmPair12(t)
			list := func(tenant string) []DMAgent {
				t.Helper()
				out, err := ds.DMAgents(ctx, tenant, pair)
				if err != nil {
					t.Fatalf("DMAgents: %v", err)
				}
				return out
			}
			if got := list(tid); len(got) != 0 {
				t.Fatalf("no agent added yet: %+v", got)
			}
			if err := ds.AddDMAgent(ctx, tid, pair, dmAgent, "HUM-1", now); err != nil {
				t.Fatalf("AddDMAgent: %v", err)
			}
			want := DMAgent{Agent: dmAgent, Origin: DMAgentInvite, InvitedBy: "HUM-1", AddedAt: now}
			if got := list(tid); len(got) != 1 || got[0] != want {
				t.Fatalf("after add: %+v, want [%+v]", got, want)
			}
			// A second add of a live agent changes nothing.
			if err := ds.AddDMAgent(ctx, tid, pair, dmAgent, "HUM-2", now.Add(time.Minute)); err != nil {
				t.Fatalf("2nd add: %v", err)
			}
			if got := list(tid); len(got) != 1 || got[0] != want {
				t.Fatalf("2nd add changed the row: %+v", got)
			}
			// Another workspace sees none of it.
			if got := list(newTenant(t, s)); len(got) != 0 {
				t.Fatalf("other workspace reads %+v", got)
			}

			at := now.Add(2 * time.Minute)
			if err := ds.RemoveDMAgent(ctx, tid, pair, dmAgent, at); err != nil {
				t.Fatalf("RemoveDMAgent: %v", err)
			}
			removed := want
			removed.Origin, removed.RemovedAt = DMAgentRemoved, at
			if got := list(tid); len(got) != 1 || got[0] != removed {
				t.Fatalf("after remove: %+v, want [%+v]", got, removed)
			}
			if err := ds.RemoveDMAgent(ctx, tid, pair, dmAgent, at.Add(time.Minute)); err != nil {
				t.Fatalf("removing a removed agent: %v", err)
			}
			if got := list(tid); len(got) != 1 || got[0] != removed {
				t.Fatalf("2nd remove changed the row: %+v", got)
			}
			if err := ds.RemoveDMAgent(ctx, tid, pair, DMEnd{"c-10", "box-a"}, at); !errors.Is(err, ErrNotFound) {
				t.Fatalf("removing an agent never added: %v, want ErrNotFound", err)
			}

			// Added again: live, by the new person, from the new time.
			back := now.Add(3 * time.Minute)
			if err := ds.AddDMAgent(ctx, tid, pair, dmAgent, "HUM-2", back); err != nil {
				t.Fatalf("re-add: %v", err)
			}
			again := DMAgent{Agent: dmAgent, Origin: DMAgentInvite, InvitedBy: "HUM-2", AddedAt: back}
			second := DMAgent{Agent: DMEnd{"a-1", "box-b"}, Origin: DMAgentInvite, InvitedBy: "HUM-1", AddedAt: back}
			if err := ds.AddDMAgent(ctx, tid, pair, second.Agent, "HUM-1", back); err != nil {
				t.Fatalf("2nd agent: %v", err)
			}
			if got := list(tid); !slices.Equal(got, []DMAgent{second, again}) {
				t.Fatalf("after re-add: %+v, want sorted [%+v %+v]", got, second, again)
			}
		})
	}
}

// TestDMAgentsRefuse: bad pairs and agents are refused before any write.
func TestDMAgentsRefuse(t *testing.T) {
	now := time.Now().UTC()
	if _, err := NewDMPair(dmHum1, dmHum1); !errors.Is(err, ErrBadDMPair) {
		t.Fatalf("same ends: %v", err)
	}
	if _, err := NewDMPair(dmHum1, DMEnd{"HUM-2", ""}); !errors.Is(err, ErrBadDMPair) {
		t.Fatalf("an end with no box: %v", err)
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ds := context.Background(), s.(DMAgentStore)
			tid, pair := newTenant(t, s), dmPair12(t)
			unsorted := DMPair{A: pair.B, B: pair.A}
			for _, tc := range []struct {
				name  string
				pair  DMPair
				agent DMEnd
				want  error
			}{
				{"unsorted pair", unsorted, dmAgent, ErrBadDMPair},
				{"agent is an end", pair, dmHum2, ErrBadDMAgent},
				{"agent with no box", pair, DMEnd{"c-9", ""}, ErrBadDMAgent},
			} {
				if err := ds.AddDMAgent(ctx, tid, tc.pair, tc.agent, "HUM-1", now); !errors.Is(err, tc.want) {
					t.Errorf("%s: add %v, want %v", tc.name, err, tc.want)
				}
				if err := ds.RemoveDMAgent(ctx, tid, tc.pair, tc.agent, now); !errors.Is(err, tc.want) {
					t.Errorf("%s: remove %v, want %v", tc.name, err, tc.want)
				}
			}
			if _, err := ds.DMAgents(ctx, tid, unsorted); !errors.Is(err, ErrBadDMPair) {
				t.Errorf("list of an unsorted pair: %v", err)
			}
			if err := ds.AddDMAgent(ctx, "", pair, dmAgent, "HUM-1", now); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant: %v", err)
			}
		})
	}
}

// TestDMAgentReadDoor is the readableBy case (spec 151 4.1): the reply of an
// agent added to the DM HUM-1 <-> HUM-2, written to HUM-1 in that DM's
// topic, is readable by HUM-2 too. Red controls, each one message that HUM-2
// must NOT read: the same agent's line to HUM-1 before it was added, after
// it was removed, and in a private topic of HUM-1 and the agent alone; and
// HUM-3, no end of the DM, reads none of the agent's lines.
func TestDMAgentReadDoor(t *testing.T) {
	base := time.Now().UTC().Truncate(time.Microsecond).Add(-time.Hour)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ds := context.Background(), s.(DMAgentStore)
			tid, pair := newTenant(t, s), dmPair12(t)
			dmTask, privTask := uuid4(), uuid4()
			put := func(task string, from, to DMEnd, at time.Duration, body string) string {
				t.Helper()
				m := msgFor(tid, task, to.Box, base.Add(at), base.Add(at), "env-"+uuid4())
				m.Channel, m.Body, m.FromID, m.FromBox, m.ToID = "", body, from.ID, from.Box, to.ID
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m.MsgID
			}
			opening := put(dmTask, dmHum1, dmHum2, 0, "hi HUM-2")
			early := put(dmTask, dmAgent, dmHum1, time.Minute, "before I was added")
			if err := ds.AddDMAgent(ctx, tid, pair, dmAgent, "HUM-1", base.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			reply := put(dmTask, dmAgent, dmHum1, 3*time.Minute, "the agent's reply")
			put(privTask, dmHum1, dmAgent, 4*time.Minute, "private to the agent")
			private := put(privTask, dmAgent, dmHum1, 5*time.Minute, "private answer")
			if err := ds.RemoveDMAgent(ctx, tid, pair, dmAgent, base.Add(6*time.Minute)); err != nil {
				t.Fatal(err)
			}
			late := put(dmTask, dmAgent, dmHum1, 7*time.Minute, "after I was removed")

			now := base.Add(time.Hour)
			read := func(reader, task string) []string {
				t.Helper()
				vs, err := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: task, Reader: reader, Now: now, Limit: 50})
				if err != nil {
					t.Fatalf("ViewTopic %s: %v", reader, err)
				}
				var ids []string
				for _, v := range vs {
					ids = append(ids, v.MsgID)
				}
				return ids
			}
			if got := read("HUM-1", dmTask); !slices.Equal(got, []string{opening, early, reply, late}) {
				t.Fatalf("CONTROL: HUM-1, an end, reads every line: %v", got)
			}
			got := read("HUM-2", dmTask)
			if !slices.Equal(got, []string{opening, reply}) {
				t.Fatalf("HUM-2 reads %v, want the opening and the agent's reply %v (not early %s, not late %s)",
					got, []string{opening, reply}, early, late)
			}
			if got := read("HUM-2", privTask); len(got) != 0 {
				t.Fatalf("HUM-2 reads the agent's private topic with HUM-1: %v (private answer %s)", got, private)
			}
			if got := read("HUM-3", dmTask); len(got) != 0 {
				t.Fatalf("HUM-3, no end, reads %v", got)
			}

			// The topic list: HUM-2 sees the DM topic, with the reply counted,
			// and not the private one; HUM-3 sees neither.
			rows, err := s.ViewTopics(ctx, tid, TopicQuery{Now: now, Reader: "HUM-2", Limit: 50})
			if err != nil || len(rows) != 1 || rows[0].TaskID != dmTask || rows[0].Count != 2 {
				t.Fatalf("HUM-2 topic list: %v %+v, want %s with count 2", err, rows, dmTask)
			}
			if rows, err := s.ViewTopics(ctx, tid, TopicQuery{Now: now, Reader: "HUM-3", Limit: 50}); err != nil || len(rows) != 0 {
				t.Fatalf("HUM-3 topic list: %v %+v", err, rows)
			}
		})
	}
}

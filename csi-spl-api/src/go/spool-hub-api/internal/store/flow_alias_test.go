package store

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 130 FR-007: only an agent (<id>@<box>, agentid.IsAgent) is an agent
// flow member. The everyone-alias ALL-0 and the other -0 aliases (CI-0,
// HUB-0, LGC-0) are participants, not agents: a line to ALL-0 on box-wui, or
// one that names an alias with a box, keys no flow_events row to it. prd t1
// held 9 'ALL-0@box-wui' mention rows before this (2026-10-11).
// Memory and, with SPOOL_TEST_PG_DSN, Postgres.
func TestFlowAliasIsNoAgent(t *testing.T) {
	for _, key := range []string{"ALL-0@box-wui", "CI-0@box-a", "HUB-0@box-a", "LGC-0@box-a", "BOX-1@box-a"} {
		if IsFlowAgent(key) {
			t.Errorf("IsFlowAgent(%q) = true: an alias is no agent", key)
		}
	}
	for _, key := range []string{"c-002@box-a", "CLE-77952@box-a"} {
		if !IsFlowAgent(key) {
			t.Errorf("IsFlowAgent(%q) = false: an agent id with its box is an agent", key)
		}
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe := s.(FlowEvents)
			ctx := context.Background()
			now := time.Now().UTC()
			tid := newTenant(t, s)
			post := func(to, toBox, kind, body string) {
				t.Helper()
				m := msgFor(tid, uuid4(), toBox, now, now, "env-"+uuid4())
				m.FromID, m.ToID, m.Channel, m.Kind, m.Body = "c-009", to, "lobby", kind, body
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			read := func(member string) FlowPage {
				t.Helper()
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: member, Limit: 50, Now: now.Add(time.Minute)})
				if err != nil {
					t.Fatal(err)
				}
				return p
			}
			post("ALL-0", "box-wui", "note", "to everyone, @ALL-0@box-wui and @CI-0@box-a, and @c-002@box-a")
			for _, alias := range []string{"ALL-0@box-wui", "CI-0@box-a"} {
				if p := read(alias); len(p.Events) != 0 {
					t.Fatalf("%s holds %d flow events (first kind %s): an alias is keyed as an agent flow member", alias, len(p.Events), p.Events[0].Kind)
				}
			}
			if p := read("c-002@box-a"); len(p.Events) != 1 || p.Events[0].Kind != FlowMention {
				t.Fatalf("c-002@box-a flow %+v: the named agent keeps its mention", p.Events)
			}

			// A blocker that names an agent writes ONE event, kind blocked.
			// counts.mention is the badge bucket of mention, poke, blocked and
			// ready (spec 130 section 6, "Badge: unchanged"; FlowCounts.add),
			// so it reads 1, not 2.
			post("ALL-0", "box-wui", "blocker", "stuck, @c-003@box-a")
			p := read("c-003@box-a")
			if len(p.Events) != 1 || p.Events[0].Kind != FlowBlocked {
				t.Fatalf("c-003@box-a flow %+v: a blocker naming an agent is one blocked event", p.Events)
			}
			if p.Counts.Mention != 1 || p.Counts.Total != 1 {
				t.Fatalf("c-003@box-a counts %+v: the blocked line counts once", p.Counts)
			}
		})
	}
}

// rdb 0179 deletes the alias rows already stored (prd t1: 9 'ALL-0@box-wui')
// and keeps every seat and agent row. Postgres only: the rows are written
// raw, as the old hub wrote them, then the file runs again.
func TestFlowAliasRows0179(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	tid := newTenant(t, pg)
	m := msgFor(tid, uuid4(), "box-wui", now, now, "env-"+uuid4())
	m.FromID, m.ToID, m.Channel, m.Body = "c-009", "ALL-0", "lobby", "plain"
	if _, err := pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(sqlDir(t), "0179_flow_alias_rows.sql"))
	if err != nil {
		t.Fatal(err)
	}
	keep := []string{"HUM-1", "c-002@box-a", "CLE-77952@box-a"}
	gone := []string{"ALL-0@box-wui", "CI-0@box-a", "HUB-0@box-a", "LGC-0@box-a", "c-000@box-a"}
	var left []string
	err = pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		for _, member := range append(append([]string{}, keep...), gone...) {
			if _, err := tx.Exec(ctx, `INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at)
				VALUES ($1, $2, $3, $4, 'mention', $5, $6)`, tid, member, m.MsgID, m.TaskID, now, m.ExpiresAt); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, string(body)); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT member_id FROM flow_events WHERE tenant_id = $1 ORDER BY member_id`, tid)
		if err != nil {
			return err
		}
		left, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	want := append([]string{}, keep...)
	sort.Strings(want)
	if strings.Join(left, ",") != strings.Join(want, ",") {
		t.Fatalf("after 0179 flow_events members = %v, want %v", left, want)
	}
}

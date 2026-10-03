package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestLifecycleKeysPinRdbChecks pins rdb 0105's CHECK on every config column
// to LifecycleKeys (spec 063 section 11, the way ArchivePolicy* pins 0093): a
// range changed on one side only turns this red.
func TestLifecycleKeysPinRdbChecks(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0105_agent_lifecycle.sql"))
	if err != nil {
		t.Fatal(err)
	}
	body := string(raw)
	start := strings.Index(body, "CREATE TABLE agent_lifecycle_config")
	end := strings.Index(body, "CREATE TABLE agent_lifecycle_events")
	if start < 0 || end < start {
		t.Fatal("0105 lost its two CREATE TABLEs")
	}
	col := regexp.MustCompile(`(?m)^\s+([a-z_]+)\s+(?:integer|text)\s+NULL CHECK \((.*)\),$`)
	got := map[string]string{}
	for _, m := range col.FindAllStringSubmatch(body[start:end], -1) {
		got[m[1]] = m[2]
	}
	if len(got) != len(LifecycleKeys) {
		t.Fatalf("0105 has %d config columns, LifecycleKeys %d: %v", len(got), len(LifecycleKeys), got)
	}
	for _, k := range LifecycleKeys {
		want := fmt.Sprintf("%s BETWEEN %d AND %d", k.Key, k.Min, k.Max)
		if k.Enum != nil {
			want = fmt.Sprintf("%s IN ('%s')", k.Key, strings.Join(k.Enum, "', '"))
		} else if k.ZeroOff {
			want = fmt.Sprintf("%s = 0 OR %s", k.Key, want)
		}
		if got[k.Key] != want {
			t.Errorf("%s: rdb CHECK (%s), Go table says (%s)", k.Key, got[k.Key], want)
		}
		if !k.Allows(k.Default) {
			t.Errorf("%s: default %d outside its own range %s", k.Key, k.Default, k.Range())
		}
	}
	// CONTROL: the parser does see a mismatch.
	if fmt.Sprintf("%s BETWEEN %d AND %d", "lane_restart_ctx_k", 100, 951) == got["lane_restart_ctx_k"] {
		t.Fatal("the pin compares nothing")
	}
}

func ip(v int) *int { return &v }

// boundaries is what TestAgentLifecycleRdbChecks writes to each key: both
// ends, one past each end, and for an enum every value plus a stranger.
func boundaries(k LifecycleKey) []any {
	if k.Enum != nil {
		out := []any{"nosuch"}
		for _, v := range k.Enum {
			out = append(out, v)
		}
		return out
	}
	return []any{k.Min - 1, k.Max + 1, k.Min, k.Max, 0}
}

func TestAgentLifecycleConfig(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			al, ok := st.(AgentLifecycle)
			if !ok {
				t.Fatal("driver keeps no agent lifecycle")
			}
			tid := newTenant(t, st)
			now := time.Now().UTC().Truncate(time.Second)

			c, err := al.AgentLifecycleConfig(ctx, tid)
			if err != nil || len(c.Stored) != 0 || !c.UpdatedAt.IsZero() {
				t.Fatalf("fresh config %+v: %v", c, err)
			}
			if e := c.Effective(); e["lane_restart_ctx_k"] != 400 || e["lane_checkpoint_min"] != 0 || e["seat_fail_action"] != "compact" || len(e) != 11 {
				t.Fatalf("fresh effective %v", e)
			}

			old, cur, err := al.PatchAgentLifecycleConfig(ctx, tid, LifecyclePatch{"lane_restart_ctx_k": 500, "lane_checkpoint_min": 30, "seat_fail_action": "respawn"}, "HUM-1", now)
			if err != nil {
				t.Fatal(err)
			}
			if len(old.Stored) != 0 || cur.Stored["lane_restart_ctx_k"] != 500 || cur.UpdatedBy != "HUM-1" || !cur.UpdatedAt.Equal(now) {
				t.Fatalf("patch old %+v cur %+v", old, cur)
			}
			// A reset (nil) is NULL = the default again; an unnamed key stays.
			_, cur, err = al.PatchAgentLifecycleConfig(ctx, tid, LifecyclePatch{"lane_restart_ctx_k": nil}, "HUM-2", now.Add(time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			if _, set := cur.Stored["lane_restart_ctx_k"]; set || cur.Effective()["lane_restart_ctx_k"] != 400 || cur.Stored["lane_checkpoint_min"] != 30 || cur.Stored["seat_fail_action"] != "respawn" {
				t.Fatalf("after reset %+v", cur)
			}
			if c, _ := al.AgentLifecycleConfig(ctx, tid); c.Stored["lane_checkpoint_min"] != 30 || c.Stored["seat_fail_action"] != "respawn" || c.UpdatedBy != "HUM-2" {
				t.Fatalf("read back %+v", c)
			}

			// CONTROL: out of range and unknown keys are refused, nothing written.
			for _, bad := range []LifecyclePatch{{"lane_restart_ctx_k": 99}, {"lane_restart_ctx_k": 951},
				{"lane_checkpoint_min": 5}, {"seat_compact_after_fails": -1}, {"seat_fail_action": "reboot"}, {"seat_fail_action": 1}, {"lane_restart_ctx_k": "400"}, {"nosuch": 1}} {
				if _, _, err := al.PatchAgentLifecycleConfig(ctx, tid, bad, "HUM-1", now); !errors.Is(err, ErrBadLifecycleKey) {
					t.Errorf("patch %v: %v", bad, err)
				}
			}

			// Each patch wrote one config_change with old and new.
			evs, err := al.ListLifecycleEvents(ctx, tid, now.Add(-time.Hour), 10)
			if err != nil || len(evs) != 2 {
				t.Fatalf("events %d: %v", len(evs), err)
			}
			e := evs[0] // newest: the reset
			if e.Event != "config_change" || e.AgentID != "HUM-2" || e.WriterBox != "hub" || e.Detail != "lane_restart_ctx_k" {
				t.Fatalf("config_change %+v", e)
			}
			var cc map[string]map[string]int
			if err := json.Unmarshal(e.Config, &cc); err != nil || cc["old"]["lane_restart_ctx_k"] != 500 || cc["new"]["lane_restart_ctx_k"] != 400 || len(cc["new"]) != 1 {
				t.Fatalf("config_change config %s: %v", e.Config, err)
			}
		})
	}
}

func TestAgentLifecycleEvents(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			al := st.(AgentLifecycle)
			tid, other := newTenant(t, st), newTenant(t, st)
			base := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)
			put := func(tenant string, e LifecycleEvent) {
				t.Helper()
				if why := CheckLifecycleEvent(e); why != "" {
					t.Fatalf("check %+v: %s", e, why)
				}
				if err := al.AppendLifecycleEvent(ctx, tenant, e); err != nil {
					t.Fatal(err)
				}
			}
			// orch rotate: before 300, 400, 500, 600 (median 450, p90 570);
			// one with no measurement; one fail; refetch sums 1, 3, 0 (mean 4/3).
			for i, b := range []int{300, 400, 500, 600} {
				e := LifecycleEvent{At: base.Add(time.Duration(i) * time.Minute), Fleet: "main", AgentID: "c-001",
					AgentBox: "sat", WriterBox: "sat", Role: "orch", Event: "rotate", Reason: "size", CtxBeforeK: ip(b),
					CtxAfterK: ip(b / 10), Outcome: "ok"}
				switch i {
				case 0:
					e.Refetch = map[string]int{"lane_map": 1}
				case 1:
					e.Refetch = map[string]int{"lane_map": 1, "old_transcript": 2}
				case 2:
					e.Refetch = map[string]int{}
				}
				put(tid, e)
			}
			put(tid, LifecycleEvent{At: base.Add(5 * time.Minute), WriterBox: "sat", Role: "orch", Event: "rotate", Outcome: "fail", Detail: "step3"})
			put(tid, LifecycleEvent{At: base.Add(6 * time.Minute), WriterBox: "sat", Role: "lane", Event: "restart", CtxBeforeK: ip(410)})
			put(tid, LifecycleEvent{At: base.Add(-91 * 24 * time.Hour), WriterBox: "sat", Role: "lane", Event: "restart"}) // past retention
			put(other, LifecycleEvent{At: base, WriterBox: "box-x", Role: "orch", Event: "rotate", CtxBeforeK: ip(9000)})

			evs, err := al.ListLifecycleEvents(ctx, tid, base.Add(-time.Minute), 0)
			if err != nil || len(evs) != 6 || evs[0].Event != "restart" || evs[5].CtxBeforeK == nil || *evs[5].CtxBeforeK != 300 {
				t.Fatalf("list %d %+v: %v", len(evs), evs, err)
			}
			if evs[4].Refetch == nil || evs[4].Refetch["old_transcript"] != 2 || evs[3].Refetch == nil || len(evs[3].Refetch) != 0 || evs[2].Refetch != nil {
				t.Fatalf("refetch round trip %v %v %v", evs[2].Refetch, evs[3].Refetch, evs[4].Refetch)
			}
			if lim, _ := al.ListLifecycleEvents(ctx, tid, base.Add(-time.Minute), 2); len(lim) != 2 {
				t.Fatalf("limit 2 gave %d", len(lim))
			}

			ag, err := al.LifecycleAggregates(ctx, tid, base.Add(-time.Minute))
			if err != nil || len(ag) != 2 {
				t.Fatalf("aggregates %+v: %v", ag, err)
			}
			l, o := ag[0], ag[1]
			if l.Role != "lane" || l.Count != 1 || *l.CtxBeforeMedian != 410 || l.CtxAfterMedian != nil || l.RefetchMean != nil {
				t.Fatalf("lane aggregate %+v", l)
			}
			if o.Role != "orch" || o.Event != "rotate" || o.Count != 5 || o.Failed != 1 ||
				*o.CtxBeforeMedian != 450 || *o.CtxBeforeP90 != 570 || *o.CtxAfterMedian != 45 ||
				o.RefetchMean == nil || fmt.Sprintf("%.4f", *o.RefetchMean) != "1.3333" {
				t.Fatalf("orch aggregate %+v", o)
			}

			n, err := al.PruneLifecycleEvents(ctx, time.Now().Add(-LifecycleRetention))
			if err != nil || n < 1 {
				t.Fatalf("prune %d: %v", n, err)
			}
			if all, _ := al.ListLifecycleEvents(ctx, tid, time.Time{}, 200); len(all) != 6 {
				t.Fatalf("after prune %d rows", len(all))
			}
			if oth, _ := al.ListLifecycleEvents(ctx, other, time.Time{}, 200); len(oth) != 1 {
				t.Fatalf("other tenant %d rows", len(oth))
			}
		})
	}
}

// The 0105 CHECKs refuse what the Go checks refuse, on the raw table.
func TestAgentLifecycleRdbChecks(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("needs $SPOOL_TEST_PG_DSN")
	}
	ctx := context.Background()
	tid := newTenant(t, pg)
	for _, k := range LifecycleKeys {
		for _, v := range boundaries(k) {
			err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO agent_lifecycle_config (tenant_id, `+k.Key+`) VALUES ($1, $2)
					ON CONFLICT (tenant_id) DO UPDATE SET `+k.Key+` = EXCLUDED.`+k.Key, tid, v)
				return err
			})
			if (err == nil) != k.Allows(v) {
				t.Errorf("%s=%d: rdb err %v, Go allows %v", k.Key, v, err, k.Allows(v))
			}
		}
	}
	for _, bad := range []string{`role = 'boss'`, `event = 'nap'`, `reason = 'whim'`, `outcome = 'meh'`, `detail = repeat('x', 201)`} {
		err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO agent_lifecycle_events (tenant_id, at, writer_box, event)
				VALUES ($1, now(), 'b', 'rotate')`, tid)
			if err != nil {
				return err
			}
			_, err = tx.Exec(ctx, `UPDATE agent_lifecycle_events SET `+bad+` WHERE tenant_id = $1`, tid)
			return err
		})
		if err == nil {
			t.Errorf("rdb took %s", bad)
		}
	}
}

func TestCheckLifecycleEvent(t *testing.T) {
	good := LifecycleEvent{Fleet: "main", AgentID: "c-001", AgentBox: "sat", Role: "lane", Event: "restart", Reason: "size", Outcome: "ok"}
	if why := CheckLifecycleEvent(good); why != "" {
		t.Fatal(why)
	}
	for name, mut := range map[string]func(*LifecycleEvent){
		"role":    func(e *LifecycleEvent) { e.Role = "boss" },
		"event":   func(e *LifecycleEvent) { e.Event = "" },
		"reason":  func(e *LifecycleEvent) { e.Reason = "whim" },
		"outcome": func(e *LifecycleEvent) { e.Outcome = "meh" },
		"detail":  func(e *LifecycleEvent) { e.Detail = strings.Repeat("x", 201) },
		"newline": func(e *LifecycleEvent) { e.Detail = "a\nb" },
		"fleet":   func(e *LifecycleEvent) { e.Fleet = "Main" },
		"count":   func(e *LifecycleEvent) { e.Turns = ip(-1) },
		"refetch": func(e *LifecycleEvent) { e.Refetch = map[string]int{"x": -1} },
		"config":  func(e *LifecycleEvent) { e.Config = json.RawMessage(`[1]`) },
	} {
		e := good
		mut(&e)
		if CheckLifecycleEvent(e) == "" {
			t.Errorf("%s: accepted %+v", name, e)
		}
	}
}

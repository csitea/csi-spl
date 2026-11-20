package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Spec 183 row P1, the store half: TopicExportRows is a topic's live rows,
// oldest first by (ts, msg_id), with the door fields; BoxOperatorHumans is
// a box's bound members, sorted. Memory and Postgres answer alike.
func TestTopicExportReads(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			ex := s.(TopicExports)
			task, other := uuid4(), uuid4()
			put := func(task, channel, to string, ts time.Time, expires time.Time) string {
				t.Helper()
				m := msgFor(tid, task, "box-b", ts, now, `{"x":1}`)
				m.Channel, m.ToID, m.ExpiresAt = channel, to, expires
				if channel == "" {
					m.TypedBy = "HUM-3" // the DM was typed at the agent's terminal
				}
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m.MsgID
			}
			live := now.Add(time.Hour)
			second := put(task, "devel", "ALL-0", now.Add(time.Second), live)
			dm := put(task, "", "HUM-7", now.Add(2*time.Second), live)
			put(task, "devel", "ALL-0", now.Add(3*time.Second), now.Add(-time.Second)) // expired
			put(other, "devel", "ALL-0", now, live)                                    // another topic
			first := put(task, "devel", "ALL-0", now, live)
			rows, err := ex.TopicExportRows(ctx, tid, task, now)
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, r := range rows {
				got = append(got, r.MsgID)
			}
			if want := []string{first, second, dm}; strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("rows %v, want %v", got, want)
			}
			if r := rows[2]; r.Channel != "" || r.FromID != "GRK-03" || r.ToID != "HUM-7" || string(r.Env) != `{"x":1}` ||
				r.TaskID != task || r.Body != "hi" || r.Kind != "task" || r.FromBox != "box-a" || r.TypedBy != "HUM-3" || !r.TS.Equal(now.Add(2*time.Second)) {
				t.Fatalf("dm row %+v", r)
			}
			if r := rows[0]; r.Channel != "devel" || r.ToID != "ALL-0" || r.TypedBy != "" {
				t.Fatalf("channel row %+v", r)
			}
			if rows, err := ex.TopicExportRows(ctx, tid, "not-a-uuid", now); err != nil || len(rows) != 0 {
				t.Fatalf("a non-uuid task read %v %v", rows, err)
			}

			h, ops := s.(Humans), s.(BoxOperators)
			admit := func(sub string) string {
				t.Helper()
				mail := sub + tid + "@example.com"
				if err := h.PutInvite(ctx, Invite{TenantID: tid, Email: mail, Role: "developer", InvitedBy: "operator",
					ExpiresAt: now.Add(time.Hour)}, now); err != nil {
					t.Fatal(err)
				}
				id, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid(sub), Email: mail}, tid, AdmitPolicy{BootstrapOwner: true}, now)
				if err != nil {
					t.Fatal(err)
				}
				return id
			}
			a, b := admit("op-a-"), admit("op-b-")
			for _, bind := range [][2]string{{"box-b", b}, {"box-b", a}, {"box-c", a}} {
				if err := ops.GrantBoxOperator(ctx, tid, bind[0], bind[1], "operator", now); err != nil {
					t.Fatal(err)
				}
			}
			want := []string{a, b}
			if a > b {
				want = []string{b, a}
			}
			if got, err := ex.BoxOperatorHumans(ctx, tid, "box-b"); err != nil || strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("box-b operators %v %v, want %v", got, err, want)
			}
			if got, err := ex.BoxOperatorHumans(ctx, tid, "box-x"); err != nil || len(got) != 0 {
				t.Fatalf("box-x operators %v %v, want none", got, err)
			}
		})
	}
}

package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// t1 bc1a43e1 (fix B): c-001@<box> stayed in its box's roster ~26 h after its
// last session ended, so the WUI kept offering it. The real box client
// leaves out of its announce an agent its run report has said does not run
// for longer than DropAfter, and puts it back once it runs again. Counting:
// exactly one of three agents leaves, and only after the threshold.
// CONTROL: DropAfter 0 (the pre-fix client) keeps all three for ever.
func TestHubclientDropsDeadAgent(t *testing.T) {
	for _, tc := range []struct {
		name  string
		after time.Duration
		late  map[string]string // the roster past the threshold
	}{
		{"drop after 1h", time.Hour, map[string]string{"c-044": "online", "c-046": "online"}},
		{"CONTROL off", 0, map[string]string{"c-044": "online", "c-045": "not_running", "c-046": "online"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
			tid, _ := e.tenant()
			ctx := context.Background()
			a := e.box(tid, "box-a", "c-044", "c-045", "c-046")
			e.pin(tid, a)
			now := time.Now()
			a.c.Now = func() time.Time { return now }
			a.c.DropAfter = tc.after
			running := map[string]bool{"c-044": true, "c-045": false, "c-046": true}
			a.c.AgentRun = func(agents []string) map[string]bool {
				out := map[string]bool{}
				for _, id := range agents {
					out[id] = running[id]
				}
				return out
			}
			sess, err := a.c.Dial(ctx, wire.RoleBox)
			if err != nil {
				t.Fatal(err)
			}
			defer closeWait(sess)
			all := map[string]string{"c-044": "online", "c-045": "not_running", "c-046": "online"}
			waitStates(t, e, tid, "hello", all)

			now = now.Add(time.Hour) // at the threshold: kept
			if err := sess.Announce(ctx); err != nil {
				t.Fatal(err)
			}
			waitStates(t, e, tid, "at 1h", all)

			now = now.Add(time.Minute) // past it
			if err := sess.Announce(ctx); err != nil {
				t.Fatal(err)
			}
			waitStates(t, e, tid, "past 1h", tc.late)

			running["c-045"] = true // it runs again: back
			if err := sess.Announce(ctx); err != nil {
				t.Fatal(err)
			}
			waitStates(t, e, tid, "runs again", map[string]string{"c-044": "online", "c-045": "online", "c-046": "online"})
		})
	}
}

package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// b24-01 (SPL-4895 N1): the reader's OWN Flow is cut by the box owner lock
// (spec 130 section 3.1). A line of a box locked to someone else is left out
// of the events, the folded lines, counts, unread and keys of the unfolded,
// counts_only and fold=day reads, and of the pushed `flow` frames (the
// fan-out's and pushFlowCounts'). Red before the store cut: 10 lines, keys
// name the locked box's topic and counts / unread total 2 on each read.

// flowLockSay posts word in #ops from agent of b, mentioning who; its task id.
func flowLockSay(t *testing.T, b *box, agent, word, who string) string {
	t.Helper()
	ctx := context.Background()
	cli, err := b.c.Dial(ctx, "cli")
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(cli)
	m := chanMsg(uuidV4(), "ALL-0", "note", word+" ping @"+who+" look")
	m.From = agent
	if _, err := cli.Send(ctx, signedIn(t, b, hub.WUIBox, "ops", "", m)); err != nil {
		t.Fatalf("%s post: %v", agent, err)
	}
	return m.TaskID
}

// flowLockKeysClean fails for every key that names one of tasks.
func flowLockKeysClean(t *testing.T, where string, keys map[string]any, tasks ...string) {
	t.Helper()
	for k := range keys {
		for _, task := range tasks {
			if strings.Contains(k, task) {
				t.Errorf("%s: keys name the locked box's topic %s", where, k)
			}
		}
	}
}

func TestFlowOwnReadCutByLock(t *testing.T) {
	r := newViewRig(t)
	lockedTask := flowLockSay(t, r.own, "CLE-01", "wombat", r.admin) // box-own is locked to r.owner
	openTask := flowLockSay(t, r.sh, "CLE-02", "quokka", r.admin)    // control: box-sh is not locked
	for _, q := range []string{"", "?counts_only=true", "?fold=day"} {
		code, out, n := flowOf(t, r.e, r.tid, "/v1/view/flow"+q, r.admin)
		if code != http.StatusOK {
			t.Fatalf("admin own flow%s: %d %v", q, code, out)
		}
		keys, _ := out["keys"].(map[string]any)
		if lines, _ := out["lines"].([]any); q == "?fold=day" {
			n = 0
			for _, l := range lines {
				if l.(map[string]any)["task_id"] == lockedTask {
					t.Errorf("admin own flow%s: a line opens the locked box's topic: %v", q, l)
				} else {
					n++
				}
			}
		}
		if q != "?counts_only=true" && n != 1 {
			t.Errorf("CONTROL admin own flow: %d events, want 1 (the open box's): %v", n, out)
		}
		if _, ok := keys["t:"+openTask]; !ok {
			t.Errorf("CONTROL admin own flow%s: no key for the open box's topic: %v", q, keys)
		}
		flowLockKeysClean(t, "admin own flow"+q, keys, lockedTask, r.ownTask, r.xTask)
		if c := countOf(out, "counts", "total"); c != 1 {
			t.Errorf("admin own flow%s: counts.total %v, want 1 (the locked line counted)", q, c)
		}
		if u := countOf(out, "unread", "total"); u != 1 {
			t.Errorf("admin own flow%s: unread.total %v, want 1 (the locked line counted)", q, u)
		}
	}
	// CONTROL: the lock's owner, hiding nothing, reads the locked box's line.
	ownerTask := flowLockSay(t, r.own, "CLE-01", "numbat", r.owner)
	_, out, _ := flowOf(t, r.e, r.tid, "/v1/view/flow?counts_only=true", r.owner)
	if keys, _ := out["keys"].(map[string]any); keys["t:"+ownerTask] == nil {
		t.Errorf("CONTROL the lock owner's own flow: no key for its box's topic: %v", keys)
	}
}

// The pushed frames: the fan-out of an open box's line and the counts-only
// frame of a mark write carry the counts cut by the lock, as the read does.
func TestFlowOwnFramesCutByLock(t *testing.T) {
	r := newViewRig(t)
	c := dialFlowMember(t, r.e, r.tid, r.admin)
	lockedTask := flowLockSay(t, r.own, "CLE-01", "wombat", r.admin)
	flowLockSay(t, r.sh, "CLE-02", "quokka", r.admin)
	f := readFrame(t, c, "flow") // the locked line gives the admin no frame: this is the open one's
	if ev, _ := f["event"].(map[string]any); ev["task_id"] == lockedTask {
		t.Fatalf("the fan-out pushed the locked box's line: %v", ev)
	}
	keys, _ := f["keys"].(map[string]any)
	flowLockKeysClean(t, "fan-out frame", keys, lockedTask, r.ownTask, r.xTask)
	if n := countOf(f, "counts", "total"); n != 1 {
		t.Errorf("fan-out frame: counts.total %v, want 1 (the locked line counted)", n)
	}
	if n := countOf(f, "unread", "total"); n != 1 {
		t.Errorf("fan-out frame: unread.total %v, want 1 (the locked line counted)", n)
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if code, out := call(t, r.e, r.tid, http.MethodPut, "/v1/me/reads", r.admin, map[string]any{"marks": map[string]any{"f:seen": map[string]any{"ts": now}}}); code != http.StatusOK {
		t.Fatalf("PUT f:seen: %d %v", code, out)
	}
	f = readFrame(t, c, "flow")
	keys, _ = f["keys"].(map[string]any)
	flowLockKeysClean(t, "counts frame", keys, lockedTask, r.ownTask, r.xTask)
	if n := countOf(f, "unread", "total"); n != 1 {
		t.Errorf("counts frame: unread.total %v, want 1 (the locked line counted)", n)
	}
}

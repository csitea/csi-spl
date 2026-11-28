package hub_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 182 v0.12 (SPL-6744; owner HUM-10, t1 0cf1d4cf msg 122b69a5): the
// loop routes take and answer the work window of the every_* triggers, on
// row L1's store (Memory, and Postgres under SPOOL_TEST_PG_DSN). The due
// walk itself is the store's (store/topic_loop_window_test.go).

// TestTopicLoopWindowRoutes: an add with a window answers it with its zone,
// an edit clears it, and a bad window is 400 bad_loop with the reason.
func TestTopicLoopWindowRoutes(t *testing.T) {
	r := newRealLoopRig(t)
	path := "/v1/topics/" + r.task + "/loops"
	body := loopBody(store.LoopEveryHour)
	body["window_from"], body["window_to"], body["workdays_only"], body["daily_tz"] = "08:00", "17:00", true, "Europe/Helsinki"
	code, out := call(t, r.e, r.tid, http.MethodPost, path, "HUM-1", body)
	if code != http.StatusCreated || out["window_from"] != "08:00" || out["window_to"] != "17:00" ||
		out["workdays_only"] != true || out["daily_tz"] != "Europe/Helsinki" || out["next_due_at"] == nil {
		t.Fatalf("add with a window: %d %v", code, out)
	}
	id := out["loop_id"].(string)
	// R7 N2: one bound against the stored other gets the over-midnight text.
	code, out = call(t, r.e, r.tid, http.MethodPut, path+"/"+id, "HUM-1", map[string]any{"window_to": "07:00"})
	if msg, _ := out["detail"].(string); code != http.StatusBadRequest || out["error"] != "bad_loop" || !strings.Contains(msg, "over midnight") {
		t.Fatalf("edit window_to before the stored window_from: %d %v, want 400 naming over midnight", code, out)
	}
	if code, out = call(t, r.e, r.tid, http.MethodPut, path+"/"+id, "HUM-1", map[string]any{"window_to": "16:00"}); code != http.StatusOK || out["window_to"] != "16:00" {
		t.Fatalf("edit window_to inside: %d %v", code, out)
	}
	code, out = call(t, r.e, r.tid, http.MethodPut, path+"/"+id, "HUM-1",
		map[string]any{"window_from": "", "window_to": "", "workdays_only": false})
	if _, has := out["window_from"]; code != http.StatusOK || has || out["workdays_only"] != nil {
		t.Fatalf("clear the window: %d %v", code, out)
	}
	plain := loopBody(store.LoopEveryHour)
	if code, out = call(t, r.e, r.tid, http.MethodPost, path, "HUM-1", plain); code != http.StatusCreated {
		t.Fatalf("add with no window: %d %v", code, out)
	}
	if _, has := out["window_from"]; has || out["workdays_only"] != nil || out["daily_tz"] != nil {
		t.Fatalf("no window answers no window fields: %v", out)
	}
	for why, c := range map[string]struct {
		body map[string]any
		want string
	}{
		"overnight":     {map[string]any{"window_from": "22:00", "window_to": "06:00"}, "over midnight"},
		"same minute":   {map[string]any{"window_from": "08:00", "window_to": "08:00"}, "over midnight"},
		"not 24-hour":   {map[string]any{"window_from": "8am", "window_to": "17:00"}, "hh:mm"},
		"only a start":  {map[string]any{"window_from": "08:00"}, "work window"},
		"not a timer":   {map[string]any{"workdays_only": true, "triggers": []string{store.LoopAfterHumanReply}}, "work window"},
		"workdays type": {map[string]any{"workdays_only": "yes"}, "body must be"},
	} {
		b := loopBody(store.LoopEveryHour)
		for k, v := range c.body {
			b[k] = v
		}
		code, out := call(t, r.e, r.tid, http.MethodPost, path, "HUM-1", b)
		if msg, _ := out["detail"].(string); code != http.StatusBadRequest || out["error"] != "bad_loop" || !strings.Contains(msg, c.want) {
			t.Errorf("%s: %d %v, want 400 naming %q", why, code, out, c.want)
		}
	}
}

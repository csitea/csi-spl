package hub_test

import (
	"context"
	"strings"
	"testing"

	"github.com/coder/websocket/wsjson"
)

// Pins of browser-send refusals no other test drove, taken before wuiSend
// was split into named steps (SPL-1029 round 2): a message that fails the
// v:1 checks answers bad_json 400 under the browser's msg_id and stores
// nothing.
func TestWUISendInvalidMessage(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	c := dialMember(t, e, tid, "Tess", "HUM-1")
	files := []map[string]any{}
	for i := 0; i < 17; i++ {
		files = append(files, map[string]any{"file_id": strings.Repeat("ab", 32), "name": "f.txt", "bytes": 1})
	}
	for _, tc := range []struct {
		name  string
		frame map[string]any
	}{
		{"body over the v:1 cap", map[string]any{"type": "send", "task_id": lobby, "msg_id": uuidV4(), "body": strings.Repeat("a", 70000)}},
		{"17 attachments", map[string]any{"type": "send", "task_id": lobby, "msg_id": uuidV4(), "body": "x", "files": files}},
	} {
		wsjson.Write(context.Background(), c, tc.frame) //nolint:errcheck
		f := readType(t, c, "error")
		if f["error"] != "bad_json" || f["status"] != float64(400) || f["msg_id"] != tc.frame["msg_id"] {
			t.Errorf("%s: %v", tc.name, f)
		}
		if has(t, e, tid, tc.frame["msg_id"].(string)) {
			t.Errorf("%s: a refused send was stored", tc.name)
		}
	}
}

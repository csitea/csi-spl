package hub

import (
	"bytes"
	"compress/flate"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"
)

// untrimWUIEnv is the WUI's messageFromFrame rebuild (utils/live-ws.mjs,
// R2-3) of an env trimmed by trimWUIEnv: box-wui ends, sig "", the frame's
// channel and task_id, files [].
func untrimWUIEnv(t *testing.T, env []byte, taskID, channel string) map[string]any {
	t.Helper()
	var e map[string]any
	if err := json.Unmarshal(env, &e); err != nil {
		t.Fatalf("trimmed env: %v", err)
	}
	m, _ := e["msg"].(map[string]any)
	for _, k := range []string{"from_box", "to_box"} {
		if _, ok := e[k]; !ok {
			e[k] = WUIBox
		}
	}
	if _, ok := e["sig"]; !ok {
		e["sig"] = ""
	}
	if _, ok := e["channel"]; !ok && channel != "" {
		e["channel"] = channel
	}
	if _, ok := m["task_id"]; !ok {
		m["task_id"] = taskID
	}
	if _, ok := m["files"]; !ok {
		m["files"] = []any{}
	}
	return e
}

func asObject(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatalf("env: %v", err)
	}
	return v
}

// TestTrimWUIEnvRoundTrip: what the trimmed `message` frame drops, the WUI
// rebuilds to the same object; what is not redundant is kept.
func TestTrimWUIEnvRoundTrip(t *testing.T) {
	const task, ch = "5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a", "general"
	cases := []struct {
		name, env string
		keep      []string // top-level / msg keys that must survive
	}{
		{"browser post", `{"from_box":"box-wui","to_box":"box-wui","channel":"general","msg":{"v":1,"msg_id":"m1","task_id":"` + task + `","from":"HUM-1","to":"ALL-0","kind":"note","body":"hi <b>","ts":"2026-10-02T19:18:07Z","files":[]},"sig":""}`, nil},
		{"signed agent post", `{"from_box":"box-desk","to_box":"box-wui","channel":"general","msg":{"v":1,"msg_id":"m2","task_id":"` + task + `","files":[{"file_id":"f","name":"a"}]},"sig":"c2ln"}`, []string{"from_box", "sig", "files"}},
		{"moved row", `{"from_box":"box-wui","to_box":"box-a","channel":"other","parent_task_id":"P","msg":{"v":1,"msg_id":"m3","task_id":"old-task","files":[]},"sig":""}`, []string{"to_box", "channel", "task_id", "parent_task_id"}},
	}
	for _, c := range cases {
		got := trimWUIEnv([]byte(c.env), task, ch)
		obj := asObject(t, got)
		msg, _ := obj["msg"].(map[string]any)
		for _, k := range c.keep {
			_, top := obj[k]
			_, in := msg[k]
			if !top && !in {
				t.Errorf("%s: %q dropped but not redundant: %s", c.name, k, got)
			}
		}
		if want := asObject(t, []byte(c.env)); !reflect.DeepEqual(untrimWUIEnv(t, got, task, ch), want) {
			t.Errorf("%s: round trip\n got %s\nwant %s", c.name, got, c.env)
		}
		if len(got) > len(c.env) {
			t.Errorf("%s: trimmed %d B > raw %d B", c.name, len(got), len(c.env))
		}
	}
	if raw := []byte(`not json`); string(trimWUIEnv(raw, task, ch)) != "not json" {
		t.Error("unparsable env must pass unchanged")
	}
}

// flateWire is a message's payload bytes on a no-context-takeover socket:
// plain below threshold, else one BestSpeed deflate block with its 4 B sync
// tail stripped (RFC 7692 §7.2.1), as coder/websocket writes it.
func flateWire(t *testing.T, p []byte, threshold int) int {
	t.Helper()
	if len(p) < threshold {
		return len(p)
	}
	var b bytes.Buffer
	w, _ := flate.NewWriter(&b, flate.BestSpeed)
	w.Write(p) //nolint:errcheck
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	return b.Len() - 4
}

// TestWUIMessageFrameBytes: a browser post's `message` frame, full (old,
// 512 B threshold) vs trimmed (R2-3, wuiFlateThreshold), raw and on the wire.
// Without the lower threshold the trimmed frame went out plain and larger.
func TestWUIMessageFrameBytes(t *testing.T) {
	const task, ch, id = "5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a", "general", "457221b3-c833-4912-9527-03e6f874c40a"
	at := time.Date(2026, 10, 2, 19, 18, 7, 165146000, time.UTC)
	for _, body := range []string{"ok", "the deploy finished, dev and prd both report v3.1.4 now", strings.Repeat("a longer line of text ", 20)} {
		msgJSON, _ := json.Marshal(map[string]any{"v": 1, "msg_id": id, "task_id": task, "from": "HUM-1", "to": "ALL-0",
			"kind": "note", "body": body, "ts": "2026-10-02T19:18:07Z", "files": []any{}})
		env, _ := json.Marshal(map[string]any{"from_box": WUIBox, "to_box": WUIBox, "channel": ch, "msg": json.RawMessage(msgJSON), "sig": ""})
		full, _ := json.Marshal(map[string]any{"type": "message", "task_id": task, "cursor": encCursor(at, id),
			"received_at": rfc(at), "env": json.RawMessage(env), "is_parent": 1, "channel": ch})
		trim, _ := json.Marshal(map[string]any{"type": "message", "task_id": task,
			"received_at": rfc(at), "env": trimWUIEnv(env, task, ch), "is_parent": 1, "channel": ch})
		before, after := flateWire(t, full, 512), flateWire(t, trim, wuiFlateThreshold)
		t.Logf("body %3d B: raw %d -> %d B, wire %d -> %d B", len(body), len(full), len(trim), before, after)
		if len(trim) >= len(full) || after >= before {
			t.Errorf("body %d B: trimmed frame not smaller: raw %d -> %d, wire %d -> %d", len(body), len(full), len(trim), before, after)
		}
	}
}

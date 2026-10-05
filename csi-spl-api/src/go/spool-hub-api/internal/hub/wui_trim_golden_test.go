package hub

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// trimWUIEnvRef is trimWUIEnv as it was before perf edition 20261004 E13:
// env and msg decoded into maps, trimmed, encoded twice. The one-pass
// trimWUIEnv must match it byte for byte, so the WUI's messageFromFrame
// (utils/live-ws.mjs) rebuilds the same message.
func trimWUIEnvRef(env []byte, taskID, channel string) json.RawMessage {
	var e map[string]json.RawMessage
	if json.Unmarshal(env, &e) != nil {
		return env
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(e["msg"], &m) != nil || m == nil {
		return env
	}
	dropIf := func(o map[string]json.RawMessage, k, v string) {
		var got string
		if raw, ok := o[k]; ok && json.Unmarshal(raw, &got) == nil && got == v {
			delete(o, k)
		}
	}
	dropIf(e, "sig", "")
	dropIf(e, "from_box", WUIBox)
	dropIf(e, "to_box", WUIBox)
	if channel != "" {
		dropIf(e, "channel", channel)
	}
	dropIf(m, "task_id", taskID)
	if f, ok := m["files"]; ok && strings.TrimSpace(string(f)) == "[]" {
		delete(m, "files")
	}
	mb, err := json.Marshal(m)
	if err != nil {
		return env
	}
	e["msg"] = mb
	out, err := json.Marshal(e)
	if err != nil {
		return env
	}
	return out
}

func sameWUITrim(t *testing.T, env, taskID, channel string) {
	t.Helper()
	want := trimWUIEnvRef([]byte(env), taskID, channel)
	if got := trimWUIEnv([]byte(env), taskID, channel); !bytes.Equal(got, want) {
		t.Errorf("trimWUIEnv(%q, %q, %q):\n got  %q\n want %q", env, taskID, channel, got, want)
	}
}

// wuiStoredEnv is a browser post as the hub stores it (wire.Canonical:
// sorted, no HTML escaping): box-wui both ends, unsigned, in #ops.
func wuiStoredEnv(body string) string {
	b, _ := json.Marshal(body)
	return `{"channel":"ops","from_box":"box-wui","msg":{"body":` + strings.NewReplacer(`<`, "<", `>`, ">", `&`, "&").Replace(string(b)) +
		`,"files":[],"from":"HUM-1","kind":"note","msg_id":"m1","task_id":"` + goldenTopic +
		`","to":"ALL-0","ts":"2026-10-04T00:00:00Z","v":1},"sig":"","to_box":"box-wui"}`
}

func TestTrimWUIEnvGolden(t *testing.T) {
	x := wuiStoredEnv("x")
	envs := []string{
		wuiStoredEnv("a <b> & c"), wuiStoredEnv("line sep     é 😀"), wuiStoredEnv("tab\tnl\n\"q\" \\ /"), wuiStoredEnv(""),
		strings.Replace(x, `"files":[]`, `"files":[{"file_id":"f","name":"a&b"}]`, 1),
		strings.Replace(x, `"files":[]`, `"files":[ ]`, 1),
		strings.Replace(x, `"task_id":"`+goldenTopic+`"`, `"task_id":"1`+goldenTopic[1:]+`"`, 1),
		strings.Replace(x, `"task_id":"`+goldenTopic+`"`, `"task_id":7`, 1),
		strings.Replace(x, `"task_id":"`+goldenTopic+`"`, `"task_id":null`, 1),
		strings.Replace(x, `"task_id":"`+goldenTopic+`"`, `"task_id":"1`+goldenTopic[1:]+`"`, 1),
		strings.Replace(x, `"to":"ALL-0"`, `"to":"ALL-0","to":"@dup"`, 1),
		strings.Replace(x, `"to":"ALL-0"`, `"a<b":1,"é":2,"to":3`, 1),
		strings.Replace(x, `"sig":""`, `"sig":1,"sig":""`, 1),
		strings.Replace(x, `"sig":""`, `"sig":null`, 1),
		strings.Replace(x, `"sig":""`, `"sig":"c2ln"`, 1),
		strings.Replace(x, `"sig":""`, `"sig":0`, 1),
		strings.Replace(x, `"from_box":"box-wui"`, `"from_box":"box-a"`, 1),
		strings.Replace(x, `"from_box":"box-wui"`, `"from_box":null`, 1),
		strings.Replace(x, `"from_box":"box-wui"`, `"from_box":"box-wui"`, 1),
		strings.Replace(x, `"to_box":"box-wui"`, `"to_box":"box-b"`, 1),
		strings.Replace(x, `"channel":"ops"`, `"channel":null`, 1),
		strings.Replace(x, `"channel":"ops"`, `"channel":"dev"`, 1),
		strings.Replace(x, `"channel":"ops"`, `"channel":"ops","parent_task_id":"`+goldenTopic+`"`, 1),
		strings.Replace(x, `"channel":"ops",`, ``, 1),
		`{"to_box":"b","from_box":"a","msg":null,"sig":"s"}`, `{"msg":"str","sig":""}`, `{"msg":[1,{"b":2,"a":1}]}`,
		`{"msg":{}}`, `{"msg":{},"sig":""}`, `{}`, `{"from_box":"box-wui"}`, `{"sig":"","msg":{"a":1},"msg":{"b":2}}`,
		" \n{ \"z\" : 1 ,\"sig\" : \"\" ,\n \"msg\" : { \"files\" : [] , \"b\" : \"<\\u0041>\" } }\t",
		`{"msg":{"files":[],"task_id":"` + goldenTopic + `"}}`, `{"msg":{"task_id":""}}`, `{"msg":{"task_id":null}}`,
		"{\"msg\":{\"body\":\"raw\xe2\x80\xa8\xff\"},\"sig\":\"\xff\"}", "{\"from_box\":\"box-wui\xff\",\"msg\":{}}",
		`null`, `[]`, `"x"`, `1`, `x`, `{"a":}`, ``, `{"a":1}{"b":2}`,
	}
	for _, env := range envs {
		for _, task := range []string{goldenTopic, "", "other"} {
			for _, ch := range []string{"ops", "", "dev"} {
				sameWUITrim(t, env, task, ch)
			}
		}
	}
}

// TestTrimWUIEnvRandom compares the two on n=3000 random envelopes (fixed
// seed): pretty-printed or not, members dropped or changed, tricky bodies.
func TestTrimWUIEnvRandom(t *testing.T) {
	r := &goldenRand{s: 13}
	bodies := []string{"", "plain", "a <b> & c", "  ", "é 漢字 😀", "\x00\x1f", `"\/`, "</script>", " "}
	pick := func(vs ...any) any { return vs[r.Intn(len(vs))] }
	for i := 0; i < 3000; i++ {
		inner := map[string]any{"body": bodies[r.Intn(len(bodies))] + bodies[r.Intn(len(bodies))], "from": "HUM-1",
			"kind": "note", "msg_id": fmt.Sprint("m", i), "ts": "2026-10-04T00:00:00Z", "v": 1}
		switch r.Intn(3) {
		case 0:
			inner["files"] = []any{}
		case 1:
			inner["files"] = []any{map[string]any{"file_id": "f<&>"}}
		}
		if r.Intn(3) > 0 {
			inner["task_id"] = pick(goldenTopic, "other", "", nil)
		}
		e := map[string]any{"msg": inner}
		for k, vs := range map[string][]any{
			"sig": {"", "c2ln", nil}, "from_box": {WUIBox, "box-a", nil}, "to_box": {WUIBox, "box-b"},
			"channel": {"ops", "dev", ""}, "parent_task_id": {goldenTopic, ""},
		} {
			if r.Intn(4) > 0 {
				e[k] = vs[r.Intn(len(vs))]
			}
		}
		var b []byte
		if r.Intn(2) == 0 {
			b, _ = json.MarshalIndent(e, "", "  ")
		} else {
			b, _ = json.Marshal(e)
		}
		sameWUITrim(t, string(b), pick(goldenTopic, "", "other").(string), pick("ops", "", "dev").(string))
	}
}

// FuzzTrimWUIEnv: any document, every task and channel.
func FuzzTrimWUIEnv(f *testing.F) {
	f.Add(wuiStoredEnv("a <b> & c"), goldenTopic, "ops")
	f.Add(`{"msg":{"files":[ ],"task_id":null},"sig":null,"from_box":"box-wui"}`, "", "")
	f.Add(`{"b":1,"b":2}`, "", "x")
	f.Fuzz(func(t *testing.T, env, taskID, channel string) {
		sameWUITrim(t, env, taskID, channel)
	})
}

// BenchmarkTrimWUIEnvAB runs the map (ref) and one-pass (new) trimWUIEnv
// on a stored browser post per body size, interleaved by -count:
//
//	go test ./internal/hub -run '^$' -bench BenchmarkTrimWUIEnvAB -benchmem -count 6
func BenchmarkTrimWUIEnvAB(b *testing.B) {
	for _, bs := range []struct {
		name string
		n    int
	}{{"chat_80B", 80}, {"para_1KB", 1 << 10}, {"paste_16KB", 16 << 10}} {
		env := []byte(wuiStoredEnv(strings.Repeat("ab <c> & d é ", bs.n/14+1)[:bs.n]))
		for _, impl := range []struct {
			name string
			f    func([]byte, string, string) json.RawMessage
		}{{"ref", trimWUIEnvRef}, {"new", trimWUIEnv}} {
			b.Run(bs.name+"/"+impl.name, func(b *testing.B) {
				b.ReportAllocs()
				for b.Loop() {
					impl.f(env, goldenTopic, "ops")
				}
			})
		}
	}
}

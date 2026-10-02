package hub

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// trimEnvRef is trimEnv as it was before perf round 4 (G9): decode into maps,
// delete, encode back. The one-pass trimEnv must match it byte for byte.
func trimEnvRef(env []byte, topic string) json.RawMessage {
	var e map[string]json.RawMessage
	if json.Unmarshal(env, &e) != nil {
		return env
	}
	delete(e, "sig")
	var m map[string]json.RawMessage
	if raw, ok := e["msg"]; ok && json.Unmarshal(raw, &m) == nil {
		if f, ok := m["files"]; ok && string(bytes.TrimSpace(f)) == "[]" {
			delete(m, "files")
		}
		var id string
		if t, ok := m["task_id"]; ok && topic != "" && json.Unmarshal(t, &id) == nil && id == topic {
			delete(m, "task_id")
		}
		if b, err := json.Marshal(m); err == nil {
			e["msg"] = b
		}
	}
	b, err := json.Marshal(e)
	if err != nil {
		return env
	}
	return b
}

const goldenTopic = "11111111-1111-4111-8111-111111111111"

func sameTrim(t *testing.T, env, topic string) {
	t.Helper()
	want := trimEnvRef([]byte(env), topic)
	if got := trimEnv([]byte(env), topic); !bytes.Equal(got, want) {
		t.Errorf("trimEnv(%q, %q):\n got  %q\n want %q", env, topic, got, want)
	}
}

// storedEnv is an envelope as the hub stores it (wire.Canonical: sorted, no
// HTML escaping) around body.
func storedEnv(body string) string {
	b, _ := json.Marshal(body)
	return `{"channel":"ops","from_box":"box-a","msg":{"body":` + strings.NewReplacer(`<`, "<", `>`, ">", `&`, "&").Replace(string(b)) +
		`,"files":[],"from":"HUM-1","kind":"msg","msg_id":"m1","task_id":"` + goldenTopic +
		`","to":"@lobby","ts":"2026-10-02T00:00:00Z","v":1},"sig":"` + strings.Repeat("c2ln", 22) + `","to_box":"box-wui"}`
}

func TestTrimEnvGolden(t *testing.T) {
	envs := []string{
		storedEnv("a <b> & c"), storedEnv("line sep  é 😀"), storedEnv("tab\tnl\n\"q\" \\ /"), storedEnv(""),
		strings.Replace(storedEnv("x"), `"files":[]`, `"files":[{"file_id":"f","name":"a&b"}]`, 1),
		strings.Replace(storedEnv("x"), `"files":[]`, `"files":[ ]`, 1),
		strings.Replace(storedEnv("x"), `"task_id":"`+goldenTopic+`"`, `"task_id":"1`+goldenTopic[1:]+`"`, 1),
		strings.Replace(storedEnv("x"), `"task_id":"`+goldenTopic+`"`, `"task_id":7`, 1),
		strings.Replace(storedEnv("x"), `"task_id":"`+goldenTopic+`"`, `"task_id":null`, 1),
		strings.Replace(storedEnv("x"), `"to":"@lobby"`, `"to":"@lobby","to":"@dup"`, 1),
		strings.Replace(storedEnv("x"), `"to":"@lobby"`, `"a<b":1,"é":2,"to":3`, 1),
		strings.Replace(storedEnv("x"), `"sig":`, `"sig":1,"sig":`, 1),
		`{"to_box":"b","from_box":"a","msg":null,"sig":"s"}`, `{"msg":"str","sig":"s"}`, `{"msg":[1,{"b":2,"a":1}]}`,
		`{"msg":{}}`, `{}`, `{"from_box":"a"}`, " \n{ \"z\" : 1 ,\n \"msg\" : { \"files\" : [] , \"b\" : \"<\\u0041>\" } }\t",
		`{"msg":{"files":[],"task_id":"` + goldenTopic + `"}}`, "{\"msg\":{\"body\":\"raw\xe2\x80\xa8\xff\"}}",
		`null`, `[]`, `"x"`, `1`, `x`, `{"a":}`, ``, `{"a":1}{"b":2}`,
	}
	for _, env := range envs {
		for _, topic := range []string{goldenTopic, "", "other"} {
			sameTrim(t, env, topic)
		}
	}
}

// TestTrimEnvRandom compares the two on n=3000 random envelopes (fixed seed):
// pretty-printed or not, members shuffled, fields dropped, tricky bodies.
func TestTrimEnvRandom(t *testing.T) {
	r := &goldenRand{s: 21}
	bodies := []string{"", "plain", "a <b> & c", "  ", "é 漢字 😀", "\x00\x1f", `"\/`, "</script>"}
	for i := 0; i < 3000; i++ {
		inner := map[string]any{"body": bodies[r.Intn(len(bodies))] + bodies[r.Intn(len(bodies))], "from": "HUM-1",
			"kind": "msg", "msg_id": fmt.Sprint("m", i), "ts": "2026-10-02T00:00:00Z", "v": 1}
		switch r.Intn(3) {
		case 0:
			inner["files"] = []any{}
		case 1:
			inner["files"] = []any{map[string]any{"file_id": "f<&>"}}
		}
		switch r.Intn(3) {
		case 0:
			inner["task_id"] = goldenTopic
		case 1:
			inner["task_id"] = "other"
		}
		e := map[string]any{"from_box": "box-a", "to_box": "box-b", "msg": inner, "sig": "c2ln"}
		if r.Intn(2) == 0 {
			delete(e, "sig")
		}
		var b []byte
		if r.Intn(2) == 0 {
			b, _ = json.MarshalIndent(e, "", "  ")
		} else {
			b, _ = json.Marshal(e)
		}
		sameTrim(t, string(b), []string{goldenTopic, "", "other"}[r.Intn(3)])
	}
}

// FuzzTrimEnv: any document, every topic shape.
func FuzzTrimEnv(f *testing.F) {
	f.Add(storedEnv("a <b> & c"), goldenTopic)
	f.Add(`{"msg":{"files":[ ],"task_id":"x"},"sig":1}`, "x")
	f.Add(`{"b":1,"b":2}`, "")
	f.Fuzz(func(t *testing.T, env, topic string) {
		sameTrim(t, env, topic)
	})
}

// BenchmarkTrimEnvAB runs the map (ref) and one-pass (new) trimEnv on a stored
// envelope per body size, interleaved by -count:
//
//	go test ./internal/hub -run '^$' -bench BenchmarkTrimEnvAB -benchmem -count 6
func BenchmarkTrimEnvAB(b *testing.B) {
	for _, bs := range []struct {
		name string
		n    int
	}{{"chat_80B", 80}, {"para_1KB", 1 << 10}, {"paste_16KB", 16 << 10}} {
		env := []byte(storedEnv(strings.Repeat("ab <c> & d é ", bs.n/14+1)[:bs.n]))
		for _, impl := range []struct {
			name string
			f    func([]byte, string) json.RawMessage
		}{{"ref", trimEnvRef}, {"new", trimEnv}} {
			b.Run(bs.name+"/"+impl.name, func(b *testing.B) {
				b.ReportAllocs()
				for b.Loop() {
					impl.f(env, goldenTopic)
				}
			})
		}
	}
}

// goldenRand is a fixed-seed xorshift: the random corpus only has to be
// varied and repeatable, not unpredictable.
type goldenRand struct{ s uint64 }

func (r *goldenRand) next() uint64 {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return r.s
}

func (r *goldenRand) Intn(n int) int { return int(r.next() % uint64(n)) }

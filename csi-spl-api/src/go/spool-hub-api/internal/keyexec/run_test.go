package keyexec

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClassify(t *testing.T) {
	cases := []struct {
		exit int
		line string
		want Verdict
	}{
		{1, "API Error: status 402 Payment Required", Exhausted},
		{1, `{"type":"error","error":{"type":"billing_error"}}`, Exhausted},
		{1, "Credit balance is too low", Exhausted},
		{1, "Error code: 429 - insufficient_quota: You exceeded your current quota", Exhausted},
		{1, "HTTP 401 Unauthorized", Exhausted},
		{1, "Invalid API key · Please run /login", Exhausted},
		{1, `authentication_error: invalid x-api-key`, Exhausted},
		{1, "The API key has been revoked", Exhausted},
		// A plain rate limit clears by itself: not a refusal (spec 159 9).
		{1, "API Error: 429 rate limit exceeded, retry in 20s", Other},
		{1, "Overloaded (529)", Other},
		{1, "connect ECONNRESET", Other},
		{1, "wrote 402 lines", Other},
		// A clean exit is never a refusal.
		{0, "API Error: status 402 Payment Required", Other},
	}
	for _, c := range cases {
		if got := Classify(c.exit, []byte(c.line)); got != c.want {
			t.Errorf("Classify(%d, %q) = %v, want %v", c.exit, c.line, got, c.want)
		}
	}
}

// supervise restarts the seat as a supervisor would, until the wrapper
// says the key is exhausted, at most max starts.
func supervise(s *seat, kind, mode string, noClassify bool, max int) (runs int, last int) {
	for runs = 1; runs <= max; runs++ {
		last, _ = s.run(kind, mode, noClassify)
		if last == ExitKeyExhausted {
			return runs, last
		}
	}
	return max, last
}

// TestRedControlFake402 is spec 159 T5's red control, box half: a fake CLI
// exits on a fake 402 -> the desk is told `exhausted grok` (no vendor text),
// the wrapper exits 79, and the next start is refused at the lease without
// the CLI running. With the classifier off the same seat restarts on the
// dead key every time and the desk never learns of it.
func TestRedControlFake402(t *testing.T) {
	s := newSeat(t)
	runs, last := supervise(s, "grok", "402", false, 5)
	if runs != 1 || last != ExitKeyExhausted {
		t.Fatalf("classifier on: %d runs, last exit %d; want 1 run, exit %d", runs, last, ExitKeyExhausted)
	}
	if n := len(s.desk.reports); n != 1 || s.desk.reports[0].Kind != "grok" {
		t.Fatalf("desk reports = %+v, want one exhausted grok", s.desk.reports)
	}
	rc, msg := s.run("grok", "402", false)
	if rc != ExitKeyExhausted || len(s.starts()) != 1 {
		t.Fatalf("next start: exit %d, CLI started %d times; want %d and the CLI not started again", rc, len(s.starts()), ExitKeyExhausted)
	}
	if !strings.Contains(msg, "marked exhausted") || strings.Contains(msg, fakeKey) {
		t.Fatalf("refused start says %q", msg)
	}

	off := newSeat(t)
	runs, last = supervise(off, "grok", "402", true, 5)
	if runs != 5 || last != 1 || len(off.starts()) != 5 || len(off.desk.reports) != 0 {
		t.Fatalf("classifier off: %d runs, exit %d, %d CLI starts, %d reports; want the seat looping on the dead key (5, 1, 5, 0)",
			runs, last, len(off.starts()), len(off.desk.reports))
	}
}

// A plain rate limit is the CLI's own exit, never a report.
func TestRateLimitIsNotExhausted(t *testing.T) {
	s := newSeat(t)
	if rc, _ := s.run("grok", "ratelimit", false); rc != 1 || len(s.desk.reports) != 0 {
		t.Fatalf("rate limit: exit %d, %d reports; want 1, 0", rc, len(s.desk.reports))
	}
}

// L6 + L15 + L10 + L7 for an env kind: the key only in the CLI's
// environment, never its argv; no other vendor's variable; a hard core
// limit of 0 the CLI cannot raise.
func TestGrokSeatEnvArgvCore(t *testing.T) {
	s := newSeat(t)
	rc, _ := s.run("grok", "ok", false,
		"ANTHROPIC_API_KEY=sk-other-1111", "OPENAI_API_KEY=sk-other-2222", "GEMINI_API_KEY=x",
		"GROK_AUTH_PROVIDER_COMMAND=/bin/true", SockEnv+"=/run/x")
	if rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	rec := s.starts()[0]
	env := envOf(rec)
	if env["XAI_API_KEY"] != fakeKey || env["GROK_HOME"] != s.seatDir || env["GROK_TELEMETRY_ENABLED"] != "false" {
		t.Fatalf("grok env: XAI_API_KEY set=%v GROK_HOME=%q telemetry=%q", env["XAI_API_KEY"] == fakeKey, env["GROK_HOME"], env["GROK_TELEMETRY_ENABLED"])
	}
	for _, v := range vendorVars {
		if _, ok := env[v]; ok && v != "XAI_API_KEY" && v != "GROK_HOME" {
			t.Errorf("L10: the grok seat sees %s", v)
		}
	}
	if strings.Contains(rec["cmdline"].(string), fakeKey) {
		t.Errorf("L6: the key is on the CLI's argv")
	}
	if rec["core_hard"].(float64) != 0 || rec["core_raise_refused"] != true {
		t.Errorf("L7: core hard limit %v, raise refused %v; want 0, true", rec["core_hard"], rec["core_raise_refused"])
	}
}

// L14 + L10 for claude: no key in any variable; the seat's own settings
// file names the helper, passed by --settings, and holds no key.
func TestClaudeSeatUsesHelperOnly(t *testing.T) {
	s := newSeat(t)
	if rc, _ := s.run("claude", "ok", false, "ANTHROPIC_API_KEY=sk-other-1111"); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	rec := s.starts()[0]
	for k, v := range envOf(rec) {
		if strings.Contains(v, fakeKey) || k == "ANTHROPIC_API_KEY" {
			t.Errorf("L14: claude seat env carries %s", k)
		}
	}
	args := rec["args"].([]any)
	f := filepath.Join(s.seatDir, "claude-settings.json")
	if len(args) < 3 || args[0] != "--settings" || args[1] != f || args[2] != "--fake-arg" {
		t.Fatalf("claude args = %v, want --settings %s first", args, f)
	}
	b, err := os.ReadFile(f)
	if err != nil || !strings.Contains(string(b), "apiKeyHelper") || strings.Contains(string(b), fakeKey) {
		t.Fatalf("seat settings %q (err %v): want the helper, no key", b, err)
	}
	if st, _ := os.Stat(f); st.Mode().Perm() != 0o600 {
		t.Errorf("seat settings mode %o, want 600", st.Mode().Perm())
	}
}

func TestQwenPinsAuthType(t *testing.T) {
	s := newSeat(t)
	if rc, _ := s.run("qwen", "ok", false); rc != 0 {
		t.Fatalf("exit %d", rc)
	}
	rec := s.starts()[0]
	args := rec["args"].([]any)
	if len(args) < 2 || args[0] != "--auth-type" || args[1] != "openai" {
		t.Fatalf("qwen args = %v, want --auth-type openai first", args)
	}
	if env := envOf(rec); env["OPENAI_API_KEY"] != fakeKey || env["OPENAI_BASE_URL"] != "https://llm.example.com/v1" {
		t.Fatalf("qwen env not set from the lease")
	}
}

// The starts a seat refuses: the CLI never runs.
func TestRefusedStarts(t *testing.T) {
	cases := []struct {
		name, kind string
		prep       func(s *seat)
		want       int
	}{
		{"grok auth.json (L14)", "grok", func(s *seat) { write(s.t, filepath.Join(s.seatDir, "auth.json")) }, ExitRefused},
		{"grok provider command", "grok", func(s *seat) {
			writeText(s.t, filepath.Join(s.seatDir, "config.toml"), "auth_provider_command = \"x\"\n")
		}, ExitRefused},
		{"mistral .vibe/.env", "mistral", func(s *seat) {
			if err := os.MkdirAll(filepath.Join(s.home, ".vibe"), 0o700); err != nil {
				s.t.Fatal(err)
			}
			write(s.t, filepath.Join(s.home, ".vibe", ".env"))
		}, ExitRefused},
		{"seat dir open to others", "grok", func(s *seat) { _ = os.Chmod(s.seatDir, 0o755) }, ExitRefused},
		{"agy off until B0c", "agy", func(*seat) {}, ExitRefused},
		{"desk: no key", "mistral", func(s *seat) { s.desk.refuse = "no_key" }, ExitRefused},
		{"desk: key exhausted", "mistral", func(s *seat) { s.desk.refuse = TokenKeyExhausted }, ExitKeyExhausted},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newSeat(t)
			c.prep(s)
			rc, msg := s.run(c.kind, "ok", false)
			if rc != c.want || len(s.starts()) != 0 {
				t.Fatalf("exit %d (%q), CLI started %d times; want %d, never", rc, msg, len(s.starts()), c.want)
			}
			if strings.Contains(msg, fakeKey) {
				t.Fatalf("the refusal prints the key")
			}
		})
	}
}

func write(t *testing.T, p string) { writeText(t, p, "{}\n") }

func writeText(t *testing.T, p, s string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

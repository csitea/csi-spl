package keyexec

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Kinds are the five agent kinds of spec 127 section 3.
var Kinds = []string{"claude", "grok", "agy", "mistral", "qwen"}

// SeatDirEnv names the seat's own dir: `<runtime>/spool-seat/<seat-id>/`,
// tmpfs, mode 0700, made by the desk (127 5.4). grok's GROK_HOME, claude's
// seat settings file and agy's credential file live there.
const SeatDirEnv = "SPOOL_SEAT_DIR"

// TaskEnv names the task the seat runs, when its launcher knows it (spec 159
// 9 points 3-4): an exhausted report carries it, so the hub can post one line
// in that task's topic. Unset is today's report, with no task.
const TaskEnv = "SPOOL_TASK_ID"

// vendorVars is every variable through which some CLI picks up a vendor
// credential or endpoint (127 3, L10). The wrapper removes all of them, then
// sets only its own kind's.
var vendorVars = []string{
	"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
	"XAI_API_KEY", "GROK_AUTH_PROVIDER_COMMAND", "GROK_HOME",
	"MISTRAL_API_KEY",
	"OPENAI_API_KEY", "OPENAI_BASE_URL", "DASHSCOPE_API_KEY",
	"GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS",
	"AGY_ADC_AUTH", "CLOUDSDK_CONFIG",
	SockEnv, // the seat's children never get the desk socket's name from us
}

// telemetry is each kind's telemetry switch, off (127 L16, as B0 named them).
var telemetry = map[string][]string{
	"claude":  {"DISABLE_TELEMETRY=1", "DISABLE_ERROR_REPORTING=1"},
	"grok":    {"GROK_TELEMETRY_ENABLED=false"},
	"mistral": {"VIBE_ENABLE_TELEMETRY=false"},
}

// IsKind reports whether k is one of the five kinds.
func IsKind(k string) bool {
	for _, x := range Kinds {
		if x == k {
			return true
		}
	}
	return false
}

// Seat is what a kind's CLI is started with.
type Seat struct {
	Env  []string // the full environment, KEY=VALUE
	Args []string // the CLI's args, with the wrapper's pins in front
}

// SeatSpec is the input of BuildSeat.
type SeatSpec struct {
	Kind    string
	Base    []string // the wrapper's own environment
	Args    []string // the CLI's args as given
	Lease   Lease    // empty for claude: its key comes through the helper
	SeatDir string
	Helper  string // claude: the apiKeyHelper command line (no key in it)
}

// BuildSeat strips every vendor variable from the base environment, then
// sets the kind's key, pins and telemetry switches.
func BuildSeat(s SeatSpec) (Seat, error) {
	env := stripVendor(s.Base)
	env = append(env, telemetry[s.Kind]...)
	args := append([]string(nil), s.Args...)
	switch s.Kind {
	case "claude":
		// Never ANTHROPIC_API_KEY: interactive + env leaves the key's last 20
		// chars in .claude.json (127 3, L14). The seat's own settings file
		// names the helper, passed by --settings.
		f, err := writeClaudeSettings(s.SeatDir, s.Helper)
		if err != nil {
			return Seat{}, err
		}
		args = append([]string{"--settings", f}, args...)
	case "grok":
		if err := grokHomeOK(s.SeatDir); err != nil {
			return Seat{}, err
		}
		env = append(env, "GROK_HOME="+s.SeatDir, "XAI_API_KEY="+s.Lease.Key)
	case "mistral":
		if err := noVibeEnvFile(s.Base); err != nil {
			return Seat{}, err
		}
		env = append(env, "MISTRAL_API_KEY="+s.Lease.Key)
	case "qwen":
		if !strings.HasPrefix(s.Lease.BaseURL, "https://") {
			return Seat{}, errors.New("qwen: the lease carries no https base_url")
		}
		env = append(env, "OPENAI_API_KEY="+s.Lease.Key, "OPENAI_BASE_URL="+s.Lease.BaseURL)
		args = append([]string{"--auth-type", "openai"}, args...) // never another vendor's key (127 3)
	case "agy":
		// 127 R5.2: off until the B0c gate passes; no credential file is
		// written while it is off.
		return Seat{}, errors.New("agy: not supported for workspace keys until the B0c gate passes (spec 127 9.2)")
	default:
		return Seat{}, fmt.Errorf("%s: not a kind key-exec starts", s.Kind)
	}
	return Seat{Env: env, Args: args}, nil
}

func stripVendor(base []string) []string {
	drop := map[string]bool{}
	for _, v := range vendorVars {
		drop[v] = true
	}
	out := make([]string, 0, len(base))
	for _, kv := range base {
		name, _, _ := strings.Cut(kv, "=")
		if !drop[name] {
			out = append(out, kv)
		}
	}
	return out
}

func envGet(env []string, name string) string {
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok && k == name {
			return v
		}
	}
	return ""
}

// seatDirOK refuses a seat dir that is missing, not a dir, or open to others.
func seatDirOK(dir string) error {
	if dir == "" {
		return fmt.Errorf("no seat dir: $%s is not set (the desk makes it, 127 5.4)", SeatDirEnv)
	}
	st, err := os.Lstat(dir)
	if err != nil || !st.IsDir() {
		return fmt.Errorf("seat dir %s is not a directory", dir)
	}
	if st.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("seat dir %s is mode %o, want 0700", dir, st.Mode().Perm())
	}
	return nil
}

// grokHomeOK: a stored login beats XAI_API_KEY (B0 2.5), so the seat's
// GROK_HOME must hold no auth.json and no config naming a provider command.
func grokHomeOK(dir string) error {
	if err := seatDirOK(dir); err != nil {
		return err
	}
	if _, err := os.Lstat(filepath.Join(dir, "auth.json")); err == nil {
		return errors.New("grok: the seat's GROK_HOME holds an auth.json, which would win over the workspace key")
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.toml"))
	more, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	files = append(files, more...)
	sort.Strings(files)
	for _, f := range files {
		b, err := os.ReadFile(f) // #nosec G304 -- the seat's own dir
		if err == nil && strings.Contains(string(b), "auth_provider_command") {
			return errors.New("grok: a config in GROK_HOME names auth_provider_command")
		}
	}
	return nil
}

// noVibeEnvFile: vibe's onboarding writes the key to ~/.vibe/.env (127 3).
func noVibeEnvFile(base []string) error {
	home := envGet(base, "HOME")
	if home == "" {
		return nil
	}
	if _, err := os.Lstat(filepath.Join(home, ".vibe", ".env")); err == nil {
		return errors.New("mistral: the seat home holds .vibe/.env; a seat on a workspace key runs with none")
	}
	return nil
}

// writeClaudeSettings writes the seat's own settings file, naming the helper
// and nothing else; never a shared settings file (127 5.2 step 5).
func writeClaudeSettings(dir, helper string) (string, error) {
	if err := seatDirOK(dir); err != nil {
		return "", err
	}
	if strings.TrimSpace(helper) == "" {
		return "", errors.New("claude: no apiKeyHelper command")
	}
	f := filepath.Join(dir, "claude-settings.json")
	body := fmt.Sprintf("{\"apiKeyHelper\": %q}\n", helper)
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		return "", fmt.Errorf("claude: seat settings: %w", err)
	}
	return f, nil
}

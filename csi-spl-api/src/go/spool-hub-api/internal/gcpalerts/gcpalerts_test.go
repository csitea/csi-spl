package gcpalerts

import (
	"context"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

var updateTools = flag.Bool("update", false, "rewrite testdata/tools.golden from the current server")

// call is one Runner call the fake recorded.
type call struct {
	action string
	env    []string
}

// connect serves a server with a fake runner and keys under a temp home that
// hold a key file for each of keyEnvs.
func connect(t *testing.T, keyEnvs ...string) (*sdk.ClientSession, *[]call) {
	t.Helper()
	home := t.TempDir()
	keys := KeyPathOf(home, "org", "app")
	for _, e := range keyEnvs {
		if err := os.MkdirAll(filepath.Dir(keys(e)), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(keys(e), []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	calls := &[]call{}
	run := func(_ context.Context, action string, env []string) (string, error) {
		*calls = append(*calls, call{action, env})
		return "TYPE COUNT\nhub 5xx rate 2\n", nil
	}
	ctx := context.Background()
	ct, st := sdk.NewInMemoryTransports()
	if _, err := NewServer("test", Options{Run: run, KeyPath: keys}).Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := sdk.NewClient(&sdk.Implementation{Name: "t", Version: "test"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs, calls
}

func callText(t *testing.T, cs *sdk.ClientSession, name string, args map[string]any) (string, bool) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &sdk.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("call %s: protocol error %v", name, err)
	}
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*sdk.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String(), res.IsError
}

// TestToolsListGolden pins what an MCP client is told: every tool's name,
// description and schemas, byte for byte (the pattern of mcp's).
func TestToolsListGolden(t *testing.T) {
	cs, _ := connect(t)
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := json.MarshalIndent(res.Tools, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	const path = "testdata/tools.golden"
	if *updateTools {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("tools/list differs from %s:\n%s", path, got)
	}
}

// A missing key fails before the action runs: no runner call at all, and the
// error names the env and the path (never a key's content).
func TestMissingKeyFailsFast(t *testing.T) {
	cs, calls := connect(t, "dev")
	out, isErr := callText(t, cs, "gcp_alert_incidents", map[string]any{"env": "prd"})
	if !isErr || !strings.Contains(out, "no service-account key for prd at ") || !strings.Contains(out, "exit 78") {
		t.Fatalf("want a key refusal, got isErr=%v %q", isErr, out)
	}
	out, isErr = callText(t, cs, "gcp_alert_incident", map[string]any{"env": "prd", "policy": "hub 5xx rate", "opened": "2026-10-22T09:31Z"})
	if !isErr || !strings.Contains(out, "no service-account key for prd") {
		t.Fatalf("want a key refusal, got isErr=%v %q", isErr, out)
	}
	if len(*calls) != 0 {
		t.Fatalf("a missing key ran the action: %v", *calls)
	}
}

// Each tool runs its named action with ENV and its argument, and returns the
// action's stdout.
func TestToolsRunTheNamedAction(t *testing.T) {
	cs, calls := connect(t, "dev", "prd")
	out, isErr := callText(t, cs, "gcp_alert_incidents", map[string]any{"env": "dev"})
	if isErr || !strings.Contains(out, "hub 5xx rate") {
		t.Fatalf("list: isErr=%v %q", isErr, out)
	}
	if _, isErr = callText(t, cs, "gcp_alert_incidents", map[string]any{"env": "prd", "since": "7d"}); isErr {
		t.Fatal("list 7d refused")
	}
	if _, isErr = callText(t, cs, "gcp_alert_incident", map[string]any{"env": "prd", "policy": "csi-spl-prd hub 5xx rate", "opened": "2026-10-22T09:31Z"}); isErr {
		t.Fatal("get refused")
	}
	want := []string{
		ListAction + " ENV=dev SINCE=24h",
		ListAction + " ENV=prd SINCE=7d",
		GetAction + " ENV=prd POLICY=csi-spl-prd hub 5xx rate OPENED=2026-10-22T09:31Z",
	}
	if len(*calls) != len(want) {
		t.Fatalf("calls %v, want %v", *calls, want)
	}
	for i, c := range *calls {
		if got := c.action + " " + strings.Join(c.env, " "); got != want[i] {
			t.Errorf("call %d = %q, want %q", i, got, want[i])
		}
	}
}

// Bad input is refused before the key check and the action: no shell text,
// no third env, no open-ended window.
func TestInputRefused(t *testing.T) {
	cs, calls := connect(t, "dev", "prd")
	for _, c := range []struct {
		tool string
		args map[string]any
	}{
		{"gcp_alert_incidents", map[string]any{"env": "stg"}},
		{"gcp_alert_incidents", map[string]any{"env": "dev", "since": "24h; id"}},
		{"gcp_alert_incidents", map[string]any{"env": "dev", "since": "0h"}},
		{"gcp_alert_incidents", map[string]any{"env": "dev", "since": "1000d"}},
		{"gcp_alert_incident", map[string]any{"env": "dev", "policy": "$(id)", "opened": "2026-10-22T09:31Z"}},
		{"gcp_alert_incident", map[string]any{"env": "dev", "policy": "", "opened": "2026-10-22T09:31Z"}},
		{"gcp_alert_incident", map[string]any{"env": "dev", "policy": "hub 5xx rate", "opened": "yesterday"}},
		{"gcp_alert_incident", map[string]any{"env": "dev", "policy": "a\nb", "opened": "2026-10-22T09:31Z"}},
	} {
		if out, isErr := callText(t, cs, c.tool, c.args); !isErr || !strings.Contains(out, "exit 78") {
			t.Errorf("%s %v: want a refusal, got isErr=%v %q", c.tool, c.args, isErr, out)
		}
	}
	if len(*calls) != 0 {
		t.Fatalf("refused input ran the action: %v", *calls)
	}
}

// IACRunner runs <iac>/run -a <action> in iac, with ORG, APP and the call's env.
func TestIACRunner(t *testing.T) {
	iac := t.TempDir()
	script := "#!/bin/sh\necho \"$1 $2 $ORG $APP $ENV $SINCE $(pwd)\"\n[ \"$ENV\" = dev ] || { echo boom >&2; exit 3; }\n"
	if err := os.WriteFile(filepath.Join(iac, "run"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	run := IACRunner(iac, "org", "app")
	out, err := run(context.Background(), ListAction, []string{"ENV=dev", "SINCE=24h"})
	if err != nil {
		t.Fatal(err)
	}
	if want := "-a " + ListAction + " org app dev 24h " + iac + "\n"; out != want {
		t.Fatalf("out %q, want %q", out, want)
	}
	if _, err := run(context.Background(), ListAction, []string{"ENV=prd"}); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("want the failure with its stderr, got %v", err)
	}
}

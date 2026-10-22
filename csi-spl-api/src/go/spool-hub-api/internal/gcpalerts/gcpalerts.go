// Package gcpalerts is the read-only stdio MCP server of the Google Cloud
// alert incidents (`spool mcp-gcp-alerts`, SPL-2887, spec 146): two tools
// over the csi-spl-iac named actions that read them. It never runs gcloud
// itself and never opens a key: each call runs `<iac>/run -a <action>` with
// ENV and the call's arguments, and the action reads the environment's
// service-account key. Before it runs anything it checks that the key FILE of
// the env exists, so a missing key fails at once, by its path, instead of
// after a gcloud start.
package gcpalerts

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

// The named actions the tools run, in csi-spl-iac (nothing ad hoc).
const (
	ListAction = "do_gcp_list_alert_incidents"
	GetAction  = "do_gcp_get_alert_incident"
)

// IncidentsIn is the input of gcp_alert_incidents.
type IncidentsIn struct {
	Env   string `json:"env" jsonschema:"dev or prd"`
	Since string `json:"since,omitempty" jsonschema:"the window back from now: <n>m, <n>h or <n>d, n 1..999 (default 24h)"`
}

// IncidentIn is the input of gcp_alert_incident. Cloud Monitoring has no
// public incidents API and logs no entry per incident, so an incident has no
// id: the list action rebuilds them from each policy's condition, and one is
// named by its policy and the minute it opened, as the list prints them.
type IncidentIn struct {
	Env    string `json:"env" jsonschema:"dev or prd"`
	Policy string `json:"policy" jsonschema:"the alert policy display name, as the incident line of gcp_alert_incidents prints it"`
	Opened string `json:"opened" jsonschema:"the minute the incident opened, UTC, YYYY-MM-DDTHH:MMZ, as the incident line prints it"`
}

// Runner runs one named action with extra environment and returns its stdout.
type Runner func(ctx context.Context, action string, env []string) (string, error)

// Options shape a server.
type Options struct {
	// Run runs a named action (IACRunner in production).
	Run Runner
	// KeyPath maps an env to its service-account key file; the server only
	// checks that the file exists, it never reads it.
	KeyPath func(env string) string
}

var (
	envRE    = regexp.MustCompile(`^(dev|prd)$`)
	sinceRE  = regexp.MustCompile(`^[1-9][0-9]{0,2}[mhd]$`)
	policyRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._:/()-]{0,127}$`)
	openedRE = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$`)
)

// errRefused marks an input or precondition refusal (exit 78, as the spool's).
var errRefused = errors.New("refused")

// NewServer returns the gcp-alerts server with its two tools.
func NewServer(version string, o Options) *sdk.Server {
	s := sdk.NewServer(&sdk.Implementation{Name: "gcp-alerts", Version: version}, nil)
	t := tools{o: o}
	sdk.AddTool(s, &sdk.Tool{
		Name: "gcp_alert_incidents",
		Description: "Read-only: the Google Cloud Monitoring alert incidents of one environment in a window, grouped by alert type " +
			"(policy) with count, first and last seen and the resource (== ENV=<env> SINCE=<since> ./run -a " + ListAction + ").",
	}, t.incidents)
	sdk.AddTool(s, &sdk.Tool{
		Name: "gcp_alert_incident",
		Description: "Read-only: one Google Cloud Monitoring alert incident with its policy, resource and timeline " +
			"(== ENV=<env> POLICY=<policy> OPENED=<opened> ./run -a " + GetAction + ").",
	}, t.incident)
	return s
}

type tools struct{ o Options }

func (t tools) incidents(ctx context.Context, _ *sdk.CallToolRequest, in IncidentsIn) (*sdk.CallToolResult, any, error) {
	since := in.Since
	if since == "" {
		since = "24h"
	}
	if !sinceRE.MatchString(since) {
		return nil, nil, toolErr(fmt.Errorf("since %q is not <n>m, <n>h or <n>d (n 1..999): %w", since, errRefused))
	}
	return t.run(ctx, in.Env, ListAction, "SINCE="+since)
}

func (t tools) incident(ctx context.Context, _ *sdk.CallToolRequest, in IncidentIn) (*sdk.CallToolResult, any, error) {
	if !policyRE.MatchString(in.Policy) {
		return nil, nil, toolErr(fmt.Errorf("policy %q is not a policy display name: %w", in.Policy, errRefused))
	}
	if !openedRE.MatchString(in.Opened) {
		return nil, nil, toolErr(fmt.Errorf("opened %q is not YYYY-MM-DDTHH:MMZ: %w", in.Opened, errRefused))
	}
	return t.run(ctx, in.Env, GetAction, "POLICY="+in.Policy, "OPENED="+in.Opened)
}

// run checks the env and its key file, then runs the action.
func (t tools) run(ctx context.Context, env, action string, args ...string) (*sdk.CallToolResult, any, error) {
	if !envRE.MatchString(env) {
		return nil, nil, toolErr(fmt.Errorf("env %q is not dev or prd: %w", env, errRefused))
	}
	if t.o.KeyPath == nil || t.o.Run == nil {
		return nil, nil, toolErr(fmt.Errorf("the server has no key path or runner: %w", errRefused))
	}
	key := t.o.KeyPath(env)
	if st, err := os.Stat(key); err != nil || !st.Mode().IsRegular() {
		return nil, nil, toolErr(fmt.Errorf("no service-account key for %s at %s: %w", env, key, errRefused))
	}
	out, err := t.o.Run(ctx, action, append([]string{"ENV=" + env}, args...))
	if err != nil {
		return nil, nil, toolErr(err)
	}
	return &sdk.CallToolResult{Content: []sdk.Content{&sdk.TextContent{Text: out}}}, nil, nil
}

func toolErr(err error) error {
	code := 1
	if errors.Is(err, errRefused) {
		code = 78
	}
	return fmt.Errorf("gcp-alerts: %w (exit %d)", err, code)
}

// RunTimeout bounds one action run.
const RunTimeout = 180 * time.Second

// IACRunner runs `<iac>/run -a <action>` in iac with ORG and APP set: the
// caller's environment plus env. stdout is the result; on a failure the last
// lines of the output are the error.
func IACRunner(iac, org, app string) Runner {
	return func(ctx context.Context, action string, env []string) (string, error) {
		ctx, cancel := context.WithTimeout(ctx, RunTimeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, filepath.Join(iac, "run"), "-a", action)
		cmd.Dir = iac
		cmd.Env = append(append(os.Environ(), "ORG="+org, "APP="+app), env...)
		var out, errb bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errb
		if err := cmd.Run(); err != nil {
			return "", fmt.Errorf("%s: %w: %s", action, err, lastLines(out.String()+errb.String(), 5))
		}
		return out.String(), nil
	}
}

// KeyPathOf is the per-env key path the iac gcloud actions read:
// <home>/.gcp/.<org>/key-<org>-<app>-<env>.json.
func KeyPathOf(home, org, app string) func(string) string {
	return func(env string) string {
		return filepath.Join(home, ".gcp", "."+org, fmt.Sprintf("key-%s-%s-%s.json", org, app, env))
	}
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " | ")
}

// Run serves the tools over stdin/stdout until the client disconnects or ctx
// ends; stdout carries only the protocol.
func Run(ctx context.Context, version string, o Options) error {
	return NewServer(version, o).Run(ctx, &sdk.StdioTransport{})
}

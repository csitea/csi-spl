package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// agentModelsStdinMax bounds the models read from stdin: 500 models of 80
// characters (the hub's own cap, contract 7.1.5) with room for line ends.
const agentModelsStdinMax = 64 << 10

// cmdAgentModels is the box's report of a live model list (spec 184 row H2,
// contract 7.1.5), on the box's own upload token:
//
//	agent-models report --vendor V --cli-version X [--read-at RFC3339]   models on stdin, one per line
//
// It prints the hub's answer {"box", "vendor", "stored"}. Exit 0 sent
// (stored true or false), 3 off (no hub mode, or a hub without the route:
// 404 / 405), 1 refused or unreachable: the codes of A1's
// spool_agent_models_report.
func cmdAgentModels(cfg *config.Config, args []string) int {
	if len(args) == 0 || args[0] != "report" {
		return fail(errors.New("usage: spool agent-models report --vendor <v> --cli-version <x> [--read-at <RFC 3339>] (models on stdin)"))
	}
	fs := flag.NewFlagSet("agent-models report", flag.ContinueOnError)
	vendor := fs.String("vendor", "", "the vendor whose CLI was read (claude, grok, mistral, agy, qwen, codex)")
	cli := fs.String("cli-version", "", "the CLI version the list came from")
	at := fs.String("read-at", "", "when the list was read, RFC 3339 (default now)")
	if err := fs.Parse(args[1:]); err != nil {
		return 1
	}
	if *vendor == "" {
		return fail(errors.New("agent-models report: --vendor is required"))
	}
	if cfg.HubURL == "" {
		fmt.Fprintln(os.Stderr, "spool: agent-models report: off, no hub mode ($SPOOL_HUB_URL is not set)")
		return 3
	}
	r := hubclient.AgentModelReading{Vendor: *vendor, CLIVersion: *cli, ReadAt: time.Now().UTC()}
	if *at != "" {
		t, err := time.Parse(time.RFC3339, *at)
		if err != nil {
			return fail(fmt.Errorf("agent-models report: --read-at: %w", err))
		}
		r.ReadAt = t
	}
	models, err := readModelLines(os.Stdin)
	if err != nil {
		return fail(err)
	}
	r.Models = models
	return agentModelsSend(cfg, r)
}

// readModelLines reads one model per line; blank lines are dropped, the
// rest is sent as it is (the hub checks the syntax, 400 bad_reading).
func readModelLines(in io.Reader) ([]string, error) {
	out := []string{}
	sc := bufio.NewScanner(io.LimitReader(in, agentModelsStdinMax+1))
	n := 0
	for sc.Scan() {
		n += len(sc.Bytes()) + 1
		if m := strings.TrimSpace(sc.Text()); m != "" {
			out = append(out, m)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("agent-models report: stdin: %w", err)
	}
	if n > agentModelsStdinMax {
		return nil, fmt.Errorf("agent-models report: stdin holds more than %d bytes", agentModelsStdinMax)
	}
	return out, nil
}

func agentModelsSend(cfg *config.Config, r hubclient.AgentModelReading) int {
	ctx, stop := interruptible()
	defer stop()
	stored, err := hubclient.New(cfg).ReportAgentModels(ctx, r)
	var he *hubclient.HubError
	if errors.As(err, &he) && (he.Status == http.StatusNotFound || he.Status == http.StatusMethodNotAllowed) {
		fmt.Fprintf(os.Stderr, "spool: agent-models report: off, the hub has no reading route (%d)\n", he.Status)
		return 3
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "spool: agent-models report: "+err.Error())
		return 1
	}
	return printJSON(map[string]any{"box": cfg.BoxID, "vendor": r.Vendor, "stored": stored})
}

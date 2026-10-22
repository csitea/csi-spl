package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/csitea/csi-spl/spool-hub-api/internal/gcpalerts"
)

var orgAppRE = regexp.MustCompile(`^[a-z][a-z0-9]{1,15}$`)

// cmdMCPGCPAlerts serves the read-only GCP alert incident tools over stdio
// (SPL-2887). It needs no box config: each tool runs a named csi-spl-iac
// action, which reads the env's service-account key under --key-home.
func cmdMCPGCPAlerts(args []string) int {
	fs := flag.NewFlagSet("mcp-gcp-alerts", flag.ContinueOnError)
	iac := fs.String("iac", os.Getenv("GCP_ALERTS_IAC"), "the <org>-<app>-iac dir whose ./run holds the alert actions (default $GCP_ALERTS_IAC)")
	org := fs.String("org", "csi", "the ORG of the iac actions and of the key path")
	app := fs.String("app", "spl", "the APP of the iac actions and of the key path")
	home, _ := os.UserHomeDir()
	keyHome := fs.String("key-home", home, "the home whose .gcp/.<org>/key-<org>-<app>-<env>.json the actions read")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if !orgAppRE.MatchString(*org) || !orgAppRE.MatchString(*app) {
		fmt.Fprintf(os.Stderr, "spool: mcp-gcp-alerts --org %q / --app %q: lower-case letters and digits only\n", *org, *app)
		return 1
	}
	if *iac == "" {
		fmt.Fprintln(os.Stderr, "spool: mcp-gcp-alerts needs --iac <dir> (or $GCP_ALERTS_IAC)")
		return 1
	}
	if st, err := os.Stat(filepath.Join(*iac, "run")); err != nil || st.Mode()&0o111 == 0 {
		fmt.Fprintf(os.Stderr, "spool: mcp-gcp-alerts: no executable %s\n", filepath.Join(*iac, "run"))
		return 1
	}
	if *keyHome == "" {
		fmt.Fprintln(os.Stderr, "spool: mcp-gcp-alerts needs --key-home (no $HOME)")
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	o := gcpalerts.Options{Run: gcpalerts.IACRunner(*iac, *org, *app), KeyPath: gcpalerts.KeyPathOf(*keyHome, *org, *app)}
	if err := gcpalerts.Run(ctx, version, o); err != nil && ctx.Err() == nil {
		return fail(err)
	}
	return 0
}

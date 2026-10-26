package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// r16-10: cmdMCPGCPAlerts' flag parsing and guards, each refusing with exit 1
// and one stderr line before any MCP server starts. The last test serves on
// a closed stdin, so the stdio server ends at once.

// iacDir is a temp dir holding ./run with the given mode.
func iacDir(t *testing.T, mode os.FileMode) string {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "run"), []byte("#!/bin/sh\nexit 0\n"), mode); err != nil {
		t.Fatal(err)
	}
	return d
}

func TestCmdMCPGCPAlertsRefusals(t *testing.T) {
	t.Setenv("GCP_ALERTS_IAC", "")
	exe, noExe := iacDir(t, 0o755), iacDir(t, 0o644)
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"unknown flag", []string{"--bogus"}, "flag provided but not defined"},
		{"org upper case", []string{"--org", "CSI", "--iac", exe}, `--org "CSI" / --app "spl": lower-case letters and digits only`},
		{"app too short", []string{"--app", "s", "--iac", exe}, `--app "s": lower-case`},
		{"app leading digit", []string{"--app", "1spl", "--iac", exe}, "lower-case letters and digits only"},
		{"no iac", nil, "needs --iac <dir> (or $GCP_ALERTS_IAC)"},
		{"iac without run", []string{"--iac", t.TempDir()}, "no executable "},
		{"run not executable", []string{"--iac", noExe}, "no executable " + filepath.Join(noExe, "run")},
		{"no key home", []string{"--iac", exe, "--key-home", ""}, "needs --key-home (no $HOME)"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var rc int
			stderr := captureFD(t, &os.Stderr, func() { rc = cmdMCPGCPAlerts(tc.args) })
			if rc != 1 {
				t.Fatalf("rc = %d, want 1; stderr %q", rc, stderr)
			}
			if !strings.Contains(string(stderr), tc.want) {
				t.Fatalf("stderr = %q, want it to contain %q", stderr, tc.want)
			}
		})
	}
}

// The iac dir may come from $GCP_ALERTS_IAC alone: past every guard, the
// server starts on a closed stdin and ends.
func TestCmdMCPGCPAlertsIACFromEnvServes(t *testing.T) {
	t.Setenv("GCP_ALERTS_IAC", iacDir(t, 0o755))
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	defer r.Close()
	oldIn := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = oldIn }()
	var rc int
	var stdout []byte
	stderr := captureFD(t, &os.Stderr, func() {
		stdout = captureFD(t, &os.Stdout, func() { rc = cmdMCPGCPAlerts([]string{"--key-home", t.TempDir()}) })
	})
	if rc != 0 || len(stderr) != 0 {
		t.Fatalf("rc = %d, stderr %q; want 0 and nothing (no guard refuses the env iac dir)", rc, stderr)
	}
	if len(stdout) != 0 {
		t.Fatalf("stdout = %q, want nothing on a closed stdin", stdout)
	}
}

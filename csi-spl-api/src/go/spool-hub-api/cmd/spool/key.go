package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keyd"
)

const keyUsage = `usage: spool key init (--as <id> | --owner) --workspace <uuid>
       spool key unlock --workspace <uuid>
       spool key lock
       spool key status
       spool key rotate --as <id>
`

func cmdKey(args []string) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(os.Stderr, keyUsage)
		if len(args) == 0 {
			return 1
		}
		return 0
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "init":
		return cmdKeyInit(rest)
	case "unlock":
		return cmdKeyUnlock(rest)
	case "lock":
		return cmdKeyLock(rest)
	case "status":
		return cmdKeyStatus(rest)
	case "rotate":
		return cmdKeyRotate(rest)
	default:
		fmt.Fprintf(os.Stderr, "unknown key command %q\n", sub)
		return 1
	}
}

func cmdKeyInit(args []string) int {
	if rc := refuseFlag(args); rc != 0 {
		return rc
	}
	fs := flag.NewFlagSet("key init", flag.ContinueOnError)
	as := fs.String("as", "", "agent id")
	owner := fs.Bool("owner", false, "create the owner key")
	ws := fs.String("workspace", "", "workspace uuid")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 0 || *owner == (*as != "") {
		fmt.Fprint(os.Stderr, keyUsage)
		return 1
	}
	if !keyd.ValidWorkspace(*ws) {
		fmt.Fprintln(os.Stderr, "spool: workspace id is not a uuid")
		return 1
	}
	if *as != "" && !agentid.IsNew(*as) {
		fmt.Fprintln(os.Stderr, "spool: agent id is not valid")
		return 1
	}
	dir, rc := encState()
	if rc != 0 {
		return rc
	}
	if cur, err := keyd.WorkspaceOf(dir); err == nil && cur != *ws {
		fmt.Fprintln(os.Stderr, "spool: workspace mismatch")
		return 1
	}
	pass, err := keyd.ReadNew()
	if err != nil {
		return passFail(err)
	}
	defer keyd.Wipe(pass)
	var pub string
	if *owner {
		pub, err = keyd.InitOwner(dir, *ws, pass)
	} else {
		pub, err = keyd.InitAgent(dir, *ws, *as, pass)
	}
	if err != nil {
		return passFail(err)
	}
	fmt.Println(pub)
	if *owner {
		fmt.Fprintln(os.Stderr, "move keys/owner.age off this box and delete it")
	}
	return 0
}

func cmdKeyUnlock(args []string) int {
	if rc := refuseFlag(args); rc != 0 {
		return rc
	}
	fs := flag.NewFlagSet("key unlock", flag.ContinueOnError)
	ws := fs.String("workspace", "", "workspace uuid")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 0 || !keyd.ValidWorkspace(*ws) {
		fmt.Fprintln(os.Stderr, "spool: workspace id is not a uuid")
		return 1
	}
	dir, rc := encState()
	if rc != 0 {
		return rc
	}
	cur, err := keyd.WorkspaceOf(dir)
	if err != nil {
		return passFail(err)
	}
	if cur != *ws {
		fmt.Fprintln(os.Stderr, "spool: workspace mismatch")
		return 1
	}
	st, err := keyd.Status(dir)
	if err != nil {
		return passFail(err)
	}
	if st == "unlocked" {
		fmt.Println("unlocked")
		return 0
	}
	if err := keyd.EnvRefused(); err != nil {
		return passFail(err)
	}
	pass, err := keyd.ReadOnce()
	if err != nil {
		return passFail(err)
	}
	defer keyd.Wipe(pass)
	agents, err := keyd.LoadAgents(dir, pass)
	if err != nil {
		return passFail(err)
	}
	if err := startKeyd(dir, cur, agents); err != nil {
		return passFail(err)
	}
	fmt.Println("unlocked")
	return 0
}

func cmdKeyLock(args []string) int {
	fs := flag.NewFlagSet("key lock", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return 1
	}
	dir, rc := encState()
	if rc != 0 {
		return rc
	}
	if err := keyd.Lock(dir); err != nil {
		return passFail(err)
	}
	return 0
}

func cmdKeyStatus(args []string) int {
	fs := flag.NewFlagSet("key status", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return 1
	}
	dir, rc := encState()
	if rc != 0 {
		return rc
	}
	st, err := keyd.Status(dir)
	if err != nil {
		return passFail(err)
	}
	fmt.Println(st)
	return 0
}

func cmdKeyRotate(args []string) int {
	if rc := refuseFlag(args); rc != 0 {
		return rc
	}
	fs := flag.NewFlagSet("key rotate", flag.ContinueOnError)
	as := fs.String("as", "", "agent id")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 0 || !agentid.IsNew(*as) {
		fmt.Fprintln(os.Stderr, "spool: agent id is not valid")
		return 1
	}
	dir, rc := encState()
	if rc != 0 {
		return rc
	}
	if _, err := keyd.WorkspaceOf(dir); err != nil {
		return passFail(err)
	}
	if err := keyd.EnvRefused(); err != nil {
		return passFail(err)
	}
	pass, err := keyd.ReadOnce()
	if err != nil {
		return passFail(err)
	}
	defer keyd.Wipe(pass)
	pub, err := keyd.Rotate(dir, *as, pass)
	if err != nil {
		return passFail(err)
	}
	fmt.Println(pub)
	return 0
}

// cmdKeyd is the daemon `key unlock` starts. Identities arrive on stdin.
// A terminal is refused so a passphrase cannot be typed at this process.
func cmdKeyd(args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(os.Stderr, "usage: spool keyd")
		return 1
	}
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprintln(os.Stderr, "spool: keyd takes identities on a pipe")
		return keyd.ExitPassphrase
	}
	dir, rc := encState()
	if rc != 0 {
		return rc
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil {
		fmt.Fprintln(os.Stderr, "spool: could not read the key bundle")
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := keyd.ServeBundle(ctx, dir, raw); err != nil {
		fmt.Fprintln(os.Stderr, "spool: "+err.Error())
		return 1
	}
	return 0
}

func startKeyd(dir, workspace string, agents []keyd.AgentKey) error {
	defer keyd.WipeAgents(agents)
	raw, err := keyd.Bundle(workspace, agents)
	if err != nil {
		return err
	}
	defer keyd.Wipe(raw)
	exe, err := os.Executable()
	if err != nil {
		return errors.New("could not start keyd")
	}
	cmd := exec.Command(exe, "keyd")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Env = childEnv(dir)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return errors.New("could not start keyd")
	}
	logf, err := os.OpenFile(filepath.Join(dir, "keyd.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return errors.New("could not start keyd")
	}
	cmd.Stdout = logf
	cmd.Stderr = logf
	if err := cmd.Start(); err != nil {
		logf.Close()
		return errors.New("could not start keyd")
	}
	logf.Close()
	_, werr := stdin.Write(raw)
	keyd.Wipe(raw)
	if werr != nil {
		stdin.Close()
		cmd.Process.Kill()
		cmd.Wait()
		return errors.New("could not start keyd")
	}
	stdin.Close()
	if err := waitUnlocked(dir); err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

func childEnv(dir string) []string {
	var out []string
	for _, e := range os.Environ() {
		k, _, _ := strings.Cut(e, "=")
		switch k {
		case "SPOOL_KEY_PASSPHRASE", "PASSPHRASE", "AGE_PASSPHRASE", "SPOOL_ENC_STATE":
			continue
		default:
			out = append(out, e)
		}
	}
	return append(out, "SPOOL_ENC_STATE="+dir)
}

func waitUnlocked(dir string) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		st, err := keyd.Status(dir)
		if err == nil && st == "unlocked" {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("keyd did not unlock")
}

func encState() (string, int) {
	dir, err := keyd.StateDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "spool: "+err.Error())
		return "", 1
	}
	return dir, 0
}

func refuseFlag(argv []string) int {
	if err := keyd.FlagRefused(argv); err != nil {
		return passFail(err)
	}
	return 0
}

func passFail(err error) int {
	if err == nil {
		return 0
	}
	fmt.Fprintln(os.Stderr, "spool: "+err.Error())
	if errors.Is(err, keyd.ErrPassphrase) {
		return keyd.ExitPassphrase
	}
	return 1
}

package keyexec

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

// Exit codes of the wrapper beyond the CLI's own.
const (
	// ExitRefused: the desk refused the lease (no key, box not approved, ...).
	ExitRefused = 78
	// ExitKeyExhausted: the vendor refused the key, now or before (the desk
	// answered key_exhausted). A supervisor stops restarting the seat on it.
	ExitKeyExhausted = 79
	// ExitUsage: a bad call of the wrapper itself.
	ExitUsage = 64
)

// tailSize is how much of the CLI's stderr the classifier reads.
const tailSize = 8 << 10

// Opts is one seat start.
type Opts struct {
	Kind    string
	CLI     string   // the CLI binary
	Args    []string // its args
	Env     []string // the wrapper's environment
	SeatDir string
	Helper  string // claude's apiKeyHelper command line
	Desk    Desk
	Stdin   io.Reader
	Stdout  io.Writer
	Stderr  io.Writer
	// NoClassify turns the classifier off: the red control of spec 159 T5
	// (the seat then restarts on the dead key). Never set in a launcher.
	NoClassify bool
}

// Run starts the seat and returns the wrapper's exit code.
func Run(ctx context.Context, o Opts) int {
	if !IsKind(o.Kind) || o.CLI == "" || o.Desk == nil {
		fmt.Fprintln(o.Stderr, "usage: spool key-exec <claude|grok|agy|mistral|qwen> -- <cli> [args...]")
		return ExitUsage
	}
	// L7: a hard core limit of 0 survives execve; the CLI cannot raise it.
	if err := unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{Cur: 0, Max: 0}); err != nil {
		fmt.Fprintf(o.Stderr, "spool key-exec: core limit: %v\n", err)
		return ExitRefused
	}
	lease, rc := takeLease(ctx, o)
	if rc != 0 {
		return rc
	}
	if o.Kind == "claude" {
		lease = Lease{} // claude asks the helper; the wrapper keeps no key
	}
	seat, err := BuildSeat(SeatSpec{Kind: o.Kind, Base: o.Env, Args: o.Args, Lease: lease, SeatDir: o.SeatDir, Helper: o.Helper})
	if err != nil {
		fmt.Fprintf(o.Stderr, "spool key-exec: %v\n", err)
		return ExitRefused
	}
	exit, tail := runCLI(o, seat)
	if o.NoClassify || Classify(exit, tail) != Exhausted {
		return exit
	}
	if err := o.Desk.Exhausted(ctx, o.Kind); err != nil {
		fmt.Fprintf(o.Stderr, "spool key-exec: the %s key was refused by the vendor; the report to the desk failed: %v\n", o.Kind, err)
	} else {
		fmt.Fprintf(o.Stderr, "spool key-exec: the %s key of this workspace was refused by the vendor (out of credit or quota); reported, the seat stops\n", o.Kind)
	}
	return ExitKeyExhausted
}

// takeLease asks the desk for the kind's key: every start does, so a key
// the hub marked exhausted stops the seat here, before the CLI runs.
func takeLease(ctx context.Context, o Opts) (Lease, int) {
	l, err := o.Desk.Lease(ctx, o.Kind)
	if err == nil {
		return l, 0
	}
	var re *RefusedError
	if errors.As(err, &re) && re.Token == TokenKeyExhausted {
		fmt.Fprintf(o.Stderr, "spool key-exec: the %s key of this workspace is marked exhausted; a workspace admin or business owner replaces it on Agent keys\n", o.Kind)
		return Lease{}, ExitKeyExhausted
	}
	fmt.Fprintf(o.Stderr, "spool key-exec: no %s key for this seat: %v\n", o.Kind, err)
	return Lease{}, ExitRefused
}

// runCLI forks the CLI with the seat's environment, its stdin and stdout
// the wrapper's own (the pane's terminal) and its stderr copied through a
// tail buffer, forwards SIGTERM and SIGHUP, and returns its exit code
// (128 + signal for a killed CLI) and the tail.
func runCLI(o Opts, seat Seat) (int, []byte) {
	tail := &tailBuf{max: tailSize}
	cmd := exec.Command(o.CLI, seat.Args...) // #nosec G204 -- the seat's own CLI, no key in argv
	cmd.Env = seat.Env
	cmd.Stdin, cmd.Stdout = o.Stdin, o.Stdout
	cmd.Stderr = io.MultiWriter(o.Stderr, tail)
	sigs := make(chan os.Signal, 4)
	// SIGINT reaches the CLI from the terminal itself (one process group);
	// the wrapper only must not die of it.
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)
	defer signal.Stop(sigs)
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(o.Stderr, "spool key-exec: start %s: %v\n", o.Kind, err)
		return ExitRefused, nil
	}
	done := make(chan struct{})
	go func() {
		for {
			select {
			case s := <-sigs:
				if s != syscall.SIGINT {
					_ = cmd.Process.Signal(s)
				}
			case <-done:
				return
			}
		}
	}()
	err := cmd.Wait()
	close(done)
	return exitCode(cmd, err), tail.Bytes()
}

func exitCode(cmd *exec.Cmd, err error) int {
	if err == nil {
		return 0
	}
	if cmd.ProcessState == nil {
		return 1
	}
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	if cmd.ProcessState.ExitCode() > 0 {
		return cmd.ProcessState.ExitCode()
	}
	return 1
}

// tailBuf keeps the last max bytes written to it.
type tailBuf struct {
	mu  sync.Mutex
	max int
	b   []byte
}

func (t *tailBuf) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.b = append(t.b, p...)
	if over := len(t.b) - t.max; over > 0 {
		t.b = append([]byte(nil), t.b[over:]...)
	}
	return len(p), nil
}

func (t *tailBuf) Bytes() []byte {
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]byte(nil), t.b...)
}

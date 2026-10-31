// Package quiesce is the writer side of the desk quiesce window (spec 069
// section 8.4.1): while do_spl_desk_move copies and verifies a desk, it keeps
// a marker file beside the desk dir, <desk dir>.quiesce, and every local
// writer of that desk's spool waits for it to go before it writes.
//
// The spool root of a desk is <desk dir>/spool, so the marker of a root is
// filepath.Dir(root) + ".quiesce". A root that is no desk's spool (the box
// spool /var/spool-hub) simply has no marker. The marker counts while its
// mtime is younger than DESK_QUIESCE_MAX_SECS (default 300): a move that
// crashed cannot freeze the desk. A writer waits up to DESK_QUIESCE_WAIT_SECS
// (default 120), then refuses with ErrQuiesced.
package quiesce

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ErrQuiesced: the desk stayed quiesced for the whole wait.
var ErrQuiesced = errors.New("desk quiesced")

// ExitCode is the CLI's exit code for ErrQuiesced (EX_TEMPFAIL: retry later).
const ExitCode = 75

// Defaults of DESK_QUIESCE_MAX_SECS and DESK_QUIESCE_WAIT_SECS.
const (
	DefaultMaxSecs  = 300
	DefaultWaitSecs = 120
)

// Waiter checks and waits on the marker of one spool root. Now, Sleep and
// the limits are fields so a test drives them without a real clock.
type Waiter struct {
	Root  string
	Max   time.Duration
	Wait  time.Duration
	Every time.Duration
	Now   func() time.Time
	Sleep func(time.Duration)
	Log   io.Writer
}

// New is the Waiter of root with the limits from the environment.
func New(root string, log io.Writer) *Waiter {
	return &Waiter{
		Root:  root,
		Max:   envSecs("DESK_QUIESCE_MAX_SECS", DefaultMaxSecs),
		Wait:  envSecs("DESK_QUIESCE_WAIT_SECS", DefaultWaitSecs),
		Every: time.Second,
		Now:   time.Now,
		Sleep: time.Sleep,
		Log:   log,
	}
}

// Marker is the marker path of a spool root ("" for an empty root).
func Marker(root string) string {
	root = strings.TrimRight(root, "/")
	if root == "" {
		return ""
	}
	return filepath.Dir(root) + ".quiesce"
}

// Live reports whether the marker exists and is younger than w.Max, and its
// first line (who holds it).
func (w *Waiter) Live() (bool, string) {
	m := Marker(w.Root)
	if m == "" {
		return false, ""
	}
	st, err := os.Stat(m)
	if err != nil || st.IsDir() || w.Now().Sub(st.ModTime()) >= w.Max {
		return false, ""
	}
	raw, _ := os.ReadFile(m)
	line, _, _ := strings.Cut(string(raw), "\n")
	return true, strings.TrimSpace(line)
}

// Gate returns nil at once when the desk is not quiesced, nil after the
// marker goes when it is, and ErrQuiesced when it is still live after w.Wait.
func (w *Waiter) Gate() error {
	live, who := w.Live()
	if !live {
		return nil
	}
	if w.Log != nil {
		fmt.Fprintf(w.Log, "spool: the desk of %s is quiesced (%s): waiting up to %s\n", w.Root, who, w.Wait)
	}
	for start := w.Now(); w.Now().Sub(start) < w.Wait; {
		w.Sleep(w.Every)
		if live, who = w.Live(); !live {
			return nil
		}
	}
	return fmt.Errorf("%w: %s holds %s for more than %s; nothing was written, retry when the move is done", ErrQuiesced, who, Marker(w.Root), w.Wait)
}

// envSecs reads whole seconds from env key, else def.
func envSecs(key string, def int) time.Duration {
	if n, err := strconv.Atoi(os.Getenv(key)); err == nil && n >= 0 {
		return time.Duration(n) * time.Second
	}
	return time.Duration(def) * time.Second
}

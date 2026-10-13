// Package keyd holds an enc workspace's age keys: the scrypt store, the
// passphrase rule (spec 136 section 5, FR5) and the keyd daemon (FR6).
package keyd

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"

	"golang.org/x/term"
)

const (
	// ExitPassphrase is the CLI exit when a passphrase is refused or rejected.
	ExitPassphrase = 2
	// ExitLocked is the exit a locked recv uses (spec 136; the recv verb is a
	// later lane). LockedLine is the sentence it prints.
	ExitLocked = 5

	minPassphrase = 16
)

// ErrPassphrase is returned for every refusal and for a rejected entry.
// The text never contains the secret.
var ErrPassphrase = errors.New("passphrase refused")

// The only environment names that refuse a read. A different variable whose
// name contains PASSPHRASE is not one of them (spec 136 section 5).
var passEnv = []string{"SPOOL_KEY_PASSPHRASE", "PASSPHRASE", "AGE_PASSPHRASE"}

var passFlags = []string{"--passphrase-file", "--password-file", "--passphrase", "--password"}

// openTTY and readPassword are the production path onto /dev/tty. Tests
// replace them to prove a refusal happens before either is called.
var (
	openTTY      = func() (*os.File, error) { return os.OpenFile("/dev/tty", os.O_RDWR, 0) }
	readPassword = term.ReadPassword
)

// FlagRefused reports an argv passphrase flag. It returns the flag's name,
// never its value, and it does not parse the rest of the command line.
func FlagRefused(argv []string) error {
	for _, a := range argv {
		for _, f := range passFlags {
			if a == f || strings.HasPrefix(a, f+"=") {
				return fmt.Errorf("%w: %s", ErrPassphrase, f)
			}
		}
	}
	return nil
}

// EnvRefused reports one of the three passphrase variables being set.
// The value is not read into the error.
func EnvRefused() error {
	for _, name := range passEnv {
		if _, ok := os.LookupEnv(name); ok {
			return fmt.Errorf("%w: %s is set", ErrPassphrase, name)
		}
	}
	return nil
}

// Refuse is the check that runs before any passphrase read.
func Refuse(argv []string, stdinTTY, stdoutTTY bool) error {
	if err := EnvRefused(); err != nil {
		return err
	}
	if err := FlagRefused(argv); err != nil {
		return err
	}
	if !stdinTTY || !stdoutTTY {
		return fmt.Errorf("%w: stdin and stdout must both be a terminal", ErrPassphrase)
	}
	return nil
}

// ReadNew reads a creation passphrase from /dev/tty: two entries, at least
// 16 characters. Refuse runs first, so a refused call does not open the tty.
func ReadNew() ([]byte, error) {
	return readNew(os.Args, term.IsTerminal(int(os.Stdin.Fd())), term.IsTerminal(int(os.Stdout.Fd())))
}

// ReadOnce reads an unlock passphrase from /dev/tty, once.
func ReadOnce() ([]byte, error) {
	return readOnce(os.Args, term.IsTerminal(int(os.Stdin.Fd())), term.IsTerminal(int(os.Stdout.Fd())))
}

func readNew(argv []string, stdinTTY, stdoutTTY bool) ([]byte, error) {
	if err := Refuse(argv, stdinTTY, stdoutTTY); err != nil {
		return nil, err
	}
	a, err := readOne("new passphrase: ")
	if err != nil {
		return nil, err
	}
	b, err := readOne("again: ")
	if err != nil {
		Wipe(a)
		return nil, err
	}
	defer Wipe(b)
	if utf8.RuneCount(a) < minPassphrase || utf8.RuneCount(b) < minPassphrase {
		Wipe(a)
		return nil, fmt.Errorf("%w: at least %d characters", ErrPassphrase, minPassphrase)
	}
	if subtle.ConstantTimeCompare(a, b) != 1 {
		Wipe(a)
		return nil, fmt.Errorf("%w: entries differ", ErrPassphrase)
	}
	return a, nil
}

func readOnce(argv []string, stdinTTY, stdoutTTY bool) ([]byte, error) {
	if err := Refuse(argv, stdinTTY, stdoutTTY); err != nil {
		return nil, err
	}
	a, err := readOne("passphrase: ")
	if err != nil {
		return nil, err
	}
	if utf8.RuneCount(a) < minPassphrase {
		Wipe(a)
		return nil, fmt.Errorf("%w: at least %d characters", ErrPassphrase, minPassphrase)
	}
	return a, nil
}

func readOne(prompt string) ([]byte, error) {
	tty, err := openTTY()
	if err != nil {
		return nil, fmt.Errorf("%w: could not read", ErrPassphrase)
	}
	defer tty.Close()
	if _, err := io.WriteString(tty, prompt); err != nil {
		return nil, fmt.Errorf("%w: could not read", ErrPassphrase)
	}
	pw, err := readPassword(int(tty.Fd()))
	_, _ = io.WriteString(tty, "\n")
	if err != nil {
		Wipe(pw)
		return nil, fmt.Errorf("%w: could not read", ErrPassphrase)
	}
	return pw, nil
}

// Wipe zeroes a secret buffer.
func Wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

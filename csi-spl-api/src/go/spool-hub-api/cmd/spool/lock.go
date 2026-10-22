package main

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/keyd"
	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// spool lock: the box side of the box owner lock (spec 025 box-owner-lock.md
// section 4, row B4). Every command that takes the lock secret or the
// recovery code reads it from the terminal, never from argv or the
// environment (keyd's passphrase rule).

const lockUsage = `usage: spool lock seal                       seal this box: new lock key, box key sealed, recovery code printed once
       spool lock unlock                     type the secret; the sealed holder opens the keys
       spool lock serve                      the sealed holder (started by unlock)
       spool lock status                     not-sealed | sealed | unlocked
       spool lock reseal [--recovery]        set a new secret (with the old secret, or the recovery code)
       spool lock rotate-recovery            replace the recovery code
       spool lock rebind --version <n> --owners <HUM-..>[,..] [--peer-boxes <box>[,..]] [--hide-posts=false]
                                             new box key, signed change of box_pubkey (6.2)
       spool lock sign --file <path>         sign a lock body or lift statement with the lock key
       spool lock create --owners <HUM-..>[,..] [--peer-boxes <box>[,..]] [--hide-posts=false]
                                             the signed lock-create body (6.1) for POST /v1/boxes/<box>/lock
`

// Seams for tests: the terminal readers, the KDF cost and the holder start.
var (
	lockReadNew     = keyd.ReadNew
	lockReadOnce    = keyd.ReadOnce
	lockParams      = lockkey.DefaultParams
	lockStartHolder = startLockHolder
)

func cmdLock(cfg *config.Config, args []string) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(os.Stderr, lockUsage)
		if len(args) == 0 {
			return 1
		}
		return 0
	}
	if rc := refuseFlag(args); rc != 0 {
		return rc
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "seal":
		return cmdLockSeal(cfg, rest)
	case "unlock":
		return cmdLockUnlock(cfg, rest)
	case "serve":
		return cmdLockServe(cfg, rest)
	case "status":
		return cmdLockStatus(cfg, rest)
	case "reseal":
		return cmdLockReseal(cfg, rest)
	case "rotate-recovery":
		return cmdLockRotateRecovery(cfg, rest)
	case "rebind":
		return cmdLockRebind(cfg, rest)
	case "sign":
		return cmdLockSign(cfg, rest)
	case "create":
		return cmdLockCreate(cfg, rest)
	}
	fmt.Fprintf(os.Stderr, "unknown lock command %q\n", sub)
	return 1
}

func noArgs(name string, args []string) bool {
	fs := flag.NewFlagSet("lock "+name, flag.ContinueOnError)
	return fs.Parse(args) == nil && fs.NArg() == 0
}

func cmdLockSeal(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lock seal", flag.ContinueOnError)
	box := fs.String("box", cfg.BoxID, "box id (default $SPOOL_BOX_ID)")
	tenant := fs.String("tenant", "", "workspace id (default $SPOOL_TENANT / the hub url)")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return 1
	}
	if *tenant == "" {
		*tenant = cfg.TenantID()
	}
	if !msg.ValidBoxID(*box) || !msg.ValidTenantID(*tenant) {
		return fail(errors.New("lock seal needs a valid box id (--box or $SPOOL_BOX_ID) and workspace id (--tenant or $SPOOL_TENANT)"))
	}
	if err := cfg.CheckKeysDir(); err != nil {
		return fail(err)
	}
	if lockkey.IsSealed(cfg.KeysDir, *box) {
		return fail(errors.New("this box is already sealed (use spool lock reseal)"))
	}
	secret, err := lockReadNew()
	if err != nil {
		return passFail(err)
	}
	defer keyd.Wipe(secret)
	res, err := lockkey.Seal(cfg.KeysDir, *tenant, *box, secret, lockParams)
	if err != nil {
		return fail(err)
	}
	fmt.Printf("sealed box %s (workspace %s)\nlock_pubkey %s\nbox_pubkey  %s\n", res.Meta.Box, res.Meta.Tenant, res.Meta.LockPubkey, res.Meta.BoxPubkey)
	fmt.Printf("RECOVERY CODE (shown once; write it down off this machine, never store it on a box):\n  %s\n", res.RecoveryCode)
	fmt.Fprintln(os.Stderr, "the box stays offline until 'spool lock unlock'")
	return 0
}

func cmdLockUnlock(cfg *config.Config, args []string) int {
	if !noArgs("unlock", args) {
		return 1
	}
	if _, err := lockkey.ReadMeta(cfg.KeysDir); err != nil {
		return fail(err)
	}
	if st, _, err := lockkey.HolderStatus(cfg.KeysDir); err == nil && st == "unlocked" {
		fmt.Println("unlocked")
		return 0
	}
	if err := keyd.EnvRefused(); err != nil {
		return passFail(err)
	}
	secret, err := lockReadOnce()
	if err != nil {
		return passFail(err)
	}
	defer keyd.Wipe(secret)
	if !lockkey.HolderAlive(cfg.KeysDir) {
		if err := lockStartHolder(cfg.KeysDir); err != nil {
			return fail(err)
		}
	}
	if err := lockkey.HolderUnlock(cfg.KeysDir, secret); err != nil {
		return fail(err)
	}
	fmt.Println("unlocked")
	return 0
}

// cmdLockServe is the sealed holder: no key until `lock unlock` sends the
// secret over its 0600 socket. A terminal is refused, so nothing is typed here.
func cmdLockServe(cfg *config.Config, args []string) int {
	if !noArgs("serve", args) {
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	h := &lockkey.Holder{KeysDir: cfg.KeysDir, Backoff: 60 * time.Second}
	if err := h.Serve(ctx); err != nil {
		return fail(err)
	}
	return 0
}

func cmdLockStatus(cfg *config.Config, args []string) int {
	if !noArgs("status", args) {
		return 1
	}
	if _, err := lockkey.ReadMeta(cfg.KeysDir); errors.Is(err, lockkey.ErrNotSealed) {
		fmt.Println("not-sealed")
		return 0
	} else if err != nil {
		return fail(err)
	}
	st, held, err := lockkey.HolderStatus(cfg.KeysDir)
	if errors.Is(err, lockkey.ErrNotRunning) {
		fmt.Println("sealed")
		return 0
	}
	if err != nil {
		return fail(err)
	}
	if st == "unlocked" && !held {
		st += " (lock key dropped)"
	}
	fmt.Println(st)
	return 0
}

// openWith opens the keys with the secret, or K_lock alone with the recovery
// code. The returned secret is nil on the recovery path.
func openWith(cfg *config.Config, recovery bool) (lockkey.Keys, []byte, error) {
	if recovery {
		fmt.Fprintln(os.Stderr, "type the RECOVERY CODE at the prompt")
		code, err := lockReadOnce()
		if err != nil {
			return lockkey.Keys{}, nil, err
		}
		defer keyd.Wipe(code)
		raw, err := lockkey.ParseRecoveryCode(string(code))
		if err != nil {
			return lockkey.Keys{}, nil, err
		}
		defer keyd.Wipe(raw)
		m, lock, err := lockkey.OpenLockByRecovery(cfg.KeysDir, raw)
		return lockkey.Keys{Meta: m, Lock: lock}, nil, err
	}
	secret, err := lockReadOnce()
	if err != nil {
		return lockkey.Keys{}, nil, err
	}
	k, err := lockkey.Unseal(cfg.KeysDir, secret)
	if err != nil {
		keyd.Wipe(secret)
		return lockkey.Keys{}, nil, err
	}
	return k, secret, nil
}

func cmdLockReseal(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lock reseal", flag.ContinueOnError)
	recovery := fs.Bool("recovery", false, "open with the recovery code (the box key is then replaced: rebind it)")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return 1
	}
	k, old, err := openWith(cfg, *recovery)
	if err != nil {
		return passFail(err)
	}
	defer k.Wipe()
	keyd.Wipe(old)
	fmt.Fprintln(os.Stderr, "now the NEW lock secret")
	secret, err := lockReadNew()
	if err != nil {
		return passFail(err)
	}
	defer keyd.Wipe(secret)
	before := k.Meta.BoxPubkey
	m, err := lockkey.Reseal(cfg.KeysDir, k, secret, lockParams)
	if err != nil {
		return fail(err)
	}
	fmt.Println("resealed")
	if m.BoxPubkey != before {
		fmt.Printf("NEW box_pubkey %s: the old box key was sealed under the lost secret.\n"+
			"The hub accepts it only after 'spool lock rebind'.\n", m.BoxPubkey)
	}
	_ = lockkey.HolderSeal(cfg.KeysDir) // a running holder keeps no key from before
	return 0
}

func cmdLockRotateRecovery(cfg *config.Config, args []string) int {
	if !noArgs("rotate-recovery", args) {
		return 1
	}
	k, secret, err := openWith(cfg, false)
	if err != nil {
		return passFail(err)
	}
	defer k.Wipe()
	keyd.Wipe(secret)
	code, err := lockkey.RotateRecovery(cfg.KeysDir, k, lockParams)
	if err != nil {
		return fail(err)
	}
	fmt.Printf("NEW RECOVERY CODE (shown once; the old one no longer opens anything):\n  %s\n", code)
	return 0
}

type lockFlags struct {
	owners, peers *string
	hide          *bool
}

func addLockFlags(fs *flag.FlagSet) lockFlags {
	return lockFlags{
		owners: fs.String("owners", "", "comma-separated HUM-* owners"),
		peers:  fs.String("peer-boxes", "", "comma-separated peer box ids (default none)"),
		hide:   fs.Bool("hide-posts", true, "hide this box's posts from non-owners (OQ-1)"),
	}
}

func (f lockFlags) body(m lockkey.Meta, version int64) (lockkey.Body, error) {
	owners := splitList(*f.owners)
	if len(owners) == 0 {
		return lockkey.Body{}, errors.New("--owners needs at least one HUM-* id")
	}
	for _, o := range owners {
		if !strings.HasPrefix(o, "HUM-") {
			return lockkey.Body{}, fmt.Errorf("owner %q is not a HUM-* id", o)
		}
	}
	peers := splitList(*f.peers)
	for _, p := range peers {
		if !msg.ValidBoxID(p) || p == m.Box {
			return lockkey.Body{}, fmt.Errorf("peer box %q is not another valid box id", p)
		}
	}
	return lockkey.Body{TenantID: m.Tenant, BoxID: m.Box, LockPubkey: m.LockPubkey, BoxPubkey: m.BoxPubkey,
		Owners: owners, PeerBoxes: peers, HidePosts: *f.hide, Version: version}, nil
}

// signedLock is what create and rebind print: the body for the route of
// row B2 (6.2), carried by the owner's WUI session.
type signedLock struct {
	SignedBody   string `json:"signed_body"`
	Signature    string `json:"signature"`
	BoxSignature string `json:"box_signature,omitempty"`
}

func printSigned(b lockkey.Body, lock, box ed25519.PrivateKey) int {
	cb, err := b.Canonical()
	if err != nil {
		return fail(err)
	}
	out := signedLock{SignedBody: string(cb), Signature: lockkey.SignB64(lock, cb)}
	if box != nil {
		out.BoxSignature = lockkey.SignB64(box, cb)
	}
	j, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(j))
	return 0
}

func cmdLockCreate(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lock create", flag.ContinueOnError)
	lf := addLockFlags(fs)
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return 1
	}
	m, err := lockkey.ReadMeta(cfg.KeysDir)
	if err != nil {
		return fail(err)
	}
	b, err := lf.body(m, 1)
	if err != nil {
		return fail(err)
	}
	k, secret, err := openWith(cfg, false)
	if err != nil {
		return passFail(err)
	}
	defer k.Wipe()
	keyd.Wipe(secret)
	return printSigned(b, k.Lock, k.Box)
}

func cmdLockRebind(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lock rebind", flag.ContinueOnError)
	lf := addLockFlags(fs)
	version := fs.Int64("version", 0, "the lock row's NEW version (current + 1)")
	recovery := fs.Bool("recovery", false, "open with the recovery code, then set a new secret")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		return 1
	}
	if *version < 2 {
		return fail(errors.New("--version is the new version, current + 1 (at least 2)"))
	}
	m, err := lockkey.ReadMeta(cfg.KeysDir)
	if err != nil {
		return fail(err)
	}
	if _, err := lf.body(m, *version); err != nil {
		return fail(err)
	}
	k, secret, err := openWith(cfg, *recovery)
	if err != nil {
		return passFail(err)
	}
	defer k.Wipe()
	if secret == nil {
		fmt.Fprintln(os.Stderr, "now the NEW lock secret")
		if secret, err = lockReadNew(); err != nil {
			return passFail(err)
		}
	}
	defer keyd.Wipe(secret)
	keyd.Wipe(k.Box)
	k.Box = nil // Reseal makes the new box key
	nm, err := lockkey.Reseal(cfg.KeysDir, k, secret, lockParams)
	if err != nil {
		return fail(err)
	}
	b, err := lf.body(nm, *version)
	if err != nil {
		return fail(err)
	}
	_ = lockkey.HolderSeal(cfg.KeysDir)
	return printSigned(b, k.Lock, nil)
}

// cmdLockSign signs a file's exact bytes (one trailing newline dropped) with
// K_lock. An unlock-proof payload is refused: only the holder signs those,
// for a hub nonce.
func cmdLockSign(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("lock sign", flag.ContinueOnError)
	path := fs.String("file", "", "the body to sign (stdin is the terminal the secret is typed on)")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || *path == "" {
		fmt.Fprint(os.Stderr, lockUsage)
		return 1
	}
	raw, err := os.ReadFile(*path)
	if err != nil {
		return fail(err)
	}
	body := []byte(strings.TrimSuffix(string(raw), "\n"))
	if len(body) == 0 || len(body) > 64<<10 {
		return fail(errors.New("the body is empty or larger than 64 KiB"))
	}
	if strings.HasPrefix(string(body), "spool-unlock-v1") {
		return fail(errors.New("an unlock-proof payload is signed only by the holder"))
	}
	k, secret, err := openWith(cfg, false)
	if err != nil {
		return passFail(err)
	}
	defer k.Wipe()
	keyd.Wipe(secret)
	fmt.Println(lockkey.SignB64(k.Lock, body))
	return 0
}

// startLockHolder starts `spool lock serve` detached, logging to
// <keys>/lock/lockd.log, and waits for its socket.
func startLockHolder(keysDir string) error {
	exe, err := os.Executable()
	if err != nil {
		return errors.New("could not start the lock holder")
	}
	cmd := exec.Command(exe, "lock", "serve")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	var env []string
	for _, e := range os.Environ() {
		switch k, _, _ := strings.Cut(e, "="); k {
		case "SPOOL_KEY_PASSPHRASE", "PASSPHRASE", "AGE_PASSPHRASE", "SPOOL_KEYS_DIR":
		default:
			env = append(env, e)
		}
	}
	cmd.Env = append(env, "SPOOL_KEYS_DIR="+keysDir)
	logf, err := os.OpenFile(filepath.Join(lockkey.LockDir(keysDir), "lockd.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return errors.New("could not start the lock holder")
	}
	cmd.Stdout, cmd.Stderr = logf, logf
	err = cmd.Start()
	logf.Close()
	if err != nil {
		return errors.New("could not start the lock holder")
	}
	go func() { _ = cmd.Wait() }()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, _, err := lockkey.HolderStatus(keysDir); err == nil {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("the lock holder did not start (see lock/lockd.log)")
}

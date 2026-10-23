package lockkey

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"math"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The sealed holder (4.3): a process of the box OS user that starts with no
// usable key and takes the lock secret only over a 0600 unix socket, from
// `spool lock unlock`. Unlocked, it holds K_box (signs for the box) and K_lock
// until DropLock (4.4 step 3: after the hub's unlock ticket). A wrong secret
// leaves it sealed; after 5 failures each try waits Backoff (60 s).

const (
	sockName = "lockd.sock"
	pidName  = "lockd.pid"
	maxReq   = 8 << 10
	// MaxFailures is the count of wrong secrets after which tries are spaced.
	MaxFailures = 5
)

// Holder is the in-memory state of the sealed holder.
type Holder struct {
	KeysDir string
	// Backoff is the wait per try after MaxFailures wrong secrets (60 s).
	Backoff time.Duration
	// Unseal opens the keys; Unseal (the package function) unless a test sets it.
	Unseal func(keysDir string, secret []byte) (Keys, error)

	mu       sync.Mutex
	keys     *Keys
	failures int
	lastTry  time.Time
}

type request struct {
	Op     string `json:"op"`
	Secret []byte `json:"secret,omitempty"`
	Nonce  string `json:"nonce,omitempty"`
	BootID string `json:"boot_id,omitempty"`
	TS     string `json:"ts,omitempty"`
}

type response struct {
	OK       bool   `json:"ok"`
	State    string `json:"state,omitempty"`
	LockHeld bool   `json:"lock_held,omitempty"`
	Seed     []byte `json:"seed,omitempty"`
	BoxPub   string `json:"box_pubkey,omitempty"`
	Sig      string `json:"sig,omitempty"`
	Error    string `json:"error,omitempty"`
}

// handle answers one request. The secret is wiped before it returns.
func (h *Holder) handle(req request) response {
	defer Wipe(req.Secret)
	h.mu.Lock()
	defer h.mu.Unlock()
	switch req.Op {
	case "status":
		if h.keys == nil {
			return response{OK: true, State: "sealed"}
		}
		return response{OK: true, State: "unlocked", LockHeld: h.keys.Lock != nil}
	case "unlock":
		return h.unlock(req.Secret)
	case "boxkey":
		if h.keys == nil {
			return response{Error: ErrSealed.Error()}
		}
		return response{OK: true, Seed: h.keys.Box.Seed(), BoxPub: h.keys.Meta.BoxPubkey}
	case "proof":
		if h.keys == nil {
			return response{Error: ErrSealed.Error()}
		}
		if h.keys.Lock == nil {
			return response{Error: "the lock key was dropped: the owner runs 'spool lock unlock' again"}
		}
		m := h.keys.Meta
		p := ProofPayload(m.Tenant, m.Box, req.Nonce, req.BootID, m.BoxPubkey, req.TS)
		return response{OK: true, Sig: SignB64(h.keys.Lock, p), BoxPub: m.BoxPubkey}
	case "drop-lock":
		if h.keys != nil {
			Wipe(h.keys.Lock)
			h.keys.Lock = nil
		}
		return response{OK: true}
	case "seal":
		if h.keys != nil {
			h.keys.Wipe()
			h.keys = nil
		}
		return response{OK: true, State: "sealed"}
	}
	return response{Error: "unknown op"}
}

// unlock opens the keys with the secret. An unlocked holder that still has
// K_lock answers as is; one whose K_lock was dropped (after a ticket, 4.4
// step 3) opens the files again, so the owner can prove the unlock once the
// ticket has expired without restarting the holder (row B9).
func (h *Holder) unlock(secret []byte) response {
	if h.keys != nil && h.keys.Lock != nil {
		return response{OK: true, State: "unlocked", LockHeld: true}
	}
	if h.failures >= MaxFailures && time.Since(h.lastTry) < h.Backoff {
		return response{Error: "too many wrong secrets: wait " + h.Backoff.String() + " between tries"}
	}
	h.lastTry = time.Now()
	open := h.Unseal
	if open == nil {
		open = Unseal
	}
	k, err := open(h.KeysDir, secret)
	if err != nil {
		h.failures++
		// The log line names the failure, never the secret.
		os.Stderr.WriteString("lockd: unlock refused (" + strconv.Itoa(h.failures) + " failures): " + err.Error() + "\n")
		return response{Error: err.Error()}
	}
	h.failures = 0
	if h.keys != nil {
		h.keys.Wipe()
	}
	h.keys = &k
	return response{OK: true, State: "unlocked", LockHeld: true}
}

// Serve listens on <keys>/lock/lockd.sock until ctx is done, then wipes the keys.
// Each peer's uid must be this process's uid; it is checked before a request
// is read.
func (h *Holder) Serve(ctx context.Context) error {
	if _, err := ReadMeta(h.KeysDir); err != nil {
		return err
	}
	if err := harden(); err != nil {
		return err
	}
	dir := LockDir(h.KeysDir)
	sock, pidPath := filepath.Join(dir, sockName), filepath.Join(dir, pidName)
	if pidAlive(readPID(pidPath)) {
		return errors.New("lockd already running")
	}
	os.Remove(sock)
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		return err
	}
	old := syscall.Umask(0o177)
	ln, err := net.Listen("unix", sock)
	syscall.Umask(old)
	if err != nil {
		os.Remove(pidPath)
		return err
	}
	if err := os.Chmod(sock, 0o600); err != nil {
		ln.Close()
		return err
	}
	defer func() {
		ln.Close()
		os.Remove(sock)
		os.Remove(pidPath)
		h.mu.Lock()
		if h.keys != nil {
			h.keys.Wipe()
			h.keys = nil
		}
		h.mu.Unlock()
	}()
	go func() { <-ctx.Done(); ln.Close() }()
	uid := os.Getuid()
	if uid < 0 || uid > math.MaxUint32 {
		return errors.New("lockd: this process has no uid")
	}
	me := uint32(uid)
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go h.serveConn(conn, me)
	}
}

func (h *Holder) serveConn(conn net.Conn, me uint32) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if uid, err := peerUID(conn); err != nil || uid != me {
		return
	}
	line, err := bufio.NewReader(&limited{conn, maxReq}).ReadBytes('\n')
	if err != nil {
		return
	}
	var req request
	if err := json.Unmarshal(line, &req); err != nil {
		Wipe(line)
		return
	}
	Wipe(line)
	resp := h.handle(req)
	b, _ := json.Marshal(resp)
	Wipe(resp.Seed)
	_, _ = conn.Write(append(b, '\n'))
	Wipe(b)
}

type limited struct {
	c net.Conn
	n int
}

func (l *limited) Read(p []byte) (int, error) {
	if l.n <= 0 {
		return 0, errors.New("request too large")
	}
	if len(p) > l.n {
		p = p[:l.n]
	}
	n, err := l.c.Read(p)
	l.n -= n
	return n, err
}

// ---- client ----------------------------------------------------------------------

func call(keysDir string, req request) (response, error) {
	defer Wipe(req.Secret)
	conn, err := net.DialTimeout("unix", filepath.Join(LockDir(keysDir), sockName), 2*time.Second)
	if err != nil {
		return response{}, ErrNotRunning
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	b, err := json.Marshal(req)
	if err != nil {
		return response{}, err
	}
	_, err = conn.Write(append(b, '\n'))
	Wipe(b)
	if err != nil {
		return response{}, err
	}
	line, err := bufio.NewReader(&limited{conn, 1 << 16}).ReadBytes('\n')
	if err != nil {
		return response{}, errors.New("lockd closed the connection")
	}
	var resp response
	err = json.Unmarshal(line, &resp)
	Wipe(line)
	if err != nil {
		return response{}, err
	}
	if !resp.OK {
		if resp.Error == ErrSealed.Error() {
			return resp, ErrSealed
		}
		return resp, errors.New(resp.Error)
	}
	return resp, nil
}

// ErrNotRunning means no sealed holder answers on this box.
var ErrNotRunning = errors.New("no lockd runs on this box")

// HolderStatus is "sealed" or "unlocked", and whether K_lock is still held.
func HolderStatus(keysDir string) (string, bool, error) {
	r, err := call(keysDir, request{Op: "status"})
	return r.State, r.LockHeld, err
}

// HolderUnlock passes the secret to the holder. The caller wipes its copy.
func HolderUnlock(keysDir string, secret []byte) error {
	_, err := call(keysDir, request{Op: "unlock", Secret: append([]byte(nil), secret...)})
	return err
}

// HolderBoxKey is K_box from an unlocked holder; ErrSealed when it is sealed
// or not running.
func HolderBoxKey(keysDir string) (ed25519.PrivateKey, error) {
	r, err := call(keysDir, request{Op: "boxkey"})
	if errors.Is(err, ErrNotRunning) {
		return nil, ErrSealed
	}
	if err != nil {
		return nil, err
	}
	defer Wipe(r.Seed)
	if len(r.Seed) != ed25519.SeedSize {
		return nil, errors.New("lockd sent a malformed box key")
	}
	return ed25519.NewKeyFromSeed(r.Seed), nil
}

// HolderProof is the unlock proof (4.4 step 1), signed by K_lock in the holder.
func HolderProof(keysDir, hubNonce, bootID, ts string) (sig, boxPub string, err error) {
	r, err := call(keysDir, request{Op: "proof", Nonce: hubNonce, BootID: bootID, TS: ts})
	return r.Sig, r.BoxPub, err
}

// HolderDropLock wipes K_lock in the holder (4.4 step 3).
func HolderDropLock(keysDir string) error {
	_, err := call(keysDir, request{Op: "drop-lock"})
	return err
}

// HolderSeal wipes both keys in the holder; it keeps running, sealed.
func HolderSeal(keysDir string) error {
	_, err := call(keysDir, request{Op: "seal"})
	return err
}

// HolderAlive reports a live lockd pid for keysDir.
func HolderAlive(keysDir string) bool {
	return pidAlive(readPID(filepath.Join(LockDir(keysDir), pidName)))
}

func readPID(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

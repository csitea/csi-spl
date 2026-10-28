package keyd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"filippo.io/age"
	"golang.org/x/sys/unix"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

const maxReq = 2 << 20

// ErrLocked means keyd is not holding identities.
var ErrLocked = errors.New("locked")

// LockedLine is the sentence a locked recv prints (spec 136 section 4).
func LockedLine(ws string) string {
	return "LOCKED: the owner runs 'spool key unlock --workspace " + ws + "' on his terminal"
}

type request struct {
	Op string `json:"op"`
	As string `json:"as,omitempty"`
	CT string `json:"ct,omitempty"`
}

type response struct {
	OK        bool   `json:"ok"`
	State     string `json:"state,omitempty"`
	Workspace string `json:"workspace,omitempty"`
	Error     string `json:"error,omitempty"`
	Plain     string `json:"plain,omitempty"`
}

type wireBundle struct {
	V         int        `json:"v"`
	Workspace string     `json:"workspace"`
	Agents    []AgentKey `json:"agents"`
}

type secret struct {
	id  string
	raw []byte
}

// Bundle is the one-shot stdin of `spool keyd`: identities already opened,
// so the passphrase never crosses the pipe.
func Bundle(workspace string, agents []AgentKey) ([]byte, error) {
	return json.Marshal(wireBundle{V: 1, Workspace: workspace, Agents: agents})
}

// ServeBundle reads that stdin and serves until lock or ctx is done.
// The caller's buffer is wiped as soon as it has been parsed, so the clear
// bundle does not sit in swappable memory for the life of the daemon.
func ServeBundle(ctx context.Context, dir string, raw []byte) error {
	var b wireBundle
	err := json.Unmarshal(raw, &b)
	Wipe(raw)
	if err != nil || b.V != 1 {
		WipeAgents(b.Agents)
		return errors.New("bad key bundle")
	}
	ws, err := WorkspaceOf(dir)
	if err != nil {
		WipeAgents(b.Agents)
		return err
	}
	if b.Workspace != ws {
		WipeAgents(b.Agents)
		return errors.New("workspace mismatch")
	}
	return Serve(ctx, dir, ws, b.Agents)
}

// Serve listens on keyd.sock. Peer credentials are checked before a request
// body is read. Lock, or a cancelled ctx, wipes the identities and exits.
func Serve(ctx context.Context, dir, workspace string, agents []AgentKey) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := harden(); err != nil {
		return err
	}
	secs, err := lockIdentities(agents)
	if err != nil {
		return err
	}
	sock := filepath.Join(dir, "keyd.sock")
	pidPath := filepath.Join(dir, "keyd.pid")
	ln, err := listenSock(sock, pidPath)
	if err != nil {
		wipeSecrets(secs)
		return err
	}
	serveConns(ctx, ln, sock, pidPath, workspace, secs)
	return nil
}

// Test seams for lockIdentities: a test swaps them to force the mlock
// failure and to see the secrets an error path wipes.
var (
	mlock         = unix.Mlock
	wipeOnLockErr = wipeSecrets
)

// lockIdentities moves each identity into mlocked memory and wipes the
// caller's copy; on an error it wipes what it already locked.
func lockIdentities(agents []AgentKey) ([]secret, error) {
	secs := make([]secret, 0, len(agents))
	for i := range agents {
		raw := make([]byte, len(agents[i].Identity))
		copy(raw, agents[i].Identity)
		wipeString(agents[i].Identity)
		agents[i].Identity = ""
		if len(raw) == 0 {
			wipeOnLockErr(secs)
			return nil, errors.New("empty identity")
		}
		if err := mlock(raw); err != nil {
			Wipe(raw)
			wipeOnLockErr(secs)
			return nil, errors.New("could not lock the identities in memory")
		}
		secs = append(secs, secret{id: agents[i].ID, raw: raw})
	}
	return secs, nil
}

// listenSock clears a stale daemon, writes the pid file and binds sock 0600.
func listenSock(sock, pidPath string) (net.Listener, error) {
	if err := clearStale(sock, pidPath); err != nil {
		return nil, err
	}
	// The pid goes first: a Status dial between bind and listen is refused,
	// and without a live pid Status would remove the socket being started.
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0644); err != nil {
		return nil, errors.New("could not listen for keyd")
	}
	// 0177 makes the new socket 0600 before any peer can connect. Chmod
	// repeats it in case the platform ignores the umask on a unix socket.
	oldMask := unix.Umask(0o177)
	ln, err := net.Listen("unix", sock)
	unix.Umask(oldMask)
	if err != nil {
		os.Remove(pidPath)
		return nil, errors.New("could not listen for keyd")
	}
	if err := os.Chmod(sock, 0600); err != nil {
		ln.Close()
		os.Remove(sock)
		os.Remove(pidPath)
		return nil, errors.New("could not listen for keyd")
	}
	return ln, nil
}

// serveConns answers requests until Lock or ctx, then wipes and cleans up.
func serveConns(ctx context.Context, ln net.Listener, sock, pidPath, workspace string, secs []secret) {
	var once sync.Once
	shutdown := func() {
		once.Do(func() {
			wipeSecrets(secs)
			ln.Close()
			os.Remove(sock)
			os.Remove(pidPath)
		})
	}
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			shutdown()
			return
		}
		if handle(conn, workspace, secs) {
			shutdown()
			return
		}
	}
}

func handle(conn net.Conn, workspace string, secs []secret) (stop bool) {
	defer conn.Close()
	uid, err := peerUID(conn)
	// int64 so a uid is not narrowed. A negative Getuid matches nothing.
	if err != nil || int64(uid) != int64(os.Getuid()) {
		_ = writeResp(conn, response{OK: false, Error: "peer uid refused"})
		return false
	}
	req, err := readReq(conn)
	if err != nil {
		_ = writeResp(conn, response{OK: false, Error: "bad request"})
		return false
	}
	switch req.Op {
	case "status":
		_ = writeResp(conn, response{OK: true, State: "unlocked", Workspace: workspace})
	case "lock":
		_ = writeResp(conn, response{OK: true, State: "locked", Workspace: workspace})
		return true
	case "open":
		ct, err := base64.StdEncoding.DecodeString(req.CT)
		if err != nil {
			_ = writeResp(conn, response{OK: false, Error: "bad request"})
			return false
		}
		plain, err := openFor(secs, req.As, ct)
		Wipe(ct)
		if err != nil {
			_ = writeResp(conn, response{OK: false, Error: err.Error()})
			return false
		}
		_ = writeResp(conn, response{OK: true, Plain: base64.StdEncoding.EncodeToString(plain)})
		Wipe(plain)
	default:
		_ = writeResp(conn, response{OK: false, Error: "bad request"})
	}
	return false
}

func openFor(secs []secret, as string, ct []byte) ([]byte, error) {
	if !agentid.IsNew(as) {
		return nil, errors.New("agent id is not valid")
	}
	ids := make([]age.Identity, 0, 2)
	for _, s := range secs {
		if s.id != as {
			continue
		}
		id, err := age.ParseX25519Identity(string(s.raw))
		if err != nil {
			return nil, errors.New("could not use the agent key")
		}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, errors.New("no identity for that agent")
	}
	r, err := age.Decrypt(bytes.NewReader(ct), ids...)
	if err != nil {
		return nil, errors.New("not a recipient of this sealed message")
	}
	plain, err := io.ReadAll(io.LimitReader(r, 1<<20+1))
	if err != nil || len(plain) > 1<<20 {
		Wipe(plain)
		return nil, errors.New("not a recipient of this sealed message")
	}
	return plain, nil
}

// Status reports "unlocked" or "locked". A dead daemon is locked, and its
// socket is removed. A live daemon that refuses the peer is an error.
func Status(dir string) (string, error) {
	resp, err := call(dir, request{Op: "status"})
	if err != nil {
		if daemonAlive(dir) {
			return "", errors.New("keyd is running but not accepting")
		}
		// Only a refused dial names a stale socket. After a dial that found
		// none, a remove could take the socket of a keyd that started since.
		if errors.Is(err, unix.ECONNREFUSED) {
			os.Remove(filepath.Join(dir, "keyd.sock"))
		}
		return "locked", nil
	}
	if !resp.OK {
		if resp.Error == "" {
			return "", errors.New("bad status")
		}
		return "", errors.New(resp.Error)
	}
	if resp.State != "unlocked" && resp.State != "locked" {
		return "", errors.New("bad status")
	}
	return resp.State, nil
}

// Lock asks the daemon to wipe and exit. A daemon that is already gone is
// a successful lock.
func Lock(dir string) error {
	resp, err := call(dir, request{Op: "lock"})
	if err != nil {
		if daemonAlive(dir) {
			return errors.New("keyd is running but not accepting")
		}
		os.Remove(filepath.Join(dir, "keyd.sock"))
		return nil
	}
	if !resp.OK {
		return errors.New("could not lock")
	}
	deadline := time.Now().Add(2 * time.Second)
	for daemonAlive(dir) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	return nil
}

// Open asks keyd to open ct with the identities of as, newest first.
func Open(dir, as string, ct []byte) ([]byte, error) {
	resp, err := call(dir, request{Op: "open", As: as, CT: base64.StdEncoding.EncodeToString(ct)})
	if err != nil {
		if daemonAlive(dir) {
			return nil, errors.New("keyd is running but not accepting")
		}
		return nil, ErrLocked
	}
	if !resp.OK {
		return nil, errors.New(resp.Error)
	}
	plain, err := base64.StdEncoding.DecodeString(resp.Plain)
	if err != nil {
		return nil, errors.New("bad response")
	}
	return plain, nil
}

func call(dir string, req request) (response, error) {
	conn, err := net.DialTimeout("unix", filepath.Join(dir, "keyd.sock"), 2*time.Second)
	if err != nil {
		return response{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if err := writeReq(conn, req); err != nil {
		return response{}, err
	}
	return readResp(conn)
}

func writeReq(w io.Writer, req request) error {
	b, err := json.Marshal(req)
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

func writeResp(w io.Writer, resp response) error {
	b, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

func readReq(r io.Reader) (request, error) {
	b, err := readLine(r)
	if err != nil {
		return request{}, err
	}
	var req request
	if err := json.Unmarshal(b, &req); err != nil {
		return request{}, errors.New("bad request")
	}
	return req, nil
}

func readResp(r io.Reader) (response, error) {
	b, err := readLine(r)
	if err != nil {
		return response{}, err
	}
	var resp response
	if err := json.Unmarshal(b, &resp); err != nil {
		return response{}, errors.New("bad response")
	}
	return resp, nil
}

func readLine(r io.Reader) ([]byte, error) {
	sc := bufio.NewScanner(io.LimitReader(r, maxReq))
	sc.Buffer(make([]byte, 0, 4096), maxReq)
	if !sc.Scan() {
		return nil, errors.New("bad request")
	}
	return append([]byte(nil), sc.Bytes()...), nil
}

// peerUID is the uid of the process at the other end of a unix socket.
// The per-OS read is sockPeerUID (keyd_linux.go, keyd_darwin.go,
// keyd_other.go); an OS with none refuses every peer.
func peerUID(conn net.Conn) (uint32, error) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, errors.New("not a unix connection")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid uint32
	var cerr error
	if err := raw.Control(func(fd uintptr) {
		uid, cerr = sockPeerUID(int(fd))
	}); err != nil {
		return 0, err
	}
	return uid, cerr
}

// wipeString zeroes a string this process owns, such as an identity just
// copied into locked memory. It is not for a string another copy shares.
func wipeString(s string) {
	if s == "" {
		return
	}
	b := unsafe.Slice(unsafe.StringData(s), len(s))
	for i := range b {
		b[i] = 0
	}
}

// WipeAgents zeroes identity material in a slice the caller is done with.
func WipeAgents(agents []AgentKey) {
	for i := range agents {
		wipeString(agents[i].Identity)
		agents[i].Identity = ""
	}
}

func wipeSecrets(secs []secret) {
	for i := range secs {
		Wipe(secs[i].raw)
		_ = unix.Munlock(secs[i].raw)
		secs[i].raw = nil
	}
}

func clearStale(sock, pidPath string) error {
	if daemonAlive(filepath.Dir(pidPath)) {
		return errors.New("keyd already running")
	}
	os.Remove(sock)
	os.Remove(pidPath)
	return nil
}

func daemonAlive(dir string) bool {
	return pidAlive(readPID(filepath.Join(dir, "keyd.pid")))
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
	err := unix.Kill(pid, 0)
	return err == nil || err == unix.EPERM
}

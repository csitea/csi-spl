package keyd

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"filippo.io/age"
	"golang.org/x/sys/unix"
)

func TestLockedLineAndExits(t *testing.T) {
	if ExitPassphrase != 2 || ExitLocked != 5 {
		t.Fatalf("exits %d %d", ExitPassphrase, ExitLocked)
	}
	ws := randWS(t)
	want := "LOCKED: the owner runs 'spool key unlock --workspace " + ws + "' on his terminal"
	if LockedLine(ws) != want {
		t.Fatal("locked sentence mismatch")
	}
}

func TestInitRotateAndOwnerStaySealed(t *testing.T) {
	dir := shortDir(t)
	pass := randPass(t)
	ownerPass := randPass(t)
	defer Wipe(pass)
	defer Wipe(ownerPass)
	ws := randWS(t)

	pub1, err := InitAgent(dir, ws, "c-101", pass)
	if err != nil {
		t.Fatal(err)
	}
	assertMode(t, dir, 0700)
	assertMode(t, filepath.Join(dir, "keys"), 0700)
	assertMode(t, filepath.Join(dir, "keys", "agents.age"), 0600)
	assertMode(t, filepath.Join(dir, "keys", "c-101.pub"), 0644)
	if got, err := WorkspaceOf(dir); err != nil || got != ws {
		t.Fatalf("workspace %q %v", got, err)
	}
	ct1 := sealTo(t, pub1, "one")

	if _, err := InitAgent(dir, randWS(t), "c-102", pass); err == nil {
		t.Fatal("mismatched workspace was accepted")
	}
	if _, err := InitAgent(dir, ws, "c-000", pass); err == nil {
		t.Fatal("agent id c-000 was accepted")
	}
	bad := randPass(t)
	defer Wipe(bad)
	if _, err := LoadAgents(dir, bad); err == nil {
		t.Fatal("wrong passphrase opened the keys")
	} else if strings.Contains(err.Error(), string(bad)) || strings.Contains(err.Error(), string(pass)) {
		t.Fatal("error contains a passphrase")
	}

	pub2, err := Rotate(dir, "c-101", pass)
	if err != nil {
		t.Fatal(err)
	}
	if pub1 == pub2 {
		t.Fatal("rotate did not change the recipient")
	}
	agents, err := LoadAgents(dir, pass)
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 2 || agents[0].ID != "c-101" || agents[1].ID != "c-101" {
		t.Fatalf("bundle len %d", len(agents))
	}
	opens(t, agents[1].Identity, ct1, "one")
	ct2 := sealTo(t, pub2, "two")
	opens(t, agents[0].Identity, ct2, "two")
	pubFile, err := os.ReadFile(filepath.Join(dir, "keys", "c-101.pub"))
	if err != nil || strings.TrimSpace(string(pubFile)) != pub2 {
		t.Fatal("recipient file is not the new key")
	}

	ownerPub, err := InitOwner(dir, ws, ownerPass)
	if err != nil {
		t.Fatal(err)
	}
	assertMode(t, filepath.Join(dir, "keys", "owner.age"), 0600)
	assertMode(t, filepath.Join(dir, "keys", "owner.pub"), 0644)
	agentPlain, err := openScrypt(filepath.Join(dir, "keys", "agents.age"), pass)
	if err != nil {
		t.Fatal(err)
	}
	defer Wipe(agentPlain)
	ownerPlain, err := openScrypt(filepath.Join(dir, "keys", "owner.age"), ownerPass)
	if err != nil {
		t.Fatal(err)
	}
	defer Wipe(ownerPlain)
	var ow ownerFile
	if err := json.Unmarshal(ownerPlain, &ow); err != nil || ow.Identity == "" {
		t.Fatal("owner file did not open")
	}
	if bytes.Contains(agentPlain, []byte(ow.Identity)) {
		t.Fatal("owner secret is in the agent bundle")
	}
	ownerPubFile, err := os.ReadFile(filepath.Join(dir, "keys", "owner.pub"))
	if err != nil || strings.TrimSpace(string(ownerPubFile)) != ownerPub {
		t.Fatal("owner recipient mismatch")
	}
	if _, err := openScrypt(filepath.Join(dir, "keys", "agents.age"), ownerPass); err == nil {
		t.Fatal("owner passphrase opened the agent keys")
	}
	assertNoSecret(t, dir)
}

func TestLockDropsIdentities(t *testing.T) {
	dir := shortDir(t)
	pass := randPass(t)
	defer Wipe(pass)
	ws := randWS(t)
	pub, err := InitAgent(dir, ws, "c-101", pass)
	if err != nil {
		t.Fatal(err)
	}
	agents, err := LoadAgents(dir, pass)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errCh := make(chan error, 1)
	go func() { errCh <- Serve(ctx, dir, ws, agents) }()
	waitStatus(t, dir, "unlocked", errCh)
	assertMode(t, filepath.Join(dir, "keyd.sock"), 0600)
	ct := sealTo(t, pub, "body")
	plain, err := Open(dir, "c-101", ct)
	if err != nil || string(plain) != "body" {
		t.Fatal("open through keyd failed")
	}
	Wipe(plain)
	if _, err := Open(dir, "c-102", ct); err == nil {
		t.Fatal("open for an unknown agent succeeded")
	}
	assertNoSecret(t, dir)
	if err := Lock(dir); err != nil {
		t.Fatal(err)
	}
	st, err := Status(dir)
	if err != nil || st != "locked" {
		t.Fatalf("after lock: %q %v", st, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "keyd.sock")); !os.IsNotExist(err) {
		t.Fatal("socket still present after lock")
	}
	if _, err := Open(dir, "c-101", ct); !errors.Is(err, ErrLocked) {
		t.Fatalf("open after lock: %v", err)
	}
	select {
	case err := <-errCh:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("keyd did not return after lock")
	}
}

func TestPeerUIDRefused(t *testing.T) {
	dir := shortDir(t)
	pass := randPass(t)
	defer Wipe(pass)
	ws := randWS(t)
	if _, err := InitAgent(dir, ws, "c-101", pass); err != nil {
		t.Fatal(err)
	}
	agents, err := LoadAgents(dir, pass)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errCh := make(chan error, 1)
	go func() { errCh <- Serve(ctx, dir, ws, agents) }()
	waitStatus(t, dir, "unlocked", errCh)
	sock := filepath.Join(dir, "keyd.sock")
	assertMode(t, sock, 0600)
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(sock, 0666); err != nil {
		t.Fatal(err)
	}
	if err := runAsSubuid(t, sock); err != nil {
		t.Fatal(err)
	}
	st, err := Status(dir)
	if err != nil || st != "unlocked" {
		t.Fatalf("same-uid status %q %v", st, err)
	}
	if err := Lock(dir); err != nil {
		t.Fatal(err)
	}
}

func TestDaemonNotDumpable(t *testing.T) {
	dir := shortDir(t)
	pass := randPass(t)
	defer Wipe(pass)
	ws := randWS(t)
	if _, err := InitAgent(dir, ws, "c-101", pass); err != nil {
		t.Fatal(err)
	}
	agents, err := LoadAgents(dir, pass)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := Bundle(ws, agents)
	if err != nil {
		t.Fatal(err)
	}
	defer Wipe(raw)
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe)
	cmd.Env = append(os.Environ(), "KEYD_HELPER=serve", "SPOOL_ENC_STATE="+dir, "KEYD_DUMPABLE_OUT="+filepath.Join(dir, "dumpable"))
	cmd.Stdin = bytes.NewReader(raw)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		Lock(dir)
		if cmd.Process != nil {
			cmd.Process.Kill()
			cmd.Wait()
		}
	})
	waitStatus(t, dir, "unlocked", nil)
	dumpPath := filepath.Join(dir, "dumpable")
	// This kernel does not publish Dumpable in /proc/pid/status. The helper
	// reads PR_GET_DUMPABLE in the process that called harden.
	var got []byte
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		b, rerr := os.ReadFile(dumpPath)
		if rerr == nil && len(b) > 0 {
			got = b
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if string(got) != "0" {
		t.Fatal("daemon is dumpable")
	}
	pid := strconv.Itoa(cmd.Process.Pid)
	lim, err := os.ReadFile("/proc/" + pid + "/limits")
	if err != nil {
		t.Fatal(err)
	}
	if !coreIsZero(lim) {
		t.Fatal("core rlimit is not 0")
	}
	assertNoSecret(t, dir)
	if err := Lock(dir); err != nil {
		t.Fatal(err)
	}
	cmd.Wait()
	if strings.Contains(stderr.String(), "AGE-SECRET-KEY-") {
		t.Fatal("daemon stderr contains an identity")
	}
}

func helperPeer() int {
	runtime.LockOSThread()
	var b [1]byte
	if _, err := os.Stdin.Read(b[:]); err != nil {
		fmt.Fprintln(os.Stderr, "map wait")
		return 1
	}
	// AllThreadsSyscall returns ENOTSUP in a cgo binary, and go test links cgo
	// when a compiler is present. Linux credentials are per-thread, and this
	// thread stays locked through connect, so SO_PEERCRED sees the mapped uid.
	// setgid is best-effort: a parent namespace that denies setgroups returns
	// EPERM, and the refusal under test is the uid.
	_, _, gerr := syscall.RawSyscall(syscall.SYS_SETGID, 1, 0, 0)
	_, _, uerr := syscall.RawSyscall(syscall.SYS_SETUID, 1, 0, 0)
	if uerr != 0 {
		fmt.Fprintf(os.Stderr, "setuid %d setgid %d\n", uerr, gerr)
		return 1
	}
	fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "socket")
		return 1
	}
	defer syscall.Close(fd)
	if err := syscall.Connect(fd, &syscall.SockaddrUnix{Name: os.Getenv("KEYD_SOCK")}); err != nil {
		fmt.Fprintln(os.Stderr, "dial")
		return 1
	}
	_, _ = syscall.Write(fd, []byte("{\"op\":\"status\"}\n"))
	var buf [128]byte
	n, err := syscall.Read(fd, buf[:])
	if n <= 0 || (err != nil && n == 0) {
		fmt.Fprintln(os.Stderr, "read")
		return 1
	}
	if !bytes.Contains(buf[:n], []byte("\"error\":\"peer uid refused\"")) {
		if bytes.Contains(buf[:n], []byte("\"ok\":true")) {
			fmt.Fprintln(os.Stderr, "same uid")
		} else {
			fmt.Fprintln(os.Stderr, "not refused")
		}
		return 1
	}
	fmt.Println("refused")
	return 0
}

func helperServe() int {
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil {
		return 1
	}
	dir := os.Getenv("SPOOL_ENC_STATE")
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go reportDumpable(dir, os.Getenv("KEYD_DUMPABLE_OUT"))
	if err := ServeBundle(ctx, dir, raw); err != nil {
		fmt.Fprintln(os.Stderr, "serve failed")
		return 1
	}
	return 0
}

func reportDumpable(dir, out string) {
	if out == "" {
		return
	}
	sock := filepath.Join(dir, "keyd.sock")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(sock); err == nil {
			n, _, errno := unix.RawSyscall6(unix.SYS_PRCTL, uintptr(unix.PR_GET_DUMPABLE), 0, 0, 0, 0, 0)
			val := []byte("err")
			if errno == 0 {
				val = []byte(strconv.Itoa(int(n)))
			}
			_ = os.WriteFile(out, val, 0600)
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func runAsSubuid(t *testing.T, sock string) error {
	t.Helper()
	subU, subG, err := subIDs()
	if err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	pr, pw, err := os.Pipe()
	if err != nil {
		return err
	}
	cmd := exec.Command("/usr/bin/unshare", "--user", "--keep-caps", exe)
	cmd.Env = []string{"KEYD_HELPER=peer", "KEYD_SOCK=" + sock, "PATH=/usr/bin:/bin"}
	cmd.Stdin = pr
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		pr.Close()
		pw.Close()
		return err
	}
	pr.Close()
	defer pw.Close()
	if err := waitNewUserNS(cmd.Process.Pid); err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		return err
	}
	// deny before gid_map so a nested namespace can install the map.
	_ = os.WriteFile(fmt.Sprintf("/proc/%d/setgroups", cmd.Process.Pid), []byte("deny\n"), 0)
	pid := strconv.Itoa(cmd.Process.Pid)
	uid := strconv.Itoa(os.Getuid())
	gid := strconv.Itoa(os.Getgid())
	if out, err := exec.Command("/usr/bin/newuidmap", pid, "0", uid, "1", "1", strconv.Itoa(subU), "1").CombinedOutput(); err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		return fmt.Errorf("newuidmap: %v: %s", err, oneLine(out))
	}
	if out, err := exec.Command("/usr/bin/newgidmap", pid, "0", gid, "1", "1", strconv.Itoa(subG), "1").CombinedOutput(); err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		return fmt.Errorf("newgidmap: %v: %s", err, oneLine(out))
	}
	if _, err := pw.Write([]byte{1}); err != nil {
		return err
	}
	pw.Close()
	if err := cmd.Wait(); err != nil {
		msg := oneLine(stderr.Bytes())
		if strings.Contains(msg, "AGE-SECRET-KEY-") {
			return fmt.Errorf("peer stderr contains an identity")
		}
		if msg == "" {
			msg = "no helper output"
		}
		return fmt.Errorf("peer helper: %v: %s", err, msg)
	}
	if strings.TrimSpace(stdout.String()) != "refused" {
		return fmt.Errorf("other uid was not refused")
	}
	if strings.Contains(stderr.String(), "AGE-SECRET-KEY-") {
		return fmt.Errorf("peer stderr contains an identity")
	}
	return nil
}

func oneLine(b []byte) string {
	s := strings.TrimSpace(string(b))
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}

func waitNewUserNS(pid int) error {
	self, err := os.Readlink("/proc/self/ns/user")
	if err != nil {
		return err
	}
	deadline := time.Now().Add(3 * time.Second)
	mapPath := fmt.Sprintf("/proc/%d/uid_map", pid)
	nsPath := fmt.Sprintf("/proc/%d/ns/user", pid)
	for time.Now().Before(deadline) {
		ns, err := os.Readlink(nsPath)
		b, rerr := os.ReadFile(mapPath)
		if err == nil && rerr == nil && ns != self && len(bytes.TrimSpace(b)) == 0 {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return fmt.Errorf("user namespace was not ready")
}

func subIDs() (int, int, error) {
	u, err := user.Current()
	if err != nil {
		return 0, 0, err
	}
	uid, err := firstSub("/etc/subuid", u.Username, u.Uid)
	if err != nil {
		return 0, 0, err
	}
	gid, err := firstSub("/etc/subgid", u.Username, u.Gid)
	if err != nil {
		return 0, 0, err
	}
	return uid, gid, nil
}

func firstSub(path, name, id string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	var start int
	found := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		parts := strings.Split(sc.Text(), ":")
		if len(parts) != 3 || (parts[0] != name && parts[0] != id) {
			continue
		}
		n, err := strconv.Atoi(parts[1])
		count, err2 := strconv.Atoi(parts[2])
		if err != nil || err2 != nil || count < 1 || n <= 0 {
			continue
		}
		start = n
		found = true
		break
	}
	if !found {
		return 0, fmt.Errorf("no subordinate id")
	}
	return start, nil
}

func coreIsZero(lim []byte) bool {
	for _, line := range bytes.Split(lim, []byte("\n")) {
		if !bytes.HasPrefix(line, []byte("Max core file size")) {
			continue
		}
		fields := strings.Fields(string(line))
		// "Max" "core" "file" "size" <soft> <hard> "bytes"
		if len(fields) < 6 {
			return false
		}
		return fields[4] == "0" && fields[5] == "0"
	}
	return false
}

func waitStatus(t *testing.T, dir, want string, errCh <-chan error) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		st, err := Status(dir)
		if err == nil && st == want {
			return
		}
		if errCh != nil {
			select {
			case serveErr := <-errCh:
				t.Fatalf("keyd exited: %v", serveErr)
			default:
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("status did not become %s", want)
}

func assertNoSecret(t *testing.T, dir string) {
	t.Helper()
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return err
		}
		if !info.Mode().IsRegular() || filepath.Base(path) == "dumpable" {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if bytes.Contains(b, []byte("AGE-SECRET-KEY-")) {
			t.Fatalf("clear identity in %s", filepath.Base(path))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != want {
		t.Fatalf("%s mode %o, want %o", filepath.Base(path), fi.Mode().Perm(), want)
	}
}

func sealTo(t *testing.T, pub, body string) []byte {
	t.Helper()
	rec, err := age.ParseX25519Recipient(pub)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	w, err := age.Encrypt(&buf, rec)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(w, body); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func opens(t *testing.T, identity string, ct []byte, body string) {
	t.Helper()
	ident, err := age.ParseX25519Identity(identity)
	if err != nil {
		t.Fatal("identity did not parse")
	}
	r, err := age.Decrypt(bytes.NewReader(ct), ident)
	if err != nil {
		t.Fatal("identity did not open the message")
	}
	got, err := io.ReadAll(r)
	if err != nil || string(got) != body {
		t.Fatal("plaintext mismatch")
	}
}

func randWS(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func shortDir(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "kd")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(d, 0700); err != nil {
		t.Fatal(err)
	}
	if len(filepath.Join(d, "keyd.sock")) >= 100 {
		os.RemoveAll(d)
		t.Fatal("socket path too long")
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d
}

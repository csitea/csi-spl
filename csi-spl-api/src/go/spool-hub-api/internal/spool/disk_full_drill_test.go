package spool

// Disk-full drill (SPL-2139, epic SPL-2129 robustness 1). No disk is filled:
// the send runs in a child copy of this test binary whose file size is capped
// by `ulimit -f` (RLIMIT_FSIZE), so the write of the message fails part-way
// exactly like a full disk (EFBIG here, ENOSPC there: both a short write).
// The drill proves the writer fails loudly (non-zero exit, the error printed)
// and leaves no file behind: no message, no half message, no ".tmp-*".
// CONTROL: the same child without the cap delivers, so the cap is what fails it.

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

const diskFullChildEnv = "SPOOL_DISK_FULL_DRILL_ROOT"

// TestDiskFullDrillChild is the child: it only runs under diskFullChildEnv,
// sends one message bigger than the cap and exits with the CLI's exit code.
func TestDiskFullDrillChild(t *testing.T) {
	root := os.Getenv(diskFullChildEnv)
	if root == "" {
		t.Skip("child of TestDiskFullDrill only")
	}
	st := New(&config.Config{SpoolRoot: root, KeysDir: filepath.Join(root, "keys"), LogLevel: "error", LogFormat: "console"})
	_, err := st.Send("GRK-03", "CLE-07", "drill-task", "task", strings.Repeat("x", 32*1024), nil)
	if err != nil {
		os.Stderr.WriteString("send failed: " + err.Error() + "\n")
	}
	os.Exit(ExitCode(err))
}

// runDiskFullChild runs the child with a file-size cap of capKiB (0 = none)
// and returns its exit code and combined output.
func runDiskFullChild(t *testing.T, root string, capKiB string) (int, string) {
	t.Helper()
	limit := "unlimited"
	if capKiB != "" {
		limit = capKiB
	}
	// SIGXFSZ is ignored by the shell before exec, so the over-cap write
	// returns an error to the writer instead of killing it.
	cmd := exec.Command("bash", "-c", `trap '' XFSZ; ulimit -f "$1"; shift; exec "$@"`,
		"drill", limit, os.Args[0], "-test.run=^TestDiskFullDrillChild$", "-test.count=1")
	cmd.Env = append(os.Environ(), diskFullChildEnv+"="+root)
	out, err := cmd.CombinedOutput()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("child did not run: %v", err)
	}
	return code, string(out)
}

// boxFiles lists every file under root's inbox and outbox dirs, temp files included.
func boxFiles(t *testing.T, root string) []string {
	t.Helper()
	var got []string
	for _, box := range []string{"CLE-07/inbox", "GRK-03/outbox"} {
		ents, _ := os.ReadDir(filepath.Join(root, box))
		for _, e := range ents {
			got = append(got, box+"/"+e.Name())
		}
	}
	return got
}

func TestDiskFullDrill_WriterFailsLoudAndLeavesNoHalfFile(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is needed for ulimit")
	}
	root := filepath.Join(t.TempDir(), "msgs")
	code, out := runDiskFullChild(t, root, "8") // 8 KiB cap, the message is 32 KiB+
	if code == 0 {
		t.Fatalf("a send that could not be written exited 0:\n%s", out)
	}
	if !strings.Contains(out, "send failed:") {
		t.Fatalf("the failure is not printed:\n%s", out)
	}
	if left := boxFiles(t, root); len(left) != 0 {
		t.Fatalf("a failed send left files behind: %v", left)
	}

	// CONTROL: no cap, the same child delivers to the inbox and the outbox.
	code, out = runDiskFullChild(t, root, "")
	if left := boxFiles(t, root); code != 0 || len(left) != 2 {
		t.Fatalf("control: uncapped send exit %d files %v:\n%s", code, left, out)
	}
	if res, err := New(&config.Config{SpoolRoot: root}).Recv("CLE-07", false); err != nil || len(res.Messages) != 1 {
		t.Fatalf("control: recv after the uncapped send: %s", recvShape(res, err))
	}
}

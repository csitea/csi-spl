package keyd

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestSetTestScryptWorkFactorInTest: inside a test binary the hook sets the
// cost within 10..18 and refuses anything outside it.
func TestSetTestScryptWorkFactorInTest(t *testing.T) {
	prev := scryptLogN
	t.Cleanup(func() { scryptLogN = prev })
	if !SetTestScryptWorkFactor(12) || scryptLogN != 12 {
		t.Fatalf("in a test binary: logN %d, want 12", scryptLogN)
	}
	for _, n := range []int{9, 19, 0, -1} {
		if SetTestScryptWorkFactor(n) || scryptLogN != 12 {
			t.Fatalf("logN %d was taken: now %d", n, scryptLogN)
		}
	}
}

// TestSetTestScryptWorkFactorRefusedOutsideTests: a plain binary that calls
// the hook gets false and still seals at the production cost, 18.
func TestSetTestScryptWorkFactorRefusedOutsideTests(t *testing.T) {
	tmp := t.TempDir()
	bin := filepath.Join(tmp, "nontest")
	build := exec.Command("go", "build", "-o", bin, "./testdata/nontest")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build nontest: %v\n%s", err, out)
	}
	state := filepath.Join(tmp, "state")
	out, err := exec.Command(bin, state, randWS(t)).CombinedOutput()
	if err != nil {
		t.Fatalf("nontest: %v\n%s", err, out)
	}
	if strings.TrimSpace(string(out)) != "took=false" {
		t.Fatalf("a non-test binary was let lower the cost: %q", out)
	}
	if n := headerScryptLogN(t, agentsPath(state)); n != 18 {
		t.Fatalf("a non-test binary sealed at scrypt logN %d, want 18", n)
	}
}

// headerScryptLogN reads the "-> scrypt <salt> <logN>" stanza of an age file.
func headerScryptLogN(t *testing.T, path string) int {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 4 && fields[0] == "->" && fields[1] == "scrypt" {
			n, err := strconv.Atoi(fields[3])
			if err != nil {
				t.Fatal(err)
			}
			return n
		}
	}
	t.Fatalf("%s: no scrypt stanza", path)
	return 0
}

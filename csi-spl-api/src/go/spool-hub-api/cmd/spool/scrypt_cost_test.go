package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// testScryptLogN is the scrypt cost the cmd/spool test binary seals with,
// in-process and in every helper or keyd child it re-execs. At the
// production cost (18, 256 MiB per seal or open) the key tests took 525 of
// the package's 533 s under -race at box load 67..80 on 16 cores, close to
// go test's 10 min cap (SPL-5352).
const testScryptLogN = 14

// TestKeyTestsSealCheaply: a bundle sealed by the test process and one
// resealed by a re-exec'd CLI child both carry the test cost in their age
// scrypt stanza, so the key tests stay far under the package's time cap.
func TestKeyTestsSealCheaply(t *testing.T) {
	dir, _, _, _ := keyFileState(t)
	stopKeyd(t, dir)
	assertScryptLogN(t, dir, "sealed by the test process")
	rc, so, se := runNoTTY(t, "key", "rotate-unlock-key")
	if rc != 0 || so != "rotated\n" {
		t.Fatalf("rotate in a child: rc %d out %q err %q", rc, so, se)
	}
	assertScryptLogN(t, dir, "resealed by a CLI child")
}

// assertScryptLogN checks the work factor of every age file under dir.
func assertScryptLogN(t *testing.T, dir, who string) {
	t.Helper()
	var files []string
	for _, pat := range []string{"*.age", "*/*.age"} {
		m, _ := filepath.Glob(filepath.Join(dir, pat))
		files = append(files, m...)
	}
	if len(files) == 0 {
		t.Fatalf("%s: no .age file under %s", who, dir)
	}
	for _, f := range files {
		if n := scryptLogNOf(t, f); n != testScryptLogN {
			t.Errorf("%s: %s is sealed at scrypt logN %d, want %d", who, filepath.Base(f), n, testScryptLogN)
		}
	}
}

// scryptLogNOf reads the "-> scrypt <salt> <logN>" stanza of an age header.
func scryptLogNOf(t *testing.T, path string) int {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		fields := strings.Fields(line)
		if len(fields) == 4 && fields[0] == "->" && fields[1] == "scrypt" {
			n, err := strconv.Atoi(fields[3])
			if err != nil {
				t.Fatalf("%s: scrypt stanza %q", path, line)
			}
			return n
		}
		if strings.HasPrefix(line, "---") {
			break
		}
	}
	t.Fatalf("%s: no scrypt stanza in the age header", path)
	return 0
}

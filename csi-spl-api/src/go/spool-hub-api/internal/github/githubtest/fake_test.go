package githubtest

import "testing"

// TestBlobSHA is git's blob id (`printf 'hello\n' | git hash-object --stdin`).
func TestBlobSHA(t *testing.T) {
	if got, want := BlobSHA([]byte("hello\n")), "ce013625030ba8dba906f756967f9e9ca394464a"; got != want {
		t.Fatalf("BlobSHA = %s, want %s", got, want)
	}
}

// TestPushMovesHead: a push lands a child of the old head that carries the
// new file, and the seed files stay.
func TestPushMovesHead(t *testing.T) {
	s := New(t, map[string]string{"README.md": "seed"})
	root := s.Head()
	if body, ok := s.File("README.md"); !ok || body != "seed" {
		t.Fatalf("seed file: %q %v", body, ok)
	}
	sha := s.Push("doc/a.md", "a", "add a")
	if s.Head() != sha || sha == root {
		t.Fatalf("head %s after push %s (root %s)", s.Head(), sha, root)
	}
	c, ok := s.Commit(sha)
	if !ok || len(c.Parents) != 1 || c.Parents[0] != root || c.Message != "add a" {
		t.Fatalf("commit %+v %v", c, ok)
	}
	if body, ok := s.File("doc/a.md"); !ok || body != "a" {
		t.Fatalf("pushed file: %q %v", body, ok)
	}
	if _, ok := s.File("README.md"); !ok {
		t.Fatal("seed file lost by the push")
	}
}

//go:build linux

package keydesk

import (
	"errors"
	"testing"
)

// sdOtherUIDPeer is a caller DefaultPeerOK refuses: another uid fails OwnUID
// before any process is looked at.
func sdOtherUIDPeer() Peer {
	return Peer{PID: 1, UID: uint32(deskUID()) + 1, GID: 0}
}

// sdLog collects the lines a Server logs.
func sdLog(lines *[]string) func(string) {
	return func(line string) { *lines = append(*lines, line) }
}

func TestServerLogfNilLogDoesNotPanic(t *testing.T) {
	(&Server{}).logf("refused %s", "peer")
}

func TestServerLogfFormatsOneLine(t *testing.T) {
	var lines []string
	s := &Server{Log: sdLog(&lines)}
	s.logf("refused %s %d", "peer", 7)
	if len(lines) != 1 || lines[0] != "refused peer 7" {
		t.Fatalf("logged %q, want the one line %q", lines, "refused peer 7")
	}
}

func TestServerPeerOKNilAnswersAsDefaultPeerOK(t *testing.T) {
	p := sdOtherUIDPeer()
	want := DefaultPeerOK(p)
	if want == nil {
		t.Fatalf("DefaultPeerOK admitted %+v, the case needs a refused peer", p)
	}
	got := (&Server{}).peerOK(p)
	if got == nil {
		t.Fatalf("peerOK admitted %+v, DefaultPeerOK refuses it: %v", p, want)
	}
	if got.Error() != want.Error() {
		t.Fatalf("peerOK answered %q, DefaultPeerOK %q", got, want)
	}
}

func TestServerPeerOKSetGivesItsAnswer(t *testing.T) {
	p := sdOtherUIDPeer()
	refusal := errors.New("sd refusal")
	cases := []struct {
		name string
		ans  error
	}{
		{"admits a peer the default refuses", nil},
		{"refuses", refusal},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var seen []Peer
			s := &Server{PeerOK: func(q Peer) error {
				seen = append(seen, q)
				return c.ans
			}}
			if got := s.peerOK(p); !errors.Is(got, c.ans) {
				t.Fatalf("peerOK answered %v, want %v", got, c.ans)
			}
			if len(seen) != 1 || seen[0] != p {
				t.Fatalf("PeerOK saw %+v, want %+v once", seen, p)
			}
		})
	}
}

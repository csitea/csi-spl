package keydesk

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// seatRec ties a seat dir to the wrapper that leased for it: its pid and the
// pid's start time, so a recycled pid is not taken for the seat.
type seatRec struct {
	pid   int32
	start string
	kind  string
}

// claimSeat records the seat dir a lease is for (127 5.4). An empty seat is
// allowed (a client that sends none): its dir is then swept only by age. A
// seat that is not a direct child dir of the seat root, a symlink, or not
// 0700 is refused bad_seat.
func (s *Server) claimSeat(seat, kind string, p Peer) string {
	if seat == "" {
		return ""
	}
	if !s.seatDirOK(seat) {
		s.logf("keydesk: refused a lease for a seat outside %s", s.SeatRoot)
		return TokBadSeat
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seats[filepath.Clean(seat)] = seatRec{pid: p.PID, start: procStart(p.PID), kind: kind}
	return ""
}

func (s *Server) seatDirOK(seat string) bool {
	if s.SeatRoot == "" || !filepath.IsAbs(seat) {
		return false
	}
	c := filepath.Clean(seat)
	if filepath.Dir(c) != filepath.Clean(s.SeatRoot) {
		return false
	}
	st, err := os.Lstat(c)
	return err == nil && st.IsDir() && st.Mode().Perm() == 0o700
}

// EmptySeats removes every seat dir under the seat root (127 5.4: the desk
// empties spool-seat/ at its start; a dir left there is a dead seat's). It
// makes the root 0700 when it is missing.
func (s *Server) EmptySeats() error {
	s.init()
	if s.SeatRoot == "" {
		return errors.New("keydesk: no seat root")
	}
	if err := os.MkdirAll(s.SeatRoot, 0o700); err != nil {
		return err
	}
	ents, err := os.ReadDir(s.SeatRoot)
	if err != nil {
		return err
	}
	for _, e := range ents {
		if err := os.RemoveAll(filepath.Join(s.SeatRoot, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

// Sweep removes every seat dir whose seat is gone (127 5.4, deleter 2): a
// recorded dir whose wrapper pid is dead or recycled, and an unrecorded dir
// older than Grace (a seat that never leased). It returns the names removed.
func (s *Server) Sweep() []string {
	s.init()
	if s.SeatRoot == "" {
		return nil
	}
	ents, err := os.ReadDir(s.SeatRoot)
	if err != nil {
		return nil
	}
	var gone []string
	for _, e := range ents {
		dir := filepath.Join(s.SeatRoot, e.Name())
		if s.seatLive(dir) {
			continue
		}
		if os.RemoveAll(dir) == nil {
			gone = append(gone, e.Name())
			s.logf("keydesk: swept seat dir %s", e.Name())
		}
	}
	return gone
}

// seatLive: the dir's wrapper still runs, or an unclaimed dir is young.
func (s *Server) seatLive(dir string) bool {
	s.mu.Lock()
	rec, ok := s.seats[dir]
	s.mu.Unlock()
	if ok {
		if rec.pid > 0 && rec.start != "" && procStart(rec.pid) == rec.start {
			return true
		}
		s.mu.Lock()
		delete(s.seats, dir)
		s.mu.Unlock()
		return false
	}
	st, err := os.Lstat(dir)
	if err != nil {
		return true // already gone, or unreadable: nothing to remove
	}
	grace := s.Grace
	if grace <= 0 {
		grace = 10 * time.Minute
	}
	return s.now().Sub(st.ModTime()) < grace
}

// procStart is field 22 of /proc/<pid>/stat (start time in clock ticks), ""
// when the pid is gone. Same uid reads it under hidepid=2.
func procStart(pid int32) string {
	if pid <= 0 {
		return ""
	}
	b, err := os.ReadFile("/proc/" + strconv.Itoa(int(pid)) + "/stat")
	if err != nil {
		return ""
	}
	// comm (field 2) may hold spaces and ')': read after the last ')'.
	i := strings.LastIndexByte(string(b), ')')
	if i < 0 {
		return ""
	}
	f := strings.Fields(string(b)[i+1:])
	if len(f) < 20 { // fields 3..22
		return ""
	}
	return f[19]
}

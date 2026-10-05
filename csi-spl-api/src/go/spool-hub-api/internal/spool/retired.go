package spool

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// ErrRetiredRecipient: a send to an id this machine retired less than the
// quarantine ago (specs/061 3.6). The sender got a reject naming the retired
// id; the message was not delivered and does not queue.
var ErrRetiredRecipient = errors.New("retired_agent")

// retiredLayout is the retired-utc column agent-id-retire.sh writes.
const retiredLayout = "20060102T150405Z"

// RetiredInQuarantine reports when id was last retired on this machine
// ($SPOOL_ROOT/registry.retired.tsv, column 6), while that is less than
// SPOOL_ID_QUARANTINE_H hours before now. The first column is matched the way
// KnownLocal matches registry.tsv: a "<box tag>: " prefix and an "@<box>"
// suffix are ignored.
func (s *Store) RetiredInQuarantine(id string, now time.Time) (time.Time, bool) {
	b, err := os.ReadFile(filepath.Join(s.cfg.SpoolRoot, "registry.retired.tsv"))
	if err != nil {
		return time.Time{}, false
	}
	var last time.Time
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 6 {
			continue
		}
		first := f[0]
		if i := strings.LastIndex(first, ": "); i >= 0 {
			first = first[i+2:]
		}
		first, _, _ = strings.Cut(first, "@")
		if strings.TrimSpace(first) != id {
			continue
		}
		if t, err := time.Parse(retiredLayout, strings.TrimSpace(f[5])); err == nil && t.After(last) {
			last = t
		}
	}
	if last.IsZero() || !now.Before(last.Add(s.cfg.IDQuarantine())) {
		return time.Time{}, false
	}
	return last, true
}

// BounceRetired is the quarantine's reject bounce (specs/061 3.6): when m.To
// is not an agent of this machine (KnownLocal) and was retired here inside
// the quarantine, a kind=reject message from the retired id, on m's task,
// goes into the sender's inbox, and ErrRetiredRecipient is returned. m itself
// is written nowhere: it does not queue for the next holder of the number.
// Any other recipient is nil, and the caller sends as before.
func (s *Store) BounceRetired(m *msg.Message) error {
	if !msg.ValidID(m.To) || s.KnownLocal(m.To) {
		return nil
	}
	now := s.now().UTC()
	at, ok := s.RetiredInQuarantine(m.To, now)
	if !ok {
		return nil
	}
	until := at.Add(s.cfg.IDQuarantine())
	from, _, _ := strings.Cut(m.From, "@")
	body := fmt.Sprintf("%s retired at %s. Your %s (msg %s) was not delivered and does not queue: "+
		"%s is quarantined until %s, then the number may name a new agent.",
		m.To, at.Format(time.RFC3339), m.Kind, m.MsgID, m.To, until.Format(time.RFC3339))
	rej, err := s.Compose(m.To, from, m.TaskID, "reject", body, nil)
	if err != nil {
		return err
	}
	if _, err := s.writeBox(rej, from, "inbox"); err != nil {
		return fmt.Errorf("%w: %s retired at %s; the reject to %s was not written either: %w",
			ErrRetiredRecipient, m.To, at.Format(time.RFC3339), from, err)
	}
	return fmt.Errorf("%w: %s retired at %s (quarantined until %s); nothing was delivered, a reject is in %s's inbox",
		ErrRetiredRecipient, m.To, at.Format(time.RFC3339), until.Format(time.RFC3339), from)
}

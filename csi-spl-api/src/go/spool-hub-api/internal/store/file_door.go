package store

import (
	"context"
	"encoding/json"
	"time"
)

// The read door on a stored FILE (rdb 0028 + 0030).
//
// An attachment is exactly as private as the messages that carry it. Before
// this, GET /v1/files/{file_id} was scoped to the tenant alone: any signed-in
// member who knew a file_id could fetch an attachment out of a channel they
// were never in, or out of another member's DM. The id is a sha256 you can
// normally only learn by reading that message - but "they would have to know
// it" is an assumption about the attacker, not a control, and the ids travel
// in links, logs and screenshots.
//
// The same file_id can sit on several messages (it is content-addressed, so
// two people uploading the same bytes share it). ANY readable one is enough:
// a reader who may see the file in one place is not helped by being refused
// it in another, and refusing would make a shared file's visibility depend on
// upload order.

// FileDoor is the store side. Memory and Postgres implement it.
type FileDoor interface {
	// FileAttached: some message in retention carries fileID, whoever may
	// read it. false means the blob is not (yet) an attachment - an upload
	// whose message has not been sent, or the leftover of messages that
	// expired. The door lets it through only within the hub's upload grace
	// of its upload, and retention deletes it after the orphan grace
	// (CLE-34962, hub/file_retention.go): an expired private attachment
	// must not turn tenant-readable. While a message carries the file, the
	// two checks below govern it.
	FileAttached(ctx context.Context, tenantID, fileID string, now time.Time) (bool, error)
	// FileReadableByHuman: some message in retention that carries fileID is
	// one this human may read - in a public default channel, in a channel
	// they belong to (channels), or a DM they are an end of.
	FileReadableByHuman(ctx context.Context, tenantID, fileID, humanID string, channels []string, now time.Time) (bool, error)
	// FileReadableByBox: some message in retention that carries fileID has
	// this box at either end, or was delivered to it (a channel post is
	// addressed to box-wui and reaches member boxes as delivery rows).
	FileReadableByBox(ctx context.Context, tenantID, fileID, boxID string, now time.Time) (bool, error)
}

var (
	_ FileDoor = (*Memory)(nil)
	_ FileDoor = (*Postgres)(nil)
)

// carriesFile reports whether a stored message's files array names fileID.
func carriesFile(files []byte, fileID string) bool {
	if fileID == "" || len(files) == 0 {
		return false
	}
	var refs []struct {
		FileID string `json:"file_id"`
		SHA256 string `json:"sha256"`
	}
	if json.Unmarshal(files, &refs) != nil {
		return false
	}
	for _, f := range refs {
		if f.FileID == fileID || f.SHA256 == fileID {
			return true
		}
	}
	return false
}

// ---- Memory ---------------------------------------------------------------

func (s *Memory) FileAttached(_ context.Context, tenant, fileID string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, m := range s.liveLocked(tenant, now) {
		if carriesFile(m.Files, fileID) {
			return true, nil
		}
	}
	return false, nil
}

func (s *Memory) FileReadableByHuman(_ context.Context, tenant, fileID, human string, channels []string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, m := range s.liveLocked(tenant, now) {
		if carriesFile(m.Files, fileID) && readableBy(m.Channel, m.FromID, m.ToID, human, channels) {
			return true, nil
		}
	}
	return false, nil
}

func (s *Memory) FileReadableByBox(_ context.Context, tenant, fileID, box string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, m := range s.liveLocked(tenant, now) {
		if !carriesFile(m.Files, fileID) {
			continue
		}
		if m.FromBox == box || m.ToBox == box {
			return true, nil
		}
		for k := range s.deliveries {
			if k[0] == tenant && k[1] == m.MsgID && k[2] == box {
				return true, nil
			}
		}
	}
	return false, nil
}

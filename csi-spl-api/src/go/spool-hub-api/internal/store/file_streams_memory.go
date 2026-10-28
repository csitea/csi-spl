package store

import (
	"context"
	"maps"
	"sort"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Memory's file streams (file_streams.go), the same contract as the
// Postgres side, under s.mu: streams by id, each stream's lines by seq.

type memFileStreams struct {
	byID  map[string]*FileStream
	lines map[string]map[int64]FileStreamLine
}

// fileStreamsLocked is the state, made on first use; s.mu is held.
func (s *Memory) fileStreamsLocked() *memFileStreams {
	if s.fileStreams == nil {
		s.fileStreams = &memFileStreams{byID: map[string]*FileStream{}, lines: map[string]map[int64]FileStreamLine{}}
	}
	return s.fileStreams
}

// of is (tenant, box, key)'s stream, or nil; s.mu is held.
func (m *memFileStreams) of(tenant, box, key string) *FileStream {
	for _, f := range m.byID {
		if f.Tenant == tenant && f.Box == box && f.StreamKey == key {
			return f
		}
	}
	return nil
}

// workspaceOK: tenant already streams, or fewer than max other workspaces do.
func (m *memFileStreams) workspaceOK(tenant string, max int) bool {
	ws := map[string]bool{}
	for _, f := range m.byID {
		if f.State == wire.FileStreamFollowing || f.State == wire.FileStreamMissing {
			ws[f.Tenant] = true
		}
	}
	return ws[tenant] || len(ws) < max
}

// AnnounceFileStreams is FileStreamStore.AnnounceFileStreams.
func (s *Memory) AnnounceFileStreams(_ context.Context, tenant, box string, in []wire.FileStreamAnnounced, lim FileStreamLimits, now time.Time) ([]wire.FileStreamAckState, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	lim = lim.Norm()
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.boxes[[2]string{tenant, box}]; !ok {
		return nil, ErrNotFound
	}
	m := s.fileStreamsLocked()
	plan := fileStreamAnnouncePlan(in, lim, !fileStreamAnnounceStreams(in) || m.workspaceOK(tenant, lim.MaxWorkspaces))
	listed := map[string]bool{}
	for i, a := range plan {
		listed[a.StreamKey] = true
		f := m.of(tenant, box, a.StreamKey)
		if f == nil {
			f = &FileStream{ID: uuid.New(), Tenant: tenant, Box: box, StreamKey: a.StreamKey, FirstSeenAt: now, Redactions: map[string]int64{}}
			m.byID[f.ID] = f
		}
		f.Path, f.State, f.Reason, f.AnnouncedAt = in[i].Path, a.State, a.Reason, now
	}
	for _, f := range m.byID {
		if f.Tenant == tenant && f.Box == box && !listed[f.StreamKey] {
			f.State, f.Reason = wire.FileStreamGone, ""
		}
	}
	return plan, nil
}

// RecordFileStreamLines is FileStreamStore.RecordFileStreamLines.
func (s *Memory) RecordFileStreamLines(_ context.Context, tenant, box string, p wire.FileStreamsPushFrame, lim FileStreamLimits, now time.Time) (FileStreamPushResult, error) {
	if err := checkTenant(tenant); err != nil {
		return FileStreamPushResult{}, err
	}
	lim = lim.Norm()
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.fileStreamsLocked()
	f := m.of(tenant, box, p.StreamKey)
	switch {
	case f == nil:
		return FileStreamPushResult{}, ErrFileStreamUnknown
	case f.Reason != "":
		return FileStreamPushResult{}, ErrFileStreamRefused
	}
	keep, expired, acked := fileStreamPrepare(p.Lines, now)
	res := FileStreamPushResult{StreamID: f.ID, Expired: expired, AckedSeq: acked}
	have := m.lines[f.ID]
	from, to := fileStreamWindow(keep)
	per := map[time.Time]int{}
	for _, l := range have {
		if !l.At.Before(from) && l.At.Before(to) {
			per[l.At.Truncate(time.Minute)]++
		}
	}
	var fresh []wire.FileStreamLine
	for _, l := range keep {
		if _, dup := have[l.Seq]; !dup {
			fresh = append(fresh, l)
			per[l.At.Truncate(time.Minute)]++
		}
	}
	if fileStreamOverRate(per, lim) {
		return FileStreamPushResult{}, ErrFileStreamRate
	}
	if have == nil {
		have = map[int64]FileStreamLine{}
		m.lines[f.ID] = have
	}
	for _, l := range fresh {
		have[l.Seq] = FileStreamLine{StreamID: f.ID, Seq: l.Seq, At: l.At, Text: l.Text, Marker: l.Marker}
		f.LinesKept++
		f.BytesKept += int64(len(l.Text))
		if f.LastLineAt == nil || l.At.After(*f.LastLineAt) {
			at := l.At
			f.LastLineAt = &at
		}
	}
	res.Inserted = len(fresh)
	f.LastSeq = max(f.LastSeq, acked)
	f.LinesTotal += int64(res.Inserted)
	f.LinesDropped += p.Dropped
	for k, n := range p.Redactions {
		f.Redactions[k] += n
	}
	res.Pruned = m.pruneToCaps(tenant, lim)
	return res, nil
}

// pruneToCaps removes tenant's oldest lines (by time, then stream and seq)
// until its kept lines and bytes are within lim; never another tenant's.
func (m *memFileStreams) pruneToCaps(tenant string, lim FileStreamLimits) int {
	var lines, bytes int64
	for _, f := range m.byID {
		if f.Tenant == tenant {
			lines, bytes = lines+f.LinesKept, bytes+f.BytesKept
		}
	}
	if lines <= lim.MaxLines && bytes <= lim.MaxBytes {
		return 0
	}
	var all []FileStreamLine
	for id, ls := range m.lines {
		if m.byID[id].Tenant == tenant {
			all = append(all, slicesOf(ls)...)
		}
	}
	sort.Slice(all, func(i, j int) bool { return fileStreamLineOlder(all[i], all[j]) })
	n := 0
	for _, l := range all {
		if lines <= lim.MaxLines && bytes <= lim.MaxBytes {
			break
		}
		f := m.byID[l.StreamID]
		delete(m.lines[l.StreamID], l.Seq)
		f.LinesKept--
		f.BytesKept -= int64(len(l.Text))
		lines, bytes, n = lines-1, bytes-int64(len(l.Text)), n+1
	}
	return n
}

// SweepFileStreams is FileStreamStore.SweepFileStreams.
func (s *Memory) SweepFileStreams(ctx context.Context, now time.Time, lim FileStreamLimits) (FileStreamSweep, error) {
	s.mu.Lock()
	tenants := map[string]bool{}
	for _, f := range s.fileStreamsLocked().byID {
		if f.LinesKept > 0 {
			tenants[f.Tenant] = true
		}
	}
	s.mu.Unlock()
	var res FileStreamSweep
	for tenant := range tenants {
		r, _ := s.sweepFileStreamTenant(ctx, tenant, now, lim)
		res.Expired, res.Pruned = res.Expired+r.Expired, res.Pruned+r.Pruned
	}
	return res, nil
}

// sweepFileStreamTenant is one workspace's part of SweepFileStreams.
func (s *Memory) sweepFileStreamTenant(_ context.Context, tenant string, now time.Time, lim FileStreamLimits) (FileStreamSweep, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.fileStreamsLocked()
	var res FileStreamSweep
	cut := now.Add(-FileStreamsRetention)
	for id, ls := range m.lines {
		f := m.byID[id]
		if f.Tenant != tenant {
			continue
		}
		for seq, l := range ls {
			if l.At.Before(cut) {
				delete(ls, seq)
				f.LinesKept--
				f.BytesKept -= int64(len(l.Text))
				res.Expired++
			}
		}
	}
	res.Pruned = m.pruneToCaps(tenant, lim.Norm())
	return res, nil
}

func slicesOf(ls map[int64]FileStreamLine) []FileStreamLine {
	out := make([]FileStreamLine, 0, len(ls))
	for _, l := range ls {
		out = append(out, l)
	}
	return out
}

// fileStreamLineOlder is the prune order: at, then stream id, then seq.
func fileStreamLineOlder(a, b FileStreamLine) bool {
	if !a.At.Equal(b.At) {
		return a.At.Before(b.At)
	}
	if a.StreamID != b.StreamID {
		return a.StreamID < b.StreamID
	}
	return a.Seq < b.Seq
}

// ListFileStreams is FileStreamStore.ListFileStreams.
func (s *Memory) ListFileStreams(_ context.Context, tenant string) ([]FileStream, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []FileStream{}
	for _, f := range s.fileStreamsLocked().byID {
		if f.Tenant == tenant {
			c := *f
			c.Redactions = maps.Clone(f.Redactions)
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Box != out[j].Box {
			return out[i].Box < out[j].Box
		}
		return out[i].StreamKey < out[j].StreamKey
	})
	return out, nil
}

// FileStreamLines is FileStreamStore.FileStreamLines.
func (s *Memory) FileStreamLines(_ context.Context, tenant, id string, q FileStreamLinesQuery) ([]FileStreamLine, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.fileStreamsLocked()
	if f := m.byID[id]; f == nil || f.Tenant != tenant {
		return nil, ErrNotFound
	}
	all := slicesOf(m.lines[id])
	sort.Slice(all, func(i, j int) bool { return all[i].Seq < all[j].Seq })
	out := append([]FileStreamLine{}, fileStreamPage(all, q)...)
	return out, nil
}

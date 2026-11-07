package store

import (
	"context"
	"sort"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Memory's removal of a file from the view (file_streams.go, spec 160 3.10),
// the same contract as the Postgres side, under s.mu.

// RemoveFileStream is FileStreamStore.RemoveFileStream.
func (s *Memory) RemoveFileStream(_ context.Context, tenant, id, actor string, now time.Time) (FileStream, error) {
	if err := checkTenant(tenant); err != nil {
		return FileStream{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.fileStreamsLocked().byID[id]
	if f == nil || f.Tenant != tenant || f.RemovedAt != nil {
		return FileStream{}, ErrNotFound
	}
	at := now
	f.RemovedAt, f.State, f.Reason = &at, wire.FileStreamGone, ""
	s.fileStreamGlobsLocked().addAudit(tenant, FileStreamGlobAuditRow{Box: f.Box, Action: FileStreamAuditFileRemove, Key: f.StreamKey, Glob: f.Path, Actor: actor, At: now})
	return *f, nil
}

// RestoreFileStream is FileStreamStore.RestoreFileStream.
func (s *Memory) RestoreFileStream(_ context.Context, tenant, id, actor string, now time.Time) (FileStream, error) {
	if err := checkTenant(tenant); err != nil {
		return FileStream{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.fileStreamsLocked().byID[id]
	if f == nil || f.Tenant != tenant || f.RemovedAt == nil {
		return FileStream{}, ErrNotFound
	}
	f.RemovedAt = nil
	s.fileStreamGlobsLocked().addAudit(tenant, FileStreamGlobAuditRow{Box: f.Box, Action: FileStreamAuditFileRestore, Key: f.StreamKey, Glob: f.Path, Actor: actor, At: now})
	return *f, nil
}

// RemovedFileStreamKeys is FileStreamStore.RemovedFileStreamKeys.
func (s *Memory) RemovedFileStreamKeys(_ context.Context, tenant, box string) ([]string, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for _, f := range s.fileStreamsLocked().byID {
		if f.Tenant == tenant && f.Box == box && f.RemovedAt != nil {
			out = append(out, f.StreamKey)
		}
	}
	sort.Strings(out)
	return out, nil
}

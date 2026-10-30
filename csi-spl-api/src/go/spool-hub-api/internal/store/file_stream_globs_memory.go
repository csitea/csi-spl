package store

import (
	"context"
	"sort"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Memory's web globs (file_stream_globs.go), the same contract as the
// Postgres side, under s.mu.

type memFileStreamGlobs struct {
	globs   map[string]*FileStreamGlob       // by id
	folders map[[2]string][]FileStreamFolder // by (tenant, box)
	audit   []memFileStreamGlobAudit
}

type memFileStreamGlobAudit struct {
	tenant string
	row    FileStreamGlobAuditRow
}

// fileStreamGlobsLocked is the state, made on first use; s.mu is held.
func (s *Memory) fileStreamGlobsLocked() *memFileStreamGlobs {
	if s.fileStreamGlobs == nil {
		s.fileStreamGlobs = &memFileStreamGlobs{globs: map[string]*FileStreamGlob{}, folders: map[[2]string][]FileStreamFolder{}}
	}
	return s.fileStreamGlobs
}

// live is (tenant, box)'s live globs, oldest first; s.mu is held.
func (m *memFileStreamGlobs) live(tenant, box string) []FileStreamGlob {
	var out []FileStreamGlob
	for _, g := range m.globs {
		if g.Tenant == tenant && (box == "" || g.Box == box) && g.RemovedAt == nil {
			out = append(out, *g)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.Before(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func (m *memFileStreamGlobs) addAudit(tenant string, a FileStreamGlobAuditRow) {
	a = fileStreamAuditRow(a)
	a.ID = uuid.New()
	m.audit = append(m.audit, memFileStreamGlobAudit{tenant: tenant, row: a})
}

// FileStreamBoxFolders is FileStreamGlobStore.FileStreamBoxFolders.
func (s *Memory) FileStreamBoxFolders(_ context.Context, tenant, box string) (bool, []FileStreamFolder, error) {
	if err := checkTenant(tenant); err != nil {
		return false, nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	fs, known := s.fileStreamGlobsLocked().folders[[2]string{tenant, box}]
	for _, f := range s.fileStreamsLocked().byID {
		known = known || (f.Tenant == tenant && f.Box == box)
	}
	return known, append([]FileStreamFolder{}, fs...), nil
}

// AddFileStreamGlob is FileStreamGlobStore.AddFileStreamGlob.
func (s *Memory) AddFileStreamGlob(_ context.Context, tenant string, in FileStreamGlobAdd, now time.Time) (FileStreamGlob, error) {
	if err := checkTenant(tenant); err != nil {
		return FileStreamGlob{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.boxes[[2]string{tenant, in.Box}]; !ok {
		return FileStreamGlob{}, ErrNotFound
	}
	m := s.fileStreamGlobsLocked()
	live := m.live(tenant, in.Box)
	for _, g := range live {
		if g.Key == in.Key {
			return FileStreamGlob{}, ErrFileStreamGlobKeyTaken
		}
	}
	if len(live) >= in.Max {
		return FileStreamGlob{}, ErrFileStreamGlobsFull
	}
	g := &FileStreamGlob{ID: uuid.New(), Tenant: tenant, Box: in.Box, Key: in.Key, Glob: in.Glob, CreatedBy: in.Actor,
		CreatedAt: now, State: wire.FileStreamGlobPending}
	m.globs[g.ID] = g
	m.addAudit(tenant, FileStreamGlobAuditRow{GlobID: g.ID, Box: g.Box, Action: FileStreamGlobAuditAdd, Key: g.Key, Glob: g.Glob,
		Actor: in.Actor, At: now})
	return *g, nil
}

// RemoveFileStreamGlob is FileStreamGlobStore.RemoveFileStreamGlob.
func (s *Memory) RemoveFileStreamGlob(_ context.Context, tenant, id, actor string, now time.Time) (FileStreamGlob, error) {
	if err := checkTenant(tenant); err != nil {
		return FileStreamGlob{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.fileStreamGlobsLocked()
	g := m.globs[id]
	if g == nil || g.Tenant != tenant || g.RemovedAt != nil {
		return FileStreamGlob{}, ErrNotFound
	}
	at := now
	g.RemovedAt = &at
	m.addAudit(tenant, FileStreamGlobAuditRow{GlobID: g.ID, Box: g.Box, Action: FileStreamGlobAuditRemove, Key: g.Key, Glob: g.Glob,
		Actor: actor, At: now})
	return *g, nil
}

// AuditFileStreamGlobRefusal is FileStreamGlobStore.AuditFileStreamGlobRefusal.
func (s *Memory) AuditFileStreamGlobRefusal(_ context.Context, tenant string, a FileStreamGlobAuditRow) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	a.GlobID, a.Action = "", FileStreamGlobAuditRefused
	s.fileStreamGlobsLocked().addAudit(tenant, a)
	return nil
}

// ListFileStreamGlobs is FileStreamGlobStore.ListFileStreamGlobs.
func (s *Memory) ListFileStreamGlobs(_ context.Context, tenant string) ([]FileStreamGlob, []FileStreamFolder, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.fileStreamGlobsLocked()
	globs := m.live(tenant, "")
	sort.SliceStable(globs, func(i, j int) bool {
		if globs[i].Box != globs[j].Box {
			return globs[i].Box < globs[j].Box
		}
		return globs[i].Key < globs[j].Key
	})
	folders := []FileStreamFolder{}
	for k, fs := range m.folders {
		if k[0] == tenant {
			folders = append(folders, fs...)
		}
	}
	sort.Slice(folders, func(i, j int) bool {
		if folders[i].Box != folders[j].Box {
			return folders[i].Box < folders[j].Box
		}
		return folders[i].Path < folders[j].Path
	})
	if globs == nil {
		globs = []FileStreamGlob{}
	}
	return globs, folders, nil
}

// FileStreamGlobAudit is FileStreamGlobStore.FileStreamGlobAudit.
func (s *Memory) FileStreamGlobAudit(_ context.Context, tenant string, before *time.Time, limit int) ([]FileStreamGlobAuditRow, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []FileStreamGlobAuditRow{}
	a := s.fileStreamGlobsLocked().audit
	for i := len(a) - 1; i >= 0 && len(out) < fileStreamAuditLimit(limit); i-- {
		if a[i].tenant == tenant && (before == nil || a[i].row.At.Before(*before)) {
			out = append(out, a[i].row)
		}
	}
	return out, nil
}

// BoxFileStreamGlobs is FileStreamGlobStore.BoxFileStreamGlobs.
func (s *Memory) BoxFileStreamGlobs(_ context.Context, tenant, box string) ([]FileStreamGlob, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.fileStreamGlobsLocked().live(tenant, box)
	if out == nil {
		out = []FileStreamGlob{}
	}
	return out, nil
}

// ReportFileStreamGlobs is FileStreamGlobStore.ReportFileStreamGlobs.
func (s *Memory) ReportFileStreamGlobs(_ context.Context, tenant, box string, folders []wire.FileStreamFolderReport, globs []wire.FileStreamGlobReport, now time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.fileStreamGlobsLocked()
	for _, r := range globs {
		g := m.globs[r.ID]
		if g == nil || g.Tenant != tenant || g.Box != box || g.RemovedAt != nil {
			continue
		}
		at := now
		g.State, g.Reason, g.Matched, g.Followed, g.OverCap, g.ReportedAt = r.State, r.Reason, r.Matched, r.Followed, r.OverCap, &at
	}
	if folders != nil {
		fs := make([]FileStreamFolder, len(folders))
		for i, f := range folders {
			fs[i] = FileStreamFolder{Box: box, Path: f.Path, State: f.State, Reason: f.Reason, ReportedAt: now}
		}
		m.folders[[2]string{tenant, box}] = fs
	}
	return nil
}

// PruneFileStreamGlobAudit is FileStreamGlobStore.PruneFileStreamGlobAudit.
func (s *Memory) PruneFileStreamGlobAudit(_ context.Context, before time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.fileStreamGlobsLocked()
	keep := m.audit[:0]
	for _, a := range m.audit {
		if !a.row.At.Before(before) {
			keep = append(keep, a)
		}
	}
	n := len(m.audit) - len(keep)
	m.audit = keep
	return n, nil
}

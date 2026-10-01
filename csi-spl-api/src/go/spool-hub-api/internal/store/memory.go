package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// Memory is an in-process Store for unit tests (003 Assumptions: memory
// allowed in tests; production is Postgres). Same semantics as Postgres.
type Memory struct {
	mu       sync.Mutex
	tenants  map[string]Tenant
	pins     map[[2]string]*memPin
	history  []memHist
	boxes    map[[2]string]time.Time
	roster   map[[2]string][]string
	messages map[[2]string]*Message
	// specs/032: every body a message has had, oldest first, per (tenant, msg).
	revisions map[[2]string][]MessageRevision
	// SPL-952: every kind change of a message, oldest first, per (tenant, msg).
	kindChanges map[[2]string][]KindChange
	// rdb 0037: emoji rows per (tenant, msg), in the order they were added.
	reactions  map[[2]string][]memReaction
	leases     map[[3]string]memLease // rdb 0094 fleet_leases
	deliveries map[[3]string]*memDelivery
	seq        int
	hum        memHumans               // humans_memory.go, guarded by mu
	ch         memChannels             // channels_memory.go, guarded by mu
	pay        memPayments             // payments_memory.go, guarded by mu
	hosts      map[string]TenantHost   // tenant_hosts.go, guarded by mu
	keys       memKeys                 // human_keys_memory.go, guarded by mu
	events     memEvents               // human_events_memory.go, guarded by mu
	operators  map[[3]string]time.Time // box_operators.go (rdb 0040), guarded by mu
	iss        memIssues               // issues.go (rdb 0047), guarded by mu
	fb         memFallbacks            // fallback_memory.go (rdb 0067), guarded by mu
	anyMoved   bool                    // message_move.go (rdb 0069): a row was ever moved
	// tenant_settings.go (rdb 0074): tenants.default_locale, guarded by mu
	tenantLocale map[string]string
}

type memPin struct {
	pub     ed25519.PublicKey
	revoked bool
	lastOp  time.Time
}

type memHist struct {
	tenant, box, reason string
	pub                 ed25519.PublicKey
	at                  time.Time
}

type memDelivery struct {
	state      string
	receivedAt time.Time
	expiresAt  time.Time
	seq        int
}

// NewMemory returns an empty in-memory store.
func NewMemory() *Memory {
	return &Memory{
		tenants: map[string]Tenant{}, pins: map[[2]string]*memPin{},
		boxes: map[[2]string]time.Time{}, roster: map[[2]string][]string{},
		messages: map[[2]string]*Message{}, deliveries: map[[3]string]*memDelivery{},
		revisions: map[[2]string][]MessageRevision{},
	}
}

func (s *Memory) CreateTenant(_ context.Context, t Tenant) error {
	if err := normalizeTenant(&t); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if old, ok := s.tenants[t.ID]; ok {
		if !bytes.Equal(old.RootPubKey, t.RootPubKey) {
			return ErrConflict
		}
		return nil
	}
	if s.projectHeldLocked(t.ID, t.ProjectID) {
		return ErrConflict
	}
	t.BoughtAt = t.BoughtAt.UTC()
	s.tenants[t.ID] = t
	s.ch.seedLocked(t.ID, time.Now().UTC())
	return nil
}

func (s *Memory) GetTenant(_ context.Context, id string) (Tenant, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[id]
	if !ok {
		return Tenant{}, ErrNotFound
	}
	return t, nil
}

func (s *Memory) SetBillingStatus(_ context.Context, id, status string) error {
	if !billing.ValidStatus(status) {
		return fmt.Errorf("invalid billing_status %q", status)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[id]
	if !ok {
		return ErrNotFound
	}
	t.BillingStatus = status
	s.tenants[id] = t
	return nil
}

func (s *Memory) PutPin(_ context.Context, tenant, box string, pub ed25519.PublicKey, force bool, opTS, now time.Time) error {
	opTS = opTS.Truncate(time.Microsecond) // timestamptz precision: compare like Postgres stores
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	k := [2]string{tenant, box}
	reason := "pin"
	if p, ok := s.pins[k]; ok {
		if bytes.Equal(p.pub, pub) && !p.revoked {
			return nil
		}
		if !force {
			return ErrConflict
		}
		if !p.lastOp.IsZero() && !opTS.After(p.lastOp) {
			return ErrStale
		}
		reason = "force"
	}
	cp := append(ed25519.PublicKey(nil), pub...)
	s.pins[k] = &memPin{pub: cp, lastOp: opTS}
	s.history = append(s.history, memHist{tenant: tenant, box: box, reason: reason, pub: cp, at: now})
	return nil
}

func (s *Memory) RevokePin(_ context.Context, tenant, box string, opTS, now time.Time) error {
	opTS = opTS.Truncate(time.Microsecond) // timestamptz precision: compare like Postgres stores
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.pins[[2]string{tenant, box}]
	if !ok {
		return ErrNotFound
	}
	if p.revoked {
		return nil
	}
	if !p.lastOp.IsZero() && !opTS.After(p.lastOp) {
		return ErrStale
	}
	p.revoked, p.lastOp = true, opTS
	s.history = append(s.history, memHist{
		tenant: tenant, box: box, reason: "revoke",
		pub: append(ed25519.PublicKey(nil), p.pub...), at: now,
	})
	return nil
}

func (s *Memory) GetPin(_ context.Context, tenant, box string) (ed25519.PublicKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.pins[[2]string{tenant, box}]
	if !ok || p.revoked {
		return nil, ErrNotFound
	}
	return p.pub, nil
}

func (s *Memory) ListPins(_ context.Context, tenant string) ([]Pin, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Pin
	for k, p := range s.pins {
		if k[0] == tenant && !p.revoked {
			out = append(out, Pin{BoxID: k[1], PubKey: p.pub})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].BoxID < out[j].BoxID })
	return out, nil
}

func (s *Memory) TouchBox(_ context.Context, tenant, box string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.boxes[[2]string{tenant, box}] = now
	return nil
}

func (s *Memory) SetRoster(_ context.Context, tenant, box string, agents []string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if t, ok := s.tenants[tenant]; ok && t.SeatsBots > 0 &&
		overBotCap(t.SeatsBots, s.countBotsLocked(tenant), s.roster[[2]string{tenant, box}], agents) {
		return ErrSeatQuota
	}
	s.boxes[[2]string{tenant, box}] = now
	a := append([]string(nil), agents...)
	sort.Strings(a)
	s.roster[[2]string{tenant, box}] = a
	return nil
}

func (s *Memory) Roster(_ context.Context, tenant string) (map[string][]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string][]string{}
	for k, a := range s.roster {
		if k[0] == tenant && len(a) > 0 {
			out[k[1]] = append([]string(nil), a...)
		}
	}
	return out, nil
}

func (s *Memory) InsertMessage(_ context.Context, m Message) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{m.TenantID, m.MsgID}
	if old, ok := s.messages[k]; ok {
		if bytes.Equal(old.Env, m.Env) {
			return false, nil
		}
		return false, ErrConflict
	}
	c := m
	s.messages[k] = &c
	return true, nil
}

func (s *Memory) Enqueue(_ context.Context, tenant, msgID, toBox string, now, expires time.Time, maxPerBox int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [3]string{tenant, msgID, toBox}
	if _, ok := s.deliveries[k]; !ok {
		s.seq++
		s.deliveries[k] = &memDelivery{state: StateQueued, receivedAt: now, expiresAt: expires, seq: s.seq}
	}
	s.capLocked(tenant, toBox, maxPerBox)
	return nil
}

// capLocked expires the oldest queued rows of (tenant, box) beyond max.
func (s *Memory) capLocked(tenant, box string, max int) int {
	if max <= 0 {
		return 0
	}
	var q []*memDelivery
	for k, d := range s.deliveries {
		if k[0] == tenant && k[2] == box && d.state == StateQueued {
			q = append(q, d)
		}
	}
	if len(q) <= max {
		return 0
	}
	sort.Slice(q, func(i, j int) bool { return older(q[i], q[j]) })
	n := len(q) - max
	for _, d := range q[:n] {
		d.state = StateExpired
	}
	return n
}

func older(a, b *memDelivery) bool {
	if !a.receivedAt.Equal(b.receivedAt) {
		return a.receivedAt.Before(b.receivedAt)
	}
	return a.seq < b.seq
}

func (s *Memory) ClaimSent(_ context.Context, tenant, msgID, toBox string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deliveries[[3]string{tenant, msgID, toBox}]
	if !ok || d.state != StateQueued || !now.Before(d.expiresAt) {
		return false, nil
	}
	d.state = StateSent
	return true, nil
}

func (s *Memory) Unclaim(_ context.Context, tenant, msgID, toBox string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d, ok := s.deliveries[[3]string{tenant, msgID, toBox}]; ok && d.state == StateSent {
		d.state = StateQueued
	}
	return nil
}

func (s *Memory) DeliveryState(_ context.Context, tenant, msgID, toBox string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deliveries[[3]string{tenant, msgID, toBox}]
	if !ok {
		return "", ErrNotFound
	}
	return d.state, nil
}

func (s *Memory) QueuedFor(_ context.Context, tenant, toBox string, now time.Time) ([]Queued, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	type row struct {
		d   *memDelivery
		env []byte
		id  string
	}
	var rows []row
	for k, d := range s.deliveries {
		if k[0] == tenant && k[2] == toBox && d.state == StateQueued && now.Before(d.expiresAt) {
			if m, ok := s.messages[[2]string{tenant, k[1]}]; ok {
				rows = append(rows, row{d, m.Env, k[1]})
			}
		}
	}
	sort.Slice(rows, func(i, j int) bool { return older(rows[i].d, rows[j].d) })
	out := make([]Queued, len(rows))
	for i, r := range rows {
		out[i] = Queued{MsgID: r.id, Env: r.env}
	}
	return out, nil
}

func (s *Memory) TaskEnvelopes(_ context.Context, tenant, taskID string) ([][]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ms []*Message
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == taskID {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool {
		if !ms[i].TS.Equal(ms[j].TS) {
			return ms[i].TS.Before(ms[j].TS)
		}
		return ms[i].MsgID < ms[j].MsgID
	})
	out := make([][]byte, len(ms))
	for i, m := range ms {
		out[i] = m.Env
	}
	return out, nil
}

func (s *Memory) BoxTaskEnvelopes(_ context.Context, tenant, taskID, box string, now time.Time) ([][]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ms []*Message
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != taskID || !m.ExpiresAt.After(now) {
			continue
		}
		if _, got := s.deliveries[[3]string{tenant, m.MsgID, box}]; m.FromBox == box || m.ToBox == box || got {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool {
		if !ms[i].TS.Equal(ms[j].TS) {
			return ms[i].TS.Before(ms[j].TS)
		}
		return ms[i].MsgID < ms[j].MsgID
	})
	out := make([][]byte, len(ms))
	for i, m := range ms {
		out[i] = m.Env
	}
	return out, nil
}

func (s *Memory) Sweep(_ context.Context, now time.Time) (SweepResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var r SweepResult
	for _, d := range s.deliveries {
		if d.state == StateQueued && !now.Before(d.expiresAt) {
			d.state = StateExpired
			r.Expired++
		}
	}
	for k, m := range s.messages {
		if !now.Before(m.ExpiresAt) {
			delete(s.messages, k)
			for dk := range s.deliveries {
				if dk[0] == k[0] && dk[1] == k[1] {
					delete(s.deliveries, dk)
				}
			}
			r.Purged++
		}
	}
	return r, nil
}

func (s *Memory) CountMessagesSince(_ context.Context, tenant string, since time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for k, m := range s.messages {
		if k[0] == tenant && !m.ReceivedAt.Before(since) {
			n++
		}
	}
	return n, nil
}

func (s *Memory) HasMessage(_ context.Context, tenant, msgID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.messages[[2]string{tenant, msgID}]
	return ok, nil
}

func (s *Memory) HasTopicOrMessage(_ context.Context, tenant, id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.messages[[2]string{tenant, id}]; ok {
		return true, nil
	}
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == id {
			return true, nil
		}
	}
	return false, nil
}

func (s *Memory) MessageTimes(_ context.Context, tenant, msgID string) (time.Time, time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok {
		return time.Time{}, time.Time{}, ErrNotFound
	}
	return m.TS, m.ReceivedAt, nil
}

func (s *Memory) TopicChannel(_ context.Context, tenant, taskID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var root *Message
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != taskID || m.IsParent != 1 {
			continue
		}
		if root == nil || m.ReceivedAt.Before(root.ReceivedAt) ||
			(m.ReceivedAt.Equal(root.ReceivedAt) && m.MsgID < root.MsgID) {
			root = m
		}
	}
	if root == nil {
		return "", nil
	}
	return root.Channel, nil
}

func (s *Memory) TaskFirstChannel(_ context.Context, tenant, taskID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var first *Message
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != taskID {
			continue
		}
		if first == nil || m.ReceivedAt.Before(first.ReceivedAt) ||
			(m.ReceivedAt.Equal(first.ReceivedAt) && m.MsgID < first.MsgID) {
			first = m
		}
	}
	if first == nil {
		return "", nil
	}
	return first.Channel, nil
}

func (s *Memory) Close() {}

// ---- M4 seats (seats.go) ------------------------------------------------------

func (s *Memory) projectHeldLocked(tenant, projectID string) bool {
	if projectID == "" {
		return false
	}
	for id, t := range s.tenants {
		if id != tenant && t.ProjectID == projectID {
			return true
		}
	}
	return false
}

func (s *Memory) countBotsLocked(tenant string) int {
	n := 0
	for k, a := range s.roster {
		if k[0] != tenant {
			continue
		}
		for _, id := range a {
			if isBot(id) {
				n++
			}
		}
	}
	return n
}

func (s *Memory) CountMembers(_ context.Context, tenant string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hum.memberCount(tenant), nil
}

func (s *Memory) CountBots(_ context.Context, tenant string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.countBotsLocked(tenant), nil
}

func (s *Memory) SetSeatCaps(_ context.Context, tenant string, users, bots int) error {
	if err := checkSeatCaps(users, bots); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[tenant]
	if !ok {
		return ErrNotFound
	}
	t.SeatsUsers, t.SeatsBots = users, bots
	s.tenants[tenant] = t
	return nil
}

func (s *Memory) SetBuyStamp(_ context.Context, tenant, org, app, projectID string, boughtAt time.Time) error {
	if err := checkBuyStamp(org, app, projectID); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.tenants[tenant]
	if !ok {
		return ErrNotFound
	}
	if s.projectHeldLocked(tenant, projectID) {
		return ErrConflict
	}
	t.Org, t.App, t.ProjectID, t.BoughtAt = org, app, projectID, boughtAt.UTC()
	s.tenants[tenant] = t
	return nil
}

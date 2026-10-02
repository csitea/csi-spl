package store

import (
	"crypto/ed25519"
	"sync"
	"time"
)

// hotCache holds the two rows every box send reads before anything else: the
// sender's pin (and the to_box pin) and the tenant row (billing status), 027
// T040. Only found rows are cached, never a miss or an error, so a new pin or
// tenant is seen at once.
//
// Staleness bound (the spec states it): a write through this *Postgres - a pin
// PUT or REVOKE, a billing status change, a payment, a claim, seat caps, a buy
// stamp - clears the whole cache after its transaction commits, so the next
// read on this instance sees it. A write this process did not make (another
// hub instance, e.g. the old revision during a roll, or SQL run by hand) is
// seen within hotCacheTTL. gen makes a fill that raced a write unable to store
// the row it read before that write.
//
// DB payload cut 5: it also holds the view door's membership read (role,
// channel_order and the human's channel_humans list, memberRead) per
// (tenant, human), which every view request and browser frame read again.
// Only a request carrying a memo reads or fills it (memo.go), so a path
// without one still reads the membership live. Every writer of a membership's
// role, suspension or channel_order, of channel_humans, or of a channel's
// archive state clears it the same way, so a revocation is seen at once on
// this instance and within hotCacheTTL on any other.
type hotCache struct {
	mu      sync.Mutex
	gen     uint64
	tenants map[string]hotEntry[Tenant]
	pins    map[[2]string]hotEntry[ed25519.PublicKey]
	doors   map[[2]string]hotEntry[memberRead]
}

type hotEntry[V any] struct {
	v   V
	exp time.Time
}

// hotCacheTTL bounds how long a row written by another process can be served.
const hotCacheTTL = 5 * time.Second

// hotNow is the cache clock (a test moves it).
var hotNow = time.Now

// generation is read BEFORE the database read whose row may be stored.
func (c *hotCache) generation() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.gen
}

// forget drops every cached row; every tenants / pins / door writer defers it.
func (c *hotCache) forget() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.gen++
	c.tenants, c.pins, c.doors = nil, nil, nil
}

func (c *hotCache) tenant(id string) (Tenant, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.tenants[id]
	if !ok || !hotNow().Before(e.exp) {
		return Tenant{}, false
	}
	t := e.v
	t.RootPubKey = append(ed25519.PublicKey(nil), t.RootPubKey...)
	return t, true
}

func (c *hotCache) putTenant(gen uint64, t Tenant) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if gen != c.gen {
		return
	}
	if c.tenants == nil {
		c.tenants = map[string]hotEntry[Tenant]{}
	}
	t.RootPubKey = append(ed25519.PublicKey(nil), t.RootPubKey...)
	c.tenants[t.ID] = hotEntry[Tenant]{v: t, exp: hotNow().Add(hotCacheTTL)}
}

func (c *hotCache) pin(tenant, box string) (ed25519.PublicKey, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.pins[[2]string{tenant, box}]
	if !ok || !hotNow().Before(e.exp) {
		return nil, false
	}
	return append(ed25519.PublicKey(nil), e.v...), true
}

func (c *hotCache) putPin(gen uint64, tenant, box string, pub ed25519.PublicKey) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if gen != c.gen {
		return
	}
	if c.pins == nil {
		c.pins = map[[2]string]hotEntry[ed25519.PublicKey]{}
	}
	c.pins[[2]string{tenant, box}] = hotEntry[ed25519.PublicKey]{v: append(ed25519.PublicKey(nil), pub...), exp: hotNow().Add(hotCacheTTL)}
}

// door is the cached membership read of human in tenant (a found row only).
func (c *hotCache) door(tenant, human string) (memberRead, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.doors[[2]string{tenant, human}]
	if !ok || !hotNow().Before(e.exp) {
		return memberRead{}, false
	}
	return e.v.clone(), true
}

func (c *hotCache) putDoor(gen uint64, tenant, human string, v memberRead) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if gen != c.gen {
		return
	}
	if c.doors == nil {
		c.doors = map[[2]string]hotEntry[memberRead]{}
	}
	c.doors[[2]string{tenant, human}] = hotEntry[memberRead]{v: v.clone(), exp: hotNow().Add(hotCacheTTL)}
}

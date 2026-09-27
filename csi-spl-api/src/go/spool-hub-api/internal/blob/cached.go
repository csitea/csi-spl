package blob

import (
	"bytes"
	"container/list"
	"context"
	"io"
	"strings"
	"sync"
	"time"
)

// Cached keeps recently read content-addressed objects in memory in front of
// a Store (CLE-35061). An attachment read was one GCS round trip every time:
// prd 2026-09-27, GET /v1/files/{id} 71 ms p50 / 157 ms p95 of server time
// (n=116, 6 h), and one browser fetched the same picture 15 times, because
// the answer varies on the session cookie and a tenant switch mints a new one.
//
// Only keys whose name IS the sha256 of their bytes are cached (t/<tenant>/
// files/<sha256> and avatars/<sha256>): a cached copy can never be stale in
// content. It can outlive a Delete done by ANOTHER hub instance, so an entry
// lives at most ttl; a Delete, Put or Promote through this Store evicts at
// once. Scratch keys (tmp/) and every other call pass straight through.
// Reading is still behind the hub's read door: the cache only saves the
// object store round trip after the door said yes.
type Cached struct {
	Store
	maxBytes, maxObj int64
	ttl              time.Duration
	now              func() time.Time

	mu    sync.Mutex
	size  int64
	order *list.List // front = most recently used
	items map[string]*list.Element
}

type cachedObj struct {
	key string
	b   []byte
	at  time.Time
}

// NewCached wraps s with at most maxBytes of objects of at most maxObj bytes
// each, each kept for at most ttl.
func NewCached(s Store, maxBytes, maxObj int64, ttl time.Duration) *Cached {
	return &Cached{Store: s, maxBytes: maxBytes, maxObj: maxObj, ttl: ttl, now: time.Now,
		order: list.New(), items: map[string]*list.Element{}}
}

// cacheable: the key names its own content.
func cacheable(key string) bool {
	name := key[strings.LastIndexByte(key, '/')+1:]
	if !sha256Re.MatchString(name) {
		return false
	}
	return strings.HasPrefix(key, "avatars/") || (strings.HasPrefix(key, "t/") && strings.HasSuffix(key, "/files/"+name))
}

func (c *Cached) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	if !cacheable(key) || c.maxObj <= 0 {
		return c.Store.Get(ctx, key)
	}
	if b, ok := c.lookup(key); ok {
		return io.NopCloser(bytes.NewReader(b)), nil
	}
	rc, err := c.Store.Get(ctx, key)
	if err != nil {
		return nil, err
	}
	// Read up to one byte past the object limit: a small object is kept,
	// a big one streams on from where the read stopped.
	var buf bytes.Buffer
	n, err := io.CopyN(&buf, rc, c.maxObj+1)
	if err != nil && err != io.EOF {
		rc.Close()
		return nil, err
	}
	if n > c.maxObj {
		return struct {
			io.Reader
			io.Closer
		}{io.MultiReader(bytes.NewReader(buf.Bytes()), rc), rc}, nil
	}
	rc.Close()
	b := buf.Bytes()
	c.keep(key, b)
	return io.NopCloser(bytes.NewReader(b)), nil
}

func (c *Cached) lookup(key string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.items[key]
	if !ok {
		return nil, false
	}
	o := e.Value.(*cachedObj)
	if c.now().Sub(o.at) > c.ttl {
		c.drop(e)
		return nil, false
	}
	c.order.MoveToFront(e)
	return o.b, true
}

func (c *Cached) keep(key string, b []byte) {
	if int64(len(b)) > c.maxBytes {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.items[key]; ok {
		c.drop(e)
	}
	c.items[key] = c.order.PushFront(&cachedObj{key: key, b: b, at: c.now()})
	c.size += int64(len(b))
	for c.size > c.maxBytes {
		c.drop(c.order.Back())
	}
}

// drop removes e; the caller holds mu.
func (c *Cached) drop(e *list.Element) {
	o := e.Value.(*cachedObj)
	c.order.Remove(e)
	delete(c.items, o.key)
	c.size -= int64(len(o.b))
}

func (c *Cached) evict(keys ...string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, k := range keys {
		if e, ok := c.items[k]; ok {
			c.drop(e)
		}
	}
}

func (c *Cached) Put(ctx context.Context, key string, data []byte) error {
	c.evict(key)
	return c.Store.Put(ctx, key, data)
}

func (c *Cached) Promote(ctx context.Context, src, dst string) (bool, error) {
	c.evict(src, dst)
	return c.Store.Promote(ctx, src, dst)
}

func (c *Cached) Delete(ctx context.Context, key string) error {
	c.evict(key)
	return c.Store.Delete(ctx, key)
}

package store

// perf round 4 G3: Postgres round trips of the two write transactions that
// queue their statements as a pgx.Batch (MergeTopic, CreateIssue), counted
// by a TCP proxy between the store and the server. A round trip is one
// client-to-server packet: pgx writes one buffer per round trip, and a batch
// is one. Skipped without SPOOL_TEST_PG_DSN (the memory store has no wire).
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/store -run TestWriteBatchRoundTrips -v

import (
	"context"
	"io"
	"net"
	"net/url"
	"os"
	"sort"
	"sync/atomic"
	"testing"
	"time"
)

type rtProxy struct {
	ln      net.Listener
	packets atomic.Int64
}

func newRTProxy(t *testing.T, target string) *rtProxy {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	p := &rtProxy{ln: ln}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			s, err := net.Dial("tcp", target)
			if err != nil {
				c.Close()
				continue
			}
			go func() { io.Copy(c, s); c.Close() }() //nolint:errcheck
			go func() {
				buf := make([]byte, 64<<10)
				for {
					n, err := c.Read(buf)
					if n > 0 {
						p.packets.Add(1)
						if _, werr := s.Write(buf[:n]); werr != nil {
							break
						}
					}
					if err != nil {
						break
					}
				}
				s.Close()
			}()
		}
	}()
	return p
}

func TestWriteBatchRoundTrips(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if u.Host == "" {
		t.Skip("SPOOL_TEST_PG_DSN is a unix socket; the counting proxy needs TCP")
	}
	ctx := context.Background()
	direct, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(direct.Close)
	if _, err := Migrate(ctx, direct.Pool(), sqlDir(t)); err != nil {
		t.Fatal(err)
	}
	proxy := newRTProxy(t, u.Host)
	u.Host = proxy.ln.Addr().String()
	pg, err := OpenPostgres(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)

	now := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	put := func(task, parent string, isParent, n int) Message {
		t.Helper()
		at := now.Add(time.Duration(n) * time.Second)
		m := msgFor(tid, task, "box-b", at, at, `{"n":"`+uuid4()+`"}`)
		m.ParentTaskID, m.IsParent, m.Channel = parent, isParent, "devel"
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	bug, err := pg.CreateIssueLabel(ctx, IssueLabel{TenantID: tid, Name: "bug", Color: "#FF0000", CreatedBy: "HUM-1"}, now)
	if err != nil {
		t.Fatal(err)
	}
	epic, err := pg.CreateIssue(ctx, Issue{TenantID: tid, Title: "epic", Kind: "epic", TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
	if err != nil {
		t.Fatal(err)
	}

	// Each probe's setup runs outside the count; only the call it returns is
	// counted. budget bounds the median of n. Measured n=5 on ead5b2e3, one
	// statement at a time: merge 12, create 6 plain / 8 with label + parent.
	probes := []struct {
		name   string
		budget int64
		setup  func() func() error
	}{
		{"MergeTopic (3-row source)", 7, func() func() error {
			S, T := uuid4(), uuid4()
			c := put(S, "", 1, 0)
			put(S, "", 0, 1)
			put(uuid4(), S, 1, 2)
			put(T, "", 1, 3)
			return func() error {
				_, err := pg.MergeTopic(ctx, tid, c.MsgID, S, T, "devel", "HUM-1", now)
				return err
			}
		}},
		{"CreateIssue (plain)", 6, func() func() error {
			return func() error {
				_, err := pg.CreateIssue(ctx, Issue{TenantID: tid, Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
				return err
			}
		}},
		{"CreateIssue (label + parent)", 8, func() func() error {
			return func() error {
				_, err := pg.CreateIssue(ctx, Issue{TenantID: tid, Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1",
					Labels: []string{bug.LabelID}, Parent: epic.Number}, now)
				return err
			}
		}},
	}
	const n = 5
	for _, p := range probes {
		if err := p.setup()(); err != nil { // warm the statement cache
			t.Fatalf("%s: %v", p.name, err)
		}
		var got []int64
		for i := 0; i < n; i++ {
			run := p.setup()
			before := proxy.packets.Load()
			if err := run(); err != nil {
				t.Fatalf("%s: %v", p.name, err)
			}
			got = append(got, proxy.packets.Load()-before)
		}
		sort.Slice(got, func(a, b int) bool { return got[a] < got[b] })
		t.Logf("%-30s RT n=%d min/median/max %d/%d/%d", p.name, n, got[0], got[n/2], got[n-1])
		if got[n/2] > p.budget {
			t.Errorf("%s: median %d round trips, budget %d", p.name, got[n/2], p.budget)
		}
	}
}

package hub_test

// 027 T040 (FR-001): the onSend hot path over a real socket against a real
// Postgres. Skipped without SPOOL_TEST_PG_DSN. One tenant per period size
// ({10k, 200k} messages received this period), 0 or 2 blob attachments,
// concurrency 1 or 50 (one ws session per worker). Besides ns/op it reports
// sends/s, p50/p95 in ms and DB round trips per send, counted as the
// client-to-server packets through a TCP proxy in front of Postgres (pgx
// writes one buffer per round trip).
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/hub -run '^$' -bench BenchmarkOnSend -count 5
//
// SPOOL_BENCH_BLOB_LATENCY (e.g. 15ms) adds that delay to every blob Exists,
// the stand-in for the GCS metadata call production makes per attachment.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/jackc/pgx/v5"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// pgProxy forwards to Postgres and counts client-to-server packets.
type pgProxy struct {
	ln      net.Listener
	packets atomic.Int64
}

func newPGProxy(b testing.TB, target string) *pgProxy {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		b.Fatal(err)
	}
	p := &pgProxy{ln: ln}
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

type slowBlob struct {
	blob.Store
	d time.Duration
}

func (s slowBlob) Exists(ctx context.Context, key string) (bool, error) {
	time.Sleep(s.d)
	return s.Store.Exists(ctx, key)
}

type benchHub struct {
	proxy *pgProxy
	pg    *store.Postgres
	dial  func(ctx context.Context, network, addr string) (net.Conn, error)
	priv  ed25519.PrivateKey
	files []msg.Attachment
}

var (
	benchOnce sync.Once
	benchEnv  *benchHub
	benchErr  error
)

const benchQueueCap = 1000

var benchTenants = map[int]string{10_000: "tbench10k", 200_000: "tbench200k"}

func sqlDir() string {
	if d := os.Getenv("SPOOL_TEST_SQL_DIR"); d != "" {
		return d
	}
	_, f, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(f), "..", "..", "..", "..", "..", "..", "csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
}

// seed makes tenant hold rows messages received between the period start and
// now (skipped when it already holds them: -count reruns reuse the seed).
func seed(ctx context.Context, pg *store.Postgres, tenant string, rows int, rootPub ed25519.PublicKey) error {
	if err := pg.CreateTenant(ctx, store.Tenant{ID: tenant, RootPubKey: rootPub}); err != nil {
		return err
	}
	start := billing.PeriodStart(time.Now())
	n, err := pg.CountMessagesSince(ctx, tenant, start)
	if err != nil || n >= rows {
		return err
	}
	return pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id,
				to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at)
			SELECT $1, gen_random_uuid(), gen_random_uuid(), t, 'box-a', 'GRK-03', 'box-b', 'CLE-07', 'note',
				'seed', '[]', '{}', 'x', '\x00'::bytea, t, t + interval '30 days'
			FROM (SELECT $2::timestamptz + (i * ($3::timestamptz - $2::timestamptz) / $4) AS t
				FROM generate_series(1, $4::int) i) s`, tenant, start, time.Now(), rows-n); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `ANALYZE messages`)
		return err
	})
}

func setupBench(b *testing.B) *benchHub {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		b.Skip("SPOOL_TEST_PG_DSN unset")
	}
	benchOnce.Do(func() { benchEnv, benchErr = buildBench(b, dsn) })
	if benchErr != nil {
		b.Fatal(benchErr)
	}
	return benchEnv
}

func buildBench(b *testing.B, dsn string) (*benchHub, error) {
	ctx := context.Background()
	seedPG, err := store.OpenPostgres(ctx, dsn)
	if err != nil {
		return nil, err
	}
	defer seedPG.Close()
	if _, err := store.Migrate(ctx, seedPG.Pool(), sqlDir()); err != nil {
		return nil, err
	}
	u, err := url.Parse(dsn)
	if err != nil {
		return nil, err
	}
	proxy := newPGProxy(b, u.Host)
	u.Host = proxy.ln.Addr().String()
	pg, err := store.OpenPostgres(ctx, u.String())
	if err != nil {
		return nil, err
	}

	// Fixed keys: a -count or a second run reuses the seeded tenants and pins.
	key := func(b byte) ed25519.PrivateKey {
		return ed25519.NewKeyFromSeed(bytes.Repeat([]byte{b}, ed25519.SeedSize))
	}
	rootPub := key(1).Public().(ed25519.PublicKey)
	priv := key(2)
	boxPub := priv.Public().(ed25519.PublicKey)
	peerPub := key(3).Public().(ed25519.PublicKey)
	dir, err := os.MkdirTemp("", "onsend-bench-*") // outlives the first sub-benchmark (b.TempDir would not)
	if err != nil {
		return nil, err
	}
	blobs := blob.Store(blob.Dir{Root: dir})
	var files []msg.Attachment
	for i := 0; i < 2; i++ {
		data := []byte(fmt.Sprintf("bench file %d", i))
		sum := sha256.Sum256(data)
		id := hex.EncodeToString(sum[:])
		files = append(files, msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id,
			Name: fmt.Sprintf("f%d.txt", i), Bytes: int64(len(data))})
		for _, tenant := range benchTenants {
			key, _ := blob.Key(tenant, id)
			if err := blobs.Put(ctx, key, data); err != nil {
				return nil, err
			}
		}
	}
	for rows, tenant := range benchTenants {
		if err := seed(ctx, seedPG, tenant, rows, rootPub); err != nil {
			return nil, err
		}
		now := time.Now()
		for box, pub := range map[string]ed25519.PublicKey{"box-a": boxPub, "box-b": peerPub} {
			if err := pg.PutPin(ctx, tenant, box, pub, true, now, now); err != nil && err != store.ErrStale {
				return nil, err
			}
		}
	}
	if d, err := time.ParseDuration(os.Getenv("SPOOL_BENCH_BLOB_LATENCY")); err == nil && d > 0 {
		blobs = slowBlob{Store: blobs, d: d}
	}
	srv, err := hub.New(hub.Options{
		Store: pg, Blob: blobs, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 5 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: benchQueueCap,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "bench",
		QuotaMessagesPerMonth: 100_000_000,
	})
	if err != nil {
		return nil, err
	}
	ts := httptest.NewServer(srv.Handler())
	addr := ts.Listener.Addr().String()
	return &benchHub{proxy: proxy, pg: pg, priv: priv, files: files,
		dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		}}, nil
}

func (h *benchHub) session(b *testing.B, tenant string) *websocket.Conn {
	ctx := context.Background()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = h.dial
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/ws", &websocket.DialOptions{HTTPClient: &http.Client{Transport: tr}})
	if err != nil {
		b.Fatal(err)
	}
	var ch wire.Frame
	if err := wsjson.Read(ctx, c, &ch); err != nil {
		b.Fatal(err)
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	p, _ := wire.HelloPayload("box-a", ch.Nonce, ts)
	hello := wire.Frame{Type: wire.THello, BoxID: "box-a", TS: ts, Nonce: ch.Nonce, Role: wire.RoleCLI, Sig: sign.Sign(h.priv, p)}
	if err := wsjson.Write(ctx, c, hello); err != nil {
		b.Fatal(err)
	}
	var wel wire.Frame
	if err := wsjson.Read(ctx, c, &wel); err != nil || wel.Type != wire.TWelcome {
		b.Fatalf("welcome: %v %+v", err, wel)
	}
	return c
}

func uuid4() string {
	var u [16]byte
	rand.Read(u[:]) //nolint:errcheck
	u[6] = u[6]&0x0f | 0x40
	u[8] = u[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:])
}

func (h *benchHub) frame(b *testing.B, files []msg.Attachment) (string, wire.Frame) {
	m := &msg.Message{V: msg.V1, MsgID: uuid4(), TaskID: uuid4(), TS: time.Now().UTC().Format(time.RFC3339),
		From: "GRK-03", To: "CLE-07", Kind: "note", Body: "bench", Files: files}
	env, err := wire.NewEnvelope(h.priv, "box-a", "box-b", m)
	if err != nil {
		b.Fatal(err)
	}
	raw, err := env.Marshal()
	if err != nil {
		b.Fatal(err)
	}
	return m.MsgID, wire.Frame{Type: wire.TSend, Env: raw}
}

func BenchmarkOnSend(b *testing.B) {
	for _, rows := range []int{10_000, 200_000} {
		for _, nfiles := range []int{0, 2} {
			for _, conc := range []int{1, 50} {
				name := fmt.Sprintf("rows=%d/files=%d/c=%d", rows, nfiles, conc)
				b.Run(name, func(b *testing.B) { benchOnSend(b, benchTenants[rows], nfiles, conc) })
			}
		}
	}
}

func benchOnSend(b *testing.B, tenant string, nfiles, conc int) {
	h := setupBench(b)
	conns := make([]*websocket.Conn, conc)
	for i := range conns {
		conns[i] = h.session(b, tenant)
	}
	defer func() {
		for _, c := range conns {
			c.CloseNow() //nolint:errcheck
		}
	}()
	files := h.files[:nfiles]
	lat := make([]time.Duration, b.N)
	var next atomic.Int64
	var failed atomic.Value
	var errs atomic.Int64 // an error reply (e.g. 500 "message not stored") is counted, not fatal
	var wg sync.WaitGroup
	p0 := h.proxy.packets.Load()
	b.ResetTimer()
	t0 := time.Now()
	for _, c := range conns {
		wg.Add(1)
		go func(c *websocket.Conn) {
			defer wg.Done()
			ctx := context.Background()
			for {
				i := int(next.Add(1)) - 1
				if i >= b.N {
					return
				}
				id, f := h.frame(b, files)
				s := time.Now()
				if err := wsjson.Write(ctx, c, f); err != nil {
					failed.Store(err.Error())
					return
				}
				var r wire.Frame
				if err := wsjson.Read(ctx, c, &r); err != nil || r.MsgID != id {
					failed.Store(fmt.Sprintf("reply %v %+v", err, r))
					return
				}
				if r.Type != wire.TSent {
					errs.Add(1)
				}
				lat[i] = time.Since(s)
			}
		}(c)
	}
	wg.Wait()
	el := time.Since(t0)
	b.StopTimer()
	if v := failed.Load(); v != nil {
		b.Fatal(v)
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	pct := func(p float64) float64 { return float64(lat[int(p*float64(len(lat)-1))].Microseconds()) / 1000 }
	b.ReportMetric(float64(b.N)/el.Seconds(), "sends/s")
	b.ReportMetric(pct(0.50), "p50_ms")
	b.ReportMetric(pct(0.95), "p95_ms")
	b.ReportMetric(float64(h.proxy.packets.Load()-p0)/float64(b.N), "rt/send")
	b.ReportMetric(float64(errs.Load()), "errors")
	// box-b is never online: its queue sits at the cap. Rows over it are the
	// cap's overshoot right after the burst (Enqueue skips the trim when
	// another send of the same box holds the cap lock).
	q, err := h.pg.QueuedFor(context.Background(), tenant, "box-b", time.Now())
	if err != nil {
		b.Fatal(err)
	}
	b.ReportMetric(float64(len(q)-benchQueueCap), "queued_over_cap")
}

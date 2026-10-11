package hub_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/121 T105: the embed's abuse limits, bans and repeat offenders
// (embed_abuse.go). Each refusal also proves that nothing was written: no
// visitor row for a refused mint, no message for a refused post.

// abuseClock is a settable hub clock.
type abuseClock struct {
	mu sync.Mutex
	at time.Time
}

func (c *abuseClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.at }

func (c *abuseClock) add(d time.Duration) { c.mu.Lock(); c.at = c.at.Add(d); c.mu.Unlock() }

// abuseEnv is embedEnv (flag on) with the limits lim and, when clock is not
// nil, the hub reading that clock; it skips without Postgres.
func abuseEnv(t *testing.T, lim hub.EmbedLimits, clock *abuseClock) (*env, *store.Postgres) {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorToken
		o.EmbedEnabled, o.EmbedTokenLife, o.EmbedMessageMaxBytes = true, embedLife, 4096
		o.EmbedLimits = lim
		if clock != nil {
			o.Now = clock.now
		}
	})
	return e, pgOnly(t, e)
}

// newClock is a clock at 10:20:30 UTC today: mid-day, mid-hour,
// mid-minute, so a test's hour and minute steps never cross a window (a UTC
// day above all) by accident.
func newClock() *abuseClock {
	return &abuseClock{at: time.Now().UTC().Truncate(24 * time.Hour).Add(10*time.Hour + 20*time.Minute + 30*time.Second)}
}

// embedCounts is how many visitors embed has, and how many messages its
// visitor channels hold, read as the owner role in tid's scope.
func embedCounts(t *testing.T, pg *store.Postgres, tid, embed string) (visitors, messages int) {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM embed_visitors WHERE tenant_id = $1 AND embed_id = $2),
		(SELECT count(*) FROM messages m JOIN embed_visitors v ON v.tenant_id = m.tenant_id AND v.channel_id = m.channel
		 WHERE v.tenant_id = $1 AND v.embed_id = $2)`, tid, embed).Scan(&visitors, &messages); err != nil {
		t.Fatal(err)
	}
	return visitors, messages
}

// refusedAs checks a refusal's status and token.
func refusedAs(t *testing.T, name string, code int, raw []byte, wantCode int, wantToken string) {
	t.Helper()
	var out struct{ Error string }
	if code != wantCode || json.Unmarshal(raw, &out) != nil || out.Error != wantToken {
		t.Fatalf("%s: %d %s, want %d %s", name, code, raw, wantCode, wantToken)
	}
}

// TestEmbedVisitorsPerIPRefused: the address's third visitor of an hour is
// 429 embed_visitors and writes no visitor; the next hour admits again until
// the address's day is full (429 again, still no row).
func TestEmbedVisitorsPerIPRefused(t *testing.T) {
	clock := newClock()
	e, pg := abuseEnv(t, hub.EmbedLimits{VisitorsPerIPHour: 2, VisitorsPerIPDay: 3, BanAfterHits: 50, ChallengeAfterHits: 50}, clock)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	mintPath := "/v1/embed/" + embed + "/visitor"
	mint(t, e, tid, embed)
	mint(t, e, tid, embed)
	code, raw := embedCall(t, e, tid, http.MethodPost, mintPath, "", "")
	refusedAs(t, "third this hour", code, raw, http.StatusTooManyRequests, hub.TokenEmbedVisitors)
	if v, _ := embedCounts(t, pg, tid, embed); v != 2 {
		t.Fatalf("a refused mint wrote: %d visitors, want 2", v)
	}
	clock.add(time.Hour)
	mint(t, e, tid, embed) // CONTROL: a new hour admits
	code, raw = embedCall(t, e, tid, http.MethodPost, mintPath, "", "")
	refusedAs(t, "fourth this day", code, raw, http.StatusTooManyRequests, hub.TokenEmbedVisitors)
	if v, _ := embedCounts(t, pg, tid, embed); v != 3 {
		t.Fatalf("a refused mint wrote: %d visitors, want 3", v)
	}
}

// TestEmbedFullRefused: with the embed's live visitors at the limit a mint
// is 503 embed_full and writes no visitor. CONTROL: once the live visitor's
// token has expired, the mint is 201.
func TestEmbedFullRefused(t *testing.T) {
	clock := newClock()
	e, pg := abuseEnv(t, hub.EmbedLimits{LiveVisitorsMax: 1}, clock)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	mint(t, e, tid, embed)
	code, raw := embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/visitor", "", "")
	refusedAs(t, "full embed", code, raw, http.StatusServiceUnavailable, hub.TokenEmbedFull)
	if v, _ := embedCounts(t, pg, tid, embed); v != 1 {
		t.Fatalf("a refused mint wrote: %d visitors, want 1", v)
	}
	clock.add(embedLife.Sliding + time.Minute)
	mint(t, e, tid, embed)
}

// TestEmbedPostQuotaRefused: a visitor's third post of a minute is 429
// embed_quota and stores no message; the next minute posts again until its
// day is full (429, no message).
func TestEmbedPostQuotaRefused(t *testing.T) {
	clock := newClock()
	e, pg := abuseEnv(t, hub.EmbedLimits{PostsPerMinute: 2, PostsPerDay: 3, PowBits: 8, BanAfterHits: 50, ChallengeAfterHits: 50}, clock)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	tok, _ := mint(t, e, tid, embed)
	base := "/v1/embed/" + embed + "/messages"
	post := func(body string) (int, []byte) { return embedCall(t, e, tid, http.MethodPost, base, tok, body) }
	if code, raw := post(solvedPost(t, e, tid, embed, tok, "one")); code != http.StatusCreated {
		t.Fatalf("first post: %d %s", code, raw)
	}
	if code, raw := post(`{"body":"two"}`); code != http.StatusCreated {
		t.Fatalf("second post: %d %s", code, raw)
	}
	code, raw := post(`{"body":"three"}`)
	refusedAs(t, "third this minute", code, raw, http.StatusTooManyRequests, hub.TokenEmbedQuota)
	if _, m := embedCounts(t, pg, tid, embed); m != 2 {
		t.Fatalf("a refused post wrote: %d messages, want 2", m)
	}
	clock.add(time.Minute)
	if code, raw := post(`{"body":"three"}`); code != http.StatusCreated { // CONTROL: a new minute
		t.Fatalf("next minute: %d %s", code, raw)
	}
	code, raw = post(`{"body":"four"}`)
	refusedAs(t, "fourth this day", code, raw, http.StatusTooManyRequests, hub.TokenEmbedQuota)
	if _, m := embedCounts(t, pg, tid, embed); m != 3 {
		t.Fatalf("a refused post wrote: %d messages, want 3", m)
	}
}

// TestEmbedTooLargeWritesNothing: a post over the byte limit is 413 and
// stores no message, before the challenge or a counter is reached.
// CONTROL: the same visitor's post at the limit is 201.
func TestEmbedTooLargeWritesNothing(t *testing.T) {
	e, pg := abuseEnv(t, hub.EmbedLimits{PowBits: 8}, nil)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	tok, _ := mint(t, e, tid, embed)
	base := "/v1/embed/" + embed + "/messages"
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, tok, solvedPost(t, e, tid, embed, tok, strings.Repeat("x", 4097))); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over 4 KB: %d %s, want 413", code, raw)
	}
	if _, m := embedCounts(t, pg, tid, embed); m != 0 {
		t.Fatalf("a refused post wrote: %d messages", m)
	}
	if code, raw := embedCall(t, e, tid, http.MethodPost, base, tok, solvedPost(t, e, tid, embed, tok, strings.Repeat("x", 4096))); code != http.StatusCreated {
		t.Fatalf("CONTROL: at 4 KB: %d %s", code, raw)
	}
}

// TestEmbedRepeatOffender: hits of an address (here a filled honeypot)
// first make every post solve the challenge (ChallengeAfterHits), then ban
// the address (BanAfterHits): its posts and its new visitors are 403
// embed_banned and write nothing. CONTROL: before the hits a second post
// needs no proof; after BanFor and HitsWindow the address mints again.
func TestEmbedRepeatOffender(t *testing.T) {
	clock := newClock()
	e, pg := abuseEnv(t, hub.EmbedLimits{PowBits: 8, ChallengeAfterHits: 2, BanAfterHits: 3}, clock)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	tok, _ := mint(t, e, tid, embed)
	base := "/v1/embed/" + embed + "/messages"
	post := func(body string) (int, []byte) { return embedCall(t, e, tid, http.MethodPost, base, tok, body) }
	honeypot := `{"body":"buy now","website":"x"}`
	if code, raw := post(solvedPost(t, e, tid, embed, tok, "hello")); code != http.StatusCreated {
		t.Fatalf("first post: %d %s", code, raw)
	}
	code, raw := post(honeypot)
	refusedAs(t, "honeypot 1", code, raw, http.StatusForbidden, hub.TokenEmbedChallenge)
	if c := getChallenge(t, e, tid, embed, tok); c.Required {
		t.Fatalf("CONTROL: one hit: %+v, want not required", c)
	}
	code, raw = post(honeypot)
	refusedAs(t, "honeypot 2", code, raw, http.StatusForbidden, hub.TokenEmbedChallenge)
	if c := getChallenge(t, e, tid, embed, tok); !c.Required {
		t.Fatalf("two hits: %+v, want required", c)
	}
	code, raw = post(`{"body":"again"}`)
	refusedAs(t, "no proof after two hits", code, raw, http.StatusPreconditionRequired, hub.TokenEmbedChallenge)
	code, raw = post(honeypot)
	refusedAs(t, "honeypot 3", code, raw, http.StatusForbidden, hub.TokenEmbedChallenge)
	code, raw = post(solvedPost(t, e, tid, embed, tok, "again"))
	refusedAs(t, "banned post", code, raw, http.StatusForbidden, hub.TokenEmbedBanned)
	code, raw = embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/visitor", "", "")
	refusedAs(t, "banned mint", code, raw, http.StatusForbidden, hub.TokenEmbedBanned)
	if v, m := embedCounts(t, pg, tid, embed); v != 1 || m != 1 {
		t.Fatalf("refusals wrote: %d visitors, %d messages, want 1 and 1", v, m)
	}
	clock.add(26 * time.Hour)
	mint(t, e, tid, embed)
}

// TestEmbedTurnQuota: the sales agent's turns of one visitor (EmbedTurn,
// for T306) stop at TurnsPerDay with 429 embed_quota; the next UTC day
// grants them again.
func TestEmbedTurnQuota(t *testing.T) {
	clock := newClock()
	e, pg := abuseEnv(t, hub.EmbedLimits{TurnsPerDay: 2}, clock)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	tok, _ := mint(t, e, tid, embed)
	req, _ := http.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	hash, err := auth.EmbedBearer(req)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	v, err := pg.EmbedVisitorByToken(ctx, embed, hash, clock.now())
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if tok, status, _ := e.srv.EmbedTurn(ctx, v); tok != "" {
			t.Fatalf("turn %d: %s %d", i+1, tok, status)
		}
	}
	if tok, status, _ := e.srv.EmbedTurn(ctx, v); tok != hub.TokenEmbedQuota || status != http.StatusTooManyRequests {
		t.Fatalf("third turn: %s %d, want 429 embed_quota", tok, status)
	}
	clock.add(24 * time.Hour)
	if tok, status, _ := e.srv.EmbedTurn(ctx, v); tok != "" {
		t.Fatalf("CONTROL: next day: %s %d", tok, status)
	}
}

// replayMarks is how many sign-in replay marks (kind embed_jwt) tid holds.
func replayMarks(t *testing.T, pg *store.Postgres, tid string) int {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM quota_counts WHERE tenant_id = $1 AND kind = 'embed_jwt'`, tid).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// signInFrom posts jwt to embed's sign-in as the client address ip (the
// edge's one trusted X-Forwarded-For hop): the code and the raw body.
func signInFrom(t *testing.T, e *env, tid, embed, jwt, ip string) (int, []byte) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"jwt": jwt})
	req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/embed/"+embed+"/signin", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", ip)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, raw
}

// TestEmbedSignInPerIPRefused: an address's third sign-in of an hour (T205)
// is 429 embed_visitors and writes nothing: no replay mark, no visitor. The
// same JWT from another address is 200 (CONTROL: it was never marked used,
// and the other address has its own counters); the next hour admits the
// first address again until its day is full (429, still nothing written).
func TestEmbedSignInPerIPRefused(t *testing.T) {
	clock := newClock()
	e := rbacEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorToken
		o.EmbedEnabled, o.EmbedTokenLife, o.EmbedMessageMaxBytes = true, embedLife, 4096
		o.EmbedLimits = hub.EmbedLimits{VisitorsPerIPHour: 2, VisitorsPerIPDay: 3, BanAfterHits: 50, ChallengeAfterHits: 50}
		o.Edge.TrustedProxyHops = 1
		o.Now = clock.now
	})
	pg := pgOnly(t, e)
	k := newEmbedKey(t, "k-signin-ip")
	tid, embed := keyedEmbed(t, e, k)
	const ipA, ipB = "198.51.100.7", "203.0.113.9"
	jwt := func(sub string) string { return signJWT(t, k, es256(k.Kid), claimsFor(embed, sub, clock.now())) }
	ok := func(what, j, ip string) {
		t.Helper()
		if code, raw := signInFrom(t, e, tid, embed, j, ip); code != http.StatusOK {
			t.Fatalf("%s: %d %s, want 200", what, code, raw)
		}
	}
	nothingWritten := func(what string, visitors, marks int) {
		t.Helper()
		if v, _ := embedCounts(t, pg, tid, embed); v != visitors {
			t.Fatalf("%s wrote: %d visitors, want %d", what, v, visitors)
		}
		if m := replayMarks(t, pg, tid); m != marks {
			t.Fatalf("%s wrote: %d replay marks, want %d", what, m, marks)
		}
	}
	ok("first this hour", jwt("user-1"), ipA)
	ok("second this hour", jwt("user-2"), ipA)
	over := jwt("user-3")
	code, raw := signInFrom(t, e, tid, embed, over, ipA)
	refusedAs(t, "third this hour", code, raw, http.StatusTooManyRequests, hub.TokenEmbedVisitors)
	nothingWritten("a refused sign-in", 2, 2)
	ok("CONTROL: the refused JWT from another address", over, ipB)
	clock.add(time.Hour)
	ok("CONTROL: a new hour", jwt("user-4"), ipA)
	code, raw = signInFrom(t, e, tid, embed, jwt("user-5"), ipA)
	refusedAs(t, "fourth this day", code, raw, http.StatusTooManyRequests, hub.TokenEmbedVisitors)
	nothingWritten("a refused sign-in", 4, 4)
}

// quotaRows is how many quota_counts rows tid holds, and their sum of n,
// read as the owner role in tid's scope.
func quotaRows(t *testing.T, pg *store.Postgres, tid string) (rows, sum int) {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT count(*), coalesce(sum(n), 0)::int FROM quota_counts WHERE tenant_id = $1`,
		tid).Scan(&rows, &sum); err != nil {
		t.Fatal(err)
	}
	return rows, sum
}

// TestEmbedSignInBannedRefused: a banned address (here banned by its own
// hit on the sign-in limit, BanAfterHits 1) signing in in a new hour, with
// room in its sign-in counters, is 403 embed_banned as at the mint, and
// writes nothing: no visitor, no replay mark, no quota row or unit (the ban
// is checked before the per-IP count). CONTROL: the same JWT from an
// unbanned address is 200; without the ban check the banned address's
// sign-in is 200 too (it has quota left).
func TestEmbedSignInBannedRefused(t *testing.T) {
	clock := newClock()
	e := rbacEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorToken
		o.EmbedEnabled, o.EmbedTokenLife, o.EmbedMessageMaxBytes = true, embedLife, 4096
		o.EmbedLimits = hub.EmbedLimits{VisitorsPerIPHour: 1, VisitorsPerIPDay: 5, BanAfterHits: 1, ChallengeAfterHits: 50}
		o.Edge.TrustedProxyHops = 1
		o.Now = clock.now
	})
	pg := pgOnly(t, e)
	k := newEmbedKey(t, "k-signin-ban")
	tid, embed := keyedEmbed(t, e, k)
	const ipA, ipB = "198.51.100.7", "203.0.113.9"
	jwt := func(sub string) string { return signJWT(t, k, es256(k.Kid), claimsFor(embed, sub, clock.now())) }
	if code, raw := signInFrom(t, e, tid, embed, jwt("user-1"), ipA); code != http.StatusOK {
		t.Fatalf("first sign-in: %d %s, want 200", code, raw)
	}
	code, raw := signInFrom(t, e, tid, embed, jwt("user-2"), ipA)
	refusedAs(t, "over the hour (the hit that bans)", code, raw, http.StatusTooManyRequests, hub.TokenEmbedVisitors)
	clock.add(time.Hour)
	rows, sum := quotaRows(t, pg, tid)
	banned := jwt("user-3")
	code, raw = signInFrom(t, e, tid, embed, banned, ipA)
	refusedAs(t, "banned address", code, raw, http.StatusForbidden, hub.TokenEmbedBanned)
	if v, _ := embedCounts(t, pg, tid, embed); v != 1 {
		t.Fatalf("a banned sign-in wrote: %d visitors, want 1", v)
	}
	if m := replayMarks(t, pg, tid); m != 1 {
		t.Fatalf("a banned sign-in wrote: %d replay marks, want 1", m)
	}
	if r2, s2 := quotaRows(t, pg, tid); r2 != rows || s2 != sum {
		t.Fatalf("a banned sign-in wrote quota: %d rows (sum %d), want %d (sum %d)", r2, s2, rows, sum)
	}
	if code, raw := signInFrom(t, e, tid, embed, banned, ipB); code != http.StatusOK {
		t.Fatalf("CONTROL: the same JWT from an unbanned address: %d %s, want 200", code, raw)
	}
}

package hub_test

import (
	"context"
	"encoding/json"
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

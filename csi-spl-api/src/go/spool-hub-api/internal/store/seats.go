package store

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// M4 seats and the buy-time GCP project id (specs/009-spool-m4, rdb 0012).
//
// Occupancy reuses existing rows (009 D-1): a user seat is a
// tenant_memberships row, a bot seat is a roster row whose agent_id is not
// HUM-*. A box, a pin, a message or a WUI tab is never a seat. A disabled
// human keeps its membership row and so still occupies its seat (D-4).

// Seats is the store side of M4. Memory and Postgres both implement it.
type Seats interface {
	// CountMembers is the tenant's user-seat occupancy: every membership row,
	// disabled humans included (009 D-4).
	CountMembers(ctx context.Context, tenantID string) (int, error)
	// CountBots is the tenant's bot-seat occupancy: roster rows (agent@box)
	// whose agent_id is not HUM-*.
	CountBots(ctx context.Context, tenantID string) (int, error)
	// SetSeatCaps writes the paid seats (>= 0; 0 = M4 off). It never lowers
	// occupancy: existing seats keep working, only new ones are refused.
	SetSeatCaps(ctx context.Context, tenantID string, users, bots int) error
	// SetBuyStamp writes org, app, project_id ("" = NULL, hosted M2) and
	// bought_at. A project_id another tenant holds is ErrConflict (the
	// caller re-mints, see StampBuy); an absent tenant is ErrNotFound.
	SetBuyStamp(ctx context.Context, tenantID, org, app, projectID string, boughtAt time.Time) error
}

var (
	codeRe      = regexp.MustCompile(`^[a-z]{3}$`)
	projectIDRe = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
	envRe       = regexp.MustCompile(`^[a-z][a-z0-9]{1,5}$`)
)

// ProjectIDMaxLen is GCP's project-id limit (009 FR-003).
const ProjectIDMaxLen = 30

// stampLayout is YYYYMMDDHHmm (UTC minute).
const stampLayout = "200601021504"

func checkSeatCaps(users, bots int) error {
	if users < 0 || bots < 0 {
		return errors.New("seat caps must be >= 0 (0 = M4 off)")
	}
	return nil
}

// checkBuyStamp: org / app are optional ("" = NULL, hosted M2) 3-letter
// codes; a project_id (dedicated SKU) needs both and the GCP id rule.
func checkBuyStamp(org, app, projectID string) error {
	if (org != "" && !codeRe.MatchString(org)) || (app != "" && !codeRe.MatchString(app)) {
		return errors.New("org and app must be 3-letter codes ^[a-z]{3}$")
	}
	if projectID == "" {
		return nil
	}
	if org == "" || app == "" {
		return errors.New("a project_id needs org and app")
	}
	if !projectIDRe.MatchString(projectID) {
		return fmt.Errorf("project_id %q is not a GCP project id (6..%d chars)", projectID, ProjectIDMaxLen)
	}
	return nil
}

// isBot reports whether a roster agent id is a bot seat (not a HUM-*).
func isBot(agentID string) bool { return !strings.HasPrefix(agentID, "HUM-") }

// botsAfterReplace is the SetRoster seat math (009 D-3): tenant bots minus
// this box's old set plus the new set, and whether the new set adds a bot.
func botsAfterReplace(tenantBots int, old, next []string) (total int, adds bool) {
	had := map[string]bool{}
	for _, a := range old {
		if isBot(a) {
			had[a] = true
		}
	}
	total = tenantBots - len(had)
	for _, a := range next {
		if isBot(a) {
			total++
			if !had[a] {
				adds = true
			}
		}
	}
	return total, adds
}

// overBotCap: refuse only a replace that adds a bot and ends above a
// non-zero cap. Shrinking or re-announcing the same set always passes, even
// on a tenant already over a lowered cap.
func overBotCap(capBots, tenantBots int, old, next []string) bool {
	if capBots == 0 {
		return false
	}
	total, adds := botsAfterReplace(tenantBots, old, next)
	return adds && total > capBots
}

// MintProjectID is the dedicated SKU's GCP project id (009 T005, FR-003):
// {org}-{app}-{env}-{YYYYMMDDHHmm} from the buy time's UTC minute, e.g.
// abc-xyz-dev-202609171743. org and app are 3-letter codes; env is the hub
// env (dev, prd).
func MintProjectID(org, app, env string, at time.Time) (string, error) {
	if !envRe.MatchString(env) {
		return "", fmt.Errorf("env %q must match %s", env, envRe)
	}
	id := fmt.Sprintf("%s-%s-%s-%s", org, app, env, at.UTC().Format(stampLayout))
	if err := checkBuyStamp(org, app, id); err != nil {
		return "", err
	}
	return id, nil
}

// StampRetryMinutes is how many later minutes StampBuy tries before a nonce.
const StampRetryMinutes = 3

const nonceAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

// nonce2 returns 2 random [a-z0-9] chars; a var so tests can pin it.
var nonce2 = func() (string, error) {
	b := make([]byte, 2)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	for i := range b {
		b[i] = nonceAlphabet[int(b[i])%len(nonceAlphabet)]
	}
	return string(b), nil
}

// PeriodStart is the first instant of t's UTC calendar month: the seat
// period (009 D-4, the 006 billing month).
func PeriodStart(t time.Time) time.Time {
	u := t.UTC()
	return time.Date(u.Year(), u.Month(), 1, 0, 0, 0, 0, time.UTC)
}

// StampBuy is what the paid webhook calls for a dedicated SKU (009 T005 +
// T007, D-8): it mints the project id from boughtAt's UTC minute and writes
// org, app, project_id and bought_at. A clash on project_id retries the next
// minute (StampRetryMinutes times), then the minted id plus a 2-char nonce
// suffix (-xx, still <= 30). bought_at stays the real buy time. A duplicate
// DNS slug is the tenant create's 409 (ErrConflict), not this.
func StampBuy(ctx context.Context, st Seats, tenantID, org, app, env string, boughtAt time.Time) (string, error) {
	return stampWith(func(id string) error { return st.SetBuyStamp(ctx, tenantID, org, app, id, boughtAt) },
		org, app, env, boughtAt)
}

// stampWith is StampBuy's candidate order over any setter that answers
// ErrConflict on a held project_id (the store's paid transition uses it
// inside its own transaction).
func stampWith(set func(projectID string) error, org, app, env string, boughtAt time.Time) (string, error) {
	var last error
	for i := 0; i <= StampRetryMinutes; i++ {
		id, err := MintProjectID(org, app, env, boughtAt.Add(time.Duration(i)*time.Minute))
		if err != nil {
			return "", err
		}
		last = set(id)
		if last == nil {
			return id, nil
		}
		if !errors.Is(last, ErrConflict) {
			return "", last
		}
	}
	base, _ := MintProjectID(org, app, env, boughtAt)
	for i := 0; i < 8; i++ {
		n, err := nonce2()
		if err != nil {
			return "", err
		}
		id := base + "-" + n
		last = set(id)
		if last == nil {
			return id, nil
		}
		if !errors.Is(last, ErrConflict) {
			return "", last
		}
	}
	return "", fmt.Errorf("project_id: no free stamp for %s-%s-%s at %s: %w", org, app, env,
		boughtAt.UTC().Format(stampLayout), last)
}

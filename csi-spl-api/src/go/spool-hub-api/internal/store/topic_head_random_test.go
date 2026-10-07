package store

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2" // nosemgrep: go.lang.security.audit.crypto.math_random.math-random-used -- a seeded, replayable test draw (spec 099 7.2), never a secret
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 099 T003, section 7.2: random sequences of every head writer on the
// case table's seed. After EVERY operation topic_head_diff is empty; every
// 25 operations 16 seeded list shapes compare the walk with the reference
// (and the head read, once T005 sets topicHeadRead); at the end the full
// grid. Operations draw from sorted slices only - never a Go map - so a seed
// replays: TOPIC_HEAD_SEED=<n> runs that seed alone and TOPIC_HEAD_OPS=<k>
// its first k operations. Default 4 seeds x 300 operations; SPOOL_TEST_LONG=1
// runs 200 seeds (T007's nightly). Postgres only (SPOOL_TEST_PG_DSN).

// headRandPurgeSQL is the sweep's chunk DELETE (Postgres.Sweep) plus
// tenant_id: the global Sweep would purge other tests' rows.
const headRandPurgeSQL = `DELETE FROM messages WHERE tenant_id = $3 AND expires_at <= $1 AND (tenant_id, msg_id) IN (
		SELECT tenant_id, msg_id FROM messages WHERE tenant_id = $3 AND expires_at <= $1 LIMIT $2)`

// headRand is one seed's run: the fixture, the generator and the names it
// draws from (sorted, or in creation order: both replay).
type headRand struct {
	f       *headFix
	rng     *rand.Rand
	topics  []string           // topic names, sorted
	lines   []string           // line names, in creation order
	live    []string           // the lines still stored, in creation order (refresh)
	cards   []string           // the topics whose card is still stored, sorted (refresh)
	sent    map[string]Message // line name -> the row as inserted (lookup only)
	next    int                // the next line / topic number
	log     []string           // one entry per operation: what it drew and how it ended
	applied int
	tally   map[string][2]int // op name -> applied, refused (printed in table order)
}

// randOp is one writer of the case table; weight is its share of the draws.
type randOp struct {
	name   string
	weight int
	run    func(r *headRand) error
}

// headRandOps is the operation table, in a fixed order.
func headRandOps() []randOp {
	return []randOp{
		{"E01/E02 insert", 8, (*headRand).opInsert},
		{"E04/E05 edit", 1, (*headRand).opEdit},
		{"E06 kind", 1, (*headRand).opKind},
		{"E07/E08 move line", 3, (*headRand).opMoveLine},
		{"E09 move topic", 1, (*headRand).opMoveTopic},
		{"E10/E11 merge (and unmerge)", 2, (*headRand).opMerge},
		{"E12/E12b promote (and demote)", 2, (*headRand).opPromote},
		{"E13..E15 archive or unarchive", 3, (*headRand).opArchive},
		{"E16 delete line", 2, (*headRand).opDeleteLine},
		{"E17 merge lines", 1, (*headRand).opMergeLines},
		{"E18 delete topic", 1, (*headRand).opDeleteTopic},
		{"E19/E29/E37 channel", 1, (*headRand).opChannel},
		{"E34 resend", 1, (*headRand).opResend},
		{"E36 mirrored DM", 1, (*headRand).opMirror},
		{"clock past one key line", 2, (*headRand).opClock},
		{"tenant-scoped purge chunk", 2, (*headRand).opPurge},
	}
}

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}

// TestTopicHeadRandomSequences: see the file comment.
func TestTopicHeadRandomSequences(t *testing.T) {
	pg := pgOnly(t)
	seeds := []int64{1, 2, 3, 4}
	if os.Getenv("SPOOL_TEST_LONG") == "1" {
		seeds = seeds[:0]
		for s := int64(1); s <= 200; s++ {
			seeds = append(seeds, s)
		}
	}
	if s := envInt("TOPIC_HEAD_SEED", 0); s > 0 {
		seeds = []int64{int64(s)}
	}
	ops := envInt("TOPIC_HEAD_OPS", 300)
	t0 := time.Now().UTC().Truncate(time.Microsecond)
	for _, seed := range seeds {
		seed := seed
		t.Run(fmt.Sprintf("seed-%d", seed), func(t *testing.T) {
			t.Parallel()
			r := newHeadRand(seedHeadFix(t, pg, t0), seed)
			r.runOps(t, seed, ops)
			pages, nonEmpty := compareAll(t, r.f)
			t.Logf("seed %d: %d ops, %d applied, %d lines; full grid %d pages, %d non-empty shapes", seed, ops, r.applied, len(r.lines), pages, nonEmpty)
		})
	}
}

func newHeadRand(f *headFix, seed int64) *headRand {
	r := &headRand{f: f, rng: rand.New(rand.NewPCG(uint64(seed), 0)), sent: map[string]Message{}, tally: map[string][2]int{}}
	for name := range f.task {
		r.topics = append(r.topics, name)
	}
	sort.Strings(r.topics)
	for name := range f.msg {
		r.lines = append(r.lines, name)
	}
	sort.Strings(r.lines)
	return r
}

// runOps draws and applies n operations, checking the diff after each and
// 16 seeded shapes every 25; a store refusal (not a Postgres error) is a
// no-op, and at least half of the draws must apply, or the run is vacuous.
func (r *headRand) runOps(t *testing.T, seed int64, n int) {
	t.Helper()
	table := headRandOps()
	total := 0
	for _, op := range table {
		total += op.weight
	}
	shapeRng := rand.New(rand.NewPCG(uint64(seed*7919), 0))
	for i := 1; i <= n; i++ {
		op := r.draw(table, total)
		r.log = append(r.log, fmt.Sprintf("%d %s", i, op.name))
		r.refresh(t)
		err := op.run(r)
		var pe *pgconn.PgError
		switch {
		case errors.As(err, &pe):
			r.fail(t, seed, i, fmt.Sprintf("%s: postgres error %v", op.name, err))
		case err != nil:
			r.log[len(r.log)-1] += fmt.Sprintf(" -> refused (%v)", err)
			c := r.tally[op.name]
			c[1]++
			r.tally[op.name] = c
		default:
			r.applied++
			c := r.tally[op.name]
			c[0]++
			r.tally[op.name] = c
		}
		if d := randDiff(t, r.f); len(d) != 0 {
			r.fail(t, seed, i, fmt.Sprintf("after %s, topic_head_diff: %v", op.name, d))
		}
		if i%25 == 0 {
			r.checkShapes(t, seed, i, shapeRng)
		}
	}
	var per []string
	for _, op := range table {
		per = append(per, fmt.Sprintf("%s %d/%d", op.name, r.tally[op.name][0], r.tally[op.name][0]+r.tally[op.name][1]))
	}
	t.Logf("seed %d applied/drawn: %s", seed, strings.Join(per, ", "))
	if r.applied*2 < n {
		t.Fatalf("seed %d: only %d of %d operations applied: the run is vacuous\n%s", seed, r.applied, n, strings.Join(r.log, "\n"))
	}
}

func (r *headRand) draw(table []randOp, total int) randOp {
	k := r.rng.IntN(total)
	for _, op := range table {
		if k < op.weight {
			return op
		}
		k -= op.weight
	}
	return table[len(table)-1]
}

// fail stops the seed with the replay line and the last operations.
func (r *headRand) fail(t *testing.T, seed int64, i int, msg string) {
	t.Helper()
	from := len(r.log) - 12
	if from < 0 {
		from = 0
	}
	t.Fatalf("seed %d op %d: %s\nreplay: TOPIC_HEAD_SEED=%d TOPIC_HEAD_OPS=%d\nlast operations:\n%s",
		seed, i, msg, seed, i, strings.Join(r.log[from:], "\n"))
}

// randDiff is topic_head_diff of f's tenant, as operator.
func randDiff(t *testing.T, f *headFix) map[string]string {
	t.Helper()
	var d map[string]string
	if err := f.pg.asOperator(context.Background(), func(tx pgx.Tx) (err error) {
		d, err = txDiff(context.Background(), tx, f.tn)
		return err
	}); err != nil {
		t.Fatalf("topic_head_diff: %v", err)
	}
	return d
}

// checkShapes compares 16 shapes, drawn from the sorted grid, on every page.
func (r *headRand) checkShapes(t *testing.T, seed int64, i int, rng *rand.Rand) {
	t.Helper()
	shapes := topicHeadShapes(r.f)
	names := make([]string, 0, len(shapes))
	for n := range shapes {
		names = append(names, n)
	}
	sort.Strings(names)
	for k := 0; k < 16; k++ {
		name := names[rng.IntN(len(names))]
		if msg := comparePaged(r.f, shapes[name]); msg != "" {
			r.fail(t, seed, i, name+": "+msg)
		}
	}
}

// comparePaged pages one shape through the walk, the reference and (when
// set) the head read; "" when they agree on every page.
func comparePaged(f *headFix, q TopicQuery) string {
	ctx := context.Background()
	for page := 0; page < 100; page++ {
		walk, err := f.pg.ViewTopics(ctx, f.tn, q)
		if err != nil {
			return "walk: " + err.Error()
		}
		ref, err := refTopics(ctx, f.pg, f.tn, q)
		if err != nil {
			return "reference: " + err.Error()
		}
		if d := sameRows(walk, ref); d != "" {
			return fmt.Sprintf("page %d: walk != reference: %s", page, d)
		}
		if topicHeadRead != nil {
			head, err := topicHeadRead(ctx, f.pg, f.tn, q)
			if err != nil {
				return "head read: " + err.Error()
			}
			if d := sameRows(head, walk); d != "" {
				return fmt.Sprintf("page %d: head != walk: %s", page, d)
			}
		}
		if q.Limit == 0 || len(walk) < q.Limit {
			return ""
		}
		q.BeforeAt, q.BeforeTask = walk[len(walk)-1].LastAt, walk[len(walk)-1].TaskID
	}
	return "more than 100 pages"
}

// refresh reads which lines and cards are stored now, so a draw rarely
// names a line a purge or a delete already took. Existence is a function of
// the seed's operations, so the draws still replay.
func (r *headRand) refresh(t *testing.T) {
	t.Helper()
	ids := map[string]bool{}
	ctx := context.Background()
	err := r.f.pg.inTenant(ctx, r.f.tn, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT msg_id::text FROM messages WHERE tenant_id = $1`, []any{r.f.tn}, func(rows pgx.Rows) error {
			var id string
			err := rows.Scan(&id)
			ids[id] = true
			return err
		})
	})
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	r.live, r.cards = r.live[:0], r.cards[:0]
	for _, name := range r.lines {
		if ids[r.f.msg[name]] {
			r.live = append(r.live, name)
		}
	}
	for _, name := range r.topics {
		if ids[r.f.task[name]] {
			r.cards = append(r.cards, name)
		}
	}
	if len(r.live) == 0 {
		r.live = append(r.live, r.lines...)
	}
	if len(r.cards) == 0 {
		r.cards = append(r.cards, r.topics...)
	}
}

// note adds what an operation drew to its log entry.
func (r *headRand) note(format string, a ...any) {
	r.log[len(r.log)-1] += ": " + fmt.Sprintf(format, a...)
}

func (r *headRand) pick(names []string) string { return names[r.rng.IntN(len(names))] }

// newName is the next line or topic name: deterministic per seed.
func (r *headRand) newName(prefix string) string {
	r.next++
	return fmt.Sprintf("%s%04d", prefix, r.next)
}

func (r *headRand) addTopic(name string) {
	r.topics = append(r.topics, name)
	sort.Strings(r.topics)
}

// insert stores one new line named name in topic task, ago before the list
// clock (the clock only moves forward).
func (r *headRand) insert(name, task string, ago time.Duration, o lineOpt) error {
	m := r.f.lineMsg(name, task, r.f.t0.Sub(r.f.now)+ago, o)
	if _, err := r.f.pg.InsertMessage(context.Background(), m); err != nil {
		return err
	}
	r.lines = append(r.lines, name)
	r.sent[name] = m
	return nil
}

// randLineOpt is a line of a random part: #lobby, #crew, or one of two DM
// pairs; one in four expires within two hours.
func (r *headRand) randLineOpt() lineOpt {
	o := lineOpt{}
	switch r.rng.IntN(4) {
	case 0:
		o.ch = "crew"
	case 1:
		o = dmHumAgt
	case 2:
		o = lineOpt{ch: "-", from: "HUM-2", fromBox: "box-wui", to: "AGT-2", toBox: "box-b"}
	}
	if r.rng.IntN(4) == 0 {
		o.ttl = time.Duration(1+r.rng.IntN(120)) * time.Minute
	}
	return o
}

func (r *headRand) channel() string {
	if r.rng.IntN(2) == 0 {
		return "crew"
	}
	return ChannelLobby
}

// opInsert (E01, E02): a line into a known topic, or one time in six the
// card of a new topic.
func (r *headRand) opInsert() error {
	name, o, task := r.newName("r"), r.randLineOpt(), r.pick(r.topics)
	if r.rng.IntN(6) == 0 {
		task, o.card = r.newName("R"), true
		r.addTopic(task)
	}
	ago := time.Duration(r.rng.IntN(90)) * time.Minute
	r.note("%s into %s ch=%q ttl=%s ago=%s", name, task, o.ch, o.ttl, ago)
	return r.insert(name, task, ago, o)
}

func (r *headRand) opEdit() error {
	line := r.pick(r.live)
	r.note("%s", line)
	_, err := r.f.pg.ApplyEdit(context.Background(), r.f.tn, r.f.msg[line], r.f.edit("edited "+line))
	return err
}

func (r *headRand) opKind() error {
	line, kind := r.pick(r.live), r.pick([]string{"note", "reject", "result", "task"})
	r.note("%s -> %s", line, kind)
	_, err := r.f.pg.SetKind(context.Background(), r.f.tn, r.f.msg[line], kind, "HUM-1", r.f.t0)
	return err
}

func (r *headRand) opMoveLine() error {
	line, task, ch := r.pick(r.live), r.pick(r.topics), r.channel()
	r.note("%s -> %s #%s", line, task, ch)
	_, err := r.f.pg.MoveMessage(context.Background(), r.f.tn, r.f.msg[line], r.f.task[task], ch, "HUM-1", r.f.t0, time.Time{})
	return err
}

func (r *headRand) opMoveTopic() error {
	task, ch := r.pick(r.cards), r.channel()
	r.note("%s -> #%s", task, ch)
	_, err := r.f.pg.MoveTopic(context.Background(), r.f.tn, r.f.task[task], r.f.task[task], ch, "HUM-1", r.f.t0)
	return err
}

func (r *headRand) opMerge() error {
	src, dst, ch := r.pick(r.cards), r.pick(r.topics), r.channel()
	undo := r.rng.IntN(2) == 0
	r.note("%s into %s #%s undo=%v", src, dst, ch, undo)
	if src == dst {
		return errors.New("same topic")
	}
	ctx := context.Background()
	res, err := r.f.pg.MergeTopic(ctx, r.f.tn, r.f.task[src], r.f.task[src], r.f.task[dst], ch, "HUM-1", r.f.t0)
	if err != nil || !undo {
		return err
	}
	return r.f.pg.UnmergeTopic(ctx, r.f.tn, r.f.task[src], res.MsgIDs)
}

// lineTask is the topic a line is in now.
func (r *headRand) lineTask(line string) (string, error) {
	var task string
	err := r.f.pg.queryRowTenant(context.Background(), r.f.tn, `SELECT task_id::text FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
		[]any{r.f.tn, r.f.msg[line]}, &task)
	return task, err
}

func (r *headRand) opPromote() error {
	line, topic, undo := r.pick(r.live), r.newName("P"), r.rng.IntN(2) == 0
	r.note("%s -> new %s undo=%v", line, topic, undo)
	src, err := r.lineTask(line)
	if err != nil {
		return err
	}
	ctx := context.Background()
	r.f.task[topic] = uuid4()
	res, err := r.f.pg.PromoteMessage(ctx, r.f.tn, r.f.msg[line], src, r.f.task[topic], "HUM-1", r.f.t0)
	if err != nil {
		return err
	}
	r.addTopic(topic)
	if !undo {
		return nil
	}
	return r.f.pg.DemoteTopic(ctx, r.f.tn, r.f.msg[line], res.MsgIDs)
}

// opArchive (E13..E15): a line or, one time in three, a topic's card.
func (r *headRand) opArchive() error {
	msg, what := r.f.msg[r.pick(r.live)], "line"
	if r.rng.IntN(3) == 0 {
		task := r.pick(r.cards)
		msg, what = r.f.task[task], "card of "+task
	}
	on := r.rng.IntN(3) != 0
	r.note("%s archived=%v", what, on)
	_, err := r.f.pg.SetArchived(context.Background(), r.f.tn, msg, "HUM-1", r.f.t0, on)
	return err
}

func (r *headRand) opDeleteLine() error {
	line := r.pick(r.live)
	r.note("%s", line)
	return r.f.pg.DeleteMessage(context.Background(), r.f.tn, r.f.msg[line])
}

func (r *headRand) opMergeLines() error {
	keep, drop := r.pick(r.live), r.pick(r.live)
	r.note("%s <- %s", keep, drop)
	if keep == drop {
		return errors.New("same line")
	}
	_, err := r.f.pg.MergeMessages(context.Background(), r.f.tn, r.f.msg[keep], r.f.msg[drop], r.f.edit("merged "+keep))
	return err
}

func (r *headRand) opDeleteTopic() error {
	task := r.pick(r.cards)
	r.note("%s", task)
	_, err := r.f.pg.DeleteTopic(context.Background(), r.f.tn, r.f.task[task], r.f.task[task])
	return err
}

// opChannel (E29, E37, E19): archive #crew, unarchive it, or delete it (its
// topics go) and create it again.
func (r *headRand) opChannel() error {
	ctx, k := context.Background(), r.rng.IntN(4)
	switch k {
	case 0:
		r.note("archive #crew")
		return r.f.pg.ArchiveChannel(ctx, r.f.tn, "crew", "HUM-1", r.f.t0)
	case 3:
		r.note("delete and re-create #crew")
		if err := r.f.pg.DeleteChannel(ctx, r.f.tn, "crew", "HUM-1", r.f.t0); err != nil {
			return err
		}
		return r.f.pg.CreateChannel(ctx, Channel{TenantID: r.f.tn, ChannelID: "crew", Name: "crew", CreatedBy: "HUM-1"})
	}
	r.note("unarchive #crew")
	return r.f.pg.UnarchiveChannel(ctx, r.f.tn, "crew")
}

func (r *headRand) opResend() error {
	line := r.pick(r.live)
	r.note("%s", line)
	m, ok := r.sent[line]
	if !ok {
		return errors.New("a seed line: nothing to resend")
	}
	_, err := r.f.pg.InsertMessage(context.Background(), m)
	return err
}

// opMirror (E36's writer): a DM line into one topic and its channel copy
// into another, in one InsertMirrored.
func (r *headRand) opMirror() error {
	dmName, cpName := r.newName("r"), r.newName("r")
	dmTask, cpTask := r.pick(r.topics), r.pick(r.topics)
	r.note("%s into %s, copy %s into %s", dmName, dmTask, cpName, cpTask)
	lead := r.f.t0.Sub(r.f.now) + time.Duration(r.rng.IntN(30))*time.Minute
	dm := r.f.lineMsg(dmName, dmTask, lead, dmHumAgt)
	cp := r.f.lineMsg(cpName, cpTask, lead, lineOpt{from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a", mirror: dmName})
	if _, err := r.f.pg.InsertMirrored(context.Background(), dm, time.Time{}, cp, time.Time{}); err != nil {
		return err
	}
	r.lines = append(r.lines, dmName, cpName)
	return nil
}

// opClock moves the list clock just past the earliest head key line that is
// still valid (its valid_until), or an hour when none is.
func (r *headRand) opClock() error {
	var next *time.Time
	ctx := context.Background()
	if err := r.f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT min(valid_until) FROM topic_heads WHERE tenant_id = $1 AND valid_until > $2`, r.f.tn, r.f.now).Scan(&next)
	}); err != nil {
		return err
	}
	if next == nil {
		r.f.now = r.f.now.Add(time.Hour)
	} else {
		r.f.now = next.Add(time.Microsecond)
	}
	r.note("now = t0 + %s", r.f.now.Sub(r.f.t0))
	return nil
}

func (r *headRand) opPurge() error {
	chunk := 1 + r.rng.IntN(20)
	var n int64
	ctx := context.Background()
	err := r.f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, headRandPurgeSQL, r.f.now, chunk, r.f.tn)
		n = tag.RowsAffected()
		return err
	})
	r.note("chunk %d purged %d", chunk, n)
	return err
}

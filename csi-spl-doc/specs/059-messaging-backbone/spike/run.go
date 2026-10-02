// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Usage:
//
//	spike run     -backend nats|kafka|pgq -test 1|2|3|4 [-n 1000] -dir <out>
//	spike consume ... (started by run as a child process, so a test can SIGKILL it)
func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: spike run|consume [flags]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "run":
		err = cmdRun(os.Args[2:])
	case "consume":
		err = cmdConsume(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "spike:", err)
		os.Exit(1)
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// cmdConsume stands in for an agent desk: receive, "poke" (append one line to
// the out file), then ack. -crash-after K kills the process with SIGKILL on
// the K-th delivery, after receiving and BEFORE the poke and the ack.
func cmdConsume(args []string) error {
	fs := flag.NewFlagSet("consume", flag.ExitOnError)
	be := fs.String("backend", "", "")
	subject := fs.String("subject", "", "")
	group := fs.String("group", "", "")
	name := fs.String("name", "", "")
	out := fs.String("out", "", "")
	crashAfter := fs.Int("crash-after", 0, "")
	idle := fs.Duration("idle", 5*time.Second, "")
	work := fs.Duration("work", 0, "simulated processing time per delivery")
	fs.Parse(args) //nolint:errcheck
	b, err := backendByName(*be)
	if err != nil {
		return err
	}
	ctx := context.Background()
	f, err := os.OpenFile(*out, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	var c Consumer
	for i := 0; ; i++ { // the broker may still be coming up
		if c, err = b.Consumer(ctx, *subject, *group, *name); err == nil {
			break
		}
		if i > 50 {
			return err
		}
		time.Sleep(200 * time.Millisecond)
	}
	defer c.Close()
	n := 0
	ready := false
	var pending []*Msg
	t0 := time.Now()
	for !ready { // warm up: poll briefly until the subscription is held
		m, err := c.Next(ctx, 200*time.Millisecond)
		if m != nil {
			pending = append(pending, m)
		}
		if err != nil && !errors.Is(err, errIdle) {
			fmt.Fprintln(os.Stderr, "consume warm-up:", err)
		}
		if c.Ready() || time.Since(t0) > 60*time.Second {
			ready = true
			os.WriteFile(*out+".ready", []byte(fmt.Sprintf("%d\n", time.Since(t0).Milliseconds())), 0o644) //nolint:errcheck
		}
	}
	for {
		var m *Msg
		var err error
		if len(pending) > 0 {
			m, pending = pending[0], pending[1:]
		} else {
			m, err = c.Next(ctx, *idle)
		}
		if errors.Is(err, errIdle) {
			return nil
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "consume:", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		now := time.Now().UnixNano()
		n++
		if n == *crashAfter {
			syscall.Kill(os.Getpid(), syscall.SIGKILL) //nolint:errcheck
			select {}
		}
		if *work > 0 {
			time.Sleep(*work)
		}
		p, err := decode(m.Data)
		if err != nil {
			return err
		}
		fmt.Fprintf(f, "%s %d %d %s\n", p.ID, (now-p.TSNs)/1000, now, *name)
		for i := 0; ; i++ {
			actx, cancel := context.WithTimeout(ctx, 2*time.Second)
			err = m.Ack(actx)
			cancel()
			if err == nil {
				break
			}
			if i > 20 {
				fmt.Fprintln(os.Stderr, "ack gave up:", p.ID, err)
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
	}
}

// waitReady blocks until every consumer wrote its .ready marker and returns
// the slowest join time in ms (Kafka: the group assignment).
func waitReady(outs ...string) float64 {
	var worst float64
	for _, o := range outs {
		for i := 0; i < 600; i++ {
			if b, err := os.ReadFile(o + ".ready"); err == nil {
				v, _ := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
				worst = max(worst, v)
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	return worst
}

type child struct {
	cmd  *exec.Cmd
	done chan struct{}
}

func startConsumer(be, subject, group, name, out string, extra ...string) (*child, error) {
	args := append([]string{"consume", "-backend", be, "-subject", subject, "-group", group,
		"-name", name, "-out", out}, extra...)
	cmd := exec.Command(os.Args[0], args...)
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c := &child{cmd: cmd, done: make(chan struct{})}
	go func() { cmd.Wait(); close(c.done) }() //nolint:errcheck
	return c, nil
}

// Result is one test on one backend: what the one-page table reads.
type Result struct {
	Backend      string  `json:"backend"`
	Test         int     `json:"test"`
	Consumers    string  `json:"consumers"`
	Want         int     `json:"want"`
	Got          int     `json:"got_unique"`
	Lost         int     `json:"lost"`
	Dup          int     `json:"dup_raw"`
	P50ms        float64 `json:"p50_ms"`
	P95ms        float64 `json:"p95_ms"`
	P99ms        float64 `json:"p99_ms"`
	MaxMs        float64 `json:"max_ms"`
	GapMs        float64 `json:"max_gap_ms"`
	PubRetries   int     `json:"publish_retries"`
	PubErrors    int     `json:"publish_errors"`
	RestartMs    float64 `json:"restart_ms,omitempty"`
	JoinMs       float64 `json:"join_ms"`
	Redelivered  *bool   `json:"redelivered,omitempty"`
	Pass         bool    `json:"pass"`
	Note         string  `json:"note,omitempty"`
	DurationSecs float64 `json:"duration_s"`
}

type line struct {
	id    string
	latUs int64
	atNs  int64
}

func readLines(files ...string) ([]line, error) {
	var out []line
	for _, fn := range files {
		f, err := os.Open(fn)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			p := strings.Fields(sc.Text())
			if len(p) < 3 {
				continue
			}
			lat, _ := strconv.ParseInt(p[1], 10, 64)
			at, _ := strconv.ParseInt(p[2], 10, 64)
			out = append(out, line{p[0], lat, at})
		}
		f.Close()
	}
	return out, nil
}

// score fills lost / dup / latency / gap for the ids that should each have
// arrived exactly once across files.
func score(r *Result, ids []string, files ...string) error {
	ls, err := readLines(files...)
	if err != nil {
		return err
	}
	seen := map[string]int{}
	var lats []float64
	var ats []int64
	for _, l := range ls {
		seen[l.id]++
		if seen[l.id] == 1 {
			lats = append(lats, float64(l.latUs)/1000)
		}
		ats = append(ats, l.atNs)
	}
	r.Want = len(ids)
	for _, id := range ids {
		switch n := seen[id]; {
		case n == 0:
			r.Lost++
		default:
			r.Got++
			r.Dup += n - 1
		}
	}
	sort.Float64s(lats)
	q := func(p float64) float64 {
		if len(lats) == 0 {
			return 0
		}
		return lats[min(len(lats)-1, int(p*float64(len(lats))))]
	}
	r.P50ms, r.P95ms, r.P99ms = q(0.5), q(0.95), q(0.99)
	if len(lats) > 0 {
		r.MaxMs = lats[len(lats)-1]
	}
	sort.Slice(ats, func(i, j int) bool { return ats[i] < ats[j] })
	for i := 1; i < len(ats); i++ {
		if g := float64(ats[i]-ats[i-1]) / 1e6; g > r.GapMs {
			r.GapMs = g
		}
	}
	return nil
}

// produce publishes n ids at rate/s; a failed publish is retried with the
// SAME id (the idempotent-producer path) until it succeeds or 60 s pass.
// onIndex runs before each publish (test 2 and 4 hook their fault there).
func produce(ctx context.Context, p Producer, subject, prefix string, n, rate int, r *Result, onIndex func(int)) []string {
	ids := make([]string, n)
	tick := time.Second / time.Duration(rate)
	next := time.Now()
	for i := 0; i < n; i++ {
		if onIndex != nil {
			onIndex(i)
		}
		ids[i] = fmt.Sprintf("%s-%05d", prefix, i)
		start := time.Now()
		for {
			err := p.Publish(ctx, subject, ids[i], encode(ids[i]))
			if err == nil {
				break
			}
			r.PubRetries++
			if time.Since(start) > 60*time.Second {
				r.PubErrors++
				fmt.Fprintln(os.Stderr, "publish gave up:", ids[i], err)
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		next = next.Add(tick)
		if d := time.Until(next); d > 0 {
			time.Sleep(d)
		}
	}
	return ids
}

func cmdRun(args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	be := fs.String("backend", "", "")
	test := fs.Int("test", 1, "")
	n := fs.Int("n", 1000, "")
	dir := fs.String("dir", "", "")
	fs.Parse(args) //nolint:errcheck
	b, err := backendByName(*be)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*dir, 0o755); err != nil {
		return err
	}
	ctx := context.Background()
	r := &Result{Backend: b.Name(), Test: *test}
	if b.Name() == "kafka" && os.Getenv("SPIKE_KAFKA_COMMIT") == "marks" {
		r.Backend = "kafka-batch"
	}
	t0 := time.Now()
	out := func(name string) string {
		return filepath.Join(*dir, fmt.Sprintf("%s-t%d-%s.log", b.Name(), *test, name))
	}
	for _, f := range []string{"a", "b", "c1", "c2", "d"} {
		os.Remove(out(f))            //nolint:errcheck
		os.Remove(out(f) + ".ready") //nolint:errcheck
	}
	switch *test {
	case 1:
		err = test1(ctx, b, *n, r, out)
	case 2:
		err = test2(ctx, b, *n, r, out)
	case 3:
		err = test3(ctx, b, r, out)
	case 4:
		err = test4(ctx, b, *n, r, out)
	default:
		err = fmt.Errorf("test %d?", *test)
	}
	if err != nil {
		return err
	}
	r.DurationSecs = time.Since(t0).Seconds()
	j, _ := json.Marshal(r)
	fmt.Println(string(j))
	return os.WriteFile(filepath.Join(*dir, fmt.Sprintf("%s-t%d.json", r.Backend, *test)), append(j, '\n'), 0o644)
}

func setupProducer(ctx context.Context, b Backend, groups map[string][]string, parts int) (Producer, error) {
	if err := b.Setup(ctx, groups, parts); err != nil {
		return nil, fmt.Errorf("setup: %w", err)
	}
	return b.Producer(ctx)
}

// Test 1: 1,000 posts to one subject that two agents (two groups) each must
// get exactly once; 200 a second, about 270x prd's peak minute (44).
func test1(ctx context.Context, b Backend, n int, r *Result, out func(string) string) error {
	subj := "post.t1.chan1.topic1"
	p, err := setupProducer(ctx, b, map[string][]string{subj: {"agentA", "agentB"}}, 1)
	if err != nil {
		return err
	}
	defer p.Close()
	ca, err := startConsumer(b.Name(), subj, "agentA", "A", out("a"))
	if err != nil {
		return err
	}
	cb, err := startConsumer(b.Name(), subj, "agentB", "B", out("b"))
	if err != nil {
		return err
	}
	r.JoinMs = waitReady(out("a"), out("b"))
	ids := produce(ctx, p, subj, "t1", n, 200, r, nil)
	<-ca.done
	<-cb.done
	ra, rb := &Result{}, &Result{}
	if err := score(ra, ids, out("a")); err != nil {
		return err
	}
	if err := score(rb, ids, out("b")); err != nil {
		return err
	}
	r.Consumers = "2 groups x 1"
	r.Want, r.Got, r.Lost, r.Dup = 2*n, ra.Got+rb.Got, ra.Lost+rb.Lost, ra.Dup+rb.Dup
	r.P50ms, r.P95ms, r.P99ms, r.MaxMs = max(ra.P50ms, rb.P50ms), max(ra.P95ms, rb.P95ms), max(ra.P99ms, rb.P99ms), max(ra.MaxMs, rb.MaxMs)
	r.Pass = r.Lost == 0 && r.Dup == 0 && r.P95ms < 3000
	return nil
}

// Test 2: two dispatchers in ONE group; the first is SIGKILLed when half the
// posts are out. Counted by msg id across both.
func test2(ctx context.Context, b Backend, n int, r *Result, out func(string) string) error {
	subj := "dispatch.t1"
	p, err := setupProducer(ctx, b, map[string][]string{subj: {"dispatchers"}}, 2)
	if err != nil {
		return err
	}
	defer p.Close()
	c1, err := startConsumer(b.Name(), subj, "dispatchers", "D1", out("c1"), "-idle", "20s", "-work", "2ms")
	if err != nil {
		return err
	}
	c2, err := startConsumer(b.Name(), subj, "dispatchers", "D2", out("c2"), "-idle", "20s", "-work", "2ms")
	if err != nil {
		return err
	}
	r.JoinMs = waitReady(out("c1"), out("c2"))
	time.Sleep(2 * time.Second) // a Kafka group rebalances once more after the 2nd join
	ids := produce(ctx, p, subj, "t2", n, 200, r, func(i int) {
		if i == n/2 {
			c1.cmd.Process.Kill() //nolint:errcheck // SIGKILL
		}
	})
	<-c1.done
	<-c2.done
	if err := score(r, ids, out("c1"), out("c2")); err != nil {
		return err
	}
	l1, _ := readLines(out("c1"))
	l2, _ := readLines(out("c2"))
	r.Consumers = fmt.Sprintf("1 group x 2 (D1 %d, D2 %d)", len(l1), len(l2))
	r.Pass = r.Lost == 0 && r.Dup == 0
	if r.Dup > 0 && r.Lost == 0 {
		r.Note = "at-least-once: dups carry the same msg id, so a consumer that dedups by id (as the spool's inbox file name does) removes them"
	}
	return nil
}

// Test 3: 10 posts; the consumer is SIGKILLed on the 5th after receiving it
// and before the poke and the ack. A fresh consumer must get the 5th.
func test3(ctx context.Context, b Backend, r *Result, out func(string) string) error {
	subj := "agent.CLE-3.box-a"
	p, err := setupProducer(ctx, b, map[string][]string{subj: {"agentC"}}, 1)
	if err != nil {
		return err
	}
	defer p.Close()
	ids := produce(ctx, p, subj, "t3", 10, 50, r, nil)
	c1, err := startConsumer(b.Name(), subj, "agentC", "C1", out("c1"), "-crash-after", "5", "-idle", "5s")
	if err != nil {
		return err
	}
	<-c1.done
	t := time.Now()
	c2, err := startConsumer(b.Name(), subj, "agentC", "C2", out("c2"), "-idle", "15s")
	if err != nil {
		return err
	}
	<-c2.done
	if err := score(r, ids, out("c1"), out("c2")); err != nil {
		return err
	}
	l2, _ := readLines(out("c2"))
	red := false
	for _, l := range l2 {
		if l.id == ids[4] {
			red = true
			r.RestartMs = float64(l.atNs-t.UnixNano()) / 1e6
		}
	}
	r.Redelivered = &red
	r.Consumers = "1, killed on #5, then a fresh one"
	r.Pass = red && r.Lost == 0 && r.Dup == 0
	return nil
}

// Test 4: 1,000 posts at 100 a second to a live consumer; the broker is
// restarted (docker restart) at 40 %. No acked post may come back, none may
// be lost; the producer retries a failed publish with the same id.
func test4(ctx context.Context, b Backend, n int, r *Result, out func(string) string) error {
	subj := "agent.CLE-4.box-a"
	p, err := setupProducer(ctx, b, map[string][]string{subj: {"agentD"}}, 1)
	if err != nil {
		return err
	}
	defer p.Close()
	c, err := startConsumer(b.Name(), subj, "agentD", "D", out("d"), "-idle", "45s")
	if err != nil {
		return err
	}
	r.JoinMs = waitReady(out("d"))
	var wg sync.WaitGroup
	ids := produce(ctx, p, subj, "t4", n, 100, r, func(i int) {
		if i == n*4/10 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				t := time.Now()
				if o, err := exec.Command("docker", "restart", "-t", "10", b.Container()).CombinedOutput(); err != nil {
					fmt.Fprintln(os.Stderr, "docker restart:", err, string(o))
				}
				r.RestartMs = float64(time.Since(t).Milliseconds())
			}()
		}
	})
	wg.Wait()
	<-c.done
	if err := score(r, ids, out("d")); err != nil {
		return err
	}
	r.Consumers = "1, broker restarted at 40 %"
	r.Pass = r.Lost == 0 && r.Dup == 0
	return nil
}

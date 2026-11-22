package hubclient

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The collector of spec 071 7.6.3 (SPL-6239 row T2), the fixture part of the
// 7.8 "box handler" test: fixture /proc files and a stub df give the
// expected sample. The frames, the 30 s guard and the hello feature are row
// T3's. The parity with the tick's bash collector is
// csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh, through
// TestBoxSampleParityOut below.

// The tick's own fixtures (csi-spl-orc box-stats-cron.tst.sh): a mount with
// a space, a repeated mount, and a network row with dashes.
const (
	boxFixLoadavg = "2.50 1.75 0.47 3/900 12345\n"
	boxFixMeminfo = "MemTotal: 16000000 kB\nMemAvailable: 6000000 kB\nSwapTotal: 1000 kB\nSwapFree: 400 kB\n"
	boxFixDF      = "Filesystem 1024-blocks Used Available Capacity Mounted on\n" +
		"/dev/sda1 100 55 40 58% /\n/dev/sdb1 900 400 500 45% /mnt/my data\n" +
		"/dev/sda1 100 55 40 58% /\nsrv:/x - - - - /net\n"
)

func boxFixtures(t *testing.T) (dir string, s BoxSampler) {
	t.Helper()
	dir = t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	return dir, BoxSampler{Box: "sat", Loadavg: write("loadavg", boxFixLoadavg), Meminfo: write("meminfo", boxFixMeminfo),
		CPUs: func() int { return 8 }, DF: func(context.Context) ([]byte, error) { return []byte(boxFixDF), nil }}
}

func TestBoxSampleCollectFixture(t *testing.T) {
	_, s := boxFixtures(t)
	s.AgentRun = func() map[string]bool { return map[string]bool{"c-001": true, "c-150": true, "c-151": false} }
	got, err := s.Collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := store.BoxStat{Box: "sat", Load1: 2.5, Load5: 1.75, Load15: 0.47, CPUs: 8, MemTotalKB: 16000000,
		MemAvailKB: 6000000, SwapUsedKB: 600, AgentsLive: 2, Disks: []store.BoxDisk{
			{Mount: "/", TotalKB: 100, AvailKB: 40, UsedKB: 55}, {Mount: "/mnt/my data", TotalKB: 900, AvailKB: 500, UsedKB: 400}}}
	if !reflect.DeepEqual(got.Stat, want) || !got.AgentsReported {
		t.Fatalf("sample:\n got %+v reported=%v\nwant %+v reported=true", got.Stat, got.AgentsReported, want)
	}
	if why := store.CheckBoxStat(got.Stat); why != "" {
		t.Fatalf("the hub would refuse it: %s", why)
	}
}

func TestBoxSampleNoRunReport(t *testing.T) {
	_, s := boxFixtures(t)
	for name, run := range map[string]func() map[string]bool{"no func": nil, "stale report": func() map[string]bool { return nil }} {
		s.AgentRun = run
		got, err := s.Collect(context.Background())
		if err != nil || got.AgentsReported || got.Stat.AgentsLive != 0 {
			t.Fatalf("%s: reported=%v agents_live=%d err=%v, want unreported 0", name, got.AgentsReported, got.Stat.AgentsLive, err)
		}
	}
}

func TestBoxSampleUnreadableSendsNothing(t *testing.T) {
	dir, s := boxFixtures(t)
	bad := s
	bad.Loadavg = filepath.Join(dir, "nosuch")
	if _, err := bad.Collect(context.Background()); err == nil {
		t.Fatal("an unreadable loadavg gave a sample")
	}
	noAvail := filepath.Join(dir, "meminfo-short")
	if err := os.WriteFile(noAvail, []byte("MemTotal: 16000000 kB\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	bad = s
	bad.Meminfo = noAvail
	if _, err := bad.Collect(context.Background()); err == nil {
		t.Fatal("a meminfo without MemAvailable gave a sample")
	}
	bad = s
	bad.CPUs = func() int { return 0 }
	if _, err := bad.Collect(context.Background()); err == nil {
		t.Fatal("0 cpus gave a sample")
	}
}

func TestBoxSampleDiskCapAndFailures(t *testing.T) {
	_, s := boxFixtures(t)
	var df strings.Builder
	df.WriteString("head\n")
	for i := 1; i <= 20; i++ {
		fmt.Fprintf(&df, "/dev/x%d 10 1 9 10%% /m%d\n", i, i)
	}
	s.DF = func(context.Context) ([]byte, error) { return []byte(df.String()), nil }
	got, _ := s.Collect(context.Background())
	if n := len(got.Stat.Disks); n != store.BoxDisksMax || got.Stat.Disks[15].Mount != "/m16" {
		t.Fatalf("20 mounts: %d kept, want the first %d", n, store.BoxDisksMax)
	}
	s.DF = func(context.Context) ([]byte, error) { return nil, fmt.Errorf("exit status 1") }
	got, _ = s.Collect(context.Background())
	if raw, _ := json.Marshal(got.Stat.Disks); string(raw) != "[]" {
		t.Fatalf("df fails: disks %s, want []", raw)
	}
}

// A df stuck on a hung mount: Collect still returns, with disks [], once the
// timeout passes. The stub never returns before the test ends (a fixture
// that plays the hung peer, not a wait).
func TestBoxSampleHungDF(t *testing.T) {
	_, s := boxFixtures(t)
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	s.DFTimeout = boxSampleDFTimeout / 30
	s.DF = func(context.Context) ([]byte, error) { <-release; return []byte(boxFixDF), nil }
	got, err := s.Collect(context.Background())
	if raw, _ := json.Marshal(got.Stat.Disks); err != nil || string(raw) != "[]" {
		t.Fatalf("hung df: disks %s err %v, want [] and a sample", raw, err)
	}
}

// Load lines the tick refuses give no sample.
func TestBoxSampleBadLoad(t *testing.T) {
	dir, s := boxFixtures(t)
	for i, line := range []string{"1.0 2.0\n", "1.0 x 3.0\n", "1.2.3 1 1\n"} {
		s.Loadavg = filepath.Join(dir, fmt.Sprintf("loadavg-bad%d", i))
		if err := os.WriteFile(s.Loadavg, []byte(line), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Collect(context.Background()); err == nil {
			t.Fatalf("loadavg %q gave a sample", line)
		}
	}
}

// The zero value reads the live box: /proc, the CPU count, the real df.
func TestBoxSampleLiveDefaults(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("/proc is Linux's")
	}
	got, err := BoxSampler{Box: "sat"}.Collect(context.Background())
	if err != nil || got.Stat.CPUs != runtime.NumCPU() || got.Stat.MemTotalKB <= 0 || got.Stat.Disks == nil {
		t.Fatalf("live box: %+v err %v", got.Stat, err)
	}
	if why := store.CheckBoxStat(got.Stat); why != "" {
		t.Fatalf("the hub would refuse the live sample: %s", why)
	}
}

// The default df run: the tick's argv, through exec, on a stub df.
func TestBoxSampleRunDF(t *testing.T) {
	dir := t.TempDir()
	stub := filepath.Join(dir, "df")
	body := "#!/bin/sh\necho \"$@\" >" + filepath.Join(dir, "argv") + "\nprintf '" + strings.ReplaceAll(boxFixDF, "%", "%%") + "'\n"
	if err := os.WriteFile(stub, []byte(body), 0o700); err != nil { // #nosec G306 -- an executable stub
		t.Fatal(err)
	}
	out, err := runBoxDF(context.Background(), append([]string{stub}, boxSampleDFArgv[1:]...))
	if err != nil || len(parseBoxDF(out)) != 2 {
		t.Fatalf("stub df: %q err %v", out, err)
	}
	argv, _ := os.ReadFile(filepath.Join(dir, "argv"))
	if got := strings.TrimSpace(string(argv)); got != "-kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs" {
		t.Fatalf("df argv %q, not the tick's", got)
	}
}

// TestBoxSampleParityOut is the Go half of box-sample-parity.tst.sh: with
// BOX_SAMPLE_PARITY_OUT set it collects from the tick's own fixture knobs
// (LANE_LOADAVG, LANE_MEMINFO, LANE_NPROC, LANE_DF_CMD, LANE_BOX) and writes
// the sample's JSON there. Without it there is nothing to compare: skipped.
func TestBoxSampleParityOut(t *testing.T) {
	out := os.Getenv("BOX_SAMPLE_PARITY_OUT")
	if out == "" {
		t.Skip("run by csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh")
	}
	cpus, err := strconv.Atoi(os.Getenv("LANE_NPROC"))
	if err != nil {
		t.Fatalf("LANE_NPROC: %v", err)
	}
	argv := strings.Fields(os.Getenv("LANE_DF_CMD")) // the tick runs $LANE_DF_CMD unquoted: word split, no shell
	if len(argv) == 0 {
		t.Fatal("LANE_DF_CMD is empty")
	}
	s := BoxSampler{Box: os.Getenv("LANE_BOX"), Loadavg: os.Getenv("LANE_LOADAVG"), Meminfo: os.Getenv("LANE_MEMINFO"),
		CPUs: func() int { return cpus }, DF: func(ctx context.Context) ([]byte, error) { return runBoxDF(ctx, argv) }}
	got, err := s.Collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(got.Stat)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(out, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

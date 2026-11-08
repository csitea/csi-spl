package hubclient

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// hpEnv is a box of the given GOOS that answers each probe by its whole argv
// (fakeHostEnv keys on argv[0], so `sysctl -n <x>` needs one of its own),
// reads only files and runs nothing real. An argv it does not know fails.
func hpEnv(goos string, files, outs map[string]string) hostEnv {
	return hostEnv{
		run: func(_ context.Context, argv []string) (string, error) {
			if o, ok := outs[strings.Join(argv, " ")]; ok {
				return o, nil
			}
			return "", errors.New("not found")
		},
		read: func(p string) ([]byte, error) {
			if f, ok := files[p]; ok {
				return []byte(f), nil
			}
			return nil, errors.New("absent")
		},
		goos: goos, arch: "arm64", cpus: 10,
	}
}

// hpDarwin is what a Mac prints for each probe hostOS and hostSystem run.
func hpDarwin() map[string]string {
	return map[string]string{
		"sw_vers -productName":               "macOS",
		"sw_vers -productVersion":            "15.1",
		"uname -r":                           "24.1.0",
		"sysctl -n machdep.cpu.brand_string": "Apple M2 Pro",
		"sysctl -n vm.loadavg":               "{ 1.0 2.0 3.0 }",
		"sysctl -n hw.memsize":               "17179869184",
		"sysctl -n kern.boottime":            "{ sec = 1700000000, usec = 0 } Tue Nov 14 22:13:20 2023",
	}
}

// On macOS the name and version come from sw_vers and the kernel from uname.
func TestHostOSDarwin(t *testing.T) {
	got := hostOS(context.Background(), hpEnv("darwin", nil, hpDarwin()))
	want := wire.HostOS{Name: "macOS", Version: "15.1", Kernel: "24.1.0", Arch: "arm64"}
	if *got != want {
		t.Fatalf("os = %+v, want %+v", *got, want)
	}
}

// A sw_vers that fails keeps the GOOS as the name and leaves no version.
func TestHostOSDarwinNoSwVers(t *testing.T) {
	got := hostOS(context.Background(), hpEnv("darwin", nil, map[string]string{"uname -r": "24.1.0"}))
	want := wire.HostOS{Name: "darwin", Kernel: "24.1.0", Arch: "arm64"}
	if *got != want {
		t.Fatalf("os = %+v, want %+v", *got, want)
	}
}

// Any other Unix reports its GOOS and uname's kernel; a failing uname leaves
// the kernel empty, and Windows never runs uname at all.
func TestHostOSOtherGOOS(t *testing.T) {
	cases := []struct {
		name, goos string
		outs       map[string]string
		want       wire.HostOS
	}{
		{"uname answers", "freebsd", map[string]string{"uname -r": "14.1-RELEASE"},
			wire.HostOS{Name: "freebsd", Kernel: "14.1-RELEASE", Arch: "arm64"}},
		{"uname fails", "freebsd", nil, wire.HostOS{Name: "freebsd", Arch: "arm64"}},
		{"windows skips uname", "windows", map[string]string{"uname -r": "never read"},
			wire.HostOS{Name: "windows", Arch: "arm64"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := hostOS(context.Background(), hpEnv(c.goos, nil, c.outs))
			if *got != c.want {
				t.Fatalf("os = %+v, want %+v", *got, c.want)
			}
		})
	}
}

// On macOS sysctl gives the CPU model, the load, the memory in MiB and the
// boot time; the host name and zone come as on any box.
func TestHostSystemDarwin(t *testing.T) {
	env := hpEnv("darwin", map[string]string{"/etc/timezone": "Europe/Helsinki\n"}, hpDarwin())
	env.hostname = func() (string, error) { return "mac-a", nil }
	got := hostSystem(context.Background(), env)
	want := wire.HostSystem{Hostname: "mac-a", Timezone: "Europe/Helsinki", CPUs: 10, CPUModel: "Apple M2 Pro",
		Load: "1.0 2.0 3.0", MemTotalMB: 16384, BootAt: time.Unix(1700000000, 0).UTC().Format(time.RFC3339)}
	if *got != want {
		t.Fatalf("system = %+v\nwant %+v", *got, want)
	}
}

// A memsize that is not a number and a boottime with no `sec =` leave those
// fields empty; a load of fewer than three numbers is not reported; a
// failing sysctl leaves the CPU model empty. Nothing else is lost.
func TestHostSystemDarwinGarbage(t *testing.T) {
	outs := map[string]string{
		"sysctl -n vm.loadavg":    "{ 1.0 2.0 }",
		"sysctl -n hw.memsize":    "lots",
		"sysctl -n kern.boottime": "Tue Nov 14 22:13:20 2023",
	}
	env := hpEnv("darwin", map[string]string{"/etc/timezone": "UTC"}, outs)
	got := hostSystem(context.Background(), env)
	want := wire.HostSystem{Timezone: "UTC", CPUs: 10}
	if *got != want {
		t.Fatalf("system = %+v\nwant %+v", *got, want)
	}
}

// A GOOS with neither /proc nor sysctl reports only the host, zone and CPUs.
func TestHostSystemOtherGOOS(t *testing.T) {
	env := hpEnv("freebsd", map[string]string{"/etc/timezone": "UTC"}, hpDarwin())
	env.hostname = func() (string, error) { return "bsd-a", nil }
	got := hostSystem(context.Background(), env)
	want := wire.HostSystem{Hostname: "bsd-a", Timezone: "UTC", CPUs: 10}
	if *got != want {
		t.Fatalf("system = %+v\nwant %+v", *got, want)
	}
}

// /etc/timezone wins over the /etc/localtime link; with no file, a link
// outside zoneinfo, a failing readlink or none at all, the clock's zone
// name is the answer.
func TestHostTimezone(t *testing.T) {
	clock, _ := time.Now().Zone()
	link := func(l string, err error) func(string) (string, error) {
		return func(p string) (string, error) {
			if p != "/etc/localtime" {
				t.Errorf("readlink(%q), want /etc/localtime", p)
			}
			return l, err
		}
	}
	cases := []struct {
		name     string
		files    map[string]string
		readlink func(string) (string, error)
		want     string
	}{
		{"file wins over link", map[string]string{"/etc/timezone": " America/New_York\n"},
			link("/usr/share/zoneinfo/Europe/Helsinki", nil), "America/New_York"},
		{"blank file falls to link", map[string]string{"/etc/timezone": "\n"},
			link("/usr/share/zoneinfo/Europe/Helsinki", nil), "Europe/Helsinki"},
		{"link outside zoneinfo", nil, link("/etc/static/localtime", nil), clock},
		{"link to bare zoneinfo/", nil, link("/usr/share/zoneinfo/", nil), clock},
		{"readlink fails", nil, link("", errors.New("not a link")), clock},
		{"no readlink", nil, nil, clock},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := hpEnv("linux", c.files, nil)
			env.readlink = c.readlink
			if got := hostTimezone(env); got != c.want {
				t.Fatalf("timezone = %q, want %q", got, c.want)
			}
		})
	}
}

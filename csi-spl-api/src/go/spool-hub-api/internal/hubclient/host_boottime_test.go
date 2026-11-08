package hubclient

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// btEnv is a Mac whose `sysctl -n kern.boottime` prints line; every other
// argv fails, so only the boot time is probed to a value.
func btEnv(line string) hostEnv {
	return hostEnv{
		run: func(_ context.Context, argv []string) (string, error) {
			if strings.Join(argv, " ") == "sysctl -n kern.boottime" {
				return line, nil
			}
			return "", errors.New("not found")
		},
		read: func(string) ([]byte, error) { return nil, errors.New("absent") },
		goos: "darwin", arch: "arm64", cpus: 10,
	}
}

// The boot time is the whole field sec: a usec field alone is no boot time.
func TestHostSystemDarwinBootTime(t *testing.T) {
	cases := []struct{ name, line, want string }{
		{"sec first", "{ sec = 1696000000, usec = 0 } Fri Sep 29 15:06:40 2023", "2023-09-29T15:06:40Z"},
		{"usec only", "{ usec = 7 }", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := hostSystem(context.Background(), btEnv(c.line)).BootAt; got != c.want {
				t.Fatalf("BootAt = %q, want %q", got, c.want)
			}
		})
	}
}

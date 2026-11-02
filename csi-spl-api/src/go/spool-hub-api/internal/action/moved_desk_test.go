package action

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// Spec 169 T7b: which desks a client may re-route through. A desk root finds its
// siblings, $SPOOL_DESKS names them, and anything else resolves none: the post is
// then refused by hubclient, never sent another way.
func TestMovedDeskResolver(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "desk")
	root := filepath.Join(dir, "t1", "box-a", "spool")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		cfg  config.Config
		want string
	}{
		{"a desk root reads its siblings", config.Config{SpoolRoot: root, BoxID: "box-a", Tenant: "t1"}, "no desk box-a in t2"},
		{"a root that is no desk", config.Config{SpoolRoot: filepath.Join(dir, "other"), BoxID: "box-a", Tenant: "t1"}, "not a desk"},
		{"another tenant's root is no desk of this one", config.Config{SpoolRoot: root, BoxID: "box-a", Tenant: "t9"}, "not a desk"},
		{"another box's root is no desk of this one", config.Config{SpoolRoot: root, BoxID: "box-b", Tenant: "t1"}, "not a desk"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := tc.cfg
			if _, err := MovedDesk(&cfg)("t2"); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v, want %q", err, tc.want)
			}
		})
	}
	t.Run("SPOOL_DESKS names the desks", func(t *testing.T) {
		t.Setenv("SPOOL_DESKS", dir)
		cfg := config.Config{SpoolRoot: filepath.Join(dir, "other"), BoxID: "box-a", DeskBox: "box-d", Tenant: "t1"}
		if _, err := MovedDesk(&cfg)("t2"); err == nil || !strings.Contains(err.Error(), "no desk box-d in t2") {
			t.Fatalf("got %v", err)
		}
	})
}

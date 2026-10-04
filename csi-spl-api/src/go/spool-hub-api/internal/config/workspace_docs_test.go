package config

import "testing"

// specs/075 Phase 2: a workspace docs bucket that cannot name one dot-free
// bucket per workspace stops the hub at boot; unset = the routes are off.
func TestWorkspaceDocsBucketFailsFast(t *testing.T) {
	for _, tc := range []struct {
		bucket, dir string
		ok          bool
	}{
		{"", "", true},
		{"csi-spl-dev-docs-{tenant}", "", true},
		{"", "/var/docs", true},
		{"csi-spl-dev-docs", "", false},                   // one bucket for every workspace
		{"{tenant}-{tenant}", "", false},                  // twice
		{"{tenant}.docs.example.com", "", false},          // dotted: domain verification
		{"Csi-Spl-{tenant}", "", false},                   // upper case
		{"csi-spl-dev-docs-{tenant}", "/var/docs", false}, // both
	} {
		h := &Hub{WorkspaceDocsBucket: tc.bucket, WorkspaceDocsDir: tc.dir}
		if err := h.validateWorkspaceDocs(); (err == nil) != tc.ok {
			t.Errorf("bucket %q dir %q: err %v, want ok=%v", tc.bucket, tc.dir, err, tc.ok)
		}
	}
}

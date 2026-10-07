package config

import "testing"

// Spec 099 5.1: SPOOL_HUB_TOPIC_HEADS is off by default, takes off / shadow /
// on only, and its sample is 1 (every list) unless set, never below 1.
func TestLoadHubTopicHeads(t *testing.T) {
	t.Setenv("SPOOL_HUB_DB_DSN", "postgres://spool@/spool?sslmode=disable")
	t.Setenv("SPOOL_HUB_FILES_DIR", t.TempDir())
	t.Setenv("SPOOL_HUB_FILES_BUCKET", "")
	t.Setenv("SPOOL_HUB_TENANT_HOST_PATTERN", "{tenant}.hub.test")
	t.Setenv("SPOOL_HUB_ENV", "prd")
	t.Setenv("SPOOL_HUB_TOPIC_HEADS", "")
	t.Setenv("SPOOL_HUB_TOPIC_HEADS_SAMPLE", "")
	h, err := LoadHub()
	if err != nil || h.TopicHeads != "off" || h.TopicHeadsSample != 1 {
		t.Fatalf("defaults: %v %q %d, want off 1", err, h.TopicHeads, h.TopicHeadsSample)
	}
	for _, m := range []string{"off", "shadow", "on"} {
		t.Setenv("SPOOL_HUB_TOPIC_HEADS", m)
		if h, err := LoadHub(); err != nil || h.TopicHeads != m {
			t.Fatalf("%s: %v", m, err)
		}
	}
	for _, bad := range []string{"On", "true", "1", "heads"} {
		t.Setenv("SPOOL_HUB_TOPIC_HEADS", bad)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("mode %q accepted", bad)
		}
	}
	t.Setenv("SPOOL_HUB_TOPIC_HEADS", "shadow")
	t.Setenv("SPOOL_HUB_TOPIC_HEADS_SAMPLE", "10")
	if h, err := LoadHub(); err != nil || h.TopicHeadsSample != 10 {
		t.Fatalf("sample 10: %v", err)
	}
	t.Setenv("SPOOL_HUB_TOPIC_HEADS_SAMPLE", "0")
	if _, err := LoadHub(); err == nil {
		t.Fatal("sample 0 accepted")
	}
}

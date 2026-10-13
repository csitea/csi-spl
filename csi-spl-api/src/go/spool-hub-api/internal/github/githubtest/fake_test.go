package githubtest_test

import (
	"testing"
	"spool-hub-api/internal/github/githubtest"
)

func TestNew(t *testing.T) {
	srv := githubtest.New(t, nil)

	if srv.URL == "" {
		t.Error("server URL is empty")
	}
}
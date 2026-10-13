package fakehub_test

import (
	"testing"
	"spool-hub-api/internal/testkit/fakehub"
)

func TestNew(t *testing.T) {
	hub := fakehub.New(t)

	if hub.URL == "" {
		t.Error("hub URL is empty")
	}
}
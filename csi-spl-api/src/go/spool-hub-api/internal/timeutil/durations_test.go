package timeutil_test

import (
	"testing"
	"time"
	"spool-hub-api/internal/timeutil"
)

func TestDurations(t *testing.T) {
	if timeutil.Day != 24*time.Hour {
		t.Errorf("Day: got %v, want %v", timeutil.Day, 24*time.Hour)
	}
	if timeutil.Hour != time.Hour {
		t.Errorf("Hour: got %v, want %v", timeutil.Hour, time.Hour)
	}
	if timeutil.Minute != time.Minute {
		t.Errorf("Minute: got %v, want %v", timeutil.Minute, time.Minute)
	}
	if timeutil.Second != time.Second {
		t.Errorf("Second: got %v, want %v", timeutil.Second, time.Second)
	}
	if timeutil.Millisecond != time.Millisecond {
		t.Errorf("Millisecond: got %v, want %v", timeutil.Millisecond, time.Millisecond)
	}
}
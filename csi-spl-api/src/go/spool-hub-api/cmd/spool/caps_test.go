package main

import "testing"

// Spec 147 5.2: the desk pre-check refuses at the cap, admits under it and
// for an uncapped vendor, and names agent, vendor, workspace, cap and count.
func TestCapsVerdict(t *testing.T) {
	one, two := 1, 2
	a := capsAnswer{WorkspaceID: "example-ws",
		Caps: map[string]*int{"claude": &one, "agy": &two, "qwen": nil},
		Live: map[string]int{"claude": 1, "agy": 1, "qwen": 5}}
	if got, want := capsVerdict(a, "c-005"), "agent c-005 (claude) exceeds workspace example-ws cap of 1 (currently 1 live); seating refused"; got != want {
		t.Fatalf("claude at cap: %q, want %q", got, want)
	}
	for _, id := range []string{"a-005", "q-006", "m-004", "g-004"} {
		if got := capsVerdict(a, id); got != "" {
			t.Errorf("%s: refused %q", id, got)
		}
	}
	a.Live["agy"] = 2
	if capsVerdict(a, "a-006") == "" {
		t.Fatal("3rd agy at cap 2 admitted")
	}
}

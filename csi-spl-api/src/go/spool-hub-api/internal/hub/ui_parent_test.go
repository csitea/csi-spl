package hub

import "testing"

func TestUIParent(t *testing.T) {
	zero, one := 0, 1
	two := 2
	cases := []struct {
		name string
		in   *int
		want int
		ok   bool
	}{
		{"absent", nil, 0, true},
		{"reply", &zero, 0, true},
		{"parent", &one, 1, true},
		{"other", &two, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := uiParent(c.in)
			if ok != c.ok || (ok && got != c.want) {
				t.Fatalf("uiParent(%v) = %d, %v; want %d, %v", c.in, got, ok, c.want, c.ok)
			}
		})
	}
}

package action

import "testing"

// TestJSON pins JSON(v): the compact json.Marshal text of v, and "" when v
// cannot be marshalled (the error is dropped by design).
func TestJSON(t *testing.T) {
	type tagged struct {
		Code int `json:"exit_code"`
	}
	cases := []struct {
		name string
		in   any
		want string
	}{
		{"struct uses json tags", tagged{Code: 5}, `{"exit_code":5}`},
		{"map keys sorted", map[string]int{"b": 2, "a": 1}, `{"a":1,"b":2}`},
		{"nil", nil, `null`},
		{"unmarshallable", make(chan int), ``},
	}
	for _, c := range cases {
		if got := JSON(c.in); got != c.want {
			t.Errorf("%s: JSON(%v) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

package protocol

import "testing"

func TestCompatible(t *testing.T) {
	cases := []struct {
		client, daemon string
		want           bool
	}{
		{"0.1.0", "0.1.0", true},
		{"0.1.9", "0.1.0", true},
		{"0.2.0", "0.1.0", false},
		{"1.0.0", "0.1.0", false},
		{"1.4.0", "1.2.3", true},
		{"2.0.0", "1.2.3", false},
		{"0.1", "0.1.0", false},
		{"0.1.0-rc1", "0.1.0", false},
		{"banana", "0.1.0", false},
		{"", "0.1.0", false},
	}
	for _, c := range cases {
		if got := Compatible(c.client, c.daemon); got != c.want {
			t.Errorf("Compatible(%q, %q) = %v, want %v", c.client, c.daemon, got, c.want)
		}
	}
}

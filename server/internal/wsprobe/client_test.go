package wsprobe

import "testing"

func TestWSURL(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"127.0.0.1:52731", "ws://127.0.0.1:52731/ws"},
		{"127.0.0.1:52731/ws", "ws://127.0.0.1:52731/ws"},
		{"ws://127.0.0.1:9/ws", "ws://127.0.0.1:9/ws"},
		{"http://127.0.0.1:9", "ws://127.0.0.1:9/ws"},
		{"  localhost:1  ", "ws://localhost:1/ws"},
	}
	for _, tc := range cases {
		if got := WSURL(tc.in); got != tc.want {
			t.Fatalf("WSURL(%q)=%q, want %q", tc.in, got, tc.want)
		}
	}
}

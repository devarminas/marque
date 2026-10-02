package main

import "testing"

func TestDump(t *testing.T) {
	cases := []struct{ hex, want string }{
		{"019600012c010000", "input c2s input{dx:0.5 dz:-1 jump:true seq:300}"},
		{"020702d244060032400600d7180600", "state s2c pose{id:PlayerId(7/2) x:12.34 y:0.5 z:-100.25}"},
		{"8a0101000000000000000200000000000000e8030000022a00000006", "events s2c refused{stream:1 event_seq:2 tick:1000 source:intent seq:42 reason:cooldown}"},
	}
	for _, c := range cases {
		got, err := dump(c.hex)
		if err != nil || got != c.want {
			t.Errorf("dump(%s) = %q, %v; want %q", c.hex, got, err, c.want)
		}
	}
	if _, err := dump("7f"); err == nil || err.Error() != "wire: unknown message id" {
		t.Errorf("dump(7f) error = %v, want unknown message id", err)
	}
}

package transport

import (
	"runtime"
	"testing"
)

func TestPartialLastFragmentsCostBoundedMemory(t *testing.T) {
	rx, err := NewReceiver(Client, testConfig())
	if err != nil {
		t.Fatal(err)
	}
	var ds [][]byte
	for d := uint16(0); d < 2; d++ {
		var es []entry
		for i := uint16(0); i < 128; i++ {
			es = append(es, entry{id: d*128 + i, index: MaxFragments - 1, count: MaxFragments, data: []byte{0xaa}})
		}
		ds = append(ds, raw(Server, d, NoAcks, nil, es...))
	}
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	for _, d := range ds {
		if _, err := rx.Receive(d); err != nil {
			t.Fatal(err)
		}
	}
	runtime.ReadMemStats(&after)
	if got := after.TotalAlloc - before.TotalAlloc; got > 128<<10 {
		t.Fatalf("256 partial messages of one 1-byte last fragment allocated %d bytes, want at most 131072", got)
	}
	if got := len(rx.partial); got != 256 {
		t.Fatalf("%d partial messages buffered, want 256", got)
	}
}

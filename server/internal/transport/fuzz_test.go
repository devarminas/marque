package transport

import (
	"errors"
	"testing"
)

func FuzzReceive(f *testing.F) {
	f.Add(raw(Server, 0, NoAcks, &Unreliable{Stamp: 1, Items: [][]byte{{0x02, 0x01}}}, entry{id: 0, index: 0, count: 1, data: []byte{0x04}}))
	f.Add(raw(Client, 7, AckWindow{Latest: 3, Bits: 5}, &Unreliable{Stamp: 9, Items: [][]byte{{0x01}}}, entry{id: 0, index: 1, count: 2, data: []byte{0x05}}))
	f.Add(raw(Server, 1, NoAcks, nil, entry{id: 0, index: 0, count: 2, data: fill(FragmentSize, 0)}))
	f.Fuzz(func(t *testing.T, d []byte) {
		for _, role := range []Role{Server, Client} {
			rx, err := NewReceiver(role, testConfig())
			if err != nil {
				t.Fatal(err)
			}
			if _, err := rx.Receive(d); err != nil {
				continue
			}
			if _, err := rx.Receive(d); !errors.Is(err, ErrDuplicate) {
				t.Fatalf("%s: second receive gave %v, want ErrDuplicate", role, err)
			}
		}
	})
}

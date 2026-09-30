package transport

import (
	"encoding/binary"
	"errors"
	"testing"
)

func frames(ds ...[]byte) []byte {
	var b []byte
	for _, d := range ds {
		b = binary.LittleEndian.AppendUint16(b, uint16(len(d)))
		b = append(b, d...)
	}
	return b
}

func unframe(b []byte) [][]byte {
	var ds [][]byte
	for len(b) >= 2 {
		n := min(int(binary.LittleEndian.Uint16(b)), len(b)-2)
		ds = append(ds, b[2:2+n])
		b = b[2+n:]
	}
	return ds
}

func FuzzReceive(f *testing.F) {
	f.Add(frames(
		raw(Server, 0, NoAcks, &Unreliable{Stamp: 1, Items: [][]byte{{0x02, 0x01}}}, entry{id: 0, index: 0, count: 1, data: []byte{0x04}}),
		raw(Server, 2, NoAcks, nil, entry{id: 1, index: 1, count: 2, data: []byte{0x05}}),
		raw(Server, 1, NoAcks, nil, entry{id: 1, index: 0, count: 2, data: fill(FragmentSize, 0)}),
	))
	f.Add(frames(
		raw(Client, 65535, AckWindow{Latest: 3, Bits: 5}, &Unreliable{Stamp: 9, Items: [][]byte{{0x01}}}, entry{id: 0, index: 1, count: 2, data: []byte{0x05}}),
		raw(Client, 0, AckWindow{Latest: 4, Bits: 11}, nil, entry{id: 255, index: 0, count: 1, data: []byte{0x06}}),
		raw(Client, 32, NoAcks, nil, entry{id: 0, index: 0, count: 2, data: fill(FragmentSize, 1)}),
	))
	f.Fuzz(func(t *testing.T, b []byte) {
		ds := unframe(b)
		for _, role := range []Role{Server, Client} {
			rx, err := NewReceiver(role, testConfig())
			if err != nil {
				t.Fatal(err)
			}
			for i, d := range ds {
				if _, err := rx.Receive(d); err != nil {
					continue
				}
				if _, err := rx.Receive(d); !errors.Is(err, ErrDuplicate) {
					t.Fatalf("%s datagram %d: second receive gave %v, want ErrDuplicate", role, i, err)
				}
				if rx.buffered > WindowBytes || len(rx.partial) > WindowMessages {
					t.Fatalf("%s datagram %d: %d bytes in %d partial messages, want at most %d in %d", role, i, rx.buffered, len(rx.partial), WindowBytes, WindowMessages)
				}
			}
		}
	})
}

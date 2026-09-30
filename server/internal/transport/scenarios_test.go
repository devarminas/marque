package transport

import (
	"bytes"
	"encoding/binary"
)

func raw(from Role, seq uint16, ack AckWindow, u *Unreliable, entries ...entry) []byte {
	d := putHeader(nil, header{protocol: ProtocolID, hash: testHash, seq: seq, ack: ack})
	return encodeBody(d, from, u, entries)
}

func fill(n int, seed byte) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = seed + byte(i)
	}
	return b
}

func testConfig() Config { return DefaultConfig(testHash) }

func mustEndpoint(role Role, cfg Config, now uint64) *Endpoint {
	e, err := NewEndpoint(role, cfg, now)
	if err != nil {
		panic(err)
	}
	return e
}

func vectorScenarios() map[string]string {
	out := map[string]string{}
	for name, f := range map[string]func() *script{
		"client_basic":     clientBasic,
		"server_basic":     serverBasic,
		"fragmentation":    fragmentation,
		"resend":           resend,
		"budget":           budget,
		"stale":            stale,
		"sequence_wrap":    sequenceWrap,
		"malformed":        malformed,
		"hostile_reliable": hostileReliable,
		"slow_client":      slowClient,
		"timeout":          timeout,
	} {
		out[name] = f().text()
	}
	return out
}

func clientBasic() *script {
	s := newScript("A client receives state and one event, answers with input and an intent,\nthen goes idle until a keepalive is due.", Client, testConfig(), 0)
	s.recv(30_000, raw(Server, 0, NoAcks, &Unreliable{Stamp: 1, Items: [][]byte{{0x02, 0x01}, {0x03, 0x01, 0x02}}},
		entry{id: 0, index: 0, count: 1, data: []byte{0x04, 0x07, 0x09, 0x06}}))
	s.send([]byte{0x05, 0x01})
	s.flush(40_000, Unreliable{Stamp: 1, Items: [][]byte{{0x01, 0x64, 0x64, 0x00, 0x01}}})
	s.recv(70_000, raw(Server, 1, AckWindow{Latest: 0}, &Unreliable{Stamp: 2, Items: [][]byte{{0x02, 0x02}}}))
	s.flush(80_000, Unreliable{})
	s.flush(120_000, Unreliable{})
	s.flush(160_000, Unreliable{})
	return s
}

func serverBasic() *script {
	s := newScript("A server and a live client exchange state, events, input and intents for\nthree ticks. The client's datagrams are recorded as the recv lines.", Server, testConfig(), 0)
	cli := mustEndpoint(Client, testConfig(), 0)
	for n := uint64(1); n <= 3; n++ {
		now := n * tick
		s.send(fill(int(n)*3, byte(n)))
		ds := s.flush(now, Unreliable{Stamp: uint32(n), Items: [][]byte{fill(4, byte(n*16))}})
		for _, d := range ds {
			cli.Receive(d, now+10_000)
		}
		cli.Send(fill(2, byte(n*32)))
		for _, d := range cli.Flush(now+10_000, Unreliable{Stamp: uint32(n), Items: [][]byte{fill(5, byte(n*8))}}).Datagrams {
			s.recv(now+20_000, d)
		}
	}
	return s
}

func fragmentation() *script {
	s := newScript("A client receives a 2500-byte event (three fragments), a 1025-byte event\n(two fragments, the last one byte), and a small event, out of order and with\na duplicate. Each message is delivered once, in order, when its last\nmissing fragment arrives.", Client, testConfig(), 0)
	srv := mustEndpoint(Server, testConfig(), 0)
	srv.Send(fill(2500, 1))
	srv.Send(fill(1025, 2))
	srv.Send([]byte{0x04, 0x01, 0x02, 0x03})
	ds := srv.Flush(tick, Unreliable{}).Datagrams
	for _, i := range []int{3, 0, 2, 0, 1} {
		s.recv(50_000+uint64(i), ds[i])
	}
	s.flush(80_000, Unreliable{})
	return s
}

func resend() *script {
	s := newScript("A server's event is lost. It is due again ResendAfter after it was sent,\ngoes out in a new packet, and once that packet is acked it is never sent\nagain.", Server, testConfig(), 0)
	cli := mustEndpoint(Client, testConfig(), 0)
	s.send([]byte{0x04, 0x01, 0x02, 0x03})
	s.flush(40_000, Unreliable{})
	s.flush(80_000, Unreliable{})
	s.flush(200_000, Unreliable{})
	ds := s.flush(240_000, Unreliable{})
	cli.Receive(ds[0], 260_000)
	s.recv(280_000, cli.Flush(270_000, Unreliable{}).Datagrams[0])
	s.flush(440_000, Unreliable{})
	s.flush(480_000, Unreliable{})
	return s
}

func budget() *script {
	cfg := testConfig()
	cfg.TickBudget = 2400
	s := newScript("A 2400-byte tick budget. Events go first and are deferred, never dropped;\nstate items fill what is left, in order, in whichever datagram holds more.", Server, cfg, 0)
	for i := byte(1); i <= 3; i++ {
		s.send(fill(1000, i))
	}
	var items [][]byte
	for i := 0; i < 60; i++ {
		items = append(items, fill(40, byte(i)))
	}
	s.flush(40_000, Unreliable{Stamp: 1, Items: items})
	s.flush(80_000, Unreliable{Stamp: 2, Items: items})
	return s
}

func stale() *script {
	s := newScript("A client delivers a state section only when its stamp is newer than every\nstamp delivered before. Events in a stale datagram are still delivered.", Client, testConfig(), 0)
	st := func(n uint32) *Unreliable { return &Unreliable{Stamp: n, Items: [][]byte{{0x02, byte(n)}}} }
	s.recv(10_000, raw(Server, 0, NoAcks, st(5)))
	s.recv(20_000, raw(Server, 1, NoAcks, st(3), entry{id: 0, index: 0, count: 1, data: []byte{0x04}}))
	s.recv(30_000, raw(Server, 2, NoAcks, st(5)))
	s.recv(40_000, raw(Server, 3, NoAcks, nil, entry{id: 1, index: 0, count: 1, data: []byte{0x05}}))
	s.recv(50_000, raw(Server, 4, NoAcks, st(6)))
	return s
}

func sequenceWrap() *script {
	s := newScript("Packet sequences wrap from 65535 to 0. A repeat is a duplicate, and a\nsequence more than 32 behind the newest is too old; exactly 32 behind is\naccepted. The flush shows the ack window: latest 1, bits 0x80000007 for 0,\n65535, 65534, and 65505.", Client, testConfig(), 0)
	for i, seq := range []uint16{65534, 65535, 0, 1} {
		s.recv(uint64(10_000*(i+1)), raw(Server, seq, NoAcks, &Unreliable{Stamp: uint32(i + 1), Items: [][]byte{{0x02}}}))
	}
	s.recv(50_000, raw(Server, 65535, NoAcks, nil, entry{id: 0, index: 0, count: 1, data: []byte{0x04}}))
	s.recv(60_000, raw(Server, 65504, NoAcks, nil, entry{id: 0, index: 0, count: 1, data: []byte{0x04}}))
	s.recv(70_000, raw(Server, 65505, NoAcks, nil, entry{id: 0, index: 0, count: 1, data: []byte{0x04}}))
	s.flush(120_000, Unreliable{})
	return s
}

func malformed() *script {
	s := newScript("A server refuses each malformed datagram whole: none of them consumes\nsequence 0, so the valid datagram at the end is still accepted.", Server, testConfig(), 0)
	good := raw(Client, 0, NoAcks, &Unreliable{Stamp: 1, Items: [][]byte{{0x01}}}, entry{id: 0, index: 0, count: 1, data: []byte{0x05}})
	hdr := func() []byte {
		return putHeader(nil, header{protocol: ProtocolID, hash: testHash, seq: 0, ack: NoAcks})
	}
	with := func(b ...byte) []byte { return append(hdr(), b...) }
	intents := byte(4)
	input := byte(3)
	u16 := func(v uint16) []byte { return binary.LittleEndian.AppendUint16(nil, v) }
	cat := func(parts ...[]byte) []byte { return bytes.Join(parts, nil) }
	frag := func(id uint16, index, count byte, data []byte) []byte {
		return cat(u16(id), []byte{index, count}, putLen(nil, len(data)), data)
	}
	bad := [][]byte{
		hdr()[:HeaderSize-1],
		append(hdr(), make([]byte, MaxDatagram-HeaderSize+1)...),
		append([]byte{0x4d, 0x52, 0x51, 0x32}, hdr()[4:]...),
		append(append(hdr()[:4:4], 0xee), hdr()[5:]...),
		with(1, 1, 0, 0, 0, 1, 0, 1, 0x02),
		with(input, 1, 0, 0, 0, 0, 0),
		with(input, 1, 0, 0, 0, 1, 0, 0),
		with(input, 1, 0, 0, 0, 1, 0, 0x81, 0x00, 0x01),
		with(input, 1, 0, 0, 0, 1, 0, 0x81, 0x80, 0x01),
		with(input, 1, 0, 0, 0, 1, 0, 3, 0x01),
		cat(hdr(), []byte{intents}, u16(0)),
		cat(hdr(), []byte{intents}, u16(1), frag(0, 0, 0, []byte{1})),
		cat(hdr(), []byte{intents}, u16(1), frag(0, 0, 65, []byte{1})),
		cat(hdr(), []byte{intents}, u16(1), frag(0, 2, 2, []byte{1})),
		cat(hdr(), []byte{intents}, u16(1), frag(0, 0, 2, []byte{1})),
		cat(hdr(), []byte{intents}, u16(1), frag(0, 0, 1, fill(FragmentSize+1, 0))),
		append(bytes.Clone(good), 0x00),
		cat(hdr(), []byte{intents}, u16(1), frag(0, 0, 1, []byte{5}), []byte{input, 1, 0, 0, 0, 1, 0, 1, 1}),
	}
	for i, d := range bad {
		s.recv(uint64(1000*(i+1)), d)
	}
	s.recv(100_000, good)
	return s
}

func hostileReliable() *script {
	s := newScript("Fragments a well-behaved sender cannot produce are ignored, not fatal: an\nid 256 or more ahead of the next expected, and a fragment count that\ndisagrees with an earlier fragment of the same message. The datagram is\nstill accepted, and the real message completes.", Client, testConfig(), 0)
	s.recv(10_000, raw(Server, 0, NoAcks, nil,
		entry{id: 256, index: 0, count: 1, data: []byte{0xaa}},
		entry{id: 0, index: 1, count: 2, data: []byte{0x02}}))
	s.recv(20_000, raw(Server, 1, NoAcks, nil,
		entry{id: 0, index: 0, count: 3, data: fill(FragmentSize, 0)}))
	s.recv(30_000, raw(Server, 2, NoAcks, nil,
		entry{id: 0, index: 0, count: 2, data: fill(FragmentSize, 0)},
		entry{id: 1, index: 0, count: 1, data: []byte{0x01}}))
	return s
}

func slowClient() *script {
	cfg := testConfig()
	cfg.BacklogLimit = 2
	s := newScript("With BacklogLimit 2, a third unacked event closes the connection as\nslow_client. After that it sends nothing and refuses sends and datagrams.", Server, cfg, 0)
	s.send([]byte{0x04, 0x01})
	s.send([]byte{0x04, 0x02})
	s.flush(40_000, Unreliable{})
	s.send([]byte{0x04, 0x03})
	s.flush(80_000, Unreliable{Stamp: 2, Items: [][]byte{{0x02}}})
	s.send([]byte{0x04, 0x04})
	s.recv(90_000, raw(Client, 0, AckWindow{Latest: 0}, nil))
	return s
}

func timeout() *script {
	s := newScript("Keepalives go out once KeepaliveAfter passes with nothing sent. The\nconnection times out TimeoutAfter after the last accepted datagram. A closed\nconnection refuses sends.", Client, testConfig(), 0)
	s.flush(40_000, Unreliable{})
	s.flush(100_000, Unreliable{})
	s.flush(199_999, Unreliable{})
	s.flush(200_000, Unreliable{})
	s.recv(1_000_000, raw(Server, 0, NoAcks, nil))
	s.flush(5_999_999, Unreliable{})
	s.flush(6_000_000, Unreliable{})
	s.send([]byte{0x05})
	return s
}

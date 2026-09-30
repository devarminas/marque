// Package transport is the reliable-UDP protocol of ADR 0018 section 1. The
// byte layout and every rule below are specified in shared/wire/transport.md;
// the C++ client core implements the same spec, and the vectors under
// shared/wire/vectors/transport hold both to it.
//
// The core is sans-IO. Receiver, Sender, and Endpoint take bytes and a
// caller-supplied clock in microseconds and return bytes; nothing here opens
// a socket, starts a goroutine, or reads wall time. udp.go is the thin shell.
package transport

import (
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/devarminas/marque/server/internal/wire/codec"
)

const (
	ProtocolID     uint32 = 'M' | 'R'<<8 | 'Q'<<16 | '1'<<24
	MaxDatagram           = 1200
	HeaderSize            = 20
	FragmentSize          = 1024
	MaxFragments          = 64
	MaxMessage            = FragmentSize * MaxFragments
	WindowMessages        = 256
	WindowBytes           = MaxMessage
	AckBits               = 32
	KeepaliveAfter uint64 = 100_000
	TimeoutAfter   uint64 = 5_000_000

	unreliableSectionHeader = 1 + 4 + 2
	reliableSectionHeader   = 1 + 2
	entryHeader             = 2 + 1 + 1
)

var (
	ErrMalformed = errors.New("transport: malformed datagram")
	ErrForeign   = errors.New("transport: protocol id or schema hash mismatch")
	ErrDuplicate = errors.New("transport: duplicate packet")
	ErrTooOld    = errors.New("transport: packet older than the ack window")
	ErrClosed    = errors.New("transport: connection closed")
	ErrMessage   = errors.New("transport: reliable message empty or over MaxMessage")
)

// Role fixes which channels a side sends and receives. A server sends state
// and events and receives input and intents; a client is the mirror.
type Role uint8

const (
	Server Role = iota
	Client
)

func (r Role) String() string {
	if r == Server {
		return "server"
	}
	return "client"
}

func (r Role) channels() (unreliable, reliable codec.Channel) {
	if r == Server {
		return codec.ChannelState, codec.ChannelEvents
	}
	return codec.ChannelInput, codec.ChannelIntents
}

func (r Role) peer() Role { return 1 - r }

// AckWindow is what one side has received from the other: the newest packet
// sequence and a bit per packet before it (bit i is Latest-1-i). NoAcks is
// the value before anything has arrived.
type AckWindow struct {
	Latest uint16
	Bits   uint32
}

var NoAcks = AckWindow{Latest: 0xffff}

type header struct {
	protocol uint32
	hash     uint64
	seq      uint16
	ack      AckWindow
}

func putHeader(dst []byte, h header) []byte {
	dst = binary.LittleEndian.AppendUint32(dst, h.protocol)
	dst = binary.LittleEndian.AppendUint64(dst, h.hash)
	dst = binary.LittleEndian.AppendUint16(dst, h.seq)
	dst = binary.LittleEndian.AppendUint16(dst, h.ack.Latest)
	return binary.LittleEndian.AppendUint32(dst, h.ack.Bits)
}

func readHeader(b []byte) header {
	return header{
		protocol: binary.LittleEndian.Uint32(b[0:]),
		hash:     binary.LittleEndian.Uint64(b[4:]),
		seq:      binary.LittleEndian.Uint16(b[12:]),
		ack: AckWindow{
			Latest: binary.LittleEndian.Uint16(b[14:]),
			Bits:   binary.LittleEndian.Uint32(b[16:]),
		},
	}
}

// Unreliable is one unreliable-channel payload: a stamp (the tick for state,
// the input sequence for input) and encoded schema messages, none empty, in
// priority order.
type Unreliable struct {
	Stamp uint32
	Items [][]byte
}

type entry struct {
	id    uint16
	index uint8
	count uint8
	data  []byte
}

type body struct {
	unreliable *Unreliable
	entries    []entry
}

func lenSize(n int) int {
	if n < 0x80 {
		return 1
	}
	return 2
}

func putLen(dst []byte, n int) []byte {
	if n < 0x80 {
		return append(dst, byte(n))
	}
	return append(dst, byte(n)|0x80, byte(n>>7))
}

func itemSize(item []byte) int { return lenSize(len(item)) + len(item) }

func entrySize(data []byte) int { return entryHeader + itemSize(data) }

func encodeBody(dst []byte, role Role, u *Unreliable, entries []entry) []byte {
	unrelCh, relCh := role.channels()
	if u != nil {
		dst = append(dst, byte(unrelCh))
		dst = binary.LittleEndian.AppendUint32(dst, u.Stamp)
		dst = binary.LittleEndian.AppendUint16(dst, uint16(len(u.Items)))
		for _, it := range u.Items {
			dst = putLen(dst, len(it))
			dst = append(dst, it...)
		}
	}
	if len(entries) > 0 {
		dst = append(dst, byte(relCh))
		dst = binary.LittleEndian.AppendUint16(dst, uint16(len(entries)))
		for _, e := range entries {
			dst = binary.LittleEndian.AppendUint16(dst, e.id)
			dst = append(dst, e.index, e.count)
			dst = putLen(dst, len(e.data))
			dst = append(dst, e.data...)
		}
	}
	return dst
}

type parser struct {
	b   []byte
	err error
}

func (p *parser) fail(reason string) {
	if p.err == nil {
		p.err = fmt.Errorf("%w: %s", ErrMalformed, reason)
	}
	p.b = nil
}

func (p *parser) take(n int) []byte {
	if p.err != nil {
		return nil
	}
	if len(p.b) < n {
		p.fail("truncated")
		return nil
	}
	v := p.b[:n:n]
	p.b = p.b[n:]
	return v
}

func (p *parser) u8() uint8 {
	if v := p.take(1); v != nil {
		return v[0]
	}
	return 0
}

func (p *parser) u16() uint16 {
	if v := p.take(2); v != nil {
		return binary.LittleEndian.Uint16(v)
	}
	return 0
}

func (p *parser) u32() uint32 {
	if v := p.take(4); v != nil {
		return binary.LittleEndian.Uint32(v)
	}
	return 0
}

func (p *parser) sized() []byte {
	first := p.u8()
	n := int(first)
	if first&0x80 != 0 {
		second := p.u8()
		if second == 0 || second&0x80 != 0 {
			p.fail("non-canonical length")
			return nil
		}
		n = int(first&0x7f) | int(second)<<7
	}
	if p.err == nil && n == 0 {
		p.fail("empty item")
		return nil
	}
	return p.take(n)
}

func parseBody(b []byte, from Role) (body, error) {
	p := parser{b: b}
	unrelCh, relCh := from.channels()
	var out body
	if len(p.b) > 0 && codec.Channel(p.b[0]) == unrelCh {
		p.take(1)
		u := &Unreliable{Stamp: p.u32()}
		n := int(p.u16())
		if p.err == nil && n == 0 {
			p.fail("empty unreliable section")
		}
		for i := 0; i < n && p.err == nil; i++ {
			u.Items = append(u.Items, p.sized())
		}
		out.unreliable = u
	}
	if p.err == nil && len(p.b) > 0 && codec.Channel(p.b[0]) == relCh {
		p.take(1)
		n := int(p.u16())
		if p.err == nil && n == 0 {
			p.fail("empty reliable section")
		}
		for i := 0; i < n && p.err == nil; i++ {
			e := entry{id: p.u16(), index: p.u8(), count: p.u8()}
			e.data = p.sized()
			if p.err != nil {
				break
			}
			switch {
			case e.count == 0 || e.count > MaxFragments:
				p.fail("fragment count out of range")
			case e.index >= e.count:
				p.fail("fragment index past count")
			case len(e.data) > FragmentSize:
				p.fail("fragment over FragmentSize")
			case e.index < e.count-1 && len(e.data) != FragmentSize:
				p.fail("non-final fragment not FragmentSize")
			}
			out.entries = append(out.entries, e)
		}
	}
	if p.err == nil && len(p.b) > 0 {
		p.fail("unexpected section or trailing bytes")
	}
	if p.err != nil {
		return body{}, p.err
	}
	return out, nil
}

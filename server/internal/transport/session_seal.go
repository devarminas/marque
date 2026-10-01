package transport

import (
	"crypto/cipher"
	"encoding/binary"
	"errors"

	"golang.org/x/crypto/chacha20poly1305"
)

const (
	SessionOverhead = 8 + TagSize
	ReplayWindow    = 64
)

var (
	errReplayed = errors.New("transport: seal nonce already accepted or outside the replay window")
	errOpen     = errors.New("transport: seal failed to open")
)

type SessionSeal struct {
	send      cipher.AEAD
	sendNonce uint64

	recv   cipher.AEAD
	replay replayWindow
}

type replayWindow struct {
	have   bool
	newest uint64
	bits   uint64
}

func NewSessionSeal(role Role, keys SessionKeys) *SessionSeal {
	send, recv := keys.ServerToClient, keys.ClientToServer
	if role == Client {
		send, recv = recv, send
	}
	return &SessionSeal{send: ietfAEAD(send), recv: ietfAEAD(recv)}
}

func (*SessionSeal) Overhead() int { return SessionOverhead }

func (s *SessionSeal) Seal(dst, header, body []byte) []byte {
	n := s.sendNonce
	s.sendNonce++
	dst = binary.LittleEndian.AppendUint64(dst, n)
	return s.send.Seal(dst, sessionNonce(n), body, header)
}

func (s *SessionSeal) Open(dst, header, sealed []byte) ([]byte, error) {
	if len(sealed) < SessionOverhead {
		return nil, errOpen
	}
	n := binary.LittleEndian.Uint64(sealed)
	if !s.replay.fresh(n) {
		return nil, errReplayed
	}
	out, err := s.recv.Open(dst, sessionNonce(n), sealed[8:], header)
	if err != nil {
		return nil, errOpen
	}
	s.replay.accept(n)
	return out, nil
}

func (w replayWindow) fresh(n uint64) bool {
	if !w.have || n > w.newest {
		return true
	}
	behind := w.newest - n
	return behind < ReplayWindow && w.bits&(1<<behind) == 0
}

func (w *replayWindow) accept(n uint64) {
	switch {
	case !w.have:
		w.have, w.newest, w.bits = true, n, 1
	case n > w.newest:
		ahead := n - w.newest
		if ahead < ReplayWindow {
			w.bits = w.bits<<ahead | 1
		} else {
			w.bits = 1
		}
		w.newest = n
	default:
		w.bits |= 1 << (w.newest - n)
	}
}

func sessionNonce(n uint64) []byte {
	var b [chacha20poly1305.NonceSize]byte
	binary.LittleEndian.PutUint64(b[4:], n)
	return b[:]
}

func ietfAEAD(k Key) cipher.AEAD {
	a, err := chacha20poly1305.New(k[:])
	if err != nil {
		panic(err)
	}
	return a
}

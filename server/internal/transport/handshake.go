package transport

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"maps"
	"net/netip"
)

const (
	HandshakeID       = 0x3148524d
	RequestSize       = 512
	ChallengeLifetime = 10
	ChallengePlain    = TokenNonceSize + 8 + 8 + 8 + 8 + AddressSize + 2*KeySize
	ChallengeSize     = 5 + TokenNonceSize + ChallengePlain + TagSize
	ResponseSize      = ChallengeSize + TagSize
	requestTokenEnd   = 5 + 8 + 8 + TokenNonceSize + PrivateSealedSize
)

const (
	kindRequest   byte = 1
	kindChallenge byte = 2
	kindResponse  byte = 3
)

var (
	ErrExpired    = errors.New("transport: connect token or challenge expired")
	ErrForged     = errors.New("transport: connect token, challenge or proof failed authentication")
	ErrWrongShard = errors.New("transport: connect token names another shard")
	ErrReplayed   = errors.New("transport: connect token already admitted")
	ErrAddress    = errors.New("transport: response from an address other than the challenged one")
)

type GateConfig struct {
	SchemaHash uint64
	Shard      netip.AddrPort
	Issuer     Key
}

type Gate struct {
	cfg       GateConfig
	shard     [AddressSize]byte
	challenge Key
	random    io.Reader
	admitted  map[TokenNonce]uint64
}

type Admission struct {
	Peer    netip.AddrPort
	Account uint64
	Session uint64
	Expires uint64
	Keys    SessionKeys
}

type Outcome struct {
	Challenge []byte
	Admission *Admission
}

func NewGate(cfg GateConfig) (*Gate, error) {
	g := &Gate{cfg: cfg, random: rand.Reader, admitted: map[TokenNonce]uint64{}}
	appendAddress(g.shard[:0], cfg.Shard)
	if _, err := io.ReadFull(g.random, g.challenge[:]); err != nil {
		return nil, err
	}
	return g, nil
}

func (g *Gate) Admissions() int { return len(g.admitted) }

func (g *Gate) Handle(from netip.AddrPort, d []byte, now uint64) (Outcome, error) {
	if len(d) < 5 || binary.LittleEndian.Uint32(d) != HandshakeID {
		return Outcome{}, ErrMalformed
	}
	switch d[4] {
	case kindRequest:
		c, err := g.request(from, d, now)
		return Outcome{Challenge: c}, err
	case kindResponse:
		a, err := g.response(from, d, now)
		return Outcome{Admission: a}, err
	}
	return Outcome{}, ErrMalformed
}

func (g *Gate) request(from netip.AddrPort, d []byte, now uint64) ([]byte, error) {
	if len(d) != RequestSize || !allZero(d[requestTokenEnd:]) {
		return nil, ErrMalformed
	}
	if binary.LittleEndian.Uint64(d[5:]) != g.cfg.SchemaHash {
		return nil, ErrForeign
	}
	expires := binary.LittleEndian.Uint64(d[13:])
	if now >= expires {
		return nil, ErrExpired
	}
	nonce := TokenNonce(d[21:45])
	plain, err := xaead(g.cfg.Issuer).Open(nil, nonce[:], d[45:requestTokenEnd], tokenAD(expires))
	if err != nil {
		return nil, ErrForged
	}
	if !bytes.Equal(plain[16:16+AddressSize], g.shard[:]) {
		return nil, ErrWrongShard
	}
	if _, used := g.admitted[nonce]; used {
		return nil, ErrReplayed
	}

	var cn TokenNonce
	if _, err := io.ReadFull(g.random, cn[:]); err != nil {
		return nil, err
	}
	box := make([]byte, 0, ChallengePlain)
	box = append(box, nonce[:]...)
	box = append(box, plain[:16]...)
	box = binary.LittleEndian.AppendUint64(box, expires)
	box = binary.LittleEndian.AppendUint64(box, now+ChallengeLifetime)
	box = appendAddress(box, from)
	box = append(box, plain[16+AddressSize:]...)

	c := make([]byte, 0, ChallengeSize)
	c = binary.LittleEndian.AppendUint32(c, HandshakeID)
	c = append(c, kindChallenge)
	c = append(c, cn[:]...)
	return xaead(g.challenge).Seal(c, cn[:], box, c[:4]), nil
}

func (g *Gate) response(from netip.AddrPort, d []byte, now uint64) (*Admission, error) {
	if len(d) != ResponseSize {
		return nil, ErrMalformed
	}
	cn := d[5 : 5+TokenNonceSize]
	box, err := xaead(g.challenge).Open(nil, cn, d[5+TokenNonceSize:ChallengeSize], d[:4])
	if err != nil {
		return nil, ErrForged
	}
	nonce := TokenNonce(box)
	r := box[TokenNonceSize:]
	account, session := binary.LittleEndian.Uint64(r), binary.LittleEndian.Uint64(r[8:])
	expires, deadline := binary.LittleEndian.Uint64(r[16:]), binary.LittleEndian.Uint64(r[24:])
	if now >= expires || now >= deadline {
		return nil, ErrExpired
	}
	if !bytes.Equal(r[32:32+AddressSize], appendAddress(nil, from)) {
		return nil, ErrAddress
	}
	var keys SessionKeys
	copy(keys.ClientToServer[:], r[32+AddressSize:])
	copy(keys.ServerToClient[:], r[32+AddressSize+KeySize:])
	if _, err := xaead(keys.ClientToServer).Open(nil, cn, d[ChallengeSize:], d[:ChallengeSize]); err != nil {
		return nil, ErrForged
	}
	if _, used := g.admitted[nonce]; used {
		return nil, ErrReplayed
	}
	maps.DeleteFunc(g.admitted, func(_ TokenNonce, exp uint64) bool { return now >= exp })
	g.admitted[nonce] = expires
	return &Admission{Peer: from, Account: account, Session: session, Expires: expires, Keys: keys}, nil
}

func (t ConnectToken) Request(schemaHash uint64) []byte {
	d := make([]byte, 0, RequestSize)
	d = binary.LittleEndian.AppendUint32(d, HandshakeID)
	d = append(d, kindRequest)
	d = binary.LittleEndian.AppendUint64(d, schemaHash)
	d = binary.LittleEndian.AppendUint64(d, t.Expires)
	d = append(d, t.Nonce[:]...)
	d = append(d, t.Private[:]...)
	return append(d, make([]byte, RequestSize-len(d))...)
}

func (t ConnectToken) Respond(challenge []byte) ([]byte, error) {
	if len(challenge) != ChallengeSize || binary.LittleEndian.Uint32(challenge) != HandshakeID || challenge[4] != kindChallenge {
		return nil, ErrMalformed
	}
	r := make([]byte, 0, ResponseSize)
	r = append(r, challenge...)
	r[4] = kindResponse
	return xaead(t.Keys.ClientToServer).Seal(r, challenge[5:5+TokenNonceSize], nil, r), nil
}

func allZero(b []byte) bool {
	for _, x := range b {
		if x != 0 {
			return false
		}
	}
	return true
}

package transport

import (
	"crypto/cipher"
	"encoding/binary"
	"errors"
	"net/netip"

	"golang.org/x/crypto/chacha20poly1305"
)

const (
	KeySize           = chacha20poly1305.KeySize
	TokenNonceSize    = chacha20poly1305.NonceSizeX
	TagSize           = chacha20poly1305.Overhead
	AddressSize       = 18
	TokenVersion      = 0x3154524d
	PrivateSize       = 8 + 8 + AddressSize + 2*KeySize
	PrivateSealedSize = PrivateSize + TagSize
	TokenSize         = 4 + 8 + TokenNonceSize + AddressSize + 2*KeySize + PrivateSealedSize
	tokenADSize       = 4 + 8
)

type Key [KeySize]byte

type TokenNonce [TokenNonceSize]byte

type SessionKeys struct {
	ClientToServer Key
	ServerToClient Key
}

type Grant struct {
	Account uint64
	Session uint64
	Shard   netip.AddrPort
	Expires uint64
	Keys    SessionKeys
}

type ConnectToken struct {
	Expires uint64
	Nonce   TokenNonce
	Shard   netip.AddrPort
	Keys    SessionKeys
	Private [PrivateSealedSize]byte
}

var ErrToken = errors.New("transport: connect token malformed")

func IssueToken(issuer Key, nonce TokenNonce, g Grant) ConnectToken {
	t := ConnectToken{Expires: g.Expires, Nonce: nonce, Shard: g.Shard, Keys: g.Keys}
	plain := make([]byte, 0, PrivateSize)
	plain = binary.LittleEndian.AppendUint64(plain, g.Account)
	plain = binary.LittleEndian.AppendUint64(plain, g.Session)
	plain = appendAddress(plain, g.Shard)
	plain = append(plain, g.Keys.ClientToServer[:]...)
	plain = append(plain, g.Keys.ServerToClient[:]...)
	xaead(issuer).Seal(t.Private[:0], nonce[:], plain, tokenAD(g.Expires))
	return t
}

func ParseConnectToken(b []byte) (ConnectToken, error) {
	var t ConnectToken
	if len(b) != TokenSize || binary.LittleEndian.Uint32(b) != TokenVersion {
		return t, ErrToken
	}
	t.Expires = binary.LittleEndian.Uint64(b[4:])
	b = b[12:]
	b = b[copy(t.Nonce[:], b):]
	t.Shard = readAddress(b)
	b = b[AddressSize:]
	b = b[copy(t.Keys.ClientToServer[:], b):]
	b = b[copy(t.Keys.ServerToClient[:], b):]
	copy(t.Private[:], b)
	return t, nil
}

func (t ConnectToken) Bytes() []byte {
	b := make([]byte, 0, TokenSize)
	b = binary.LittleEndian.AppendUint32(b, TokenVersion)
	b = binary.LittleEndian.AppendUint64(b, t.Expires)
	b = append(b, t.Nonce[:]...)
	b = appendAddress(b, t.Shard)
	b = append(b, t.Keys.ClientToServer[:]...)
	b = append(b, t.Keys.ServerToClient[:]...)
	return append(b, t.Private[:]...)
}

func tokenAD(expires uint64) []byte {
	ad := make([]byte, 0, tokenADSize)
	ad = binary.LittleEndian.AppendUint32(ad, TokenVersion)
	return binary.LittleEndian.AppendUint64(ad, expires)
}

func appendAddress(b []byte, a netip.AddrPort) []byte {
	ip := a.Addr().As16()
	b = append(b, ip[:]...)
	return binary.LittleEndian.AppendUint16(b, a.Port())
}

func readAddress(b []byte) netip.AddrPort {
	return netip.AddrPortFrom(netip.AddrFrom16([16]byte(b[:16])).Unmap(), binary.LittleEndian.Uint16(b[16:]))
}

func xaead(k Key) cipher.AEAD {
	a, err := chacha20poly1305.NewX(k[:])
	if err != nil {
		panic(err)
	}
	return a
}

//go:build devtoken

package devtoken

import (
	"crypto/rand"
	"net/netip"

	"github.com/devarminas/marque/server/internal/transport"
)

var Key = transport.Key([]byte("marque-dev-issuer-key-not-secret"))

func Issue(account, session uint64, shard netip.AddrPort, expires uint64) transport.ConnectToken {
	var nonce transport.TokenNonce
	g := transport.Grant{Account: account, Session: session, Shard: shard, Expires: expires}
	rand.Read(nonce[:])
	rand.Read(g.Keys.ClientToServer[:])
	rand.Read(g.Keys.ServerToClient[:])
	return transport.IssueToken(Key, nonce, g)
}

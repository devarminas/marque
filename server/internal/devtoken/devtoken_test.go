//go:build devtoken

package devtoken

import (
	"net/netip"
	"testing"

	"github.com/devarminas/marque/server/internal/transport"
)

func TestDevTokenIsAdmittedByAShardHoldingTheDevKey(t *testing.T) {
	shard := netip.MustParseAddrPort("127.0.0.1:7777")
	client := netip.MustParseAddrPort("127.0.0.1:40000")
	const now = 1_800_000_000
	g, err := transport.NewGate(transport.GateConfig{SchemaHash: 1, Shard: shard, Issuer: Key})
	if err != nil {
		t.Fatal(err)
	}
	tok := Issue(7, 8, shard, now+30)
	o, err := g.Handle(client, tok.Request(1), now)
	if err != nil {
		t.Fatal(err)
	}
	r, err := tok.Respond(o.Challenge)
	if err != nil {
		t.Fatal(err)
	}
	o, err = g.Handle(client, r, now)
	if err != nil {
		t.Fatal(err)
	}
	want := transport.Admission{Peer: client, Account: 7, Session: 8, Expires: now + 30, Keys: tok.Keys}
	if *o.Admission != want {
		t.Fatalf("admitted %+v, want %+v", *o.Admission, want)
	}
	if tok.Keys.ClientToServer == tok.Keys.ServerToClient || Issue(7, 8, shard, now+30).Nonce == tok.Nonce {
		t.Fatal("two issues share a nonce, or one token's keys are equal")
	}
}

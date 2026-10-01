package transport

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"net/netip"
	"sync"
	"testing"
)

const testNow uint64 = 1_800_000_000

var (
	testShard  = netip.MustParseAddrPort("198.51.100.10:7777")
	testClient = netip.MustParseAddrPort("203.0.113.7:40000")
)

func seq(n int, start byte) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = start + byte(i)
	}
	return b
}

func testIssuer() Key { return Key(seq(KeySize, 0x40)) }

func vectorSessionKeys() SessionKeys {
	return SessionKeys{ClientToServer: Key(seq(KeySize, 0x00)), ServerToClient: Key(seq(KeySize, 0x20))}
}

func testGrant(account uint64) Grant {
	return Grant{Account: account, Session: account + 1000, Shard: testShard, Expires: testNow + 30, Keys: vectorSessionKeys()}
}

func tokenFor(account uint64) ConnectToken {
	var n TokenNonce
	binary.LittleEndian.PutUint64(n[:], account)
	return IssueToken(testIssuer(), n, testGrant(account))
}

func testGate(t testing.TB) *Gate {
	t.Helper()
	g, err := NewGate(GateConfig{SchemaHash: testHash, Shard: testShard, Issuer: testIssuer()})
	if err != nil {
		t.Fatal(err)
	}
	return g
}

func challengeFor(t *testing.T, g *Gate, tok ConnectToken, from netip.AddrPort) []byte {
	t.Helper()
	o, err := g.Handle(from, tok.Request(testHash), testNow)
	if err != nil || o.Challenge == nil {
		t.Fatalf("request refused: %v", err)
	}
	return o.Challenge
}

func TestTokenRoundTripsThroughBytes(t *testing.T) {
	tok := tokenFor(7)
	b := tok.Bytes()
	if len(b) != 232 {
		t.Fatalf("token is %d bytes, want 232", len(b))
	}
	back, err := ParseConnectToken(b)
	if err != nil || back != tok {
		t.Fatalf("parse gave %+v, %v; want %+v", back, err, tok)
	}
	b[0] ^= 1
	if _, err := ParseConnectToken(b); !errors.Is(err, ErrToken) {
		t.Fatalf("wrong version parsed: %v", err)
	}
	if _, err := ParseConnectToken(b[:231]); !errors.Is(err, ErrToken) {
		t.Fatalf("short token parsed: %v", err)
	}
}

func TestGateAdmitsTheChallengedTokenHolder(t *testing.T) {
	g := testGate(t)
	tok := tokenFor(7)
	c := challengeFor(t, g, tok, testClient)
	if len(c) != 183 {
		t.Fatalf("challenge is %d bytes, want 183", len(c))
	}
	if g.Admissions() != 0 {
		t.Fatalf("gate holds %d admissions after a request, want 0", g.Admissions())
	}
	r, err := tok.Respond(c)
	if err != nil || len(r) != 199 {
		t.Fatalf("Respond gave %d bytes, %v; want 199 bytes", len(r), err)
	}
	o, err := g.Handle(testClient, r, testNow+1)
	if err != nil {
		t.Fatal(err)
	}
	want := Admission{Peer: testClient, Account: 7, Session: 1007, Expires: testNow + 30, Keys: vectorSessionKeys()}
	if o.Challenge != nil || o.Admission == nil || *o.Admission != want {
		t.Fatalf("got %+v, want admission %+v", o, want)
	}
	if g.Admissions() != 1 {
		t.Fatalf("gate holds %d admissions, want 1", g.Admissions())
	}
}

func TestGateHoldsNothingForUnansweredRequests(t *testing.T) {
	g := testGate(t)
	for i := range 10_000 {
		from := netip.AddrPortFrom(netip.AddrFrom4([4]byte{10, 0, byte(i >> 8), byte(i)}), 5000)
		o, err := g.Handle(from, tokenFor(uint64(i)).Request(testHash), testNow)
		if err != nil || len(o.Challenge) != ChallengeSize {
			t.Fatalf("request %d: %d-byte challenge, %v", i, len(o.Challenge), err)
		}
	}
	if g.Admissions() != 0 {
		t.Fatalf("gate holds %d admissions after 10000 requests, want 0", g.Admissions())
	}
}

func TestGateRefusesBadTokensWithoutState(t *testing.T) {
	other := Grant{Account: 9, Session: 9, Shard: netip.MustParseAddrPort("198.51.100.11:7777"), Expires: testNow + 30, Keys: vectorSessionKeys()}
	expired := testGrant(8)
	expired.Expires = testNow
	forged := tokenFor(7).Request(testHash)
	forged[100] ^= 1
	stretched := tokenFor(7).Request(testHash)
	binary.LittleEndian.PutUint64(stretched[13:], testNow+3600)
	padded := tokenFor(7).Request(testHash)
	padded[RequestSize-1] = 1

	var got []string
	for _, tc := range []struct {
		name string
		d    []byte
	}{
		{"expired", IssueToken(testIssuer(), TokenNonce{8}, expired).Request(testHash)},
		{"forged", forged},
		{"stretched", stretched},
		{"wrong_shard", IssueToken(testIssuer(), TokenNonce{9}, other).Request(testHash)},
		{"wrong_issuer", IssueToken(Key{1}, TokenNonce{7}, testGrant(7)).Request(testHash)},
		{"foreign", tokenFor(7).Request(testHash + 1)},
		{"padded", padded},
		{"short", tokenFor(7).Request(testHash)[:RequestSize-1]},
		{"empty", nil},
	} {
		g := testGate(t)
		o, err := g.Handle(testClient, tc.d, testNow)
		got = append(got, fmt.Sprintf("%s: %v reply=%d admissions=%d", tc.name, errName(err), len(o.Challenge), g.Admissions()))
	}
	want := []string{
		"expired: expired reply=0 admissions=0",
		"forged: forged reply=0 admissions=0",
		"stretched: forged reply=0 admissions=0",
		"wrong_shard: wrong_shard reply=0 admissions=0",
		"wrong_issuer: forged reply=0 admissions=0",
		"foreign: foreign reply=0 admissions=0",
		"padded: malformed reply=0 admissions=0",
		"short: malformed reply=0 admissions=0",
		"empty: malformed reply=0 admissions=0",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got\n%v\nwant\n%v", got, want)
	}
}

func TestGateRefusesReplayedTokensWithoutState(t *testing.T) {
	g := testGate(t)
	tok := tokenFor(7)
	r := must(tok.Respond(challengeFor(t, g, tok, testClient)))
	second := must(tok.Respond(challengeFor(t, g, tok, netip.MustParseAddrPort("203.0.113.8:40000"))))
	if _, err := g.Handle(testClient, r, testNow); err != nil {
		t.Fatal(err)
	}

	var got []string
	for _, tc := range []struct {
		name string
		from netip.AddrPort
		d    []byte
	}{
		{"request", netip.MustParseAddrPort("203.0.113.9:40000"), tok.Request(testHash)},
		{"same_response", testClient, r},
		{"earlier_challenge", netip.MustParseAddrPort("203.0.113.8:40000"), second},
	} {
		o, err := g.Handle(tc.from, tc.d, testNow+1)
		got = append(got, fmt.Sprintf("%s: %v reply=%d admitted=%t admissions=%d", tc.name, errName(err), len(o.Challenge), o.Admission != nil, g.Admissions()))
	}
	want := []string{
		"request: replayed reply=0 admitted=false admissions=1",
		"same_response: replayed reply=0 admitted=false admissions=1",
		"earlier_challenge: replayed reply=0 admitted=false admissions=1",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got\n%v\nwant\n%v", got, want)
	}
}

func TestGateRefusesBadResponsesWithoutState(t *testing.T) {
	tok := tokenFor(7)
	var got []string
	for _, tc := range []struct {
		name string
		from netip.AddrPort
		now  uint64
		edit func(c, r []byte) []byte
	}{
		{"other_address", netip.MustParseAddrPort("203.0.113.8:40000"), testNow, func(_, r []byte) []byte { return r }},
		{"challenge_expired", testClient, testNow + ChallengeLifetime, func(_, r []byte) []byte { return r }},
		{"token_expired", testClient, testNow + 30, func(_, r []byte) []byte { return r }},
		{"challenge_tampered", testClient, testNow, func(_, r []byte) []byte { r[60] ^= 1; return r }},
		{"proof_tampered", testClient, testNow, func(_, r []byte) []byte { r[ResponseSize-1] ^= 1; return r }},
		{"wrong_key", testClient, testNow, func(c, _ []byte) []byte {
			other := tok
			other.Keys.ClientToServer[0] ^= 1
			return must(other.Respond(c))
		}},
		{"short", testClient, testNow, func(_, r []byte) []byte { return r[:ResponseSize-1] }},
	} {
		g := testGate(t)
		c := challengeFor(t, g, tok, testClient)
		o, err := g.Handle(tc.from, tc.edit(c, must(tok.Respond(c))), tc.now)
		got = append(got, fmt.Sprintf("%s: %v admitted=%t admissions=%d", tc.name, errName(err), o.Admission != nil, g.Admissions()))
	}
	want := []string{
		"other_address: address admitted=false admissions=0",
		"challenge_expired: expired admitted=false admissions=0",
		"token_expired: expired admitted=false admissions=0",
		"challenge_tampered: forged admitted=false admissions=0",
		"proof_tampered: forged admitted=false admissions=0",
		"wrong_key: forged admitted=false admissions=0",
		"short: malformed admitted=false admissions=0",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got\n%v\nwant\n%v", got, want)
	}
}

func TestGateForgetsAdmissionsOnceTheirTokensExpire(t *testing.T) {
	g := testGate(t)
	for _, account := range []uint64{1, 2} {
		tok := tokenFor(account)
		if _, err := g.Handle(testClient, must(tok.Respond(challengeFor(t, g, tok, testClient))), testNow); err != nil {
			t.Fatal(err)
		}
	}
	late := testGrant(3)
	late.Expires = testNow + 100
	tok := IssueToken(testIssuer(), TokenNonce{3}, late)
	o, err := g.Handle(testClient, tok.Request(testHash), testNow+30)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := g.Handle(testClient, must(tok.Respond(o.Challenge)), testNow+30); err != nil {
		t.Fatal(err)
	}
	if g.Admissions() != 1 {
		t.Fatalf("gate holds %d admissions, want 1 (tokens 1 and 2 expired at %d)", g.Admissions(), testNow+30)
	}
}

func TestRespondRefusesAMalformedChallenge(t *testing.T) {
	g := testGate(t)
	tok := tokenFor(7)
	c := challengeFor(t, g, tok, testClient)
	var got []string
	for _, d := range [][]byte{c[:ChallengeSize-1], append(bytes.Clone(c), 0), func() []byte { b := bytes.Clone(c); b[4] = 3; return b }(), func() []byte { b := bytes.Clone(c); b[0] ^= 1; return b }()} {
		_, err := tok.Respond(d)
		got = append(got, errName(err))
	}
	if fmt.Sprint(got) != "[malformed malformed malformed malformed]" {
		t.Fatalf("got %v", got)
	}
}

func TestSessionSealRefusesReplaysAndOldNonces(t *testing.T) {
	cli, srv := NewSessionSeal(Client, vectorSessionKeys()), NewSessionSeal(Server, vectorSessionKeys())
	hdr := seq(HeaderSize, 0x80)
	var sealed [][]byte
	for i := range 70 {
		sealed = append(sealed, cli.Seal(nil, hdr, []byte{byte(i)}))
	}
	open := func(i int) string {
		b, err := srv.Open(nil, hdr, sealed[i])
		if err != nil {
			return fmt.Sprintf("%d:refused", i)
		}
		return fmt.Sprintf("%d:%x", i, b)
	}
	var got []string
	for _, i := range []int{0, 0, 2, 1, 2, 69, 6, 5, 4, 69, 68} {
		got = append(got, open(i))
	}
	want := "[0:00 0:refused 2:02 1:01 2:refused 69:45 6:06 5:refused 4:refused 69:refused 68:44]"
	if fmt.Sprint(got) != want {
		t.Fatalf("got  %v\nwant %s", got, want)
	}
}

func TestSessionSealIsDirectional(t *testing.T) {
	cli := NewSessionSeal(Client, vectorSessionKeys())
	hdr := seq(HeaderSize, 0x80)
	d := cli.Seal(nil, hdr, []byte{1, 2, 3})
	if len(d) != 3+SessionOverhead {
		t.Fatalf("sealed body is %d bytes, want %d", len(d), 3+SessionOverhead)
	}
	if _, err := NewSessionSeal(Client, vectorSessionKeys()).Open(nil, hdr, d); err == nil {
		t.Fatal("a client opened its own direction")
	}
	if b, err := NewSessionSeal(Server, vectorSessionKeys()).Open(nil, hdr, d); err != nil || !bytes.Equal(b, []byte{1, 2, 3}) {
		t.Fatalf("server opened %x, %v", b, err)
	}
}

func TestTamperedSealedDatagramIsRefused(t *testing.T) {
	cfg := testConfig()
	cli := mustSealedEndpoint(Client, cfg, NewSessionSeal(Client, vectorSessionKeys()))
	if err := cli.Send([]byte{0x05, 0x01}); err != nil {
		t.Fatal(err)
	}
	good := must(cli.Flush(tick, Unreliable{Stamp: 1, Items: [][]byte{{0x01}}})).Datagrams[0]
	got := map[string]int{}
	for i := range good {
		srv := mustSealedEndpoint(Server, cfg, NewSessionSeal(Server, vectorSessionKeys()))
		bad := bytes.Clone(good)
		bad[i] ^= 0x01
		_, err := srv.Receive(bad, tick)
		st := srv.Stats()
		got[fmt.Sprintf("%v malformed=%d foreign=%d accepted=%d", errName(err), st.Malformed, st.Foreign, st.Accepted)]++
	}
	want := map[string]int{
		"foreign malformed=0 foreign=1 accepted=0":   12,
		"malformed malformed=1 foreign=0 accepted=0": len(good) - 12,
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("over %d tampered bytes got %v, want %v", len(good), got, want)
	}
	srv := mustSealedEndpoint(Server, cfg, NewSessionSeal(Server, vectorSessionKeys()))
	r, err := srv.Receive(good, tick)
	if err != nil || fmt.Sprintf("%x", r.Reliable) != "[0501]" {
		t.Fatalf("untouched datagram gave %+v, %v", r, err)
	}
	if _, err := srv.Receive(good, tick); !errors.Is(err, ErrMalformed) {
		t.Fatalf("replayed datagram gave %v, want malformed (the seal refuses it before the window)", err)
	}
}

func TestSessionSealSealsAndOpensConcurrently(t *testing.T) {
	cli, srv := NewSessionSeal(Client, vectorSessionKeys()), NewSessionSeal(Server, vectorSessionKeys())
	hdr := seq(HeaderSize, 0x80)
	const n = 2000
	in := make(chan []byte, n)
	for i := range n {
		in <- cli.Seal(nil, hdr, []byte{byte(i)})
	}
	close(in)
	var wg sync.WaitGroup
	opened := 0
	wg.Go(func() {
		for d := range in {
			if _, err := srv.Open(nil, hdr, d); err == nil {
				opened++
			}
		}
	})
	wg.Go(func() {
		for range n {
			srv.Seal(nil, hdr, []byte{1})
		}
	})
	wg.Wait()
	if opened != n || srv.sendNonce != n {
		t.Fatalf("opened %d and sealed %d, want %d each", opened, srv.sendNonce, n)
	}
}

func mustSealedEndpoint(role Role, cfg Config, seal Seal) *Endpoint {
	e, err := NewEndpoint(role, cfg, seal, 0)
	if err != nil {
		panic(err)
	}
	return e
}

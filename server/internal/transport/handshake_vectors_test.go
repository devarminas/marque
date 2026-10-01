package transport

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"testing"
)

const handshakeVectorDir = "../../../shared/wire/vectors/handshake"

type handshakeRun struct {
	gate   *Gate
	random bytes.Buffer
	seals  map[string]*SessionSeal
}

func runHandshakeOp(st *handshakeRun, line string) ([]string, error) {
	f := strings.Fields(line)
	num := func(i int) uint64 {
		v, err := strconv.ParseUint(f[i], 10, 64)
		if err != nil {
			panic(fmt.Sprintf("%q: %v", line, err))
		}
		return v
	}
	unhex := func(i int) []byte {
		b, err := hex.DecodeString(f[i])
		if err != nil {
			panic(fmt.Sprintf("%q: %v", line, err))
		}
		return b
	}
	addr := func(i int) netip.AddrPort { return readAddress(unhex(i)) }
	key := func(i int) Key { return Key(unhex(i)) }
	token := func(i int) ConnectToken {
		t, err := ParseConnectToken(unhex(i))
		if err != nil {
			panic(fmt.Sprintf("%q: %v", line, err))
		}
		return t
	}
	hash := func(i int) uint64 {
		v, err := strconv.ParseUint(f[i], 16, 64)
		if err != nil {
			panic(fmt.Sprintf("%q: %v", line, err))
		}
		return v
	}
	var out []string
	switch f[0] {
	case "token":
		t := IssueToken(key(1), TokenNonce(unhex(2)), Grant{Account: num(3), Session: num(4), Shard: addr(5), Expires: num(6), Keys: SessionKeys{key(7), key(8)}})
		out = append(out, "token "+hex.EncodeToString(t.Bytes()))
	case "gate":
		g, err := NewGate(GateConfig{SchemaHash: hash(1), Shard: addr(2), Issuer: key(3)})
		if err != nil {
			return nil, err
		}
		g.challenge, g.random = key(4), &st.random
		st.gate = g
	case "random":
		st.random.Write(unhex(1))
	case "request":
		out = append(out, "request "+hex.EncodeToString(token(2).Request(hash(1))))
	case "respond":
		r, err := token(1).Respond(unhex(2))
		if err != nil {
			out = append(out, "error "+errName(err))
			break
		}
		out = append(out, "response "+hex.EncodeToString(r))
	case "handle":
		o, err := st.gate.Handle(addr(2), unhex(3), num(1))
		switch {
		case err != nil:
			out = append(out, "error "+errName(err))
		case o.Challenge != nil:
			out = append(out, "challenge "+hex.EncodeToString(o.Challenge))
		default:
			a := o.Admission
			out = append(out, fmt.Sprintf("admitted %x %d %d %d %x %x", appendAddress(nil, a.Peer), a.Account, a.Session, a.Expires, a.Keys.ClientToServer, a.Keys.ServerToClient))
		}
		out = append(out, fmt.Sprintf("admissions %d", st.gate.Admissions()))
	case "session":
		role := Server
		if f[1] == "client" {
			role = Client
		}
		st.seals[f[1]] = NewSessionSeal(role, SessionKeys{key(2), key(3)})
	case "seal_body":
		out = append(out, "sealed "+hex.EncodeToString(st.seals[f[1]].Seal(nil, unhex(2), unhex(3))))
	case "open_body":
		b, err := st.seals[f[1]].Open(nil, unhex(2), unhex(3))
		if err != nil {
			out = append(out, "error malformed")
			break
		}
		out = append(out, "opened "+hex.EncodeToString(b))
	default:
		return nil, fmt.Errorf("unknown op %q", f[0])
	}
	return out, nil
}

type handshakeScript struct {
	run   handshakeRun
	lines []string
}

func newHandshakeScript(desc string) *handshakeScript {
	s := &handshakeScript{run: handshakeRun{seals: map[string]*SessionSeal{}}}
	for _, l := range strings.Split(desc, "\n") {
		s.lines = append(s.lines, "# "+l)
	}
	return s
}

func (s *handshakeScript) exec(format string, args ...any) []string {
	line := fmt.Sprintf(format, args...)
	out, err := runHandshakeOp(&s.run, line)
	if err != nil {
		panic(err)
	}
	s.lines = append(s.lines, line)
	for _, o := range out {
		s.lines = append(s.lines, "> "+o)
	}
	return out
}

func (s *handshakeScript) value(format string, args ...any) []byte {
	out := s.exec(format, args...)
	_, h, _ := strings.Cut(out[0], " ")
	b, err := hex.DecodeString(h)
	if err != nil {
		panic(fmt.Sprintf("%s gave %q", format, out))
	}
	return b
}

func (s *handshakeScript) text() string { return strings.Join(s.lines, "\n") + "\n" }

func hx(b []byte) string { return hex.EncodeToString(b) }

func ax(a netip.AddrPort) string { return hx(appendAddress(nil, a)) }

type vectorWorld struct {
	issuer, challengeKey Key
	keys                 SessionKeys
}

func newVectorWorld() vectorWorld {
	return vectorWorld{issuer: testIssuer(), challengeKey: Key(seq(KeySize, 0x60)), keys: vectorSessionKeys()}
}

func (w vectorWorld) token(s *handshakeScript, nonce byte, account uint64, shard netip.AddrPort, expires uint64) []byte {
	return s.value("token %s %s %d %d %s %d %s %s", hx(w.issuer[:]), hx(seq(TokenNonceSize, nonce)), account, account+1000, ax(shard), expires, hx(w.keys.ClientToServer[:]), hx(w.keys.ServerToClient[:]))
}

func (w vectorWorld) gate(s *handshakeScript) {
	s.exec("gate %016x %s %s %s", testHash, ax(testShard), hx(w.issuer[:]), hx(w.challengeKey[:]))
}

func (w vectorWorld) challenge(s *handshakeScript, tok []byte, from netip.AddrPort, random byte) []byte {
	s.exec("random %s", hx(seq(TokenNonceSize, random)))
	req := s.value("request %016x %s", testHash, hx(tok))
	return s.value("handle %d %s %s", testNow, ax(from), hx(req))
}

func handshakeScenarios() map[string]string {
	out := map[string]string{}
	for name, f := range map[string]func() *handshakeScript{
		"accept":       acceptScenario,
		"refusals":     refusalsScenario,
		"responses":    responsesScenario,
		"replay":       replayScenario,
		"session_seal": sessionSealScenario,
	} {
		out[name] = f().text()
	}
	return out
}

func acceptScenario() *handshakeScript {
	w := newVectorWorld()
	s := newHandshakeScript("The issuer seals a token for account 7 on the shard. The client's 512-byte\nrequest earns a 183-byte challenge, its 199-byte response is admitted, and\nthe gate then holds one admission.")
	w.gate(s)
	tok := w.token(s, 0x10, 7, testShard, testNow+30)
	c := w.challenge(s, tok, testClient, 0x90)
	r := s.value("respond %s %s", hx(tok), hx(c))
	s.exec("handle %d %s %s", testNow+1, ax(testClient), hx(r))
	return s
}

func refusalsScenario() *handshakeScript {
	w := newVectorWorld()
	s := newHandshakeScript("Requests the gate refuses with no reply and no admission: an expired token,\na flipped byte in the sealed part, a stretched expiry, a token for another\nshard, one sealed with another issuer key, a foreign schema hash, nonzero\npadding, a short request, an unknown kind, and a transport datagram.")
	w.gate(s)
	expired := w.token(s, 0x11, 8, testShard, testNow)
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(s.value("request %016x %s", testHash, hx(expired))))

	tok := w.token(s, 0x10, 7, testShard, testNow+30)
	req := s.value("request %016x %s", testHash, hx(tok))
	forged := bytes.Clone(req)
	forged[100] ^= 1
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(forged))
	stretched := bytes.Clone(req)
	stretched[13] ^= 1
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(stretched))

	other := w.token(s, 0x12, 9, netip.MustParseAddrPort("198.51.100.11:7777"), testNow+30)
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(s.value("request %016x %s", testHash, hx(other))))

	w2 := w
	w2.issuer = Key{1}
	wrongIssuer := w2.token(s, 0x13, 7, testShard, testNow+30)
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(s.value("request %016x %s", testHash, hx(wrongIssuer))))

	s.exec("handle %d %s %s", testNow, ax(testClient), hx(s.value("request %016x %s", testHash+1, hx(tok))))
	padded := bytes.Clone(req)
	padded[RequestSize-1] = 1
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(padded))
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(req[:RequestSize-1]))
	kind := bytes.Clone(req)
	kind[4] = 2
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(kind))
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(raw(Client, 0, NoAcks, nil)))
	return s
}

func responsesScenario() *handshakeScript {
	w := newVectorWorld()
	s := newHandshakeScript("Responses the gate refuses with no admission: from another address, after\nthe challenge or the token expired, with a flipped byte in the challenge or\nthe proof, proved with the wrong key, and short. The client refuses a\nmalformed challenge. The untouched response is then admitted.")
	w.gate(s)
	tok := w.token(s, 0x10, 7, testShard, testNow+30)
	c := w.challenge(s, tok, testClient, 0x90)
	r := s.value("respond %s %s", hx(tok), hx(c))
	s.exec("handle %d %s %s", testNow, ax(netip.MustParseAddrPort("203.0.113.8:40000")), hx(r))
	s.exec("handle %d %s %s", testNow+ChallengeLifetime, ax(testClient), hx(r))
	s.exec("handle %d %s %s", testNow+30, ax(testClient), hx(r))
	bad := bytes.Clone(r)
	bad[60] ^= 1
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(bad))
	bad = bytes.Clone(r)
	bad[ResponseSize-1] ^= 1
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(bad))

	parsed := must(ParseConnectToken(tok))
	parsed.Keys.ClientToServer[0] ^= 1
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(s.value("respond %s %s", hx(parsed.Bytes()), hx(c))))
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(r[:ResponseSize-1]))
	s.exec("respond %s %s", hx(tok), hx(c[:ChallengeSize-1]))
	s.exec("handle %d %s %s", testNow+ChallengeLifetime-1, ax(testClient), hx(r))
	return s
}

func replayScenario() *handshakeScript {
	w := newVectorWorld()
	s := newHandshakeScript("A token admitted once is refused as replayed: its request from another\naddress, the same response again, and a response to a second challenge the\ntoken earned before it was admitted.")
	w.gate(s)
	tok := w.token(s, 0x10, 7, testShard, testNow+30)
	c1 := w.challenge(s, tok, testClient, 0x90)
	other := netip.MustParseAddrPort("203.0.113.8:40000")
	c2 := w.challenge(s, tok, other, 0xa0)
	r1 := s.value("respond %s %s", hx(tok), hx(c1))
	r2 := s.value("respond %s %s", hx(tok), hx(c2))
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(r1))
	s.exec("handle %d %s %s", testNow, ax(netip.MustParseAddrPort("203.0.113.9:40000")), hx(s.value("request %016x %s", testHash, hx(tok))))
	s.exec("handle %d %s %s", testNow, ax(testClient), hx(r1))
	s.exec("handle %d %s %s", testNow, ax(other), hx(r2))
	return s
}

func sessionSealScenario() *handshakeScript {
	w := newVectorWorld()
	s := newHandshakeScript("The session seal. Client nonces 1, 0, 66 and 3 open at the server out of\norder. A repeat of 1, and nonce 2 once 66 is newest (64 behind), are\nrefused. A flipped header byte, a flipped body byte and a short body fail to\nopen, and the untouched nonce 65 then opens. The server seals its own\ndirection with nonce 0, which the client opens; a client-sealed body does\nnot open at the client.")
	k := fmt.Sprintf("%s %s", hx(w.keys.ClientToServer[:]), hx(w.keys.ServerToClient[:]))
	s.exec("session client %s", k)
	s.exec("session server %s", k)
	hdr := seq(HeaderSize, 0x80)
	var sealed [][]byte
	for i := range 67 {
		sealed = append(sealed, s.value("seal_body client %s %s", hx(hdr), hx([]byte{byte(i), 0xee})))
	}
	for _, i := range []int{1, 0, 1, 66, 3, 2} {
		s.exec("open_body server %s %s", hx(hdr), hx(sealed[i]))
	}
	tampered := bytes.Clone(hdr)
	tampered[12] ^= 1
	s.exec("open_body server %s %s", hx(tampered), hx(sealed[65]))
	body := bytes.Clone(sealed[65])
	body[9] ^= 1
	s.exec("open_body server %s %s", hx(hdr), hx(body))
	s.exec("open_body server %s %s", hx(hdr), hx(sealed[65][:SessionOverhead-1]))
	s.exec("open_body server %s %s", hx(hdr), hx(sealed[65]))
	back := s.value("seal_body server %s %s", hx(hdr), hx([]byte{0x01}))
	s.exec("open_body client %s %s", hx(hdr), hx(back))
	s.exec("open_body client %s %s", hx(hdr), hx(sealed[4]))
	return s
}

func TestHandshakeVectors(t *testing.T) {
	checkVectors(t, handshakeVectorDir, handshakeScenarios(), func() opRunner {
		st := handshakeRun{seals: map[string]*SessionSeal{}}
		return func(line string) ([]string, error) { return runHandshakeOp(&st, line) }
	})
}

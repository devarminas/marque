package interop

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/netsim"
	"github.com/devarminas/marque/server/internal/transport"
)

const (
	schemaHash    uint64 = 0x355354
	epoch         uint64 = 1700000000
	maxFrame             = 262144
	maxPackets           = 256
	maxTranscript        = 4 << 20
)

type fingerprint struct {
	Size   uint32
	Digest [32]byte
}
type sample struct {
	Stamp uint32
	Items [][]byte
}
type workload struct {
	Events, Intents, State, Input [][]byte
	Ticks                         uint32
	Stale                         bool
}
type reply struct {
	Out                          []fingerprint
	Reliable                     [][]byte
	Unreliable                   []sample
	Outcomes                     []byte
	Connected, Created           bool
	State                        byte
	Backlog, Queued, Stamp, Sent uint32
}
type frame struct {
	bytes.Buffer
	err error
}

func (f *frame) put(v uint64, n int) {
	for i := 0; i < n; i++ {
		f.WriteByte(byte(v >> (8 * i)))
	}
}
func (f *frame) get(n int) uint64 {
	b := f.take(n)
	if b == nil {
		return 0
	}
	var v uint64
	for i := 0; i < n; i++ {
		v |= uint64(b[i]) << (8 * i)
	}
	return v
}
func (f *frame) take(n int) []byte {
	if f.err != nil {
		return nil
	}
	if n < 0 || n > f.Len() {
		f.err = fmt.Errorf("truncated control frame")
		return nil
	}
	return f.Next(n)
}
func (f *frame) blob(b []byte) { f.put(uint64(len(b)), 4); f.Write(b) }
func (f *frame) readBlob() []byte {
	n := f.get(4)
	if n > transport.MaxMessage {
		f.err = fmt.Errorf("control blob limit %d", n)
		return nil
	}
	return bytes.Clone(f.take(int(n)))
}
func (f *frame) list(b [][]byte) {
	f.put(uint64(len(b)), 4)
	for _, v := range b {
		f.blob(v)
	}
}
func (f *frame) readList() [][]byte {
	n := f.get(4)
	if n > maxPackets {
		f.err = fmt.Errorf("control list limit %d", n)
		return nil
	}
	var out [][]byte
	for i := uint64(0); i < n; i++ {
		out = append(out, f.readBlob())
	}
	return out
}
func (f *frame) fingerprints(values []fingerprint) {
	f.put(uint64(len(values)), 4)
	for _, v := range values {
		f.put(uint64(v.Size), 4)
		f.Write(v.Digest[:])
	}
}
func (f *frame) readFingerprints() []fingerprint {
	n := f.get(4)
	if n > maxPackets {
		f.err = fmt.Errorf("fingerprint count limit %d", n)
		return nil
	}
	var out []fingerprint
	for i := uint64(0); i < n; i++ {
		v := fingerprint{Size: uint32(f.get(4))}
		if v.Size == 0 || v.Size > transport.MaxDatagram {
			f.err = fmt.Errorf("fingerprint size limit")
			return nil
		}
		copy(v.Digest[:], f.take(32))
		out = append(out, v)
	}
	return out
}
func (f *frame) end(t *testing.T) {
	t.Helper()
	require(t, f.err == nil && f.Len() == 0, "control frame parse err=%v trailing=%d", f.err, f.Len())
}
func digest(b []byte) fingerprint { return fingerprint{uint32(len(b)), sha256.Sum256(b)} }
func fingerprints(packets [][]byte) []fingerprint {
	out := make([]fingerprint, len(packets))
	for i, p := range packets {
		out[i] = digest(p)
	}
	return out
}
func require(t *testing.T, ok bool, format string, args ...any) {
	t.Helper()
	if !ok {
		t.Fatalf(format, args...)
	}
}

type cappedStderr struct {
	sync.Mutex
	data  []byte
	total int
}

func (b *cappedStderr) Write(p []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	b.total += len(p)
	left := 16384 - len(b.data)
	if left > 0 {
		b.data = append(b.data, p[:min(left, len(p))]...)
	}
	return len(p), nil
}
func (b *cappedStderr) String() string {
	b.Lock()
	defer b.Unlock()
	return fmt.Sprintf("%s (stderr bytes=%d)", b.data, b.total)
}

type child struct {
	cmd     *exec.Cmd
	in, out *os.File
	stderr  cappedStderr
	waited  bool
	err     error
}

func startChild(t *testing.T, ctx context.Context, helper string) *child {
	t.Helper()
	c := &child{cmd: exec.CommandContext(ctx, helper)}
	c.cmd.Stderr = &c.stderr
	in, err := c.cmd.StdinPipe()
	require(t, err == nil, "child stdin %v", err)
	c.in = in.(*os.File)
	t.Cleanup(func() {
		c.in.Close()
		if c.out != nil {
			c.out.Close()
		}
		if c.cmd.Process != nil && !c.waited {
			c.cmd.Process.Kill()
			c.err = c.cmd.Wait()
			c.waited = true
		}
	})
	out, err := c.cmd.StdoutPipe()
	require(t, err == nil, "child stdout %v", err)
	c.out = out.(*os.File)
	err = c.cmd.Start()
	require(t, err == nil, "helper launch %v", err)
	return c
}
func (c *child) exchange(t *testing.T, request *frame) *frame {
	t.Helper()
	require(t, request.Len() > 0 && request.Len() <= maxFrame, "request frame size %d", request.Len())
	deadline := time.Now().Add(3 * time.Second)
	require(t, c.in.SetWriteDeadline(deadline) == nil, "stdin deadline unavailable")
	require(t, c.out.SetReadDeadline(deadline) == nil, "stdout deadline unavailable")
	header := binary.LittleEndian.AppendUint32(nil, uint32(request.Len()))
	_, err := io.Copy(c.in, bytes.NewReader(append(header, request.Bytes()...)))
	require(t, err == nil, "control write %v stderr=%s", err, c.stderr.String())
	_, err = io.ReadFull(c.out, header)
	require(t, err == nil, "control header %v stderr=%s", err, c.stderr.String())
	n := binary.LittleEndian.Uint32(header)
	require(t, n > 0 && n <= maxFrame, "reply frame size %d", n)
	b := make([]byte, n)
	_, err = io.ReadFull(c.out, b)
	require(t, err == nil, "control body %v stderr=%s", err, c.stderr.String())
	return &frame{Buffer: *bytes.NewBuffer(b)}
}
func (c *child) finish(t *testing.T) {
	t.Helper()
	request := &frame{}
	request.put(3, 1)
	out := c.exchange(t, request)
	require(t, out.get(1) == 3, "finish reply")
	out.end(t)
	c.in.Close()
	c.err = c.cmd.Wait()
	c.waited = true
	require(t, c.err == nil, "child exit %v stderr=%s", c.err, c.stderr.String())
	require(t, c.stderr.total == 0, "unexpected stderr %s", c.stderr.String())
}
func decodeReply(t *testing.T, f *frame) reply {
	t.Helper()
	r := reply{Out: f.readFingerprints(), Reliable: f.readList()}
	n := f.get(4)
	require(t, n <= maxPackets, "unreliable observations limit")
	for i := uint64(0); i < n; i++ {
		r.Unreliable = append(r.Unreliable, sample{uint32(f.get(4)), f.readList()})
	}
	n = f.get(4)
	require(t, n <= maxPackets, "outcomes limit")
	r.Outcomes = bytes.Clone(f.take(int(n)))
	r.Connected = f.get(1) != 0
	r.Created = f.get(1) != 0
	r.State = byte(f.get(1))
	r.Backlog = uint32(f.get(4))
	r.Queued = uint32(f.get(4))
	r.Stamp = uint32(f.get(4))
	r.Sent = uint32(f.get(4))
	f.end(t)
	return r
}
func socket(t *testing.T) *net.UDPConn {
	t.Helper()
	s, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require(t, err == nil, "bind UDP %v", err)
	t.Cleanup(func() { s.Close() })
	return s
}
func writeUDP(t *testing.T, s *net.UDPConn, to *net.UDPAddr, b []byte) {
	t.Helper()
	require(t, len(b) > 0 && len(b) <= transport.MaxDatagram, "UDP send bound")
	n, err := s.WriteToUDP(b, to)
	require(t, err == nil && n == len(b), "UDP send %v", err)
}
func readUDP(t *testing.T, s *net.UDPConn) ([]byte, *net.UDPAddr) {
	t.Helper()
	require(t, s.SetReadDeadline(time.Now().Add(3*time.Second)) == nil, "UDP read deadline")
	b := make([]byte, transport.MaxDatagram+1)
	n, from, err := s.ReadFromUDP(b)
	require(t, err == nil && n > 0 && n <= transport.MaxDatagram, "UDP receive n=%d err=%v", n, err)
	return b[:n], from
}
func order(t *testing.T, received [][]byte, expected []fingerprint) [][]byte {
	t.Helper()
	require(t, len(received) == len(expected) && len(expected) <= maxPackets, "correlation count received=%d expected=%d", len(received), len(expected))
	queues := map[fingerprint][][]byte{}
	for _, b := range received {
		f := digest(b)
		queues[f] = append(queues[f], b)
	}
	out := make([][]byte, len(expected))
	for i, f := range expected {
		q := queues[f]
		require(t, len(q) > 0, "unlisted or missing UDP occurrence index=%d length=%d", i, f.Size)
		out[i] = q[0]
		queues[f] = q[1:]
	}
	for _, q := range queues {
		require(t, len(q) == 0, "unlisted UDP occurrence")
	}
	return out
}
func residual(t *testing.T, s *net.UDPConn) {
	t.Helper()
	require(t, s.SetReadDeadline(time.Now()) == nil, "residual deadline")
	b := make([]byte, transport.MaxDatagram+1)
	_, _, err := s.ReadFromUDP(b)
	e, ok := err.(net.Error)
	require(t, ok && e.Timeout(), "unlisted residual UDP err=%v", err)
}
func metadata(t *testing.T, b []byte) string {
	t.Helper()
	require(t, len(b) >= 5, "short packet metadata")
	protocol := binary.LittleEndian.Uint32(b)
	if protocol == transport.HandshakeID {
		return fmt.Sprintf("handshake=%d len=%d", b[4], len(b))
	}
	require(t, protocol == transport.ProtocolID && len(b) >= transport.HeaderSize+transport.SessionOverhead, "foreign emitted packet")
	return fmt.Sprintf("len=%d seq=%d ack=%d bits=%08x nonce=%d", len(b), binary.LittleEndian.Uint16(b[12:]), binary.LittleEndian.Uint16(b[14:]), binary.LittleEndian.Uint32(b[16:]), binary.LittleEndian.Uint64(b[20:]))
}

type transcript struct {
	records []string
	size    int
}

func (tr *transcript) add(t *testing.T, format string, args ...any) {
	t.Helper()
	s := fmt.Sprintf(format, args...)
	tr.size += len(s)
	require(t, tr.size <= maxTranscript && len(tr.records) < 50000, "transcript limit")
	tr.records = append(tr.records, s)
}
func compareTranscript(t *testing.T, a, b transcript, profile string, seed uint64, fault string) {
	t.Helper()
	n := min(len(a.records), len(b.records))
	for i := 0; i < n; i++ {
		require(t, a.records[i] == b.records[i], "semantic replay mismatch record=%d\nfirst=%s\nrepeat=%s\nprofile=%s fault=%s\nrerun=NETSIM_SEED=%d scripts/transport_interop.sh", i, a.records[i], b.records[i], profile, fault, seed)
	}
	if len(a.records) != len(b.records) {
		first, repeat := "<end>", "<end>"
		if n < len(a.records) {
			first = a.records[n]
		}
		if n < len(b.records) {
			repeat = b.records[n]
		}
		t.Fatalf("semantic replay mismatch record=%d\nfirst=%s\nrepeat=%s\nprofile=%s fault=%s\nrerun=NETSIM_SEED=%d scripts/transport_interop.sh", n, first, repeat, profile, fault, seed)
	}
}

func run(t *testing.T, ctx context.Context, helper, profile string, seed uint64, fault string, w workload, perturb bool) transcript {
	t.Helper()
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	server, proxy := socket(t), socket(t)
	defer server.Close()
	defer proxy.Close()
	serverAddr, proxyAddr := server.LocalAddr().(*net.UDPAddr), proxy.LocalAddr().(*net.UDPAddr)
	var issuer transport.Key
	var nonce transport.TokenNonce
	var keys transport.SessionKeys
	for _, b := range [][]byte{issuer[:], nonce[:], keys.ClientToServer[:], keys.ServerToClient[:]} {
		_, err := rand.Read(b)
		require(t, err == nil, "random key %v", err)
	}
	token := transport.IssueToken(issuer, nonce, transport.Grant{Account: 355, Session: 354, Shard: proxyAddr.AddrPort(), Expires: epoch + 600, Keys: keys})
	gate, err := transport.NewGate(transport.GateConfig{SchemaHash: schemaHash, Shard: proxyAddr.AddrPort(), Issuer: issuer})
	require(t, err == nil, "gate %v", err)
	c := startChild(t, ctx, helper)
	init := &frame{}
	init.put(1, 1)
	init.blob(token.Bytes())
	init.put(schemaHash, 8)
	init.list(w.Intents)
	init.list(w.Input)
	init.put(uint64(w.Ticks), 4)
	if w.Stale {
		init.put(1, 1)
	} else {
		init.put(0, 1)
	}
	init.blob(w.Events[0])
	ready := c.exchange(t, init)
	clientAddr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1).To4(), Port: int(ready.get(2))}
	ready.end(t)
	require(t, clientAddr.Port > 0, "client port")
	sim := netsim.New(netsim.Profiles[profile], seed)
	var endpoint *transport.Endpoint
	var identity *transport.Endpoint
	var tr transcript
	var receivedEvents, receivedIntents [][]byte
	var states, inputs, wantStates, wantInputs []sample
	seen := map[fingerprint]bool{}
	var newestReceivedNonce uint64
	haveReceivedNonce := false
	var emittedNonce [2]uint64
	var haveEmittedNonce [2]bool
	queued := 0
	activeTick := uint32(0)
	admissionCount := 0
	forced := false
	drain := 0
	var replayErrors, oldErrors, agedErrors, gateReplays, clientReplayErrors, clientOldErrors, clientAgedErrors int
	var forcedDuplicates [2]bool
	var held [2][]byte
	var delayed [2]bool
	submitted := 0
	submit := func(dir netsim.Direction, b []byte, now uint64) {
		submitted++
		require(t, submitted <= 8192, "simulator submission limit")
		sim.Send(dir, b, now)
	}
	var serverStale, clientStale int
	var clientCreated bool
	var clientQueued uint32
	var retries [2]int
	var emitted [2]int
	for tick := 1; tick <= 500; tick++ {
		require(t, ctx.Err() == nil, "run deadline profile=%s seed=%d tick=%d", profile, seed, tick)
		now := uint64(tick) * 40000
		previousQueued := queued
		previousClientQueued := clientQueued
		var ingress [2][][]byte
		for dir := netsim.AToB; dir <= netsim.BToA; dir++ {
			deliveries := sim.Poll(dir, now)
			require(t, len(deliveries) <= maxPackets, "delivery bound")
			for i, d := range deliveries {
				tr.add(t, "delivery t=%d dir=%d ordinal=%d at=%d %s", now, dir, i, d.At, metadata(t, d.Packet))
				ingress[dir] = append(ingress[dir], d.Packet)
				to := clientAddr
				if dir == netsim.BToA {
					to = serverAddr
				}
				writeUDP(t, proxy, to, d.Packet)
			}
		}
		var actualServer [][]byte
		for range ingress[netsim.BToA] {
			b, from := readUDP(t, server)
			require(t, from.AddrPort() == proxyAddr.AddrPort(), "server ingress source")
			actualServer = append(actualServer, b)
		}
		actualServer = order(t, actualServer, fingerprints(ingress[netsim.BToA]))
		var serverOut [][]byte
		for _, b := range actualServer {
			if binary.LittleEndian.Uint32(b) == transport.HandshakeID {
				outcome, e := gate.Handle(proxyAddr.AddrPort(), b, epoch+now/1000000)
				if e != nil {
					require(t, e == transport.ErrReplayed, "gate receive %v tick=%d", e, tick)
					gateReplays++
					tr.add(t, "gate t=%d replayed", now)
					continue
				}
				if len(outcome.Challenge) > 0 {
					serverOut = append(serverOut, outcome.Challenge)
					tr.add(t, "gate t=%d challenge", now)
				}
				if a := outcome.Admission; a != nil {
					require(t, endpoint == nil && a.Account == 355 && a.Session == 354 && a.Peer == proxyAddr.AddrPort() && a.Keys == keys, "admission identity")
					open, seal := transport.NewSessionSeal(transport.Server, a.Keys)
					endpoint, e = transport.NewEndpoint(transport.Server, transport.DefaultConfig(schemaHash), open, seal, now)
					require(t, e == nil, "server endpoint %v", e)
					identity = endpoint
					admissionCount++
					require(t, endpoint.Send(w.Events[0]) == nil, "confirmation queue")
					queued = 1
					tr.add(t, "gate t=%d admitted account=%d session=%d", now, a.Account, a.Session)
				}
				continue
			}
			require(t, endpoint != nil && endpoint == identity, "session endpoint identity")
			f := digest(b)
			packetNonce := binary.LittleEndian.Uint64(b[transport.HeaderSize:])
			r, e := endpoint.Receive(b, now)
			if e != nil {
				duplicate := seen[f]
				aged := haveReceivedNonce && packetNonce <= newestReceivedNonce && newestReceivedNonce-packetNonce >= transport.ReplayWindow
				require(t, (e == transport.ErrMalformed && (duplicate || aged)) || e == transport.ErrTooOld, "server receive %v t=%d duplicate=%v aged=%v", e, now, duplicate, aged)
				kind := "aged_nonce"
				if !duplicate && e == transport.ErrMalformed {
					agedErrors++
				}
				if duplicate {
					kind = "replay_copy"
					replayErrors++
				}
				if e == transport.ErrTooOld {
					kind = "old_packet"
					oldErrors++
					seen[f] = true
				}
				tr.add(t, "server receive t=%d %s %s", now, kind, metadata(t, b))
				continue
			}
			seen[f] = true
			if !haveReceivedNonce || packetNonce > newestReceivedNonce {
				newestReceivedNonce = packetNonce
			}
			haveReceivedNonce = true
			if r.Stale {
				serverStale++
			}
			tr.add(t, "server receive t=%d accepted stale=%v", now, r.Stale)
			for _, msg := range r.Reliable {
				assertNextReliable(t, receivedIntents, w.Intents, msg, "intent")
				receivedIntents = append(receivedIntents, msg)
				tr.add(t, "intent t=%d bytes=%x", now, msg)
			}
			if len(r.Unreliable.Items) > 0 {
				s := sample{r.Unreliable.Stamp, r.Unreliable.Items}
				inputs = append(inputs, s)
				tr.add(t, "input t=%d stamp=%d items=%x", now, s.Stamp, s.Items)
			}
		}
		step := &frame{}
		step.put(2, 1)
		step.put(now, 8)
		step.fingerprints(fingerprints(ingress[netsim.AToB]))
		if perturb {
			runtime.Gosched()
		}
		result := decodeReply(t, c.exchange(t, step))
		clientQueued = result.Queued
		require(t, len(result.Outcomes) == len(ingress[netsim.AToB]), "client ingress outcomes count")
		for i, outcome := range result.Outcomes {
			if outcome == 3 {
				clientReplayErrors++
			}
			if outcome == 4 {
				clientAgedErrors++
			}
			if outcome == 5 {
				clientOldErrors++
			}
			if outcome == 7 {
				clientStale++
			}
			tr.add(t, "client receive t=%d ordinal=%d outcome=%d", now, i, outcome)
		}
		for _, msg := range result.Reliable {
			assertNextReliable(t, receivedEvents, w.Events, msg, "event")
			receivedEvents = append(receivedEvents, msg)
			tr.add(t, "event t=%d bytes=%x", now, msg)
		}
		for _, s := range result.Unreliable {
			states = append(states, s)
			tr.add(t, "state t=%d stamp=%d items=%x", now, s.Stamp, s.Items)
		}
		require(t, !clientCreated || result.Created, "client endpoint recreation")
		clientCreated = result.Created
		require(t, result.State == byte(transport.Open), "client closed")
		if result.Connected && len(wantInputs) < int(w.Ticks) {
			require(t, result.Sent == uint32(len(w.Input)), "scheduled input sample not fully emitted stamp=%d sent=%d", result.Stamp, result.Sent)
		}
		if result.Sent > 0 {
			require(t, result.Sent == uint32(len(w.Input)), "partial input sample")
			wantInputs = append(wantInputs, sample{result.Stamp, w.Input})
		}
		if endpoint != nil {
			require(t, endpoint == identity, "server endpoint replaced")
			if queued < len(w.Events) {
				require(t, endpoint.Send(w.Events[queued]) == nil, "event queue")
				queued++
			}
			u := transport.Unreliable{}
			if result.Connected && activeTick < w.Ticks {
				u.Stamp = activeTick + 1
				if w.Stale {
					u.Stamp = 29
					if activeTick == 0 {
						u.Stamp = 30
					}
				}
				u.Items = w.State
			}
			if result.Connected {
				activeTick++
			}
			flushed, e := endpoint.Flush(now, u)
			require(t, e == nil && endpoint.State() == transport.Open, "server flush %v state=%s", e, endpoint.State())
			require(t, flushed.UnreliableSent == len(u.Items), "scheduled state sample not fully emitted stamp=%d sent=%d", u.Stamp, flushed.UnreliableSent)
			if flushed.UnreliableSent > 0 {
				require(t, flushed.UnreliableSent == len(w.State), "partial state sample")
				wantStates = append(wantStates, sample{u.Stamp, w.State})
			}
			serverOut = append(serverOut, flushed.Datagrams...)
		}
		require(t, len(serverOut) <= maxPackets, "server egress count bound")
		for _, b := range serverOut {
			writeUDP(t, server, proxyAddr, b)
		}
		var actualEgress [2][][]byte
		require(t, len(serverOut)+len(result.Out) <= 2*maxPackets, "total egress bound")
		for i := 0; i < len(serverOut)+len(result.Out); i++ {
			b, from := readUDP(t, proxy)
			dir := netsim.AToB
			if from.AddrPort() == clientAddr.AddrPort() {
				dir = netsim.BToA
			} else {
				require(t, from.AddrPort() == serverAddr.AddrPort(), "proxy unknown source")
			}
			actualEgress[dir] = append(actualEgress[dir], b)
		}
		actualEgress[netsim.AToB] = order(t, actualEgress[netsim.AToB], fingerprints(serverOut))
		actualEgress[netsim.BToA] = order(t, actualEgress[netsim.BToA], result.Out)
		for dir := netsim.AToB; dir <= netsim.BToA; dir++ {
			for i, b := range actualEgress[dir] {
				protocol := binary.LittleEndian.Uint32(b)
				if protocol == transport.ProtocolID {
					emitted[dir]++
					noNew := queued == previousQueued
					unreliableLimit := transport.HeaderSize + transport.SessionOverhead
					if dir == netsim.BToA {
						noNew = result.Queued == previousClientQueued
						if result.Sent > 0 {
							unreliableLimit += 7
							for _, item := range w.Input {
								unreliableLimit += 1 + len(item)
							}
						}
					} else if result.Connected && activeTick <= w.Ticks {
						unreliableLimit += 7
						for _, item := range w.State {
							unreliableLimit += 1 + len(item)
						}
					}
					if noNew && len(b) > unreliableLimit {
						retries[dir]++
					}
					n := binary.LittleEndian.Uint64(b[transport.HeaderSize:])
					require(t, !haveEmittedNonce[dir] || n > emittedNonce[dir], "emitted nonce restarted dir=%d", dir)
					emittedNonce[dir] = n
					haveEmittedNonce[dir] = true
				}
				tr.add(t, "emit t=%d dir=%d ordinal=%d %s", now, dir, i, metadata(t, b))
				match := fault == "confirmation" && dir == netsim.AToB && protocol == transport.ProtocolID
				if protocol == transport.HandshakeID {
					match = (fault == "request" && b[4] == 1) || (fault == "challenge" && b[4] == 2) || (fault == "response" && b[4] == 3)
				}
				if !forced && match {
					forced = true
					tr.add(t, "forced_loss t=%d kind=%s", now, fault)
					continue
				}
				if fault == "duplicate" && protocol == transport.ProtocolID && !forcedDuplicates[dir] {
					forcedDuplicates[dir] = true
					tr.add(t, "forced_duplicate t=%d dir=%d", now, dir)
					submit(dir, b, now)
				}
				if (fault == "aged_first" || fault == "old_packet") && protocol == transport.ProtocolID && !delayed[dir] {
					delayed[dir] = true
					held[dir] = bytes.Clone(b)
					tr.add(t, "held_first t=%d dir=%d", now, dir)
					continue
				}
				submit(dir, b, now)
			}
		}
		for dir := netsim.AToB; dir <= netsim.BToA; dir++ {
			threshold := uint64(65)
			if fault == "old_packet" {
				threshold = 35
			}
			if held[dir] != nil && haveEmittedNonce[dir] && emittedNonce[dir] >= threshold {
				tr.add(t, "release_first t=%d dir=%d %s", now, dir, metadata(t, held[dir]))
				submit(dir, held[dir], now)
				held[dir] = nil
			}
		}
		require(t, len(seen) <= 8192, "server packet history limit")
		serverBacklog := -1
		serverState := "absent"
		if endpoint != nil {
			serverBacklog = endpoint.Backlog()
			serverState = endpoint.State().String()
		}
		tr.add(t, "step t=%d server_created=%v server_state=%s server_backlog=%d events_queued=%d client_connected=%v client_created=%v client_state=%d client_backlog=%d intents_queued=%d input_stamp=%d input_sent=%d", now, endpoint != nil, serverState, serverBacklog, queued, result.Connected, result.Created, result.State, result.Backlog, result.Queued, result.Stamp, result.Sent)
		complete := endpoint != nil && result.Connected && queued == len(w.Events) && int(result.Queued) == len(w.Intents) && activeTick >= w.Ticks && len(wantInputs) >= int(w.Ticks) && serverBacklog == 0 && result.Backlog == 0 && reflect.DeepEqual(receivedEvents, w.Events) && reflect.DeepEqual(receivedIntents, w.Intents)
		if fault == "aged_first" || fault == "old_packet" {
			complete = complete && delayed[0] && delayed[1] && held[0] == nil && held[1] == nil
		}
		if complete {
			drain++
		} else {
			drain = 0
		}
		if drain >= 50 {
			require(t, admissionCount == 1 && gate.Admissions() == 1 && endpoint == identity, "one admission and persistent session")
			require(t, fault == "" || fault == "duplicate" || fault == "aged_first" || fault == "old_packet" || forced, "forced loss never happened")
			if fault == "confirmation" {
				require(t, gateReplays > 0, "cached response retry did not reach admitted Gate")
			}
			if fault == "duplicate" {
				require(t, forcedDuplicates[0] && forcedDuplicates[1] && replayErrors > 0 && clientReplayErrors > 0, "duplicate copies not rejected at both endpoints")
			}
			if fault == "aged_first" {
				require(t, agedErrors > 0 && clientAgedErrors > 0, "aged first arrivals not rejected at both endpoints")
			}
			if fault == "old_packet" {
				require(t, oldErrors > 0 && clientOldErrors > 0, "old packets not rejected at both endpoints")
			}
			if w.Stale {
				require(t, serverStale == 1 && clientStale == 1, "stale suppression must be observed at both endpoints server=%d client=%d", serverStale, clientStale)
			}
			validateSamples(t, states, w.State)
			validateSamples(t, inputs, w.Input)
			if profile == "clean" {
				expectedStates, expectedInputs := wantStates, wantInputs
				if w.Stale {
					expectedStates = wantStates[:1]
					expectedInputs = wantInputs[:1]
				}
				require(t, reflect.DeepEqual(states, expectedStates), "clean state transcript got=%v want=%v", states, expectedStates)
				require(t, reflect.DeepEqual(inputs, expectedInputs), "clean input transcript got=%v want=%v", inputs, expectedInputs)
			}
			residual(t, server)
			residual(t, proxy)
			c.finish(t)
			tr.add(t, "finished tick=%d admission=%d server_backlog=0 client_backlog=0 events=%d intents=%d states=%d inputs=%d server_emit=%d client_emit=%d server_retry=%d client_retry=%d server_replay=%d client_replay=%d server_old=%d client_old=%d server_aged=%d client_aged=%d gate_replay=%d submitted=%d child_exit=0", tick, admissionCount, len(receivedEvents), len(receivedIntents), len(states), len(inputs), emitted[0], emitted[1], retries[0], retries[1], replayErrors, clientReplayErrors, oldErrors, clientOldErrors, agedErrors, clientAgedErrors, gateReplays, submitted)
			t.Logf("profile=%s seed=%d fault=%s ticks=%d events=%d intents=%d states=%d inputs=%d server_emit=%d client_emit=%d server_retry=%d client_retry=%d server_replay=%d client_replay=%d server_old=%d client_old=%d server_aged=%d client_aged=%d gate_replays=%d submitted=%d transcript_records=%d transcript_bytes=%d child_exit=0", profile, seed, fault, tick, len(receivedEvents), len(receivedIntents), len(states), len(inputs), emitted[0], emitted[1], retries[0], retries[1], replayErrors, clientReplayErrors, oldErrors, clientOldErrors, agedErrors, clientAgedErrors, gateReplays, submitted, len(tr.records), tr.size)
			return tr
		}
	}
	t.Fatalf("virtual limit profile=%s seed=%d fault=%s events=%d/%d intents=%d/%d stderr=%s", profile, seed, fault, len(receivedEvents), len(w.Events), len(receivedIntents), len(w.Intents), c.stderr.String())
	return tr
}
func assertNextReliable(t *testing.T, received, expected [][]byte, msg []byte, channel string) {
	t.Helper()
	at := len(received)
	require(t, at < len(expected), "%s duplicate/extra delivery index=%d length=%d", channel, at, len(msg))
	require(t, bytes.Equal(msg, expected[at]), "%s delivery order/bytes index=%d got=%x want=%x", channel, at, msg, expected[at])
}
func validateSamples(t *testing.T, values []sample, items [][]byte) {
	t.Helper()
	require(t, len(values) > 0, "unreliable channel has no delivery")
	var last uint32
	for _, s := range values {
		require(t, s.Stamp > last && reflect.DeepEqual(s.Items, items), "unreliable stamp/payload stamp=%d previous=%d items=%x", s.Stamp, last, s.Items)
		last = s.Stamp
	}
}
func fixture(t *testing.T, name string, size int) []byte {
	t.Helper()
	file, err := os.Open(filepath.Join("../../../../shared/wire/vectors/interop", name))
	require(t, err == nil, "literal fixture %s open %v", name, err)
	defer file.Close()
	info, err := file.Stat()
	require(t, err == nil && info.Mode().IsRegular() && info.Size() == int64(size), "literal fixture %s expected size=%d err=%v", name, size, err)
	b := make([]byte, size)
	_, err = io.ReadFull(file, b)
	require(t, err == nil, "literal fixture %s read %v", name, err)
	return b
}

func TestGoCppInterop(t *testing.T) {
	helper := os.Getenv("TRANSPORT_INTEROP_CLIENT")
	if helper == "" {
		t.Skip("external C++ helper absent; run scripts/transport_interop.sh")
	}
	require(t, filepath.IsAbs(helper), "helper path must be absolute")
	info, err := os.Stat(helper)
	require(t, err == nil && info.Mode().IsRegular() && info.Mode()&0111 != 0, "helper unavailable %v", err)
	seed := uint64(355)
	if raw, ok := os.LookupEnv("NETSIM_SEED"); ok {
		seed, err = strconv.ParseUint(raw, 10, 64)
		require(t, err == nil, "invalid NETSIM_SEED %q", raw)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	base := workload{Events: [][]byte{fixture(t, "event.bin", 4)}, Intents: [][]byte{fixture(t, "intent.bin", 4)}, State: [][]byte{fixture(t, "state.bin", 4)}, Input: [][]byte{fixture(t, "input.bin", 4)}, Ticks: 8}
	check := func(t *testing.T, profile, fault string, w workload) {
		t.Helper()
		t.Logf("profile=%s seed=%d fault=%s rerun=NETSIM_SEED=%d scripts/transport_interop.sh", profile, seed, fault, seed)
		a := run(t, ctx, helper, profile, seed, fault, w, false)
		b := run(t, ctx, helper, profile, seed, fault, w, true)
		compareTranscript(t, a, b, profile, seed, fault)
		t.Log("semantic replay equal with fresh keys/ports")
	}
	t.Run("clean_slice", func(t *testing.T) { check(t, "clean", "", base) })
	broad := base
	broad.Events = append(append([][]byte(nil), base.Events...), fixture(t, "event_1025.bin", 1025), fixture(t, "event_3073.bin", 3073), fixture(t, "event_final.bin", 5))
	broad.Intents = append(append([][]byte(nil), base.Intents...), fixture(t, "intent_1025.bin", 1025), fixture(t, "intent_3073.bin", 3073), fixture(t, "intent_final.bin", 5))
	broad.Input = append(append([][]byte(nil), base.Input...), fixture(t, "input_previous.bin", 5))
	broad.Ticks = 24
	for _, profile := range []string{"clean", "lossy_5pct", "bad_wifi"} {
		t.Run(profile, func(t *testing.T) { check(t, profile, "", broad) })
	}
	for _, fault := range []string{"request", "challenge", "response", "confirmation"} {
		t.Run("loss_"+fault, func(t *testing.T) { check(t, "clean", fault, broad) })
	}
	t.Run("duplicate_copies", func(t *testing.T) { check(t, "clean", "duplicate", broad) })
	delayed := broad
	delayed.Ticks = 64
	for _, fault := range []string{"old_packet", "aged_first"} {
		t.Run(fault, func(t *testing.T) { check(t, "clean", fault, delayed) })
	}
	stale := base
	stale.Ticks = 2
	stale.Stale = true
	t.Run("stale_stamps", func(t *testing.T) { check(t, "clean", "", stale) })
}

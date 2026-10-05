package clientrecording

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/netsim"
	"github.com/devarminas/marque/server/internal/recording"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

func built[T any](t *testing.T, fields interface{ Build() (T, error) }) T {
	t.Helper()
	value, err := fields.Build()
	if err != nil {
		t.Fatal(err)
	}
	return value
}
func encoded[T wire.Message](t *testing.T, fields interface{ Build() (T, error) }) []byte {
	t.Helper()
	value := built(t, fields)
	b, err := value.Append(nil)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func item(t *testing.T, gen uint32, x float64, hp bool) []byte {
	t.Helper()
	position := built(t, (wire.TransformFields{X: x, Y: 0, Z: 0}))
	fields := wire.EntityFields{Id: wire.ItemId{Index: 7, Gen: gen}, Transform: codec.Some(position)}
	if hp {
		fields.Vitals = codec.Some(built(t, (wire.VitalsFields{Hp: 10, MaxHp: 10})))
	}
	return encoded(t, fields)
}
func closeTick(t *testing.T, tick uint32, end uint64, count uint16, cursor uint32) []byte {
	t.Helper()
	return encoded(t, (wire.TickCloseFields{Stream: 88, Epoch: 1, Tick: tick, EventEnd: end, StateItems: count, NextIntent: cursor}))
}
func inventory(t *testing.T, size int) []byte {
	t.Helper()
	slots := make([]wire.BagEntry, size)
	for i := range slots {
		slots[i] = built(t, (wire.BagEntryFields{Slot: uint8(i), Kind: strings.Repeat("s", 64)}))
	}
	if size == 1 {
		slots[0] = built(t, (wire.BagEntryFields{Slot: 0, Kind: "item7"}))
	}
	return encoded(t, (wire.InventoryFields{Stream: 88, EventSeq: 1, Tick: 1, Size: 28, Slots: slots}))
}

type capturedPacket struct{ header, body []byte }
type peer struct {
	sealer       *transport.SessionSealer
	captures     []capturedPacket
	t            *testing.T
	cmd          *exec.Cmd
	input        io.WriteCloser
	output       *bufio.Scanner
	errors       bytes.Buffer
	endpoint     *transport.Endpoint
	path         string
	poses        []string
	publications []string
	pending      []string
}

func start(t *testing.T, mode string) *peer {
	t.Helper()
	helper := os.Getenv("MARQUE_RECORDING_PEER")
	if helper == "" {
		t.Skip("MARQUE_RECORDING_PEER is unset; root recording_test.sh requires the helper")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	p := &peer{t: t, path: filepath.Join(t.TempDir(), "trace.bin")}
	p.cmd = exec.CommandContext(ctx, helper, p.path, mode)
	p.cmd.Stderr = &p.errors
	var err error
	p.input, err = p.cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := p.cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	p.output = bufio.NewScanner(out)
	p.output.Buffer(make([]byte, 4096), 1024*1024)
	opener, sealer := transport.NewSessionSeal(transport.Server, transport.SessionKeys{})
	p.sealer = sealer
	p.endpoint, err = transport.NewEndpoint(transport.Server, transport.DefaultConfig(wire.SchemaHash), opener, sealer, 0)
	if err != nil {
		t.Fatal(err)
	}
	p.endpoint.SetCapture(func(_ uint64, header, body []byte) { p.captures = append(p.captures, capturedPacket{header, body}) })
	if err = p.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	return p
}
func (p *peer) operation(now uint64, operation string) string {
	p.t.Helper()
	if _, err := fmt.Fprintf(p.input, "%s\n", operation); err != nil {
		p.t.Fatal(err)
	}
	for p.output.Scan() {
		line := p.output.Text()
		if strings.HasPrefix(line, "SEND ") {
			b, err := hex.DecodeString(strings.TrimPrefix(line, "SEND "))
			if err != nil {
				p.t.Fatal(err)
			}
			if _, err = p.endpoint.Receive(b, now); err != nil {
				p.t.Fatal(err)
			}
			continue
		}
		if strings.HasPrefix(line, "POSE ") {
			p.poses = append(p.poses, line)
			continue
		}
		if strings.HasPrefix(line, "PUB ") {
			p.publications = append(p.publications, line)
			continue
		}
		if strings.HasPrefix(line, "OK ") {
			return line
		}
		p.t.Fatalf("unexpected helper line %q", line)
	}
	p.t.Fatalf("helper stopped: %s; %v", p.errors.String(), p.output.Err())
	return ""
}
func (p *peer) receive(now uint64, packet []byte) string {
	return p.operation(now, fmt.Sprintf("recv %d %x", now, packet))
}
func (p *peer) turn(now uint64) string { return p.operation(now, fmt.Sprintf("turn %d", now)) }
func (p *peer) take(now uint64)        { p.operation(now, fmt.Sprintf("take %d", now)) }
func (p *peer) pickup(now uint64, seq uint32) string {
	b := encoded(p.t, wire.PickupFields{Seq: seq, Item: wire.ItemId{Index: 7, Gen: 1}})
	return p.operation(now, fmt.Sprintf("admit %d %x", now, b))
}
func (p *peer) flush(now uint64, state transport.Unreliable, sim *netsim.Simulator) [][]byte {
	p.t.Helper()
	out, err := p.endpoint.Flush(now, state)
	if err != nil {
		p.t.Fatal(err)
	}
	if out.State != transport.Open {
		p.t.Fatalf("server state %v", out.State)
	}
	for _, packet := range out.Datagrams {
		sim.Send(netsim.AToB, packet, now)
	}
	return out.Datagrams
}
func (p *peer) deliver(sim *netsim.Simulator, now uint64) int {
	p.t.Helper()
	packets := sim.Poll(netsim.AToB, now)
	for _, packet := range packets {
		p.receive(now, packet.Packet)
	}
	return len(packets)
}
func (p *peer) send(message []byte) {
	p.t.Helper()
	if err := p.endpoint.Send(message); err != nil {
		p.t.Fatal(err)
	}
}
func (p *peer) finish() recording.File {
	p.t.Helper()
	if err := p.input.Close(); err != nil {
		p.t.Fatal(err)
	}
	var marker string
	for p.output.Scan() {
		marker = p.output.Text()
	}
	if err := p.cmd.Wait(); err != nil {
		p.t.Fatalf("%v: %s; marker %s", err, p.errors.String(), marker)
	}
	if !strings.HasPrefix(marker, "REPLAY_PASS ") {
		p.t.Fatalf("missing exact replay marker %q", marker)
	}
	p.t.Log(marker)
	file, err := recording.Read(p.path, wire.SchemaHash)
	if err != nil {
		p.t.Fatal(err)
	}
	if err = recording.ValidateConfig(file, wire.SchemaHash); err != nil {
		p.t.Fatal(err)
	}
	return file
}
func TestCleanExactReplay(t *testing.T) {
	p := start(t, "clean")
	sim := netsim.New(netsim.Clean, 361)
	for tick := uint32(1); tick <= 3; tick++ {
		now := uint64(tick) * 40000
		cursor := uint32(1)
		end := uint64(0)
		var state []byte
		if tick == 1 {
			state = item(t, 1, 2, true)
		} else {
			cursor = 2
			end = 1
			if tick == 2 {
				state = item(t, 1, 3, false)
				p.send(inventory(t, 1))
			} else {
				state = encoded(t, wire.GoneFields{Id: wire.ItemId{Index: 7, Gen: 1}})
			}
		}
		p.send(closeTick(t, tick, end, 1, cursor))
		p.flush(now, transport.Unreliable{Stamp: tick, Items: [][]byte{state}}, sim)
		p.deliver(sim, now)
		p.turn(now)
		p.take(now + 1)
		if tick == 1 {
			p.pickup(now+2, 1)
		}
	}
	expected := []string{
		"PUB 1 visible=1 gen=1 x=2 hp=10 end=0 cursor=1 producing=0 slots=0",
		"PUB 2 visible=1 gen=1 x=3 hp=10 end=1 cursor=2 producing=1 slots=1",
		"PUB 3 visible=0 gen=1 x=-1 hp=-1 end=1 cursor=2 producing=0 slots=1",
	}
	if strings.Join(p.publications, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("publications %q", p.publications)
	}
	file := p.finish()
	text, err := exec.Command("go", "run", "../../cmd/wiregen/dump", "--recording", p.path).CombinedOutput()
	if err != nil || !bytes.Contains(text, []byte("inventory{")) || !bytes.Contains(text, []byte("item7")) || !bytes.Contains(text, []byte("tick_close{")) {
		t.Fatalf("native trace generated dump err=%v output=%s", err, text)
	}
	nativeContainerRefusals(t, p.path)
	removed := filepath.Join(t.TempDir(), "removed-command.bin")
	w, err := recording.Create(removed, file.Mode, wire.SchemaHash, file.Origin)
	if err != nil {
		t.Fatal(err)
	}
	for _, record := range file.Records {
		if record.Kind == recording.Command || record.Kind == recording.End {
			continue
		}
		if err = w.Append(record.Kind, record.Time, record.Payload); err != nil {
			t.Fatal(err)
		}
	}
	if err = w.Finish(file.Records[len(file.Records)-1].Time, 0); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(os.Getenv("MARQUE_RECORDING_PEER"), "read", removed).CombinedOutput()
	if err == nil || string(output) != "REFUSE cursor\n" {
		t.Fatalf("admission removal err=%v output=%q", err, output)
	}
}
func TestPublicationPressureAndDrainReplay(t *testing.T) {
	for _, mode := range []string{"capacity", "drain"} {
		t.Run(mode, func(t *testing.T) {
			p := start(t, mode)
			sim := netsim.New(netsim.Clean, 361)
			for tick := uint32(1); tick <= 2; tick++ {
				now := uint64(tick) * 40000
				p.send(closeTick(t, tick, 0, 1, 1))
				p.flush(now, transport.Unreliable{Stamp: tick, Items: [][]byte{item(t, 1, float64(tick), true)}}, sim)
				p.deliver(sim, now)
				outcome := p.turn(now)
				if mode == "drain" {
					if !strings.Contains(outcome, "error=0") {
						t.Fatal(outcome)
					}
					p.take(now + 1)
				} else if tick == 2 && !strings.Contains(outcome, "error=6") {
					t.Fatal(outcome)
				}
			}
			if mode == "capacity" {
				p.take(80001)
				p.take(80002)
			}
			if len(p.publications) != 2 {
				t.Fatalf("publication count %d", len(p.publications))
			}
			p.finish()
		})
	}
}
func TestBadWifiFragmentedCumulativeReplay(t *testing.T) {
	p := start(t, "wifi")
	sim := netsim.New(netsim.BadWifi, 36120261005)
	p.send(closeTick(t, 1, 0, 1, 1))
	p.flush(40000, transport.Unreliable{Stamp: 1, Items: [][]byte{item(t, 1, 2, true)}}, sim)
	admitted := false
	delivered := 0
	for now := uint64(80000); now <= 800000; now += 40000 {
		p.flush(now, transport.Unreliable{Stamp: 1, Items: [][]byte{item(t, 1, 2, true)}}, sim)
		delivered += p.deliver(sim, now)
		p.turn(now)
		if len(p.publications) > 0 {
			p.take(now + 1)
			p.pickup(now+2, 1)
			admitted = true
			break
		}
	}
	if !admitted {
		t.Fatal("initial publication never arrived")
	}
	p.send(inventory(t, 28))
	p.send(closeTick(t, 2, 1, 1, 2))
	p.send(closeTick(t, 3, 1, 1, 2))
	p.send(closeTick(t, 4, 1, 1, 2))
	for now := uint64(840000); now <= 2400000; now += 40000 {
		stamp := uint32(4)
		state := item(t, 2, 9, true)
		if now == 840000 {
			stamp = 2
			state = item(t, 1, 3, false)
		} else if now == 880000 {
			stamp = 3
			state = encoded(t, wire.GoneFields{Id: wire.ItemId{Index: 7, Gen: 1}})
		}
		p.flush(now, transport.Unreliable{Stamp: stamp, Items: [][]byte{state}}, sim)
		delivered += p.deliver(sim, now)
		p.turn(now)
		p.take(now + 1)
	}
	if len(p.publications) < 2 || p.publications[len(p.publications)-1] != "PUB 4 visible=1 gen=2 x=9 hp=10 end=1 cursor=2 producing=0 slots=28" {
		t.Fatalf("publications %q", p.publications)
	}
	expected := []string{
		"PUB 1 visible=1 gen=1 x=2 hp=10 end=0 cursor=1 producing=0 slots=0",
		"PUB 2 visible=1 gen=1 x=3 hp=10 end=1 cursor=2 producing=1 slots=28",
		"PUB 4 visible=1 gen=2 x=9 hp=10 end=1 cursor=2 producing=0 slots=28",
	}
	if strings.Join(p.publications, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("observed publication sequence changed %q", p.publications)
	}
	file := p.finish()
	packets := 0
	for _, r := range file.Records {
		if r.Kind == recording.Authenticated {
			packets++
		}
	}
	if packets < 3 || delivered < packets {
		t.Fatalf("crypto duplicates or plaintext capture not exercised delivered=%d plaintext=%d", delivered, packets)
	}
	t.Logf("actual BadWifi seed36120261005 publications=%q delivered=%d plaintext=%d", p.publications, delivered, packets)
}
func TestRealCanonicalSenderBacklogReplay(t *testing.T) {
	p := start(t, "backlog")
	sim := netsim.New(netsim.Clean, 361)
	p.send(closeTick(t, 1, 0, 1, 1))
	p.flush(40000, transport.Unreliable{Stamp: 1, Items: [][]byte{item(t, 1, 2, true)}}, sim)
	p.deliver(sim, 40000)
	p.turn(40000)
	p.take(40001)
	for seq := uint32(1); seq <= 1024; seq++ {
		out := p.pickup(40002+uint64(seq), seq)
		if !strings.Contains(out, "error=0") {
			t.Fatal(out)
		}
	}
	if out := p.turn(80000); !strings.Contains(out, "error=4") {
		t.Fatalf("real sender backlog did not close %s", out)
	}
	file := p.finish()
	commands := 0
	for _, r := range file.Records {
		if r.Kind == recording.Command {
			commands++
		}
	}
	if commands != 1024 {
		t.Fatalf("command records %d", commands)
	}
}
func (p *peer) seal(header, body []byte) []byte {
	return p.sealer.Seal(bytes.Clone(header), header, body)
}
func TestAuthenticatedBoundaryAndGenerationReplay(t *testing.T) {
	p := start(t, "generation")
	sim := netsim.New(netsim.Clean, 361)
	p.send(closeTick(t, 1, 0, 1, 1))
	packets := p.flush(40000, transport.Unreliable{Stamp: 1, Items: [][]byte{item(t, 1, 2, true)}}, sim)
	captured := p.captures[0]
	if out := p.receive(39999, p.seal(captured.header, []byte{0xff})); !strings.HasPrefix(out, "OK malformed") {
		t.Fatal(out)
	}
	p.deliver(sim, 40000)
	p.turn(40000)
	p.take(40001)
	if out := p.receive(40002, packets[0]); !strings.HasPrefix(out, "OK malformed") {
		t.Fatal(out)
	}
	tampered := bytes.Clone(packets[0])
	tampered[len(tampered)-1] ^= 1
	if out := p.receive(40003, tampered); !strings.HasPrefix(out, "OK malformed") {
		t.Fatal(out)
	}
	if out := p.receive(40004, p.seal(captured.header, captured.body)); !strings.HasPrefix(out, "OK duplicate") {
		t.Fatal(out)
	}
	p.send(closeTick(t, 2, 0, 1, 1))
	p.flush(80000, transport.Unreliable{Stamp: 2, Items: [][]byte{item(t, 2, 9, true)}}, sim)
	p.deliver(sim, 80000)
	p.turn(80000)
	p.take(80001)
	p.flush(120000, transport.Unreliable{Stamp: 1, Items: [][]byte{item(t, 1, 99, true)}}, sim)
	p.deliver(sim, 120000)
	p.turn(120000)
	p.send(closeTick(t, 3, 0, 1, 1))
	p.flush(160000, transport.Unreliable{Stamp: 3, Items: [][]byte{item(t, 1, 77, false)}}, sim)
	p.deliver(sim, 160000)
	p.turn(160000)
	p.take(160001)
	latest := p.captures[len(p.captures)-1]
	if out := p.receive(160002, p.seal(latest.header, []byte{0xff})); !strings.HasPrefix(out, "OK malformed") {
		t.Fatal(out)
	}
	expected := []string{
		"PUB 1 visible=1 gen=1 x=2 hp=10 end=0 cursor=1 producing=0 slots=0",
		"PUB 2 visible=1 gen=2 x=9 hp=10 end=0 cursor=1 producing=0 slots=0",
		"PUB 3 visible=1 gen=2 x=9 hp=10 end=0 cursor=1 producing=0 slots=0",
	}
	if strings.Join(p.publications, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("generation publications %q", p.publications)
	}
	file := p.finish()
	authenticated := 0
	for _, record := range file.Records {
		if record.Kind == recording.Authenticated {
			authenticated++
		}
	}
	if authenticated != 7 {
		t.Fatalf("authentication records %d; replayed ciphertext and tamper must not record plaintext", authenticated)
	}
}
func nativeContainerRefusals(t *testing.T, path string) {
	t.Helper()
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	offsets := []int{}
	for at := 32; at < len(original); at += 24 + int(binary.LittleEndian.Uint32(original[at+4:])) {
		offsets = append(offsets, at)
	}
	cases := []struct {
		name, expected string
		change         func([]byte) []byte
	}{
		{"schema", "schema", func(b []byte) []byte { b[16] ^= 1; return b }},
		{"version", "version", func(b []byte) []byte { b[8] = 2; return b }},
		{"missing_end", "footer", func(b []byte) []byte { return b[:offsets[len(offsets)-1]] }},
		{"oversized", "length", func(b []byte) []byte { binary.LittleEndian.PutUint32(b[36:], 2*1024*1024); return b }},
		{"backward_time", "time", func(b []byte) []byte { binary.LittleEndian.PutUint64(b[offsets[2]+16:], 0); return b }},
		{"ordinal", "ordinal", func(b []byte) []byte { binary.LittleEndian.PutUint64(b[offsets[2]+8:], 0); return b }},
		{"footer", "footer", func(b []byte) []byte { b[len(b)-1] ^= 1; return b }},
		{"trailing", "trailing", func(b []byte) []byte { return append(b, 0) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			changed := filepath.Join(t.TempDir(), c.name+".bin")
			if err := os.WriteFile(changed, c.change(bytes.Clone(original)), 0600); err != nil {
				t.Fatal(err)
			}
			output, err := exec.Command(os.Getenv("MARQUE_RECORDING_PEER"), "read", changed).CombinedOutput()
			if err == nil || string(output) != "REFUSE "+c.expected+"\n" {
				t.Fatalf("err=%v output=%q", err, output)
			}
		})
	}
}
func TestGoServerSendNativeContainer(t *testing.T) {
	helper := os.Getenv("MARQUE_RECORDING_PEER")
	if helper == "" {
		t.Skip("MARQUE_RECORDING_PEER is unset; root recording_test.sh requires it")
	}
	path := filepath.Join(t.TempDir(), "server.bin")
	cfg := transport.DefaultConfig(wire.SchemaHash)
	writer, err := recording.Create(path, recording.ServerSend, wire.SchemaHash, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err = writer.Append(recording.Begin, 0, recording.ServerConfig(cfg)); err != nil {
		t.Fatal(err)
	}
	opener, sealer := transport.NewSessionSeal(transport.Server, transport.SessionKeys{})
	endpoint, err := transport.NewEndpoint(transport.Server, cfg, opener, sealer, 0)
	if err != nil {
		t.Fatal(err)
	}
	endpoint.SetCapture(writer.CapturePacket)
	if err = endpoint.Send(inventory(t, 28)); err != nil {
		t.Fatal(err)
	}
	if _, err = endpoint.Flush(40000, transport.Unreliable{Stamp: 1, Items: [][]byte{item(t, 1, 2, true)}}); err != nil {
		t.Fatal(err)
	}
	if err = writer.Finish(40001, 0); err != nil {
		t.Fatal(err)
	}
	file, err := recording.Read(path, wire.SchemaHash)
	if err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(helper, "container", path).CombinedOutput()
	expected := fmt.Sprintf("CONTAINER_PASS records=%d mode=2\n", len(file.Records))
	if err != nil || string(output) != expected {
		t.Fatalf("cross-language err=%v output=%q expected=%q", err, output, expected)
	}
}
func TestPredictionInputClockReplay(t *testing.T) {
	p := start(t, "prediction")
	sim := netsim.New(netsim.Clean, 361)
	owner := encoded(t, wire.OwnerMotionFields{Stream: 88, Epoch: 1, Player: wire.PlayerId{Index: 7, Gen: 1}, Tick: 1, Grounded: true, Mode: wire.MotionModeFree, MapId: "village", MapRevision: 2, HalfExtent: 128, TickIntervalUs: 40000})
	p.send(closeTick(t, 1, 0, 2, 1))
	p.flush(40000, transport.Unreliable{Stamp: 1, Items: [][]byte{item(t, 1, 2, true), owner}}, sim)
	p.deliver(sim, 40000)
	p.turn(40000)
	p.take(40001)
	p.operation(40002, "input 40002 1 0 0")
	p.turn(80000)
	p.turn(120000)
	p.operation(120001, "input 120001 0 0 1")
	p.turn(160000)
	p.turn(200000)
	expected := []string{"POSE tick=1 x=0 dx=0 mode=0", "POSE tick=2 x=0.12 dx=1 mode=0", "POSE tick=3 x=0.24 dx=1 mode=0", "POSE tick=4 x=0.24 dx=0 mode=0", "POSE tick=5 x=0.24 dx=0 mode=0"}
	if strings.Join(p.poses, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("literal prediction ticks %q", p.poses)
	}
	file := p.finish()
	inputs, turns := 0, 0
	for _, r := range file.Records {
		if r.Kind == recording.Input {
			inputs++
		}
		if r.Kind == recording.Turn {
			turns++
		}
	}
	if inputs != 2 || turns != 5 {
		t.Fatalf("causal inputs=%d turns=%d", inputs, turns)
	}
}

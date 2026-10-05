package recording

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/devarminas/marque/server/internal/transport"
)

func TestRealPreSealCaptureAndContainerRefusals(t *testing.T) {
	path := filepath.Join(t.TempDir(), "send.mrq")
	cfg := transport.DefaultConfig(7)
	w, err := Create(path, ServerSend, 7, 100)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.Append(Begin, 100, ServerConfig(cfg)); err != nil {
		t.Fatal(err)
	}
	keys := transport.SessionKeys{}
	_, seal := transport.NewSessionSeal(transport.Server, keys)
	ep, err := transport.NewEndpoint(transport.Server, cfg, transport.Plain{}, seal, 100)
	if err != nil {
		t.Fatal(err)
	}
	ep.SetCapture(func(now uint64, header, body []byte) {
		w.CapturePacket(now, header, body)
		header[0] ^= 255
		if len(body) > 0 {
			body[0] ^= 255
		}
	})
	message := bytes.Repeat([]byte{7}, 3073)
	if err := ep.Send(message); err != nil {
		t.Fatal(err)
	}
	flushed, err := ep.Flush(110, transport.Unreliable{})
	if err != nil || len(flushed.Datagrams) < 3 {
		t.Fatalf("actual fragmented flush %d, %v", len(flushed.Datagrams), err)
	}
	open, _ := transport.NewSessionSeal(transport.Client, keys)
	rx, err := transport.NewReceiver(transport.Client, cfg, open)
	if err != nil {
		t.Fatal(err)
	}
	var completed [][]byte
	for _, packet := range flushed.Datagrams {
		r, err := rx.Receive(packet)
		if err != nil {
			t.Fatal(err)
		}
		completed = append(completed, r.Reliable...)
	}
	if len(completed) != 1 || !bytes.Equal(completed[0], message) {
		t.Fatal("capture mutation changed encrypted delivery")
	}
	if err := w.Finish(120, 0); err != nil {
		t.Fatal(err)
	}
	f, err := Read(path, 7)
	if err != nil || len(f.Records) != len(flushed.Datagrams)+2 {
		t.Fatalf("record count %d, %v", len(f.Records), err)
	}
	if err := ValidateConfig(f, 7); err != nil {
		t.Fatal(err)
	}
	if f.Mode != ServerSend || f.Origin != 100 || f.Records[1].Time != 110 || f.Records[1].Kind != Outbound {
		t.Fatalf("actual recorded identity/time %+v", f)
	}
	if binary.LittleEndian.Uint32(f.Records[1].Payload) != transport.ProtocolID {
		t.Fatal("captured encrypted or mutated header")
	}
	plainRx, err := transport.NewReceiver(transport.Client, cfg, transport.Plain{})
	if err != nil {
		t.Fatal(err)
	}
	completed = nil
	for _, r := range f.Records[1 : len(f.Records)-1] {
		got, err := plainRx.Receive(r.Payload)
		if err != nil {
			t.Fatal(err)
		}
		completed = append(completed, got.Reliable...)
	}
	if len(completed) != 1 || !bytes.Equal(completed[0], message) {
		t.Fatal("captured plaintext did not reassemble actual payload")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	mutations := map[string]func([]byte) []byte{
		"schema":        func(b []byte) []byte { b[16] ^= 1; return b },
		"version":       func(b []byte) []byte { b[8] = 2; return b },
		"missing end":   func(b []byte) []byte { return b[:len(b)-81] },
		"length":        func(b []byte) []byte { binary.LittleEndian.PutUint32(b[36:], maxPayload+1); return b },
		"ordinal":       func(b []byte) []byte { binary.LittleEndian.PutUint64(b[112:], 9); return b },
		"backward time": func(b []byte) []byte { binary.LittleEndian.PutUint64(b[120:], 0); return b },
		"unknown kind":  func(b []byte) []byte { b[32] = 9; return b },
		"footer":        func(b []byte) []byte { b[len(b)-1] ^= 1; return b },
		"trailing":      func(b []byte) []byte { return append(b, 0) },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode(mutate(bytes.Clone(b)), 7); !errors.Is(err, ErrInvalid) {
				t.Fatalf("invalid finalized trace accepted: %v", err)
			}
		})
	}
}

func TestIncompleteAndExclusiveFinalization(t *testing.T) {
	for _, conflict := range []bool{false, true} {
		path := filepath.Join(t.TempDir(), "trace.mrq")
		w, err := Create(path, ServerSend, 7, 100)
		if err != nil {
			t.Fatal(err)
		}
		if err := w.Append(Begin, 100, ServerConfig(transport.DefaultConfig(7))); err != nil {
			t.Fatal(err)
		}
		if conflict {
			if err := os.WriteFile(path, []byte("already owned"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := w.Finish(100, 0); err == nil {
				t.Fatal("replaced another owner's destination")
			}
			got, _ := os.ReadFile(path)
			if string(got) != "already owned" {
				t.Fatal("existing destination changed")
			}
		} else {
			if err := w.Append(Outbound, 99, make([]byte, 20)); err == nil {
				t.Fatal("pre-origin time accepted")
			}
			if err := w.Finish(100, 0); err == nil {
				t.Fatal("failed capture finalized")
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("failed capture published")
			}
		}
		_ = w.Close()
		partials, err := filepath.Glob(path + ".partial.*")
		if err != nil || len(partials) != 1 {
			t.Fatalf("failure lost owned partial: %v %v", partials, err)
		}
		if _, err := Read(partials[0], 7); err == nil {
			t.Fatal("partial accepted as complete")
		}
	}
}

func TestFinalizedConfigurationRefusal(t *testing.T) {
	for _, cfg := range []transport.Config{
		{SchemaHash: 7, TickBudget: 1199, BacklogLimit: 1, BacklogBytes: 1, ResendAfter: 1},
		{SchemaHash: 7, TickBudget: 4800, BacklogLimit: 1, BacklogBytes: MaxBytes + 1, ResendAfter: 1},
		{SchemaHash: 7, TickBudget: 4800, BacklogLimit: 1, BacklogBytes: 1, ResendAfter: 0},
	} {
		path := filepath.Join(t.TempDir(), "invalid-config.mrq")
		w, err := Create(path, ServerSend, 7, 0)
		if err != nil {
			t.Fatal(err)
		}
		if err := w.Append(Begin, 0, ServerConfig(cfg)); err != nil {
			t.Fatal(err)
		}
		if err := w.Finish(0, 0); err != nil {
			t.Fatal(err)
		}
		if _, err := Read(path, 7); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid transport config accepted: %v", err)
		}
	}
}

func TestSerializedOrdinalPreservesOriginalCoreTime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "clock.mrq")
	w, err := Create(path, ServerSend, 7, 100)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.Append(Begin, 100, ServerConfig(transport.DefaultConfig(7))); err != nil {
		t.Fatal(err)
	}
	if err := w.Append(Outbound, 110, make([]byte, 20)); err != nil {
		t.Fatal(err)
	}
	if err := w.Append(Outbound, 105, make([]byte, 20)); err != nil {
		t.Fatal(err)
	}
	if err := w.Finish(110, 0); err != nil {
		t.Fatal(err)
	}
	f, err := Read(path, 7)
	if err != nil {
		t.Fatal(err)
	}
	if len(f.Records) != 4 || f.Records[1].Time != 110 || f.Records[2].Time != 105 {
		t.Fatalf("serialized ordering rewrote original operation clocks: %+v", f.Records)
	}
}

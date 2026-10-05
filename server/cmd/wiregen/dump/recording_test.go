package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/recording"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
)

func TestDumpFinalizedActualFragmentedRecording(t *testing.T) {
	for _, incomplete := range []bool{false, true} {
		t.Run(map[bool]string{false: "complete", true: "incomplete fragments"}[incomplete], func(t *testing.T) {
			cfg := transport.DefaultConfig(wire.SchemaHash)
			path := filepath.Join(t.TempDir(), "server.mrq")
			w, err := recording.Create(path, recording.ServerSend, wire.SchemaHash, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer w.Close()
			if err := w.Append(recording.Begin, 0, recording.ServerConfig(cfg)); err != nil {
				t.Fatal(err)
			}
			var slots []wire.BagEntry
			for i := 0; i < 28; i++ {
				slot, err := (wire.BagEntryFields{Slot: uint8(i), Kind: strings.Repeat("a", 64)}).Build()
				if err != nil {
					t.Fatal(err)
				}
				slots = append(slots, slot)
			}
			inventory, err := (wire.InventoryFields{Stream: 7, EventSeq: 1, Tick: 12, Size: 28, Slots: slots}).Build()
			if err != nil {
				t.Fatal(err)
			}
			message, err := inventory.Append(nil)
			if err != nil || len(message) <= 1024 {
				t.Fatalf("literal fragmented inventory %d, %v", len(message), err)
			}
			_, seal := transport.NewSessionSeal(transport.Server, transport.SessionKeys{})
			ep, err := transport.NewEndpoint(transport.Server, cfg, transport.Plain{}, seal, 0)
			if err != nil {
				t.Fatal(err)
			}
			captured := 0
			ep.SetCapture(func(now uint64, header, body []byte) {
				captured++
				if !incomplete || captured == 1 {
					w.CapturePacket(now, header, body)
				}
			})
			if err := ep.Send(message); err != nil {
				t.Fatal(err)
			}
			flushed, err := ep.Flush(10, transport.Unreliable{})
			if err != nil || len(flushed.Datagrams) < 2 {
				t.Fatalf("actual fragment packets %d, %v", len(flushed.Datagrams), err)
			}
			if err := w.Finish(20, 0); err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			if err := dumpRecording(path, &out); err != nil {
				t.Fatal(err)
			}
			text := out.String()
			if !strings.Contains(text, "recording version 1 schema ") || !strings.Contains(text, "mode 2 origin 0\nrecord 0 time 0 begin bytes 40 prefix ") || !strings.Contains(text, " end bytes 49 prefix ") || !strings.Contains(text, "end terminal 0 records ") {
				t.Fatalf("missing container or control diagnostics %q", text)
			}
			if !strings.HasSuffix(text, "recording dump complete\n") {
				t.Fatalf("missing completion %q", text)
			}
			if incomplete {
				if strings.Contains(text, "inventory{") || !strings.Contains(text, "completed 0") {
					t.Fatalf("incomplete fragment was decoded %q", text)
				}
			} else {
				if strings.Count(text, "events s2c inventory{") != 1 || !strings.Contains(text, "stream:7 event_seq:1 tick:12 size:28") || !strings.Contains(text, "BagEntry{slot:27 kind:") {
					t.Fatalf("generated literal inventory missing %q", text)
				}
			}
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			b[len(b)-1] ^= 1
			if err := os.WriteFile(path, b, 0600); err != nil {
				t.Fatal(err)
			}
			out.Reset()
			if err := dumpRecording(path, &out); err == nil || out.Len() != 0 {
				t.Fatalf("corrupt footer decoded before validation: %v %q", err, out.String())
			}
		})
	}
}

func TestDumpMalformedBodyDiagnostic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "malformed.mrq")
	cfg := transport.DefaultConfig(wire.SchemaHash)
	w, err := recording.Create(path, recording.ServerSend, wire.SchemaHash, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if err := w.Append(recording.Begin, 0, recording.ServerConfig(cfg)); err != nil {
		t.Fatal(err)
	}
	ep, err := transport.NewEndpoint(transport.Server, cfg, transport.Plain{}, transport.Plain{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	ep.SetCapture(func(now uint64, header, body []byte) { w.CapturePacket(now, header, []byte{255}) })
	if _, err := ep.Flush(100_000, transport.Unreliable{}); err != nil {
		t.Fatal(err)
	}
	if err := w.Finish(100_000, 0); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := dumpRecording(path, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "record 1 time 100000 refused transport: malformed datagram") {
		t.Fatalf("malformed record diagnostics %q", out.String())
	}
}

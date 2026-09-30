package wire_test

import (
	"bytes"
	"testing"
)

func fuzzDecoder(f *testing.F, key string) {
	for _, v := range loadVectors(f) {
		if v.decoder == key {
			f.Add(v.bytes)
		}
	}
	f.Add([]byte{0x01})
	decode := decoders[key]
	f.Fuzz(func(t *testing.T, b []byte) {
		m, err := decode(b)
		if err != nil {
			return
		}
		_ = m.String()
		back, err := m.Append(nil)
		if err != nil {
			t.Fatalf("%x decoded to %v but re-encoding failed: %v", b, m, err)
		}
		if !bytes.Equal(back, b) {
			t.Fatalf("%x decoded to %v but re-encoded to %x", b, m, back)
		}
	})
}

func FuzzWireState(f *testing.F)    { fuzzDecoder(f, "wire/state") }
func FuzzWireEvents(f *testing.F)   { fuzzDecoder(f, "wire/events") }
func FuzzWireInput(f *testing.F)    { fuzzDecoder(f, "wire/input") }
func FuzzWireIntents(f *testing.F)  { fuzzDecoder(f, "wire/intents") }
func FuzzProbeState(f *testing.F)   { fuzzDecoder(f, "probe/state") }
func FuzzProbeEvents(f *testing.F)  { fuzzDecoder(f, "probe/events") }
func FuzzProbeInput(f *testing.F)   { fuzzDecoder(f, "probe/input") }
func FuzzProbeIntents(f *testing.F) { fuzzDecoder(f, "probe/intents") }

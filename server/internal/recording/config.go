package recording

import (
	"encoding/binary"
	"math"
	"unicode/utf8"

	"github.com/devarminas/marque/server/internal/transport"
)

func ServerConfig(c transport.Config) []byte {
	out := make([]byte, 40)
	for i, v := range []uint64{c.SchemaHash, uint64(c.TickBudget), uint64(c.BacklogLimit), uint64(c.BacklogBytes), c.ResendAfter} {
		binary.LittleEndian.PutUint64(out[8*i:], v)
	}
	return out
}

func ValidateConfig(f File, schema uint64) error {
	if len(f.Records) < 2 || f.Records[0].Kind != Begin {
		return invalid("config")
	}
	b := f.Records[0].Payload
	if f.Mode == ServerSend {
		if len(b) != 40 || binary.LittleEndian.Uint64(b) != schema {
			return invalid("config")
		}
		return validateTransport(b[8:])
	}
	if len(b) < 52 {
		return invalid("config")
	}
	if err := validateTransport(b[:32]); err != nil {
		return err
	}
	if binary.LittleEndian.Uint64(b[32:]) == 0 || binary.LittleEndian.Uint64(b[32:]) > 4096 || binary.LittleEndian.Uint64(b[40:]) == 0 || binary.LittleEndian.Uint64(b[40:]) > 128*1024*1024 {
		return invalid("config")
	}
	count := binary.LittleEndian.Uint32(b[48:52])
	if count > 64 {
		return invalid("config")
	}
	at := 52
	names := make(map[string]bool)
	for range count {
		if len(b)-at < 4 {
			return invalid("config")
		}
		n := int(binary.LittleEndian.Uint32(b[at:]))
		at += 4
		if n < 1 || n > 64 || n > len(b)-at || !utf8.Valid(b[at:at+n]) {
			return invalid("config")
		}
		name := string(b[at : at+n])
		at += n
		if names[name] {
			return invalid("config")
		}
		names[name] = true
		if len(b)-at < 24 {
			return invalid("config")
		}
		revision := binary.LittleEndian.Uint32(b[at:])
		at += 4
		half := math.Float64frombits(binary.LittleEndian.Uint64(b[at:]))
		at += 8
		ground := math.Float64frombits(binary.LittleEndian.Uint64(b[at:]))
		at += 8
		if revision == 0 || half <= 0 || half > 4096 || !finite(half) || !finite(ground) {
			return invalid("config")
		}
		vertices := binary.LittleEndian.Uint32(b[at:])
		at += 4
		if vertices > 10000 || uint64(vertices)*24 > uint64(len(b)-at) {
			return invalid("config")
		}
		for range uint64(vertices) * 3 {
			if !finite(math.Float64frombits(binary.LittleEndian.Uint64(b[at:]))) {
				return invalid("config")
			}
			at += 8
		}
		if len(b)-at < 4 {
			return invalid("config")
		}
		triangles := binary.LittleEndian.Uint32(b[at:])
		at += 4
		if triangles > 20000 || uint64(triangles)*12 > uint64(len(b)-at) {
			return invalid("config")
		}
		for range uint64(triangles) * 3 {
			if binary.LittleEndian.Uint32(b[at:]) >= vertices {
				return invalid("config")
			}
			at += 4
		}
	}
	if at != len(b) {
		return invalid("config")
	}
	return nil
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }
func validateTransport(b []byte) error {
	if len(b) < 32 {
		return invalid("config")
	}
	tick := binary.LittleEndian.Uint64(b)
	limit := binary.LittleEndian.Uint64(b[8:])
	backlog := binary.LittleEndian.Uint64(b[16:])
	resend := binary.LittleEndian.Uint64(b[24:])
	if tick < transport.MaxDatagram || tick > 1024*1024 || limit < 1 || limit > transport.MaxBacklogLimit || backlog < 1 || backlog > MaxBytes || resend == 0 {
		return invalid("config")
	}
	return nil
}

func (w *Writer) CapturePacket(time uint64, header, body []byte) {
	if len(header) != transport.HeaderSize || len(header)+len(body)+24 > transport.MaxDatagram {
		w.err = invalid("packet")
		return
	}
	payload := make([]byte, 0, len(header)+len(body))
	payload = append(payload, header...)
	payload = append(payload, body...)
	_ = w.Append(Outbound, time, payload)
}

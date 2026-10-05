package recording

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
)

const (
	MaxBytes           = 256 * 1024 * 1024
	MaxRecords         = 4_000_000
	MaxDuration uint64 = 86_400_000_000
	maxPayload         = 1024 * 1024
)

type Mode uint8

const (
	ClientReceive Mode = 1
	ServerSend    Mode = 2
)

type Kind uint8

const (
	Begin Kind = iota + 1
	Authenticated
	Command
	Input
	Turn
	Drain
	Outbound
	End
)

var ErrInvalid = errors.New("recording: invalid file")
var magic = []byte("MRQREC01")

type Record struct {
	Kind    Kind
	Time    uint64
	Payload []byte
}
type File struct {
	Mode    Mode
	Origin  uint64
	Records []Record
}

func invalid(reason string) error { return fmt.Errorf("%w: %s", ErrInvalid, reason) }
func validKind(mode Mode, kind Kind, count uint64) bool {
	if kind < Begin || kind > End || (count == 0) != (kind == Begin) {
		return false
	}
	if mode == ServerSend {
		return kind == Begin || kind == Outbound || kind == End
	}
	return kind != Outbound
}

func Read(path string, schema uint64) (File, error) {
	if strings.Contains(filepath.Base(path), ".partial.") {
		return File{}, invalid("partial")
	}
	f, err := os.Open(path)
	if err != nil {
		return File{}, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, MaxBytes+1))
	if err != nil {
		return File{}, err
	}
	return Decode(b, schema)
}

func Decode(b []byte, schema uint64) (File, error) {
	if len(b) < 32 || len(b) > MaxBytes {
		return File{}, invalid("length")
	}
	if !bytes.Equal(b[:8], magic) || binary.LittleEndian.Uint32(b[8:12]) != 1 || !bytes.Equal(b[13:16], []byte{0, 0, 0}) {
		return File{}, invalid("version")
	}
	if binary.LittleEndian.Uint64(b[16:24]) != schema {
		return File{}, invalid("schema")
	}
	mode := Mode(b[12])
	if mode != ClientReceive && mode != ServerSend {
		return File{}, invalid("mode")
	}
	origin := binary.LittleEndian.Uint64(b[24:32])
	if origin > math.MaxInt64-MaxDuration {
		return File{}, invalid("time")
	}
	out := File{Mode: mode, Origin: origin}
	var offset uint64
	ended := false
	for at := 32; at < len(b); {
		if ended {
			return File{}, invalid("trailing")
		}
		if len(out.Records) >= MaxRecords || len(b)-at < 24 {
			return File{}, invalid("length")
		}
		h := b[at : at+24]
		kind := Kind(h[0])
		if !bytes.Equal(h[1:4], []byte{0, 0, 0}) || !validKind(mode, kind, uint64(len(out.Records))) {
			return File{}, invalid("phase")
		}
		length := uint64(binary.LittleEndian.Uint32(h[4:8]))
		if binary.LittleEndian.Uint64(h[8:16]) != uint64(len(out.Records)) {
			return File{}, invalid("ordinal")
		}
		next := binary.LittleEndian.Uint64(h[16:24])
		if next < offset || next > MaxDuration {
			return File{}, invalid("time")
		}
		offset = next
		if length < 8 || length > maxPayload || length > uint64(len(b)-at-24) {
			return File{}, invalid("length")
		}
		payload := b[at+24 : at+24+int(length)]
		core := binary.LittleEndian.Uint64(payload[:8])
		if core > next || core > MaxDuration {
			return File{}, invalid("time")
		}
		if kind == End {
			if length != 57 || payload[8] > 8 || binary.LittleEndian.Uint64(payload[9:17]) != uint64(len(out.Records)) || binary.LittleEndian.Uint64(payload[17:25]) != uint64(at) {
				return File{}, invalid("footer")
			}
			digest := sha256.Sum256(b[:at])
			if !bytes.Equal(payload[25:], digest[:]) {
				return File{}, invalid("footer")
			}
			ended = true
		}
		out.Records = append(out.Records, Record{Kind: kind, Time: origin + core, Payload: bytes.Clone(payload[8:])})
		at += 24 + int(length)
	}
	if !ended || len(out.Records) < 2 {
		return File{}, invalid("footer")
	}
	if err := ValidateConfig(out, schema); err != nil {
		return File{}, err
	}
	return out, nil
}

type Writer struct {
	file                        *os.File
	partial, destination        string
	mode                        Mode
	origin, offset, count, size uint64
	hash                        hash.Hash
	err                         error
}

func Create(path string, mode Mode, schema, origin uint64) (*Writer, error) {
	if strings.Contains(filepath.Base(path), ".partial.") {
		return nil, invalid("partial destination")
	}
	if origin > math.MaxInt64-MaxDuration {
		return nil, invalid("time")
	}
	if mode != ClientReceive && mode != ServerSend {
		return nil, invalid("mode")
	}
	if _, err := os.Lstat(path); err == nil {
		return nil, os.ErrExist
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".partial.*")
	if err != nil {
		return nil, err
	}
	w := &Writer{file: f, partial: f.Name(), destination: path, mode: mode, origin: origin, hash: sha256.New()}
	h := make([]byte, 32)
	copy(h, magic)
	binary.LittleEndian.PutUint32(h[8:], 1)
	h[12] = byte(mode)
	binary.LittleEndian.PutUint64(h[16:], schema)
	binary.LittleEndian.PutUint64(h[24:], origin)
	if !w.write(h) {
		f.Close()
		return nil, w.err
	}
	return w, nil
}

func (w *Writer) write(b []byte) bool {
	if w.err != nil {
		return false
	}
	if uint64(len(b)) > MaxBytes-w.size {
		w.err = invalid("length")
		return false
	}
	n, err := w.file.Write(b)
	if err == nil && n != len(b) {
		err = io.ErrShortWrite
	}
	if err != nil {
		w.err = err
		return false
	}
	w.hash.Write(b)
	w.size += uint64(len(b))
	return true
}

func (w *Writer) append(kind Kind, time uint64, payload []byte) error {
	if w.err != nil {
		return w.err
	}
	if w.file == nil || !validKind(w.mode, kind, w.count) {
		w.err = invalid("phase")
		return w.err
	}
	if time < w.origin || time-w.origin > MaxDuration {
		w.err = invalid("time")
		return w.err
	}
	if w.count >= MaxRecords || len(payload) > maxPayload-8 || uint64(len(payload)+32) > MaxBytes-w.size {
		w.err = invalid("length")
		return w.err
	}
	core := time - w.origin
	w.offset = max(w.offset, core)
	h := make([]byte, 32)
	h[0] = byte(kind)
	binary.LittleEndian.PutUint32(h[4:], uint32(len(payload)+8))
	binary.LittleEndian.PutUint64(h[8:], w.count)
	binary.LittleEndian.PutUint64(h[16:], w.offset)
	binary.LittleEndian.PutUint64(h[24:], core)
	if !w.write(h) || !w.write(payload) {
		return w.err
	}
	w.count++
	return nil
}

func (w *Writer) Append(kind Kind, time uint64, payload []byte) error {
	if kind == End {
		w.err = invalid("end requires finalize")
		return w.err
	}
	return w.append(kind, time, payload)
}

func (w *Writer) Finish(time uint64, terminal uint8) error {
	if w.err != nil {
		return w.err
	}
	if terminal > 8 {
		w.err = invalid("terminal")
		return w.err
	}
	payload := make([]byte, 49)
	payload[0] = terminal
	binary.LittleEndian.PutUint64(payload[1:], w.count)
	binary.LittleEndian.PutUint64(payload[9:], w.size)
	copy(payload[17:], w.hash.Sum(nil))
	if err := w.append(End, time, payload); err != nil {
		return err
	}
	if err := w.file.Sync(); err != nil {
		w.err = err
		return err
	}
	err := w.file.Close()
	w.file = nil
	if err == nil {
		err = os.Link(w.partial, w.destination)
	}
	if err == nil {
		err = os.Remove(w.partial)
	}
	w.err = err
	return err
}

func (w *Writer) Close() error {
	if w.file == nil {
		return w.err
	}
	err := w.file.Close()
	w.file = nil
	if w.err != nil {
		return w.err
	}
	return err
}

func (w *Writer) Error() error { return w.err }

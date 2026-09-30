package codec

import (
	"encoding/binary"
	"errors"
	"math"
	"unicode/utf8"
)

type Channel uint8

const (
	ChannelState Channel = iota + 1
	ChannelEvents
	ChannelInput
	ChannelIntents
)

func (c Channel) String() string {
	switch c {
	case ChannelState:
		return "state"
	case ChannelEvents:
		return "events"
	case ChannelInput:
		return "input"
	case ChannelIntents:
		return "intents"
	}
	return "channel?"
}

var (
	ErrTruncated      = errors.New("wire: truncated")
	ErrTrailing       = errors.New("wire: trailing bytes")
	ErrUnknownMessage = errors.New("wire: unknown message id")
	ErrOverBound      = errors.New("wire: string or list over its bound")
	ErrNonFinite      = errors.New("wire: non-finite number")
	ErrOutOfRange     = errors.New("wire: quantized value out of range")
	ErrBadBool        = errors.New("wire: bool byte not 0 or 1")
	ErrBadEnum        = errors.New("wire: unknown enum value")
	ErrBadVarint      = errors.New("wire: overlong or oversized varint")
	ErrBadUTF8        = errors.New("wire: string is not valid UTF-8")
)

type Quant struct {
	Min, Max, PerUnit float64
	Steps             uint64
	Width             int
}

type Writer struct {
	buf   []byte
	start int
	err   error
}

func NewWriter(dst []byte) Writer { return Writer{buf: dst, start: len(dst)} }

func (w *Writer) Fail(err error) {
	if w.err == nil {
		w.err = err
	}
}

func (w *Writer) Result() ([]byte, error) {
	if w.err != nil {
		return w.buf[:w.start], w.err
	}
	return w.buf, nil
}

func (w *Writer) U8(v uint8) {
	if w.err == nil {
		w.buf = append(w.buf, v)
	}
}

func (w *Writer) U16(v uint16) {
	if w.err == nil {
		w.buf = binary.LittleEndian.AppendUint16(w.buf, v)
	}
}

func (w *Writer) U32(v uint32) {
	if w.err == nil {
		w.buf = binary.LittleEndian.AppendUint32(w.buf, v)
	}
}

func (w *Writer) U64(v uint64) {
	if w.err == nil {
		w.buf = binary.LittleEndian.AppendUint64(w.buf, v)
	}
}

func (w *Writer) Bool(v bool) {
	if v {
		w.U8(1)
	} else {
		w.U8(0)
	}
}

func (w *Writer) F32(v float32) {
	if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
		w.Fail(ErrNonFinite)
		return
	}
	w.U32(math.Float32bits(v))
}

func (w *Writer) Varint(v uint32) {
	if w.err == nil {
		w.buf = binary.AppendUvarint(w.buf, uint64(v))
	}
}

func (w *Writer) Count(n, bound int) {
	if n > bound {
		w.Fail(ErrOverBound)
		return
	}
	w.Varint(uint32(n))
}

func (w *Writer) String(s string, bound int) {
	if !utf8.ValidString(s) {
		w.Fail(ErrBadUTF8)
		return
	}
	w.Count(len(s), bound)
	if w.err == nil {
		w.buf = append(w.buf, s...)
	}
}

func (w *Writer) Quant(v float64, q Quant) {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		w.Fail(ErrNonFinite)
		return
	}
	if v < q.Min || v > q.Max {
		w.Fail(ErrOutOfRange)
		return
	}
	w.fixed(uint64(math.Round(v*q.PerUnit)-q.Min*q.PerUnit), q.Width)
}

func (w *Writer) fixed(v uint64, width int) {
	switch width {
	case 1:
		w.U8(uint8(v))
	case 2:
		w.U16(uint16(v))
	default:
		w.U32(uint32(v))
	}
}

type Reader struct {
	buf []byte
	err error
}

func NewReader(b []byte) *Reader { return &Reader{buf: b} }

func (r *Reader) Len() int { return len(r.buf) }

func (r *Reader) Err() error { return r.err }

func (r *Reader) Fail(err error) {
	if r.err == nil {
		r.err = err
	}
}

func (r *Reader) Finish() error {
	if r.err == nil && len(r.buf) > 0 {
		r.err = ErrTrailing
	}
	return r.err
}

func (r *Reader) take(n int) []byte {
	if r.err != nil {
		return nil
	}
	if len(r.buf) < n {
		r.Fail(ErrTruncated)
		return nil
	}
	b := r.buf[:n]
	r.buf = r.buf[n:]
	return b
}

func (r *Reader) U8() uint8 {
	if b := r.take(1); b != nil {
		return b[0]
	}
	return 0
}

func (r *Reader) U16() uint16 {
	if b := r.take(2); b != nil {
		return binary.LittleEndian.Uint16(b)
	}
	return 0
}

func (r *Reader) U32() uint32 {
	if b := r.take(4); b != nil {
		return binary.LittleEndian.Uint32(b)
	}
	return 0
}

func (r *Reader) U64() uint64 {
	if b := r.take(8); b != nil {
		return binary.LittleEndian.Uint64(b)
	}
	return 0
}

func (r *Reader) Bool() bool {
	switch r.U8() {
	case 0:
		return false
	case 1:
		return true
	}
	r.Fail(ErrBadBool)
	return false
}

func (r *Reader) F32() float32 {
	v := math.Float32frombits(r.U32())
	if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
		r.Fail(ErrNonFinite)
		return 0
	}
	return v
}

func (r *Reader) Varint() uint32 {
	var v uint32
	for i := 0; i < 5; i++ {
		b := r.take(1)
		if b == nil {
			return 0
		}
		c := b[0]
		if i == 4 && c > 0x0f {
			r.Fail(ErrBadVarint)
			return 0
		}
		v |= uint32(c&0x7f) << (7 * i)
		if c < 0x80 {
			if c == 0 && i > 0 {
				r.Fail(ErrBadVarint)
				return 0
			}
			return v
		}
	}
	r.Fail(ErrBadVarint)
	return 0
}

func (r *Reader) Count(bound, minElem int) int {
	n := r.Varint()
	if r.err == nil && uint64(n) > uint64(bound) {
		r.Fail(ErrOverBound)
	}
	if r.err == nil && uint64(n)*uint64(minElem) > uint64(len(r.buf)) {
		r.Fail(ErrTruncated)
	}
	if r.err != nil {
		return 0
	}
	return int(n)
}

func (r *Reader) String(bound int) string {
	b := r.take(r.Count(bound, 1))
	if r.err != nil {
		return ""
	}
	if !utf8.Valid(b) {
		r.Fail(ErrBadUTF8)
		return ""
	}
	return string(b)
}

func (r *Reader) Quant(q Quant) float64 {
	var n uint64
	switch q.Width {
	case 1:
		n = uint64(r.U8())
	case 2:
		n = uint64(r.U16())
	default:
		n = uint64(r.U32())
	}
	if r.err == nil && n > q.Steps {
		r.Fail(ErrOutOfRange)
	}
	if r.err != nil {
		return 0
	}
	return (float64(n) + q.Min*q.PerUnit) / q.PerUnit
}

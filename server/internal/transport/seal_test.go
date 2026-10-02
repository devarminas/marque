package transport

import (
	"encoding/binary"
	"errors"
)

type testSeal struct{}

func (testSeal) Overhead() int { return 4 }

func byteSum(parts ...[]byte) uint32 {
	var n uint32
	for _, p := range parts {
		for _, b := range p {
			n += uint32(b)
		}
	}
	return n
}

func (testSeal) Seal(dst, header, body []byte) []byte {
	for _, b := range body {
		dst = append(dst, b^0xa5)
	}
	return binary.LittleEndian.AppendUint32(dst, byteSum(header, body))
}

func (testSeal) Open(dst, header, sealed []byte) ([]byte, error) {
	if len(sealed) < 4 {
		return nil, errors.New("test seal: short")
	}
	start := len(dst)
	for _, b := range sealed[:len(sealed)-4] {
		dst = append(dst, b^0xa5)
	}
	if binary.LittleEndian.Uint32(sealed[len(sealed)-4:]) != byteSum(header, dst[start:]) {
		return nil, errors.New("test seal: tag mismatch")
	}
	return dst, nil
}

func sealed(d []byte) []byte {
	return testSeal{}.Seal(d[:HeaderSize:HeaderSize], d[:HeaderSize], d[HeaderSize:])
}

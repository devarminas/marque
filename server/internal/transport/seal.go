package transport

// Seal is the packet-level seam for ADR 0018 section 1.7. ARM-354 fills it
// with ChaCha20-Poly1305. The header travels in clear and is the associated
// data; only the body is transformed. Overhead bytes are reserved inside
// MaxDatagram when packing.
type Seal interface {
	Overhead() int
	// Seal appends the sealed form of body to dst.
	Seal(dst, header, body []byte) []byte
	// Open appends the opened body to dst, or fails if sealed is not
	// authentic for header.
	Open(dst, header, sealed []byte) ([]byte, error)
}

// Plain is the identity Seal used until the handshake exists.
type Plain struct{}

func (Plain) Overhead() int { return 0 }

func (Plain) Seal(dst, _, body []byte) []byte { return append(dst, body...) }

func (Plain) Open(dst, _, sealed []byte) ([]byte, error) { return append(dst, sealed...), nil }

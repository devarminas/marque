package transport

type Opener interface {
	Overhead() int
	Open(dst, header, sealed []byte) ([]byte, error)
}

type Sealer interface {
	Overhead() int
	Seal(dst, header, body []byte) []byte
}

type Plain struct{}

func (Plain) Overhead() int { return 0 }

func (Plain) Seal(dst, _, body []byte) []byte { return append(dst, body...) }

func (Plain) Open(dst, _, sealed []byte) ([]byte, error) { return append(dst, sealed...), nil }

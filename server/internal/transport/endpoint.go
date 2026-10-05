package transport

type Endpoint struct {
	rx *Receiver
	tx *Sender
}

func NewEndpoint(role Role, cfg Config, open Opener, seal Sealer, now uint64) (*Endpoint, error) {
	rx, err := NewReceiver(role, cfg, open)
	if err != nil {
		return nil, err
	}
	tx, err := NewSender(role, cfg, seal, now)
	if err != nil {
		return nil, err
	}
	return &Endpoint{rx: rx, tx: tx}, nil
}

func (e *Endpoint) Receive(d []byte, now uint64) (Received, error) {
	if e.tx.State() != Open {
		return Received{}, ErrClosed
	}
	r, err := e.rx.Receive(d)
	if err == nil {
		e.tx.Observe(r.PeerAck, r.OwnAck, now)
	}
	return r, err
}

func (e *Endpoint) Send(msg []byte) error { return e.tx.Send(msg) }

func (e *Endpoint) Flush(now uint64, u Unreliable) (Flushed, error) { return e.tx.Flush(now, u) }

func (e *Endpoint) State() State { return e.tx.State() }

func (e *Endpoint) Backlog() int { return e.tx.Backlog() }

func (e *Endpoint) Stats() Stats { return e.rx.Stats() }

func (e *Endpoint) SetCapture(capture func(uint64, []byte, []byte)) { e.tx.SetCapture(capture) }

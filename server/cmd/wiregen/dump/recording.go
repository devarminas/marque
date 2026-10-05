package main

import (
	"encoding/binary"
	"fmt"
	"io"

	"github.com/devarminas/marque/server/internal/recording"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
)

type boundedOutput struct {
	out  io.Writer
	left int
}

func (o *boundedOutput) Write(b []byte) (int, error) {
	if len(b) > o.left {
		return 0, fmt.Errorf("dump: output exceeds 16 MiB")
	}
	n, err := o.out.Write(b)
	o.left -= n
	return n, err
}

func dumpRecording(path string, out io.Writer) error {
	f, err := recording.Read(path, wire.SchemaHash)
	if err != nil {
		return err
	}
	for ordinal, r := range f.Records {
		if (r.Kind == recording.Authenticated || r.Kind == recording.Outbound) && (len(r.Payload) < transport.HeaderSize || len(r.Payload)+24 > transport.MaxDatagram) {
			return fmt.Errorf("dump: record %d packet length", ordinal)
		}
	}
	rx, err := transport.NewReceiver(transport.Client, transport.DefaultConfig(wire.SchemaHash), transport.Plain{})
	if err != nil {
		return err
	}
	output := &boundedOutput{out: out, left: 16 * 1024 * 1024}
	if _, err := fmt.Fprintf(output, "recording version 1 schema %016x mode %d origin %d\n", wire.SchemaHash, f.Mode, f.Origin); err != nil {
		return err
	}
	for ordinal, r := range f.Records {
		if r.Kind != recording.Authenticated && r.Kind != recording.Outbound {
			name := map[recording.Kind]string{recording.Begin: "begin", recording.Command: "command", recording.Input: "input", recording.Turn: "turn", recording.Drain: "drain", recording.End: "end"}[r.Kind]
			preview := r.Payload
			if len(preview) > 64 {
				preview = preview[:64]
			}
			if _, err := fmt.Fprintf(output, "record %d time %d %s bytes %d prefix %x\n", ordinal, r.Time, name, len(r.Payload), preview); err != nil {
				return err
			}
			if r.Kind == recording.End {
				if _, err := fmt.Fprintf(output, "end terminal %d records %d bytes %d\n", r.Payload[0], binary.LittleEndian.Uint64(r.Payload[1:]), binary.LittleEndian.Uint64(r.Payload[9:])); err != nil {
					return err
				}
			}
			continue
		}
		got, err := rx.Receive(r.Payload)
		if err != nil {
			if _, writeErr := fmt.Fprintf(output, "record %d time %d refused %v\n", ordinal, r.Time, err); writeErr != nil {
				return writeErr
			}
			continue
		}
		if _, err := fmt.Fprintf(output, "record %d time %d stamp %d stale %t completed %d\n", ordinal, r.Time, got.Unreliable.Stamp, got.Stale, len(got.Reliable)); err != nil {
			return err
		}
		for _, b := range got.Unreliable.Items {
			m, err := wire.DecodeState(b)
			if err != nil {
				if _, writeErr := fmt.Fprintf(output, "state refused %v\n", err); writeErr != nil {
					return writeErr
				}
			} else if _, err := fmt.Fprintf(output, "state s2c %v\n", m); err != nil {
				return err
			}
		}
		for _, b := range got.Reliable {
			m, err := wire.DecodeEvents(b)
			if err != nil {
				if _, writeErr := fmt.Fprintf(output, "events refused %v\n", err); writeErr != nil {
					return writeErr
				}
			} else if _, err := fmt.Fprintf(output, "events s2c %v\n", m); err != nil {
				return err
			}
		}
	}
	_, err = fmt.Fprintln(output, "recording dump complete")
	return err
}

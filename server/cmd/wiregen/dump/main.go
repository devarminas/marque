// Command dump prints encoded wire messages as text.
//
//	go run ./cmd/wiregen/dump <hex> [<hex>...]
//
// It lives apart from wiregen so the generator never imports the package it
// generates; a broken generated package must not stop regeneration.
package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"os"

	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: dump <hex> [<hex>...]")
		os.Exit(2)
	}
	failed := false
	for _, arg := range os.Args[1:] {
		text, err := dump(arg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", arg, err)
			failed = true
			continue
		}
		fmt.Println(text)
	}
	if failed {
		os.Exit(1)
	}
}

// channels pairs each channel's decoder with its direction.
var channels = []struct {
	dir    string
	decode func([]byte) (wire.Message, error)
}{
	{"s2c", func(b []byte) (wire.Message, error) { return wire.DecodeState(b) }},
	{"s2c", func(b []byte) (wire.Message, error) { return wire.DecodeEvents(b) }},
	{"c2s", func(b []byte) (wire.Message, error) { return wire.DecodeInput(b) }},
	{"c2s", func(b []byte) (wire.Message, error) { return wire.DecodeIntents(b) }},
}

// dump tries each channel's decoder. Message ids are unique across channels,
// so at most one decoder knows any id.
func dump(h string) (string, error) {
	b, err := hex.DecodeString(h)
	if err != nil {
		return "", err
	}
	for _, c := range channels {
		m, err := c.decode(b)
		if errors.Is(err, codec.ErrUnknownMessage) {
			continue
		}
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%s %s %v", m.Channel(), c.dir, m), nil
	}
	return "", codec.ErrUnknownMessage
}

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

// dump tries the client-bound decoder first. Message ids are unique across
// both directions, so at most one decoder knows any id.
func dump(h string) (string, error) {
	b, err := hex.DecodeString(h)
	if err != nil {
		return "", err
	}
	if m, err := wire.DecodeToClient(b); !errors.Is(err, codec.ErrUnknownMessage) {
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%s s2c %v", m.Channel(), m), nil
	}
	m, err := wire.DecodeToServer(b)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s c2s %v", m.Channel(), m), nil
}

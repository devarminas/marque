// Command wiregen reads a wire schema and writes the Go and C++ codecs for it.
//
//	wiregen gen [-root <dir>]   write every target's generated files under root
//	wiregen canon [schema]      print the canonical form that SchemaHash hashes
//
// Paths are relative to the repository root, which defaults to the parent of
// the server module (wiregen runs from server/).
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

type target struct {
	schema    string
	goFile    string
	goPkg     string
	cppHeader string
	cppSource string
	cppNS     string
}

var targets = []target{
	{
		schema:    "shared/wire/schema.wire",
		goFile:    "server/internal/wire/schema_gen.go",
		goPkg:     "wire",
		cppHeader: "native/core/include/marque/wire/gen/schema.hpp",
		cppSource: "native/core/src/wire/gen/schema.cpp",
		cppNS:     "marque::wire",
	},
	{
		schema:    "shared/wire/testdata/probe.wire",
		goFile:    "server/internal/wire/probe/probe_gen.go",
		goPkg:     "probe",
		cppHeader: "native/core/include/marque/wire/gen/probe.hpp",
		cppSource: "native/core/src/wire/gen/probe.cpp",
		cppNS:     "marque::wire::probe",
	},
}

const includeRoot = "native/core/include/"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "wiregen:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: wiregen gen [-root dir] | wiregen canon [schema]")
	}
	switch args[0] {
	case "gen":
		fs := flag.NewFlagSet("gen", flag.ContinueOnError)
		root := fs.String("root", "..", "directory the generated paths are written under")
		src := fs.String("src", "..", "repository root the schemas are read from")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		for _, t := range targets {
			if err := generate(t, *src, *root); err != nil {
				return err
			}
		}
		return nil
	case "canon":
		path := filepath.Join("..", targets[0].schema)
		if len(args) > 1 {
			path = args[1]
		}
		s, err := load(path)
		if err != nil {
			return err
		}
		fmt.Print(s.Canonical())
		return nil
	}
	return fmt.Errorf("unknown subcommand %q", args[0])
}

func load(path string) (*Schema, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	s, err := Parse(string(src))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return s, nil
}

func generate(t target, src, root string) error {
	s, err := load(filepath.Join(src, t.schema))
	if err != nil {
		return err
	}
	goSrc, err := genGo(s, t.schema, t.goPkg)
	if err != nil {
		return err
	}
	header := t.cppHeader[len(includeRoot):]
	files := map[string][]byte{
		t.goFile:    goSrc,
		t.cppHeader: genCppHeader(s, t.schema, t.cppNS),
		t.cppSource: genCppSource(s, t.schema, t.cppNS, header),
	}
	for path, body := range files {
		full := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, body, 0o644); err != nil {
			return err
		}
	}
	return nil
}

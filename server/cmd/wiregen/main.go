// Command wiregen reads a wire schema and writes the Go and C++ codecs for it.
//
//	wiregen gen [-root <dir>]   write every target's generated files under root
//	wiregen canon [schema]      print the canonical form that SchemaHash hashes
//
// gen also copies shared/wire/vectors into the server module, because go test
// caches results across edits to files outside the module but tracks files a
// test embeds. scripts/wiregen_check.sh then fails on a stale copy.
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

const (
	vectorSrc  = "shared/wire/vectors"
	vectorCopy = "server/internal/wire/testdata/vectors"
)

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
		return copyVectors(*src, *root)
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
	return writeAll(root, files)
}

func writeAll(root string, files map[string][]byte) error {
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

func copyVectors(src, root string) error {
	paths, err := filepath.Glob(filepath.Join(src, vectorSrc, "*.vec"))
	if err != nil {
		return err
	}
	files := map[string][]byte{}
	for _, p := range paths {
		body, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		// Byte-identical, so a test failure's line number is also the line in
		// shared/wire/vectors.
		files[filepath.Join(vectorCopy, filepath.Base(p))] = body
	}
	return writeAll(root, files)
}

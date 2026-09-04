// Command marqued is the Project Marque game server.
//
// It accepts WebSocket connections, runs the tick loop, and writes an NDJSON
// event log to stdout. Items live in memory and do not survive a restart; there
// is no database and no accounts.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

// itemSeed is one -item flag occurrence: an item to place before the world
// opens.
type itemSeed struct {
	kind string
	x, z float64
}

// itemSeeds collects repeated -item flags in the order they were given, which
// is the order the items enter the world and therefore the order of their ids.
//
// Syntax is "x,z" or "x,z,kind", so "-item 3,-2" and "-item 3,-2,acorn" name
// the same acorn. Zero occurrences is an empty world, which is what M0 had.
type itemSeeds []itemSeed

func (s *itemSeeds) String() string {
	parts := make([]string, 0, len(*s))
	for _, seed := range *s {
		parts = append(parts, fmt.Sprintf("%v,%v,%s", seed.x, seed.z, seed.kind))
	}
	return strings.Join(parts, " ")
}

// Set parses one occurrence. It checks syntax only: whether the coordinate is
// inside the world is the world's question, asked when the seed is applied.
func (s *itemSeeds) Set(value string) error {
	fields := strings.Split(value, ",")
	if len(fields) != 2 && len(fields) != 3 {
		return fmt.Errorf("want x,z or x,z,kind, got %q", value)
	}
	x, err := strconv.ParseFloat(strings.TrimSpace(fields[0]), 64)
	if err != nil {
		return fmt.Errorf("x in %q: %w", value, err)
	}
	z, err := strconv.ParseFloat(strings.TrimSpace(fields[1]), 64)
	if err != nil {
		return fmt.Errorf("z in %q: %w", value, err)
	}
	kind := game.KindAcorn
	if len(fields) == 3 {
		kind = strings.TrimSpace(fields[2])
		if kind == "" {
			return fmt.Errorf("kind in %q is empty", value)
		}
	}
	*s = append(*s, itemSeed{kind: kind, x: x, z: z})
	return nil
}

// shutdownGrace bounds how long a shutdown waits for HTTP handlers to return
// after their connections have been closed.
const shutdownGrace = 5 * time.Second

// wsPath is the only endpoint. Everything the protocol can express goes over
// this one socket.
const wsPath = "/ws"

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "marqued: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	addr := flag.String("addr", "127.0.0.1:8080", "host:port to listen on")
	enableLog := flag.Bool("gamelog", true, "write the NDJSON event log to stdout")
	var seeds itemSeeds
	flag.Var(&seeds, "item", "place a ground item at x,z (or x,z,kind; kind defaults to \""+game.KindAcorn+"\").\nRepeat the flag for more items. Omit it entirely for an empty world.")
	flag.Parse()

	log := gamelog.New(os.Stdout, *enableLog)
	hub := mnet.NewHub()
	world := game.NewWorld(hub, log, game.NewMemoryStore(), game.ResumeGraceTicks)

	// Bind before announcing anything, so a port clash fails immediately and
	// visibly instead of after a log line claiming the server started.
	listener, err := net.Listen("tcp", *addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", *addr, err)
	}

	mux := http.NewServeMux()
	mux.Handle(wsPath, hub)
	srv := &http.Server{Handler: mux}

	// Tick zero. Everything the log's readers need to interpret the run that
	// follows is stated once, here.
	log.Event(0, game.EvServerStarted, gamelog.Fields{
		"addr":              listener.Addr().String(),
		"path":              wsPath,
		"tick_ms":           int(game.TickDuration.Milliseconds()),
		"walk_speed":        game.WalkSpeed,
		"world_half_extent": game.WorldHalfExtent,
		"inventory_size":    game.InventorySize,
		"resume_grace":      game.ResumeGraceTicks,
		"seeded_items":      len(seeds),
	})

	// Seeding happens after the line that explains the run and before anything
	// is served, so the log opens the same way it always has and every
	// item_spawned line that follows is already interpretable. A seed the world
	// refuses is a startup failure: no client has connected, and an item
	// outside the bounds is one no player could legally walk to.
	for _, seed := range seeds {
		if err := world.SeedGroundItem(seed.kind, seed.x, seed.z); err != nil {
			return err
		}
	}

	signalCtx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	worldCtx, stopWorld := context.WithCancel(signalCtx)
	defer stopWorld()

	var running sync.WaitGroup
	running.Add(1)
	go func() {
		defer running.Done()
		world.Run(worldCtx)
	}()

	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(listener) }()

	var exitErr error
	select {
	case <-signalCtx.Done():
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			exitErr = fmt.Errorf("serve: %w", err)
		}
	}

	// Stop trapping signals first: a second interrupt during shutdown should
	// kill the process outright rather than be swallowed.
	stopSignals()
	stopWorld()

	// Close sockets before Shutdown. A WebSocket handler blocks for the life of
	// its connection, so Shutdown would otherwise wait out the whole grace
	// period with live clients attached.
	hub.Close()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil && exitErr == nil {
		exitErr = fmt.Errorf("shutdown: %w", err)
	}
	running.Wait()

	return exitErr
}

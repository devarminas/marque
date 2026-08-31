// Command marqued is the Project Marque game server.
//
// It accepts WebSocket connections, runs the tick loop, and writes an NDJSON
// event log to stdout. M0 has no database, no accounts, and no items.
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
	"sync"
	"syscall"
	"time"

	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

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
	flag.Parse()

	log := gamelog.New(os.Stdout, *enableLog)
	hub := mnet.NewHub()
	world := game.NewWorld(hub, log)

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
	})

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

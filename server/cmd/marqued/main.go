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

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

type itemSeed struct {
	kind string
	x, z float64
}

type itemSeeds []itemSeed

func (s *itemSeeds) String() string {
	parts := make([]string, 0, len(*s))
	for _, seed := range *s {
		parts = append(parts, fmt.Sprintf("%v,%v,%s", seed.x, seed.z, seed.kind))
	}
	return strings.Join(parts, " ")
}

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

const shutdownGrace = 5 * time.Second

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
	abilitiesPath := flag.String("abilities", "", "path to shared/abilities.json (default: search from cwd, or MARQUE_ABILITIES)")
	questsPath := flag.String("quests", "", "path to shared/quests.json (default: search from cwd, or MARQUE_QUESTS)")
	friendlyHP := flag.Int("friendly-hp", 0, "if >0, set seeded friendly practice dummy HP after spawn (demo harness)")
	seedClassKits := flag.Bool("seed-class-kits", false, "place one ground item per unique kind from shared/sets.json (armor + tools) on a grid near spawn for class demo/test; does not change DefaultJoinKit")
	var seeds itemSeeds
	flag.Var(&seeds, "item", "place a ground item at x,z (or x,z,kind; kind defaults to \""+game.KindAcorn+"\").\nRepeat the flag for more items. Omit it entirely for an empty world. Combines with -seed-class-kits.")
	flag.Parse()

	path := strings.TrimSpace(*abilitiesPath)
	if path == "" {
		resolved, err := abilitydef.ResolvePath()
		if err != nil {
			return err
		}
		path = resolved
	}
	abilities, err := abilitydef.Load(path)
	if err != nil {
		return err
	}

	classes, err := classdef.LoadAll()
	if err != nil {
		return err
	}
	wearables, err := classes.Wearables()
	if err != nil {
		return err
	}

	qpath := strings.TrimSpace(*questsPath)
	if qpath == "" {
		resolved, err := questdef.ResolvePath()
		if err != nil {
			return err
		}
		qpath = resolved
	}
	quests, err := questdef.Load(qpath, classes)
	if err != nil {
		return err
	}

	log := gamelog.New(os.Stdout, *enableLog)
	hub := mnet.NewHub()
	world := game.NewWorld(hub, log, game.NewMemoryStore(wearables), game.ResumeGraceTicks, game.DefaultJoinKit)
	world.SetAbilities(abilities)
	world.SetClasses(classes)
	world.SetQuests(quests)

	var groundSeeds itemSeeds
	var classKitFields []gamelog.Fields
	if *seedClassKits {
		for _, s := range game.ClassKitSeeds(classes) {
			groundSeeds = append(groundSeeds, itemSeed{kind: s.Kind, x: s.X, z: s.Z})
			classKitFields = append(classKitFields, gamelog.Fields{
				"kind": s.Kind, "x": s.X, "z": s.Z,
			})
		}
	}
	groundSeeds = append(groundSeeds, seeds...)

	listener, err := net.Listen("tcp", *addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", *addr, err)
	}

	mux := http.NewServeMux()
	mux.Handle(wsPath, hub)
	srv := &http.Server{Handler: mux}

	started := gamelog.Fields{
		"addr":              listener.Addr().String(),
		"path":              wsPath,
		"tick_ms":           int(game.TickDuration.Milliseconds()),
		"walk_speed":        game.WalkSpeed,
		"world_half_extent": game.WorldHalfExtent,
		"inventory_size":    game.InventorySize,
		"resume_grace":      game.ResumeGraceTicks,
		"seeded_items":      len(groundSeeds),
		"seed_class_kits":   *seedClassKits,
		"join_kit":          game.DefaultJoinKit,
		"worn_slots":        game.WornSlots,
		"abilities":         abilities.Len(),
		"abilities_path":    path,
		"quests":            quests.Len(),
		"quests_path":       qpath,
		"classes":           classes.ClassLen(),
		"skills":            classes.SkillLen(),
	}
	if *seedClassKits {
		started["class_kit_seeds"] = classKitFields
	}
	log.Event(0, game.EvServerStarted, started)

	for _, seed := range groundSeeds {
		if err := world.SeedGroundItem(seed.kind, seed.x, seed.z); err != nil {
			return err
		}
	}
	if err := world.SeedResourceNode(game.KindTree, game.SeedTreeX, game.SeedTreeZ); err != nil {
		return err
	}
	if err := world.SeedPracticeDummies(); err != nil {
		return err
	}
	if err := world.SeedQuestGiver(); err != nil {
		return err
	}
	if *friendlyHP > 0 {
		if err := world.SetNPCHitPointsByFaction(game.FactionFriendly, *friendlyHP); err != nil {
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

	stopSignals()
	stopWorld()

	hub.Close()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil && exitErr == nil {
		exitErr = fmt.Errorf("shutdown: %w", err)
	}
	running.Wait()

	return exitErr
}

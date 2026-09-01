package net_test

// Test harness: a real server, real WebSocket clients, real frames. Nothing
// here mocks the transport, because the assumption M0a exists to retire is that
// two clients connected to one server see each other move.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
)

const (
	// readTimeout bounds a read that is expected to succeed. Generous relative
	// to the 150ms tick so a loaded CI box does not fail an honest test.
	readTimeout = 5 * time.Second
	// silenceWindow is how long "nothing arrives" is observed for. Several
	// ticks, so a broadcast that was going to happen has happened.
	silenceWindow = 5 * game.TickDuration
	// awaitPoll is how often the event log is re-read while waiting for a line.
	awaitPoll = 5 * time.Millisecond
	// frameBuffer is how far ahead a client's reader may run of the test
	// consuming it. Deep enough that a test which ignores its stream for a while
	// does not stall the reader and hide a later assertion.
	frameBuffer = 1024
)

// syncBuffer collects the event log. The world goroutine writes it and the test
// goroutine reads it, so it is mutex-guarded; without that the race detector
// would be reporting the harness rather than the server.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer

	// hook, when set, runs on the goroutine doing the write, with the line just
	// written. The world goroutine is the only thing that writes this log, so a
	// hook that blocks is the one lever a test has on how long that goroutine
	// spends away from its ticker. TestCatchUpBoundHoldsUnderAStalledLoop is
	// the only user; nothing else needs the tick loop to fall behind.
	hook func(line []byte)
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	hook := s.hook
	n, err := s.buf.Write(p)
	s.mu.Unlock()

	// Outside the lock, and after the line has landed: a blocking hook must not
	// also block String, which the test goroutine polls while it waits.
	if hook != nil {
		hook(p)
	}
	return n, err
}

// onWrite installs the write hook. Called from the test goroutine before the
// world has anything to say.
func (s *syncBuffer) onWrite(hook func(line []byte)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hook = hook
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

type harness struct {
	t       *testing.T
	server  *httptest.Server
	hub     *mnet.Hub
	logs    *syncBuffer
	stop    context.CancelFunc
	stopped chan struct{}
	once    sync.Once
}

// seed is one ground item placed before the world opens, the way marqued's
// -item flag places one. Ids are assigned in the order given, so a test naming
// item 1 means the first seed it passed.
type seed struct {
	kind string
	x, z float64
}

func acornAt(x, z float64) seed { return seed{kind: game.KindAcorn, x: x, z: z} }

// newHarness boots hub, world, and HTTP server exactly the way cmd/marqued
// does, seeds any items it was given, and tears everything down in the same
// order marqued does.
func newHarness(t *testing.T, seeds ...seed) *harness {
	t.Helper()

	logs := &syncBuffer{}
	hub := mnet.NewHub()
	world := game.NewWorld(hub, gamelog.New(logs, true), game.NewMemoryStore())

	// Before Run, which is the only time seeding is safe: after it, the world
	// goroutine owns the store.
	for _, s := range seeds {
		if err := world.SeedGroundItem(s.kind, s.x, s.z); err != nil {
			t.Fatalf("seeding %+v: %v", s, err)
		}
	}

	mux := http.NewServeMux()
	mux.Handle("/ws", hub)

	ctx, stop := context.WithCancel(context.Background())
	h := &harness{
		t:       t,
		server:  httptest.NewServer(mux),
		hub:     hub,
		logs:    logs,
		stop:    stop,
		stopped: make(chan struct{}),
	}
	go func() {
		defer close(h.stopped)
		world.Run(ctx)
	}()

	t.Cleanup(h.shutdown)
	return h
}

// shutdown mirrors the server's own sequence: stop the world, close the
// sockets so the blocked handlers return, then close the HTTP server.
func (h *harness) shutdown() {
	h.once.Do(func() {
		h.stop()
		h.hub.Close()
		h.server.Close()
		select {
		case <-h.stopped:
		case <-time.After(readTimeout):
			h.t.Error("world goroutine did not return after its context was cancelled")
		}
	})
}

func (h *harness) wsURL() string {
	return "ws" + strings.TrimPrefix(h.server.URL, "http") + "/ws"
}

func (h *harness) dial(name string) *client {
	h.t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	ws, _, err := websocket.Dial(ctx, h.wsURL(), nil)
	if err != nil {
		h.t.Fatalf("client %s: dial %s: %v", name, h.wsURL(), err)
	}
	h.t.Cleanup(func() { _ = ws.CloseNow() })

	c := &client{t: h.t, ws: ws, name: name, frames: make(chan frame, frameBuffer)}
	go c.readPump()
	return c
}

// logEvents parses the NDJSON event log, asserting the shape the acceptance
// criterion names: every line carries the prefix, and what follows it is one
// valid JSON object per line.
func (h *harness) logEvents() []map[string]any {
	h.t.Helper()

	var events []map[string]any
	for _, line := range strings.Split(h.logs.String(), "\n") {
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, gamelog.Prefix) {
			h.t.Fatalf("log line lacks the %q prefix: %s", gamelog.Prefix, line)
		}
		var obj map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, gamelog.Prefix)), &obj); err != nil {
			h.t.Fatalf("log line is not valid JSON: %s: %v", line, err)
		}
		if _, ok := obj["t"]; !ok {
			h.t.Fatalf("log line has no tick number: %s", line)
		}
		if _, ok := obj["ev"]; !ok {
			h.t.Fatalf("log line has no event name: %s", line)
		}
		events = append(events, obj)
	}
	return events
}

func (h *harness) eventsNamed(name string) []map[string]any {
	h.t.Helper()

	var matched []map[string]any
	for _, ev := range h.logEvents() {
		if ev["ev"] == name {
			matched = append(matched, ev)
		}
	}
	return matched
}

// awaitEvents waits for at least count log lines named name. The log is written
// by the world goroutine, so a test that checks it immediately after sending a
// frame is checking before the server has read it.
func (h *harness) awaitEvents(name string, count int) []map[string]any {
	h.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for {
		matched := h.eventsNamed(name)
		if len(matched) >= count {
			return matched
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("waited %v for %d %q events, saw %d\nlog:\n%s",
				readTimeout, count, name, len(matched), h.logs.String())
		}
		time.Sleep(awaitPoll)
	}
}

// client is one real WebSocket client.
//
// A single goroutine owns the socket's read side and publishes decoded frames
// on a channel. Two things force that shape. The library allows only one
// concurrent reader, and cancelling the context of a read closes the
// connection, so a test that waits for a frame that never comes would otherwise
// disconnect the very client it is making an assertion about.
type client struct {
	t      *testing.T
	ws     *websocket.Conn
	name   string
	frames chan frame
}

// frame is a decoded server message. Every field but one is nil, which is what
// makes it a usable assertion about the key-as-tag envelope.
type frame struct {
	Welcome     *mnet.Welcome     `json:"welcome"`
	Spawn       *mnet.Spawn       `json:"spawn"`
	Despawn     *mnet.Despawn     `json:"despawn"`
	Path        *mnet.Path        `json:"path"`
	Error       *mnet.Error       `json:"error"`
	ItemSpawn   *mnet.ItemSpawn   `json:"item_spawn"`
	ItemDespawn *mnet.ItemDespawn `json:"item_despawn"`
	Inventory   *mnet.Inventory   `json:"inventory"`

	raw string
	// bad is set when the frame broke an envelope rule. The reader goroutine
	// cannot fail a test, so it reports the problem and the test goroutine
	// fails on it.
	bad string
}

func (f frame) kind() string {
	switch {
	case f.Welcome != nil:
		return "welcome"
	case f.Spawn != nil:
		return "spawn"
	case f.Despawn != nil:
		return "despawn"
	case f.Path != nil:
		return "path"
	case f.Error != nil:
		return "error"
	case f.ItemSpawn != nil:
		return "item_spawn"
	case f.ItemDespawn != nil:
		return "item_despawn"
	case f.Inventory != nil:
		return "inventory"
	default:
		return "none"
	}
}

// readPump owns the socket's read side for the client's whole life. It closes
// the frame channel when the connection ends, which is how a test observes that
// the server hung up.
func (c *client) readPump() {
	defer close(c.frames)

	for {
		typ, data, err := c.ws.Read(context.Background())
		if err != nil {
			return
		}
		c.frames <- parseFrame(typ, data)
	}
}

// parseFrame checks one inbound frame against the envelope rules: a text frame,
// carrying one JSON object, with exactly one key, and that key naming a message.
func parseFrame(typ websocket.MessageType, data []byte) frame {
	f := frame{raw: string(data)}

	if typ != websocket.MessageText {
		f.bad = fmt.Sprintf("got a %v frame, want text", typ)
		return f
	}

	var keys map[string]json.RawMessage
	if err := json.Unmarshal(data, &keys); err != nil {
		f.bad = fmt.Sprintf("not a JSON object: %v", err)
		return f
	}
	if len(keys) != 1 {
		f.bad = fmt.Sprintf("has %d keys, want exactly 1", len(keys))
		return f
	}
	if err := json.Unmarshal(data, &f); err != nil {
		f.bad = fmt.Sprintf("cannot decode: %v", err)
		return f
	}
	if f.kind() == "none" {
		f.bad = "names no known message"
	}
	return f
}

func (c *client) sendRaw(payload string) {
	c.t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	if err := c.ws.Write(ctx, websocket.MessageText, []byte(payload)); err != nil {
		c.t.Fatalf("client %s: write %s: %v", c.name, payload, err)
	}
}

func (c *client) sendBinary(payload []byte) {
	c.t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	if err := c.ws.Write(ctx, websocket.MessageBinary, payload); err != nil {
		c.t.Fatalf("client %s: write binary frame: %v", c.name, err)
	}
}

func (c *client) pickup(item mnet.ItemID) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"pickup":{"item":%d}}`, item))
}

func (c *client) moveTo(x, z float64) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"move_to":{"x":%v,"z":%v}}`, x, z))
}

func (c *client) next() frame {
	c.t.Helper()

	f, ok := c.tryNext(readTimeout)
	if !ok {
		c.t.Fatalf("client %s: nothing arrived within %v", c.name, readTimeout)
	}
	return f
}

// collect returns every frame that arrives within the window. Used where the
// interesting assertion is about the whole set rather than the next one.
func (c *client) collect(window time.Duration) []frame {
	c.t.Helper()

	var frames []frame
	for {
		f, ok := c.tryNext(window)
		if !ok {
			return frames
		}
		frames = append(frames, f)
	}
}

// tryNext takes the next frame, reporting false if none arrives in time or the
// connection has ended.
func (c *client) tryNext(within time.Duration) (frame, bool) {
	c.t.Helper()

	timer := time.NewTimer(within)
	defer timer.Stop()

	select {
	case f, open := <-c.frames:
		if !open {
			return frame{}, false
		}
		if f.bad != "" {
			c.t.Fatalf("client %s: bad frame: %s: %s", c.name, f.bad, f.raw)
		}
		return f, true
	case <-timer.C:
		return frame{}, false
	}
}

func (c *client) welcome() mnet.Welcome {
	c.t.Helper()
	got := c.welcomeFrame()
	// The joining player's own inventory is the last frame of the atomic
	// welcome step. A test that expects a path replay in between must read the
	// step a frame at a time with welcomeFrame; everything else joins a world
	// with nobody walking, where welcome and inventory are adjacent.
	c.inventory()
	return got
}

// welcomeFrame reads only the welcome, leaving the rest of the join step queued.
func (c *client) welcomeFrame() mnet.Welcome {
	c.t.Helper()
	f := c.next()
	if f.Welcome == nil {
		c.t.Fatalf("client %s: got a %s frame, want welcome: %s", c.name, f.kind(), f.raw)
	}
	return *f.Welcome
}

func (c *client) path() mnet.Path {
	c.t.Helper()
	f := c.next()
	if f.Path == nil {
		c.t.Fatalf("client %s: got a %s frame, want path: %s", c.name, f.kind(), f.raw)
	}
	return *f.Path
}

func (c *client) spawn() mnet.Spawn {
	c.t.Helper()
	f := c.next()
	if f.Spawn == nil {
		c.t.Fatalf("client %s: got a %s frame, want spawn: %s", c.name, f.kind(), f.raw)
	}
	return *f.Spawn
}

func (c *client) errorFrame() mnet.Error {
	c.t.Helper()
	f := c.next()
	if f.Error == nil {
		c.t.Fatalf("client %s: got a %s frame, want error: %s", c.name, f.kind(), f.raw)
	}
	return *f.Error
}

// awaitError reads until an error arrives, ignoring everything else. A refusal
// that follows a broadcast, such as a lost pickup's halt path, is not the next
// frame the client sees.
func (c *client) awaitError() mnet.Error {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(readTimeout)
		if !ok {
			break
		}
		if f.Error != nil {
			return *f.Error
		}
	}
	c.t.Fatalf("client %s: no error frame within %v", c.name, readTimeout)
	return mnet.Error{}
}

func (c *client) inventory() mnet.Inventory {
	c.t.Helper()
	f := c.next()
	if f.Inventory == nil {
		c.t.Fatalf("client %s: got a %s frame, want inventory: %s", c.name, f.kind(), f.raw)
	}
	return *f.Inventory
}

// awaitInventory reads until an inventory arrives, ignoring everything else. A
// pickup resolving broadcasts a despawn to every client before it unicasts the
// winner's inventory, so the winner sees traffic in between.
func (c *client) awaitInventory() mnet.Inventory {
	c.t.Helper()
	return *c.awaitInventoryFrame().Inventory
}

// awaitInventoryFrame is awaitInventory keeping the raw JSON, for the
// assertions that are about the encoding rather than the values.
func (c *client) awaitInventoryFrame() frame {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(readTimeout)
		if !ok {
			break
		}
		if f.Inventory != nil {
			return f
		}
	}
	c.t.Fatalf("client %s: no inventory within %v", c.name, readTimeout)
	return frame{}
}

// awaitItemDespawn reads until the named item is announced gone.
func (c *client) awaitItemDespawn(item mnet.ItemID) mnet.ItemDespawn {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(readTimeout)
		if !ok {
			break
		}
		if f.ItemDespawn != nil && f.ItemDespawn.ID == item {
			return *f.ItemDespawn
		}
	}
	c.t.Fatalf("client %s: no item_despawn for item %d within %v", c.name, item, readTimeout)
	return mnet.ItemDespawn{}
}

func (c *client) despawn() mnet.Despawn {
	c.t.Helper()
	f := c.next()
	if f.Despawn == nil {
		c.t.Fatalf("client %s: got a %s frame, want despawn: %s", c.name, f.kind(), f.raw)
	}
	return *f.Despawn
}

// awaitPath reads until a path for the given player arrives, ignoring frames
// about anyone else. For tests where other clients are churning in the
// background and their spawns and despawns are noise.
func (c *client) awaitPath(id mnet.PlayerID) mnet.Path {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(readTimeout)
		if !ok {
			break
		}
		if f.Path != nil && f.Path.ID == id {
			return *f.Path
		}
	}
	c.t.Fatalf("client %s: no path for player %d within %v", c.name, id, readTimeout)
	return mnet.Path{}
}

// awaitHaltPath reads until a one-point path for the given player arrives.
//
// Getting a walking player to halt takes a click that lands inside one tick, so
// an observer sees the ordinary paths of the attempts that missed before it
// sees the halt.
func (c *client) awaitHaltPath(id mnet.PlayerID) mnet.Path {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(readTimeout)
		if !ok {
			break
		}
		if f.Path != nil && f.Path.ID == id && len(f.Path.Points) == 1 {
			return *f.Path
		}
	}
	c.t.Fatalf("client %s: no halt path for player %d within %v", c.name, id, readTimeout)
	return mnet.Path{}
}

// expectSilence asserts that nothing arrives for the length of the silence
// window. Proving a broadcast did not happen is the only way to test a
// rejection, and no positive assertion can show it.
func (c *client) expectSilence() {
	c.t.Helper()

	if f, ok := c.tryNext(silenceWindow); ok {
		c.t.Fatalf("client %s: expected no frame, got %s", c.name, f.raw)
	}
}

// expectClosed asserts the server hung up, and that nothing arrives afterwards.
func (c *client) expectClosed() {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		select {
		case _, open := <-c.frames:
			if !open {
				return
			}
		case <-time.After(awaitPoll):
		}
	}
	c.t.Fatalf("client %s: connection is still open after %v", c.name, readTimeout)
}

// drain takes everything queued, so a later assertion starts from a known-empty
// stream.
func (c *client) drain() {
	c.t.Helper()
	c.collect(silenceWindow)
}

// drainUntil discards frames from another goroutine, so a client under load
// keeps up and is not dropped for being slow.
//
// It touches nothing belonging to *testing.T, because only the test's own
// goroutine may do that.
func (c *client) drainUntil(stop <-chan struct{}) {
	for {
		select {
		case <-stop:
			return
		case _, open := <-c.frames:
			if !open {
				return
			}
		}
	}
}

func (c *client) close() {
	c.t.Helper()
	if err := c.ws.Close(websocket.StatusNormalClosure, "test done"); err != nil {
		c.t.Fatalf("client %s: close: %v", c.name, err)
	}
}

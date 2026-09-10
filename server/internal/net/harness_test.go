package net_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/gamelog"
	mnet "github.com/devarminas/marque/server/internal/net"
	"github.com/devarminas/marque/server/internal/questdef"
)

const (
	readTimeout   = 5 * time.Second
	silenceWindow = 5 * game.TickDuration
	awaitPoll     = 5 * time.Millisecond
	frameBuffer   = 1024
)

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer

	hook func(line []byte)
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	hook := s.hook
	n, err := s.buf.Write(p)
	s.mu.Unlock()

	if hook != nil {
		hook(p)
	}
	return n, err
}

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

type seed struct {
	kind string
	x, z float64
}

func acornAt(x, z float64) seed { return seed{kind: game.KindAcorn, x: x, z: z} }

func mustResolveQuests(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	return filepath.Join(root, filepath.FromSlash(questdef.RelPath))
}

func newHarness(t *testing.T, seeds ...seed) *harness {
	t.Helper()
	return newHarnessWith(t, game.ResumeGraceTicks, nil, seeds...)
}

func newHarnessWithGrace(t *testing.T, grace int64, seeds ...seed) *harness {
	t.Helper()
	return newHarnessWith(t, grace, nil, seeds...)
}

func newHarnessWithKit(t *testing.T, kit []string, seeds ...seed) *harness {
	t.Helper()
	return newHarnessWith(t, game.ResumeGraceTicks, kit, seeds...)
}

func newHarnessWithSetup(t *testing.T, kit []string, setup func(*game.World), seeds ...seed) *harness {
	t.Helper()
	return newHarnessConfigured(t, game.ResumeGraceTicks, kit, setup, seeds...)
}

func newHarnessWith(t *testing.T, grace int64, kit []string, seeds ...seed) *harness {
	t.Helper()
	return newHarnessConfigured(t, grace, kit, nil, seeds...)
}

func newHarnessConfigured(t *testing.T, grace int64, kit []string, setup func(*game.World), seeds ...seed) *harness {
	t.Helper()

	logs := &syncBuffer{}
	hub := mnet.NewHub()

	classes, err := classdef.LoadAll()
	if err != nil {
		t.Fatalf("load shared class tables: %v", err)
	}
	wearables, err := classes.Wearables()
	if err != nil {
		t.Fatalf("derive wearables: %v", err)
	}
	world := game.NewWorld(hub, gamelog.New(logs, true), game.NewMemoryStore(wearables), grace, kit)
	world.SetClasses(classes)
	quests, err := questdef.Load(mustResolveQuests(t), classes)
	if err != nil {
		t.Fatalf("load quests: %v", err)
	}
	world.SetQuests(quests)
	if err := world.SeedQuestGiver(); err != nil {
		t.Fatalf("seed quest giver: %v", err)
	}
	if setup != nil {
		setup(world)
	}

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

type backgroundErr struct {
	errs chan error
}

func newBackgroundErr() *backgroundErr { return &backgroundErr{errs: make(chan error, 1)} }

func (b *backgroundErr) report(err error) {
	select {
	case b.errs <- err:
	default:
	}
}

func (b *backgroundErr) check(t *testing.T) {
	t.Helper()

	select {
	case err := <-b.errs:
		t.Fatalf("background goroutine: %v", err)
	default:
	}
}

func (h *harness) churnOnce() error {
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	ws, _, err := websocket.Dial(ctx, h.wsURL(), nil)
	if err != nil {
		return fmt.Errorf("churn: dial %s: %w", h.wsURL(), err)
	}
	defer func() { _ = ws.CloseNow() }()

	typ, data, err := ws.Read(ctx)
	if err != nil {
		return nil
	}
	f := parseFrame(typ, data)
	if f.bad != "" {
		return fmt.Errorf("churn: bad frame: %s: %s", f.bad, f.raw)
	}
	if f.Welcome == nil {
		return fmt.Errorf("churn: got a %s frame, want welcome: %s", f.kind(), f.raw)
	}

	wants := []string{"inventory", "equipment", "class", "skills", "quest_log"}
	for _, name := range wants {
		for {
			typ, data, err := ws.Read(ctx)
			if err != nil {
				return nil
			}
			g := parseFrame(typ, data)
			if g.bad != "" {
				return fmt.Errorf("churn: bad frame: %s: %s", g.bad, g.raw)
			}
			if g.kind() == name {
				break
			}
		}
	}

	if err := ws.Write(ctx, websocket.MessageText, []byte(`{"move":{"dx":1,"dz":0}}`)); err != nil {
		return nil
	}
	if err := ws.Close(websocket.StatusNormalClosure, "test done"); err != nil {
		return nil
	}
	return nil
}

func (h *harness) dial(name string) *client {
	h.t.Helper()
	return h.dialURL(name, h.wsURL())
}

func (h *harness) dialResume(name, token string) *client {
	h.t.Helper()
	return h.dialURL(name, h.wsURL()+"?"+mnet.SessionParam+"="+url.QueryEscape(token))
}

func (h *harness) dialURL(name, target string) *client {
	h.t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	ws, _, err := websocket.Dial(ctx, target, nil)
	if err != nil {
		h.t.Fatalf("client %s: dial %s: %v", name, target, err)
	}
	h.t.Cleanup(func() { _ = ws.CloseNow() })

	c := &client{t: h.t, ws: ws, name: name, frames: make(chan frame, frameBuffer)}
	go c.readPump()
	return c
}

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

func (h *harness) awaitEvents(name string, count int) []map[string]any {
	h.t.Helper()
	return h.awaitEventsWithin(name, count, readTimeout)
}

func (h *harness) awaitEventsWithin(name string, count int, within time.Duration) []map[string]any {
	h.t.Helper()

	deadline := time.Now().Add(within)
	for {
		matched := h.eventsNamed(name)
		if len(matched) >= count {
			return matched
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("waited %v for %d %q events, saw %d\nlog:\n%s",
				within, count, name, len(matched), h.logs.String())
		}
		time.Sleep(awaitPoll)
	}
}

type client struct {
	t      *testing.T
	ws     *websocket.Conn
	name   string
	id     mnet.PlayerID
	x, z   float64
	frames chan frame
}

type frame struct {
	Welcome     *mnet.Welcome     `json:"welcome"`
	Spawn       *mnet.Spawn       `json:"spawn"`
	Despawn     *mnet.Despawn     `json:"despawn"`
	Path        *mnet.Path        `json:"path"`
	Pose        *mnet.Pose        `json:"pose"`
	Error       *mnet.Error       `json:"error"`
	ItemSpawn   *mnet.ItemSpawn   `json:"item_spawn"`
	ItemDespawn *mnet.ItemDespawn `json:"item_despawn"`
	NodeSpawn   *mnet.NodeSpawn   `json:"node_spawn"`
	NodeDespawn *mnet.NodeDespawn `json:"node_despawn"`
	NodeState   *mnet.NodeUpdate  `json:"node_state"`
	NpcSpawn    *mnet.NpcSpawn    `json:"npc_spawn"`
	Inventory   *mnet.Inventory   `json:"inventory"`
	Equipment   *mnet.Equipment   `json:"equipment"`
	Class       *mnet.Class       `json:"class"`
	Skills      *mnet.Skills      `json:"skills"`
	Dialog      *mnet.Dialog      `json:"dialog"`
	QuestLog    *mnet.QuestLog    `json:"quest_log"`
	HP          *mnet.HP          `json:"hp"`
	Mana        *mnet.Mana        `json:"mana"`
	Tick        *mnet.Tick        `json:"tick"`

	raw string
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
	case f.Pose != nil:
		return "pose"
	case f.Error != nil:
		return "error"
	case f.ItemSpawn != nil:
		return "item_spawn"
	case f.ItemDespawn != nil:
		return "item_despawn"
	case f.NodeSpawn != nil:
		return "node_spawn"
	case f.NodeDespawn != nil:
		return "node_despawn"
	case f.NodeState != nil:
		return "node_state"
	case f.NpcSpawn != nil:
		return "npc_spawn"
	case f.Inventory != nil:
		return "inventory"
	case f.Equipment != nil:
		return "equipment"
	case f.Class != nil:
		return "class"
	case f.Skills != nil:
		return "skills"
	case f.Dialog != nil:
		return "dialog"
	case f.QuestLog != nil:
		return "quest_log"
	case f.HP != nil:
		return "hp"
	case f.Mana != nil:
		return "mana"
	case f.Tick != nil:
		return "tick"
	default:
		return "none"
	}
}

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

func (c *client) move(dx, dz float64) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"move":{"dx":%v,"dz":%v}}`, dx, dz))
}

func (c *client) moveBackground(dx, dz float64) error {
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()

	payload := fmt.Sprintf(`{"move":{"dx":%v,"dz":%v}}`, dx, dz)
	if err := c.ws.Write(ctx, websocket.MessageText, []byte(payload)); err != nil {
		return fmt.Errorf("client %s: write %s: %w", c.name, payload, err)
	}
	return nil
}

func (c *client) walkTo(x, z float64) {
	c.t.Helper()
	step := game.WalkSpeed * game.TickDuration.Seconds()
	travel := time.Duration(math.Ceil(math.Hypot(x-c.x, z-c.z)/game.WalkSpeed)*1000) * time.Millisecond
	deadline := time.Now().Add(travel + 2*time.Second)
	for time.Now().Before(deadline) {
		dx, dz := x-c.x, z-c.z
		dist := math.Hypot(dx, dz)
		if dist <= step*1.5 {
			c.move(0, 0)
			c.awaitPose()
			return
		}
		c.move(dx, dz)
		c.awaitPose()
	}
	c.t.Fatalf("client %s: walkTo(%.3f,%.3f) timed out at (%.3f,%.3f)", c.name, x, z, c.x, c.z)
}

func (c *client) noteSelfPose(p mnet.Pose) {
	if c.id != 0 && p.ID != c.id {
		return
	}
	c.x, c.z = p.X, p.Z
}

func (c *client) drop(slot int) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"drop":{"slot":%d}}`, slot))
}

func (c *client) equip(slot int) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"equip":{"slot":%d}}`, slot))
}

func (c *client) unequip(worn mnet.EquipSlot) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"unequip":{"worn":%q}}`, worn))
}

func (c *client) use(slot, on int) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"use":{"slot":%d,"on":%d}}`, slot, on))
}

func (c *client) talk(npc mnet.PlayerID) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"talk":{"npc":%d}}`, npc))
}

func (c *client) dialogOption(npc mnet.PlayerID, option string) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"dialog_option":{"npc":%d,"option":%q}}`, npc, option))
}

func (c *client) give(npc mnet.PlayerID, slot int) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"give":{"npc":%d,"slot":%d}}`, npc, slot))
}

func (c *client) attack(target mnet.PlayerID) {
	c.t.Helper()
	c.sendRaw(fmt.Sprintf(`{"attack":{"player":%d}}`, target))
}

func (c *client) awaitDialog() mnet.Dialog {
	c.t.Helper()
	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(time.Until(deadline))
		if !ok {
			break
		}
		if f.Dialog != nil && len(f.Dialog.Lines) > 0 {
			return *f.Dialog
		}
	}
	c.t.Fatalf("client %s: no open dialog within %v", c.name, readTimeout)
	return mnet.Dialog{}
}

func (c *client) awaitQuestLog() mnet.QuestLog {
	c.t.Helper()
	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(time.Until(deadline))
		if !ok {
			break
		}
		if f.QuestLog != nil {
			return *f.QuestLog
		}
	}
	c.t.Fatalf("client %s: no quest_log within %v", c.name, readTimeout)
	return mnet.QuestLog{}
}

func (c *client) next() frame {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(time.Until(deadline))
		if !ok {
			break
		}
		if f.Tick != nil {
			continue
		}
		return f
	}
	c.t.Fatalf("client %s: nothing arrived within %v", c.name, readTimeout)
	return frame{}
}

func (c *client) collect(window time.Duration) []frame {
	c.t.Helper()

	var frames []frame
	for {
		f, ok := c.tryNext(window)
		if !ok {
			return frames
		}
		if f.Tick != nil {
			continue
		}
		frames = append(frames, f)
	}
}

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
	c.id = got.You
	for _, p := range got.Players {
		if p.ID == got.You {
			c.x, c.z = p.X, p.Z
			break
		}
	}
	c.inventory()
	c.equipment()
	c.classFrame()
	c.skillsFrame()
	c.questLogFrame()
	return got
}

func (c *client) welcomeFrame() mnet.Welcome {
	c.t.Helper()
	return *c.welcomeEnvelope().Welcome
}

func (c *client) welcomeEnvelope() frame {
	c.t.Helper()
	f := c.next()
	if f.Welcome == nil {
		c.t.Fatalf("client %s: got a %s frame, want welcome: %s", c.name, f.kind(), f.raw)
	}
	return f
}

func (c *client) path() mnet.Path {
	c.t.Helper()
	f := c.next()
	if f.Path == nil {
		c.t.Fatalf("client %s: got a %s frame, want path: %s", c.name, f.kind(), f.raw)
	}
	return *f.Path
}

func (c *client) pose() mnet.Pose {
	c.t.Helper()
	f := c.next()
	if f.Pose == nil {
		c.t.Fatalf("client %s: got a %s frame, want pose: %s", c.name, f.kind(), f.raw)
	}
	return *f.Pose
}

func (c *client) awaitPose() mnet.Pose {
	c.t.Helper()
	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(time.Until(deadline))
		if !ok {
			break
		}
		if f.Pose != nil {
			c.noteSelfPose(*f.Pose)
			return *f.Pose
		}
	}
	c.t.Fatalf("client %s: no pose frame within %v", c.name, readTimeout)
	return mnet.Pose{}
}

func (c *client) awaitPlayerPose(id mnet.PlayerID) mnet.Pose {
	c.t.Helper()
	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(readTimeout)
		if !ok {
			break
		}
		if f.Pose != nil && f.Pose.ID == id {
			c.noteSelfPose(*f.Pose)
			return *f.Pose
		}
	}
	c.t.Fatalf("client %s: no pose for player %d within %v", c.name, id, readTimeout)
	return mnet.Pose{}
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

func (c *client) awaitInventory() mnet.Inventory {
	c.t.Helper()
	return *c.awaitInventoryFrame().Inventory
}

func (c *client) equipment() mnet.Equipment {
	c.t.Helper()
	return *c.equipmentFrame().Equipment
}

func (c *client) equipmentFrame() frame {
	c.t.Helper()
	f := c.next()
	if f.Equipment == nil {
		c.t.Fatalf("client %s: got a %s frame, want equipment: %s", c.name, f.kind(), f.raw)
	}
	return f
}

func (c *client) classFrame() mnet.Class {
	c.t.Helper()
	f := c.next()
	if f.Class == nil {
		c.t.Fatalf("client %s: got a %s frame, want class: %s", c.name, f.kind(), f.raw)
	}
	return *f.Class
}

func (c *client) skillsFrame() mnet.Skills {
	c.t.Helper()
	f := c.next()
	if f.Skills == nil {
		c.t.Fatalf("client %s: got a %s frame, want skills: %s", c.name, f.kind(), f.raw)
	}
	return *f.Skills
}

func (c *client) questLogFrame() mnet.QuestLog {
	c.t.Helper()
	f := c.next()
	if f.QuestLog == nil {
		c.t.Fatalf("client %s: got a %s frame, want quest_log: %s", c.name, f.kind(), f.raw)
	}
	return *f.QuestLog
}

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

func (c *client) awaitItemSpawn() mnet.ItemSpawn {
	c.t.Helper()
	return *c.awaitItemSpawnFrame().ItemSpawn
}

func (c *client) awaitItemSpawnFrame() frame {
	c.t.Helper()

	deadline := time.Now().Add(readTimeout)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(readTimeout)
		if !ok {
			break
		}
		if f.ItemSpawn != nil {
			return f
		}
	}
	c.t.Fatalf("client %s: no item_spawn within %v", c.name, readTimeout)
	return frame{}
}

func (c *client) countItemSpawns(item mnet.ItemID, window time.Duration) int {
	c.t.Helper()

	var seen int
	for _, f := range c.collect(window) {
		if f.ItemSpawn != nil && f.ItemSpawn.ID == item {
			seen++
		}
	}
	return seen
}

func positionOf(t *testing.T, world mnet.Welcome, id mnet.PlayerID) mnet.PlayerState {
	t.Helper()

	for _, p := range world.Players {
		if p.ID == id {
			return p
		}
	}
	t.Fatalf("player %d is not in the world snapshot %+v", id, world.Players)
	return mnet.PlayerState{}
}

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

func (c *client) awaitHaltPath(id mnet.PlayerID) mnet.Path {
	c.t.Helper()
	// Halt is pose now; return a one-point Path so existing assertions keep working.
	p := c.awaitPlayerPose(id)
	return mnet.Path{
		ID:        id,
		StartTick: p.Tick,
		Points:    []mnet.Point{mnet.Pt(p.X, p.Z)},
		Speed:     game.WalkSpeed,
	}
}

func (c *client) expectSilence() {
	c.t.Helper()

	deadline := time.Now().Add(silenceWindow)
	for time.Now().Before(deadline) {
		f, ok := c.tryNext(time.Until(deadline))
		if !ok {
			return
		}
		if f.Tick != nil {
			continue
		}
		c.t.Fatalf("client %s: expected no frame, got %s", c.name, f.raw)
	}
}

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

func (c *client) drain() {
	c.t.Helper()
	c.collect(silenceWindow)
}

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

func (c *client) destroy() {
	c.t.Helper()
	if err := c.ws.CloseNow(); err != nil {
		c.t.Fatalf("client %s: destroy: %v", c.name, err)
	}
}

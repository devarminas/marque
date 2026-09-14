package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/devarminas/marque/server/internal/classdef"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "admin_give_kits: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	addr := flag.String("addr", "", "host:port of a running marqued with -admin")
	timeout := flag.Duration("timeout", 20*time.Second, "overall deadline")
	flag.Parse()
	if strings.TrimSpace(*addr) == "" {
		return fmt.Errorf("-addr is required")
	}

	classes, err := classdef.LoadAll()
	if err != nil {
		return err
	}
	wearables, err := classes.Wearables()
	if err != nil {
		return err
	}
	kinds := make([]string, 0, len(wearables))
	for kind := range wearables {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	if len(kinds) == 0 {
		return fmt.Errorf("no sets-derived wearable kinds")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	wsURL := "ws://" + *addr + "/ws"
	ws, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		return fmt.Errorf("dial %s: %w", wsURL, err)
	}
	defer func() { _ = ws.Close(websocket.StatusNormalClosure, "done") }()

	if err := drainJoin(ctx, ws); err != nil {
		return err
	}

	for i, kind := range kinds {
		line := "/give " + kind
		frame, err := json.Marshal(map[string]any{
			"admin": map[string]any{"line": line, "seq": i + 1},
		})
		if err != nil {
			return err
		}
		if err := ws.Write(ctx, websocket.MessageText, frame); err != nil {
			return fmt.Errorf("write give %s: %w", kind, err)
		}
		reply, err := awaitAdminReply(ctx, ws)
		if err != nil {
			return fmt.Errorf("give %s: %w", kind, err)
		}
		if !strings.HasPrefix(reply, "ok: ") {
			return fmt.Errorf("give %s reply %q, want ok: prefix", kind, reply)
		}
		fmt.Printf("GAVE %s\n", kind)
	}
	fmt.Printf("KINDS %d\n", len(kinds))
	fmt.Println("ADMIN GIVE CLASS KITS HARNESS OK")
	return nil
}

func drainJoin(ctx context.Context, ws *websocket.Conn) error {
	kind, _, err := readFrame(ctx, ws)
	if err != nil {
		return err
	}
	if kind != "welcome" {
		return fmt.Errorf("first frame %q, want welcome", kind)
	}
	for {
		kind, _, err := readFrame(ctx, ws)
		if err != nil {
			return err
		}
		if kind == "inventory" {
			return nil
		}
	}
}

func awaitAdminReply(ctx context.Context, ws *websocket.Conn) (string, error) {
	for {
		kind, body, err := readFrame(ctx, ws)
		if err != nil {
			return "", err
		}
		if kind != "admin_reply" {
			continue
		}
		var reply struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(body, &reply); err != nil {
			return "", fmt.Errorf("admin_reply: %w", err)
		}
		return reply.Text, nil
	}
}

func readFrame(ctx context.Context, ws *websocket.Conn) (string, json.RawMessage, error) {
	typ, data, err := ws.Read(ctx)
	if err != nil {
		return "", nil, err
	}
	if typ != websocket.MessageText {
		return "", nil, fmt.Errorf("non-text frame")
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(data, &keys); err != nil {
		return "", nil, err
	}
	if len(keys) != 1 {
		return "", nil, fmt.Errorf("frame has %d keys", len(keys))
	}
	for k, v := range keys {
		return k, v, nil
	}
	return "", nil, fmt.Errorf("empty frame")
}

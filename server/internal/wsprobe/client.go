// Package wsprobe is a thin WebSocket client for admin lines and raw wire
// probes. It is not a game client: connect, speak one-key JSON, read replies.
package wsprobe

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/coder/websocket"
)

// Client is a single /ws connection used for admin and refuse probes.
type Client struct {
	ws *websocket.Conn
}

// Dial connects to a marque /ws endpoint (ws://host:port/ws).
func Dial(ctx context.Context, wsURL string) (*Client, error) {
	ws, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("wsprobe: dial %s: %w", wsURL, err)
	}
	return &Client{ws: ws}, nil
}

// Close closes the socket with a normal closure.
func (c *Client) Close() error {
	if c == nil || c.ws == nil {
		return nil
	}
	return c.ws.Close(websocket.StatusNormalClosure, "done")
}

// CloseNow aborts the socket without a graceful close handshake.
func (c *Client) CloseNow() error {
	if c == nil || c.ws == nil {
		return nil
	}
	return c.ws.CloseNow()
}

// DrainJoin reads welcome then waits until the join inventory frame arrives.
func (c *Client) DrainJoin(ctx context.Context) error {
	kind, _, err := c.ReadFrame(ctx)
	if err != nil {
		return err
	}
	if kind != "welcome" {
		return fmt.Errorf("wsprobe: first frame %q, want welcome", kind)
	}
	for {
		kind, _, err := c.ReadFrame(ctx)
		if err != nil {
			return err
		}
		if kind == "inventory" {
			return nil
		}
	}
}

// SendRaw writes one text WebSocket frame verbatim.
func (c *Client) SendRaw(ctx context.Context, frame string) error {
	if err := c.ws.Write(ctx, websocket.MessageText, []byte(frame)); err != nil {
		return fmt.Errorf("wsprobe: write: %w", err)
	}
	return nil
}

// SendAdmin sends {"admin":{"line":line}} with an optional seq (>=1).
func (c *Client) SendAdmin(ctx context.Context, line string, seq int) error {
	body := map[string]any{"line": line}
	if seq >= 1 {
		body["seq"] = seq
	}
	frame, err := json.Marshal(map[string]any{"admin": body})
	if err != nil {
		return err
	}
	return c.SendRaw(ctx, string(frame))
}

// ReadFrame reads the next text frame and returns its single top-level key and body.
func (c *Client) ReadFrame(ctx context.Context) (kind string, body json.RawMessage, err error) {
	typ, data, err := c.ws.Read(ctx)
	if err != nil {
		return "", nil, err
	}
	if typ != websocket.MessageText {
		return "", nil, fmt.Errorf("wsprobe: non-text frame")
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(data, &keys); err != nil {
		return "", nil, fmt.Errorf("wsprobe: frame JSON: %w", err)
	}
	if len(keys) != 1 {
		return "", nil, fmt.Errorf("wsprobe: frame has %d keys", len(keys))
	}
	for k, v := range keys {
		return k, v, nil
	}
	return "", nil, fmt.Errorf("wsprobe: empty frame")
}

// AwaitKind skips frames until kind matches, then returns that body.
func (c *Client) AwaitKind(ctx context.Context, kind string) (json.RawMessage, error) {
	for {
		got, body, err := c.ReadFrame(ctx)
		if err != nil {
			return nil, err
		}
		if got == kind {
			return body, nil
		}
	}
}

// AwaitAdminReply waits for an admin_reply and returns its text.
func (c *Client) AwaitAdminReply(ctx context.Context) (string, error) {
	body, err := c.AwaitKind(ctx, "admin_reply")
	if err != nil {
		return "", err
	}
	var reply struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body, &reply); err != nil {
		return "", fmt.Errorf("wsprobe: admin_reply: %w", err)
	}
	return reply.Text, nil
}

// WireError is a decoded server error frame (reply / GAMELOG-relevant refuse).
type WireError struct {
	Re  string `json:"re"`
	Msg string `json:"msg"`
}

// AwaitError waits for an error frame.
func (c *Client) AwaitError(ctx context.Context) (WireError, error) {
	body, err := c.AwaitKind(ctx, "error")
	if err != nil {
		return WireError{}, err
	}
	var e WireError
	if err := json.Unmarshal(body, &e); err != nil {
		return WireError{}, fmt.Errorf("wsprobe: error frame: %w", err)
	}
	return e, nil
}

// WSURL builds ws://addr/ws from a host:port (or host:port/ws) address.
func WSURL(addr string) string {
	addr = strings.TrimSpace(addr)
	addr = strings.TrimPrefix(addr, "http://")
	addr = strings.TrimPrefix(addr, "https://")
	addr = strings.TrimPrefix(addr, "ws://")
	addr = strings.TrimPrefix(addr, "wss://")
	if strings.HasSuffix(addr, "/ws") {
		return "ws://" + addr
	}
	return "ws://" + strings.TrimRight(addr, "/") + "/ws"
}

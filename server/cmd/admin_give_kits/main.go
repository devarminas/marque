package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/devarminas/marque/server/internal/classdef"
	"github.com/devarminas/marque/server/internal/wsprobe"
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

	c, err := wsprobe.Dial(ctx, wsprobe.WSURL(*addr))
	if err != nil {
		return err
	}
	defer func() { _ = c.Close() }()

	if err := c.DrainJoin(ctx); err != nil {
		return err
	}

	for i, kind := range kinds {
		if err := c.SendAdmin(ctx, "/give "+kind, i+1); err != nil {
			return fmt.Errorf("write give %s: %w", kind, err)
		}
		reply, err := c.AwaitAdminReply(ctx)
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

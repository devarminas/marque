package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/devarminas/marque/server/internal/wsprobe"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "wsprobe: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	addr := flag.String("addr", "", "host:port of a running marqued")
	admin := flag.String("admin", "", "admin line to send, e.g. /heal or /give sticks")
	raw := flag.String("raw", "", "raw one-key JSON frame to send after join")
	seq := flag.Int("seq", 1, "seq for -admin (ignored when < 1)")
	timeout := flag.Duration("timeout", 15*time.Second, "overall deadline")
	expectPrefix := flag.String("expect-prefix", "", "require admin_reply text to have this prefix")
	expectErrorRe := flag.String("expect-error-re", "", "require error.re to equal this (with -raw)")
	flag.Parse()

	if strings.TrimSpace(*addr) == "" {
		return fmt.Errorf("-addr is required")
	}
	if (*admin == "") == (*raw == "") {
		return fmt.Errorf("exactly one of -admin or -raw is required")
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

	switch {
	case *admin != "":
		if err := c.SendAdmin(ctx, *admin, *seq); err != nil {
			return err
		}
		reply, err := c.AwaitAdminReply(ctx)
		if err != nil {
			return err
		}
		fmt.Printf("admin_reply %s\n", reply)
		if *expectPrefix != "" && !strings.HasPrefix(reply, *expectPrefix) {
			return fmt.Errorf("admin_reply %q missing prefix %q", reply, *expectPrefix)
		}
	default:
		if err := c.SendRaw(ctx, *raw); err != nil {
			return err
		}
		errFrame, err := c.AwaitError(ctx)
		if err != nil {
			return err
		}
		enc, _ := json.Marshal(errFrame)
		fmt.Printf("error %s\n", enc)
		if *expectErrorRe != "" && errFrame.Re != *expectErrorRe {
			return fmt.Errorf("error.re=%q, want %q", errFrame.Re, *expectErrorRe)
		}
	}

	fmt.Println("WSPROBE OK")
	return nil
}

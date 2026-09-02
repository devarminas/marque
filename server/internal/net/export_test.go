package net

import "time"

// This file is a _test.go, so nothing it declares exists in a production build.
// It is the standard way to give a test a lever on unexported state without
// widening the package's real API.

// SetWriteTimeout shortens the per-frame write deadline for connections this
// hub has not accepted yet.
//
// It exists so that a test can reach the write-timeout branch in under a second
// instead of waiting out the production five, which is the difference between a
// suite that proves the branch and one that skips it. Call it before the hub
// serves anything: every connection copies the value at accept time and the
// field is never written again, which is what makes it lock-free.
func (h *Hub) SetWriteTimeout(d time.Duration) { h.writeTimeout = d }

// ClassifyRead and ClassifyWrite expose the two classifiers so a test can state
// what each pump *would* have reported for a given failure. That is what turns
// "the reported reason is slow_client" into a proof about ordering: without it,
// a test cannot show that the losing classification was genuinely different.
func ClassifyRead(err error) (reason, detail string)  { return readReason(err) }
func ClassifyWrite(err error) (reason, detail string) { return writeReason(err) }

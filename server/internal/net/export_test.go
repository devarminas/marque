package net

import "time"


func (h *Hub) SetWriteTimeout(d time.Duration) { h.writeTimeout = d }

func ClassifyRead(err error) (reason, detail string) { return readReason(err) }

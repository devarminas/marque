package game

import (
	"testing"

	"github.com/devarminas/marque/server/internal/classdef"
	mnet "github.com/devarminas/marque/server/internal/net"
)

func testWearables(t *testing.T) map[string][]mnet.EquipSlot {
	t.Helper()
	cat, err := classdef.LoadAll()
	if err != nil {
		t.Fatalf("load class tables: %v", err)
	}
	wearables, err := cat.Wearables()
	if err != nil {
		t.Fatalf("derive wearables: %v", err)
	}
	return wearables
}

func newStore(t *testing.T) Store {
	t.Helper()
	return NewMemoryStore(testWearables(t))
}

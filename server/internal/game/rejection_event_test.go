package game

import (
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestEveryClientMessageHasItsOwnRejectionEvent(t *testing.T) {
	seen := map[string]string{}
	for _, m := range []mnet.ClientMessage{
		mnet.MoveTo{}, mnet.Pickup{}, mnet.Drop{}, mnet.Equip{}, mnet.Unequip{}, mnet.Gather{}, mnet.Use{},
	} {
		ev := rejectionEvent(m.Name())
		if prior, dup := seen[ev]; dup {
			t.Fatalf("%s and %s share rejection event %q", prior, m.Name(), ev)
		}
		seen[ev] = m.Name()
	}
	if got := rejectionEvent(""); got != EvMoveToRejected {
		t.Fatalf("an unattributable frame files under %q, want %q", got, EvMoveToRejected)
	}
}

func TestAnUnknownIntentNameHasNoQuietRejectionEvent(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("rejectionEvent accepted an intent name it does not know")
		}
	}()
	rejectionEvent("attack")
}

package game

import (
	"encoding/json"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestFreshPlayerHasMaxMana(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	if alice.mana != MaxMana {
		t.Fatalf("mana=%d, want %d", alice.mana, MaxMana)
	}
	state := alice.wireState()
	if state.Mana != MaxMana || state.MaxMana != MaxMana {
		t.Fatalf("wireState=%+v, want mana and max_mana %d", state, MaxMana)
	}
}

func TestRespawnRestoresMaxMana(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	if !pw.w.spendMana(alice, 40) {
		t.Fatal("spendMana failed")
	}
	alice.hp = 0
	pw.w.respawnPlayer(alice, 1)
	if alice.mana != MaxMana {
		t.Fatalf("after respawn mana=%d, want %d", alice.mana, MaxMana)
	}
	if alice.hp != MaxHP {
		t.Fatalf("after respawn hp=%d, want %d", alice.hp, MaxHP)
	}
}

func TestSpendManaLogs(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	if !pw.w.spendMana(alice, 25) {
		t.Fatal("spendMana failed")
	}
	if alice.mana != MaxMana-25 {
		t.Fatalf("mana=%d, want %d", alice.mana, MaxMana-25)
	}
	got := pw.events(EvManaSpend)
	if len(got) != 1 {
		t.Fatalf("mana_spend events=%d, want 1", len(got))
	}
	if got[0]["amount"] != float64(25) || got[0]["mana"] != float64(MaxMana-25) {
		t.Fatalf("mana_spend fields=%v", got[0])
	}
	raw, err := mnet.Encode(mnet.Mana{ID: alice.id, Mana: alice.mana, MaxMana: MaxMana})
	if err != nil {
		t.Fatal(err)
	}
	var env map[string]any
	if err := json.Unmarshal(raw, &env); err != nil {
		t.Fatal(err)
	}
	body := env["mana"].(map[string]any)
	if int(body["mana"].(float64)) != MaxMana-25 || int(body["max_mana"].(float64)) != MaxMana {
		t.Fatalf("mana frame body=%v", body)
	}
}

func TestSpendManaRejectsOverspend(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	if pw.w.spendMana(alice, MaxMana+1) {
		t.Fatal("overspend succeeded")
	}
	if alice.mana != MaxMana {
		t.Fatalf("mana changed on failed spend: %d", alice.mana)
	}
	if len(pw.events(EvManaSpend)) != 0 {
		t.Fatal("failed spend logged mana_spend")
	}
}

func TestRefundManaCapsAndLogs(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	if !pw.w.spendMana(alice, 10) {
		t.Fatal("spendMana failed")
	}
	pw.w.refundMana(alice, 50)
	if alice.mana != MaxMana {
		t.Fatalf("mana=%d after over-refund, want %d", alice.mana, MaxMana)
	}
	got := pw.events(EvManaRefund)
	if len(got) != 1 {
		t.Fatalf("mana_refund events=%d, want 1", len(got))
	}
}

package game

import (
	"math"
	"testing"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/weapondef"
)

func TestFireballPacingVsPostWeaponWhites(t *testing.T) {
	weapons := loadSharedWeapons(t)
	sword, ok := weapons.Get(weapondef.Sword)
	if !ok {
		t.Fatal("missing sword")
	}
	path, err := abilitydef.ResolvePath()
	if err != nil {
		t.Fatal(err)
	}
	abilities, err := abilitydef.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	fb, ok := abilities.Get("fireball")
	if !ok {
		t.Fatal("missing fireball")
	}
	heal, ok := abilities.Get("heal")
	if !ok {
		t.Fatal("missing heal")
	}

	swordAvg := float64(sword.DamageMin+sword.DamageMax) / 2
	fbDmg := fb.Effect.Amount
	if fbDmg <= swordAvg {
		t.Fatalf("fireball amount %.0f is not worth a white (sword avg %.1f)", fbDmg, swordAvg)
	}
	if fbDmg >= float64(ImpMaxHP) {
		t.Fatalf("fireball amount %.0f one-shots Imp max HP %d", fbDmg, ImpMaxHP)
	}

	whitePeriod := float64(sword.AttackPeriodTicks) * TickDuration.Seconds()
	castSec := float64(fb.CastTicks) * TickDuration.Seconds()
	cdSec := float64(fb.CooldownTicks) * TickDuration.Seconds()
	if castSec < 1 {
		t.Fatalf("fireball cast %.2fs is shorter than 1s", castSec)
	}
	if fb.CooldownTicks < fb.CastTicks {
		t.Fatalf("fireball cooldown %d < cast %d", fb.CooldownTicks, fb.CastTicks)
	}

	whiteTTK := math.Ceil(float64(ImpMaxHP)/swordAvg) * whitePeriod
	weaveTTK := castSec + math.Ceil((float64(ImpMaxHP)-fbDmg)/swordAvg)*whitePeriod
	if weaveTTK >= whiteTTK {
		t.Fatalf("weaving fireball TTK %.2fs is not faster than whites-only %.2fs", weaveTTK, whiteTTK)
	}

	t.Logf("sword white avg %.1f / %.2fs (DPS %.2f)", swordAvg, whitePeriod, swordAvg/whitePeriod)
	t.Logf("fireball %.0f in %.2fs cast + %.2fs CD (DPC vs one white: %.1fx)", fbDmg, castSec, cdSec, fbDmg/swordAvg)
	t.Logf("Imp %d HP TTK whites-only %.2fs vs one fireball then whites %.2fs", ImpMaxHP, whiteTTK, weaveTTK)

	if heal.Effect.Amount != 25 || heal.CooldownTicks != 38 || heal.ManaCost != 20 {
		t.Fatalf("heal was retuned unexpectedly: %+v", heal)
	}
}

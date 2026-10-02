package netsim_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/devarminas/marque/server/internal/netsim"
)

const goldenSeed uint64 = 424242

const goldenVectorCount = 1000

func TestCleanProfileDeliversEverythingOnceInOrderWithZeroDelay(t *testing.T) {
	seed := netsim.SeedFromEnv(goldenSeed)
	sim := netsim.New(netsim.Clean, seed)

	const count = 200
	for i := 0; i < count; i++ {
		sim.Send(netsim.AToB, []byte{byte(i)}, uint64(i))
	}

	got := sim.Poll(netsim.AToB, uint64(count-1))
	if len(got) != count {
		t.Fatalf("seed=%d profile=clean: got %d deliveries, want %d", seed, len(got), count)
	}
	for i, d := range got {
		if len(d.Packet) != 1 || d.Packet[0] != byte(i) {
			t.Fatalf("seed=%d profile=clean: delivery %d carried packet %v, want [%d]", seed, i, d.Packet, i)
		}
		if d.At != uint64(i) {
			t.Fatalf("seed=%d profile=clean: delivery %d arrived at %d, want %d (zero delay)", seed, i, d.At, i)
		}
	}
}

func TestGoldenVectorsMatchCommittedFiles(t *testing.T) {
	seed := netsim.SeedFromEnv(goldenSeed)

	for name, profile := range netsim.Profiles {
		t.Run(name, func(t *testing.T) {
			got := strings.Join(netsim.GoldenLines(profile, seed, goldenVectorCount), "\n") + "\n"

			path := filepath.Join("..", "..", "..", "shared", "wire", "vectors", "netsim", name+".golden")
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("seed=%d profile=%s: reading golden file %s: %v", seed, name, path, err)
			}

			if got != string(want) {
				t.Fatalf("seed=%d profile=%s: fate sequence does not match %s.\ngot (first 3 lines):\n%s\nwant (first 3 lines):\n%s",
					seed, name, path, firstLines(got, 3), firstLines(string(want), 3))
			}
		})
	}
}

func firstLines(s string, n int) string {
	lines := strings.SplitN(s, "\n", n+1)
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}

func TestStatisticalSanityLossy5Pct(t *testing.T) {
	seed := netsim.SeedFromEnv(goldenSeed)
	const total = 100_000

	lines := netsim.GoldenLines(netsim.Lossy5Pct, seed, total)
	var drops, delivers, duplicates int
	for _, line := range lines {
		switch {
		case strings.Contains(line, "DROP"):
			drops++
		case strings.Contains(line, "DUPLICATE"):
			duplicates++
		case strings.Contains(line, "DELIVER"):
			delivers++
		}
	}

	const wantDrops = 4990
	const wantDelivers = 94912
	const wantDuplicates = 98

	if seed == goldenSeed {
		if drops != wantDrops || delivers != wantDelivers || duplicates != wantDuplicates {
			t.Fatalf("seed=%d profile=lossy_5pct: got drops=%d delivers=%d duplicates=%d, want drops=%d delivers=%d duplicates=%d",
				seed, drops, delivers, duplicates, wantDrops, wantDelivers, wantDuplicates)
		}
	}

	dropPct := float64(drops) / float64(total) * 100
	if dropPct < 4 || dropPct > 6 {
		t.Fatalf("seed=%d profile=lossy_5pct: drop rate %.2f%% (%d/%d) outside [4%%, 6%%]", seed, dropPct, drops, total)
	}
	if drops+delivers+duplicates != total {
		t.Fatalf("seed=%d profile=lossy_5pct: drops+delivers+duplicates=%d, want %d", seed, drops+delivers+duplicates, total)
	}
}

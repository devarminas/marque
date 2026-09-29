package netsim

import (
	"os"
	"strconv"
)

// SeedEnvVar is the environment variable that overrides a test's seed, so
// a failure that prints "seed=<n> profile=<name>" can be reproduced with
// SeedEnvVar=<n> against the same profile.
const SeedEnvVar = "NETSIM_SEED"

// SeedFromEnv returns the seed a test should run with: the value of
// SeedEnvVar if it is set and parses as a uint64, otherwise def.
func SeedFromEnv(def uint64) uint64 {
	raw := os.Getenv(SeedEnvVar)
	if raw == "" {
		return def
	}
	v, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return def
	}
	return v
}

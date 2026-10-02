package netsim

import (
	"os"
	"strconv"
)

const SeedEnvVar = "NETSIM_SEED"

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

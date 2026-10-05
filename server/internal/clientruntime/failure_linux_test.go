package clientruntime

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/netsim"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

func TestLiveRuntimeFailure(t *testing.T) {
	helperPath := os.Getenv("MARQUE_RUNTIME_PEER")
	if helperPath == "" {
		t.Skip("MARQUE_RUNTIME_PEER is unset")
	}
	for _, mode := range []string{"count", "bytes", "epoch", "gauntlet", "invalid_motion", "wrong_map", "future_input"} {
		t.Run(mode, func(t *testing.T) {
			conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			address := conn.LocalAddr().(*net.UDPAddr).AddrPort()
			var issuer transport.Key
			var nonce transport.TokenNonce
			var keys transport.SessionKeys
			for _, value := range [][]byte{issuer[:], nonce[:], keys.ClientToServer[:], keys.ServerToClient[:]} {
				if _, err := rand.Read(value); err != nil {
					t.Fatal(err)
				}
			}
			token := transport.IssueToken(issuer, nonce, transport.Grant{Account: 360, Session: 360, Shard: address, Expires: uint64(time.Now().Unix()) + 60, Keys: keys})
			gate, err := transport.NewGate(transport.GateConfig{SchemaHash: wire.SchemaHash, Shard: address, Issuer: issuer})
			if err != nil {
				t.Fatal(err)
			}
			tokenPath := filepath.Join(t.TempDir(), "token.bin")
			if err := os.WriteFile(tokenPath, token.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, helperPath, tokenPath, mode)
			var output capturedOutput
			cmd.Stdout, cmd.Stderr = &output, &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			defer func() {
				cancel()
				select {
				case <-done:
				default:
					_ = cmd.Process.Kill()
					<-done
				}
			}()
			var endpoint *transport.Endpoint
			var peer *net.UDPAddr
			started := time.Now()
			clock := func() uint64 { return uint64(time.Since(started).Microseconds()) }
			simulator := netsim.New(netsim.Profile{DropPPM: 50000, DelayBaseMicros: 5000, JitterRangeMicros: 5000, DuplicatePPM: 500000, ReorderPPM: 1000000, ReorderWindowMicros: 20000}, 36020261003)
			faults, forcedDrop := false, false
			scheduled, delivered, duplicates, reordered := 0, 0, 0, 0
			seenPackets := map[uint16]bool{}
			var lastDelivered uint16
			flushState := func(state transport.Unreliable) {
				packets, err := endpoint.Flush(clock(), state)
				if err != nil {
					t.Fatal(err)
				}
				for _, packet := range packets.Datagrams {
					if faults {
						scheduled++
						if !forcedDrop {
							forcedDrop = true
							continue
						}
						simulator.Send(netsim.BToA, packet, clock())
					} else if _, err := conn.WriteToUDP(packet, peer); err != nil {
						t.Fatal(err)
					}
				}
			}
			flush := func() { flushState(transport.Unreliable{}) }
			closeTick := func(tick uint32, epoch uint64, cursor uint32) {
				close, err := wire.TickCloseFields{Stream: 88, Epoch: epoch, Tick: tick, EventEnd: 0, StateItems: 0, NextIntent: cursor}.Build()
				if err := endpoint.Send(encoded(t, close, err)); err != nil {
					t.Fatal(err)
				}
				flush()
			}
			initial, second, third, action := false, false, false, false
			var lastState []byte
			commits := map[uint32]bool{}
			next := time.Time{}
			buffer := make([]byte, 1201)
			for {
				select {
				case err := <-done:
					done <- err
					marker := "ARM360_LIVE_" + mode + "_FAILURE_PASS"
					if mode == "gauntlet" {
						marker = "ARM360_LIVE_gauntlet_CUMULATIVE_PASS"
					}
					if err != nil || !strings.Contains(output.String(), marker) {
						t.Fatalf("helper err=%v commits=%v\n%s", err, commits, output.String())
					}
					if mode == "gauntlet" {
						if !commits[1] || !commits[5] || commits[3] || !action || !forcedDrop || duplicates == 0 || reordered == 0 {
							t.Fatalf("gauntlet commits=%v scheduled=%d delivered=%d duplicates=%d reordered=%d", commits, scheduled, delivered, duplicates, reordered)
						}
						t.Logf("actual sealed UDP forced loss and Simulator seed36020261003; scheduled=%d delivered=%d duplicates=%d reordered=%d; %s", scheduled, delivered, duplicates, reordered, strings.TrimSpace(output.String()))
						return
					}
					if !commits[1] || !action || commits[4] || (mode == "bytes" && commits[3]) || ((mode == "epoch" || mode == "invalid_motion" || mode == "wrong_map" || mode == "future_input") && commits[2]) {
						t.Fatalf("failed publication committed or first good boundary missing action=%v commits=%v", action, commits)
					}
					t.Logf("actual sealed UDP %s; commits=%v; %s", mode, commits, strings.TrimSpace(output.String()))
					return
				default:
				}
				if ctx.Err() != nil {
					t.Fatalf("deadline\n%s", output.String())
				}
				if endpoint != nil {
					if !initial {
						if mode == "invalid_motion" || mode == "wrong_map" || mode == "future_input" {
							transform, e := wire.TransformFields{}.Build()
							if e != nil {
								t.Fatal(e)
							}
							entity, e := wire.EntityFields{Id: wire.PlayerId{Index: 7, Gen: 1}, Transform: codec.Some(transform)}.Build()
							motion, me := wire.OwnerMotionFields{Stream: 88, Epoch: 1, Player: wire.PlayerId{Index: 7, Gen: 1}, Tick: 1, MapId: "village", MapRevision: 2, TickIntervalUs: 40000, HalfExtent: 128, Grounded: true, Mode: wire.MotionModeFree}.Build()
							close, ce := wire.TickCloseFields{Stream: 88, Epoch: 1, Tick: 1, StateItems: 2, NextIntent: 1}.Build()
							if e := endpoint.Send(encoded(t, close, ce)); e != nil {
								t.Fatal(e)
							}
							flushState(transport.Unreliable{Stamp: 1, Items: [][]byte{encoded(t, entity, e), encoded(t, motion, me)}})
						} else if mode == "gauntlet" {
							transform, e := wire.TransformFields{}.Build()
							if e != nil {
								t.Fatal(e)
							}
							vitals, e := wire.VitalsFields{Hp: 100, MaxHp: 100, Mana: 10, MaxMana: 20}.Build()
							if e != nil {
								t.Fatal(e)
							}
							entity, e := wire.EntityFields{Id: wire.PlayerId{Index: 7, Gen: 1}, Transform: codec.Some(transform), Vitals: codec.Some(vitals)}.Build()
							close, ce := wire.TickCloseFields{Stream: 88, Epoch: 1, Tick: 1, StateItems: 1, NextIntent: 1}.Build()
							if e := endpoint.Send(encoded(t, close, ce)); e != nil {
								t.Fatal(e)
							}
							flushState(transport.Unreliable{Stamp: 1, Items: [][]byte{encoded(t, entity, e)}})
						} else {
							closeTick(1, 1, 1)
						}
						initial = true
					}
					if _, err := os.Stat(tokenPath + ".ready"); err == nil && action && !second {
						epoch := uint64(1)
						if mode == "epoch" {
							epoch = 2
						}
						if mode == "invalid_motion" || mode == "wrong_map" || mode == "future_input" {
							transform, e := wire.TransformFields{X: 9}.Build()
							if e != nil {
								t.Fatal(e)
							}
							entity, e := wire.EntityFields{Id: wire.PlayerId{Index: 7, Gen: 1}, Transform: codec.Some(transform)}.Build()
							fields := wire.OwnerMotionFields{Stream: 88, Epoch: 1, Player: wire.PlayerId{Index: 7, Gen: 1}, Tick: 2, MapId: "village", MapRevision: 2, TickIntervalUs: 40000, HalfExtent: 128, Grounded: true, Mode: wire.MotionModeFree}
							if mode == "invalid_motion" {
								fields.X = 129
							}
							if mode == "wrong_map" {
								fields.MapRevision = 3
							}
							if mode == "future_input" {
								fields.InputSeq = 1
							}
							motion, me := fields.Build()
							entry, e := wire.BagEntryFields{Slot: 0, Kind: "logs"}.Build()
							if e != nil {
								t.Fatal(e)
							}
							inventory, ie := wire.InventoryFields{Stream: 88, EventSeq: 1, Tick: 2, Size: 28, Slots: []wire.BagEntry{entry}}.Build()
							if e := endpoint.Send(encoded(t, inventory, ie)); e != nil {
								t.Fatal(e)
							}
							close, ce := wire.TickCloseFields{Stream: 88, Epoch: 1, Tick: 2, EventEnd: 1, StateItems: 2, NextIntent: 2}.Build()
							if e := endpoint.Send(encoded(t, close, ce)); e != nil {
								t.Fatal(e)
							}
							flushState(transport.Unreliable{Stamp: 2, Items: [][]byte{encoded(t, entity, e), encoded(t, motion, me)}})
						} else if mode == "gauntlet" {
							vitals, e := wire.VitalsFields{Hp: 90, MaxHp: 100, Mana: 10, MaxMana: 20}.Build()
							if e != nil {
								t.Fatal(e)
							}
							entity, e := wire.EntityFields{Id: wire.PlayerId{Index: 7, Gen: 1}, Vitals: codec.Some(vitals)}.Build()
							swing, se := wire.SwingFields{Tick: 2, Attacker: wire.PlayerId{Index: 7, Gen: 1}, Target: wire.NpcId{Index: 9, Gen: 1}, Amount: 17, Crit: true}.Build()
							cast, ce := wire.CastPhaseFields{Tick: 2, Caster: wire.PlayerId{Index: 7, Gen: 1}, Ability: "fireball", Step: wire.CastStepBegin}.Build()
							gather, ge := wire.GatherStartFields{Tick: 2, Player: wire.PlayerId{Index: 7, Gen: 1}, Node: wire.NodeId{Index: 21, Gen: 1}}.Build()
							flushState(transport.Unreliable{Stamp: 2, Items: [][]byte{encoded(t, entity, e), encoded(t, swing, se), encoded(t, cast, ce), encoded(t, gather, ge)}})
						} else {
							closeTick(2, epoch, 2)
						}
						second, next = true, time.Now().Add(80*time.Millisecond)
					}
					if (mode == "count" || mode == "bytes" || mode == "gauntlet") && second && !third && time.Now().After(next) {
						if mode == "gauntlet" {
							faults = true
							slots := make([]wire.BagEntry, 28)
							for i := range slots {
								kind := strings.Repeat("x", 64)
								if i == 0 {
									kind = "logs"
								}
								entry, e := wire.BagEntryFields{Slot: uint8(i), Kind: kind}.Build()
								if e != nil {
									t.Fatal(e)
								}
								slots[i] = entry
							}
							inventory, e := wire.InventoryFields{Stream: 88, EventSeq: 1, Tick: 2, Size: 28, Slots: slots}.Build()
							raw := encoded(t, inventory, e)
							if len(raw) <= 1024 {
								t.Fatal("split prefix fixture is too small")
							}
							if e := endpoint.Send(raw); e != nil {
								t.Fatal(e)
							}
							quest, e := wire.QuestEntryFields{Id: "quest_one", Title: "Quest", Objective: "Find logs", Status: "active"}.Build()
							if e != nil {
								t.Fatal(e)
							}
							quests, e := wire.QuestLogFields{Stream: 88, EventSeq: 2, Tick: 3, Quests: []wire.QuestEntry{quest}}.Build()
							if e := endpoint.Send(encoded(t, quests, e)); e != nil {
								t.Fatal(e)
							}
							close, ce := wire.TickCloseFields{Stream: 88, Epoch: 1, Tick: 3, EventEnd: 2, StateItems: 1, NextIntent: 2}.Build()
							if e := endpoint.Send(encoded(t, close, ce)); e != nil {
								t.Fatal(e)
							}
							close, ce = wire.TickCloseFields{Stream: 88, Epoch: 1, Tick: 5, EventEnd: 2, StateItems: 1, NextIntent: 2}.Build()
							if e := endpoint.Send(encoded(t, close, ce)); e != nil {
								t.Fatal(e)
							}
							transform, e := wire.TransformFields{X: 5}.Build()
							if e != nil {
								t.Fatal(e)
							}
							entity, e := wire.EntityFields{Id: wire.PlayerId{Index: 7, Gen: 1}, Transform: codec.Some(transform)}.Build()
							lastState = encoded(t, entity, e)
							flushState(transport.Unreliable{Stamp: 5, Items: [][]byte{lastState}})
						} else {
							closeTick(3, 1, 2)
						}
						third = true
					}
				}
				if faults {
					for _, delivery := range simulator.Poll(netsim.BToA, clock()) {
						seq := binary.LittleEndian.Uint16(delivery.Packet[12:])
						if seenPackets[seq] {
							duplicates++
						}
						if delivered > 0 && uint16(seq-lastDelivered) >= 0x8000 {
							reordered++
						}
						seenPackets[seq] = true
						lastDelivered = seq
						delivered++
						if _, e := conn.WriteToUDP(delivery.Packet, peer); e != nil {
							t.Fatal(e)
						}
					}
				}
				if err := conn.SetReadDeadline(time.Now().Add(5 * time.Millisecond)); err != nil {
					t.Fatal(err)
				}
				n, from, err := conn.ReadFromUDP(buffer)
				if err != nil {
					if ne, ok := err.(net.Error); ok && ne.Timeout() {
						if endpoint != nil {
							if lastState != nil {
								flushState(transport.Unreliable{Stamp: 5, Items: [][]byte{lastState}})
							} else {
								flush()
							}
						}
						continue
					}
					t.Fatal(err)
				}
				if endpoint == nil {
					result, err := gate.Handle(from.AddrPort(), buffer[:n], uint64(time.Now().Unix()))
					if err != nil {
						t.Fatal(err)
					}
					if len(result.Challenge) > 0 {
						if _, err := conn.WriteToUDP(result.Challenge, from); err != nil {
							t.Fatal(err)
						}
						continue
					}
					if result.Admission == nil {
						t.Fatal("missing admission")
					}
					peer = from
					open, seal := transport.NewSessionSeal(transport.Server, result.Admission.Keys)
					endpoint, err = transport.NewEndpoint(transport.Server, transport.DefaultConfig(wire.SchemaHash), open, seal, clock())
					if err != nil {
						t.Fatal(err)
					}
					flush()
					continue
				}
				if from.AddrPort() != peer.AddrPort() {
					continue
				}
				packet, err := endpoint.Receive(buffer[:n], clock())
				if err != nil {
					if errors.Is(err, transport.ErrDuplicate) {
						continue
					}
					t.Fatal(err)
				}
				for _, raw := range packet.Reliable {
					value, err := wire.DecodeIntents(raw)
					if err != nil {
						t.Fatal(err)
					}
					switch value := value.(type) {
					case wire.ApplicationCommit:
						if value.Stream() != 88 || value.Epoch() != 1 || value.EventEnd() != 0 && mode != "gauntlet" {
							t.Fatal("commit identity")
						}
						commits[value.Tick()] = true
					case wire.Respawn:
						if value.Seq() != 1 || action {
							t.Fatal("command allocation")
						}
						action = true
					default:
						t.Fatalf("unexpected command %T", value)
					}
				}
				flush()
			}
		})
	}
}

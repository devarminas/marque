package intents_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"github.com/devarminas/marque/server/internal/intents"

	"github.com/devarminas/marque/server/internal/abilitydef"
	"github.com/devarminas/marque/server/internal/game"
	"github.com/devarminas/marque/server/internal/netsim"
	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"io"
	"math"
	"os"
	"os/exec"
	"testing"
	"time"
)

type motionLog struct{ data []byte }

func (b *motionLog) Write(p []byte) (int, error) {
	n := len(p)
	if len(b.data) < 16384 {
		keep := min(len(p), 16384-len(b.data))
		b.data = append(b.data, p[:keep]...)
	}
	return n, nil
}

type motionPeer struct {
	cmd    *exec.Cmd
	in     io.WriteCloser
	out    io.ReadCloser
	stderr motionLog
}

func startMotionPeer(t *testing.T, path string) *motionPeer {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	peer := &motionPeer{cmd: exec.CommandContext(ctx, path)}
	peer.cmd.Stderr = &peer.stderr
	var e error
	peer.in, e = peer.cmd.StdinPipe()
	if e != nil {
		t.Fatal(e)
	}
	peer.out, e = peer.cmd.StdoutPipe()
	if e != nil {
		t.Fatal(e)
	}
	if e = peer.cmd.Start(); e != nil {
		cancel()
		t.Fatal(e)
	}
	t.Cleanup(func() {
		cancel()
		peer.in.Close()
		peer.out.Close()
		if peer.cmd.ProcessState == nil {
			peer.cmd.Process.Kill()
			peer.cmd.Wait()
		}
	})
	return peer
}

type motionResponse struct {
	active                               bool
	pose                                 [6]float64
	tick                                 uint32
	mode                                 uint8
	seq, tickPublished, cursor, replayed uint32
	baseline                             [3]float64
	grounded                             bool
	packets                              [][]byte
}

func (p *motionPeer) step(t *testing.T, now uint64, sampling bool, dx, dz float64, jump bool, command []byte, packets []netsim.Delivery) (motionResponse, []byte) {
	t.Helper()
	var frame bytes.Buffer
	binary.Write(&frame, binary.LittleEndian, now)
	if sampling {
		frame.WriteByte(1)
	} else {
		frame.WriteByte(0)
	}
	binary.Write(&frame, binary.LittleEndian, dx)
	binary.Write(&frame, binary.LittleEndian, dz)
	if jump {
		frame.WriteByte(1)
	} else {
		frame.WriteByte(0)
	}
	if len(command) > 1032 {
		t.Fatal("intent capacity")
	}
	binary.Write(&frame, binary.LittleEndian, uint16(len(command)))
	frame.Write(command)
	if len(packets) > 256 {
		t.Fatal("delivery batch capacity")
	}
	binary.Write(&frame, binary.LittleEndian, uint16(len(packets)))
	for _, d := range packets {
		if len(d.Packet) > 1200 {
			t.Fatal("datagram capacity")
		}
		binary.Write(&frame, binary.LittleEndian, uint16(len(d.Packet)))
		frame.Write(d.Packet)
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(frame.Len()))
	if _, e := p.in.Write(header[:]); e != nil {
		t.Fatalf("peer frame header %v %s", e, p.stderr.data)
	}
	if _, e := p.in.Write(frame.Bytes()); e != nil {
		t.Fatalf("peer frame body %v %s", e, p.stderr.data)
	}
	if _, e := io.ReadFull(p.out, header[:]); e != nil {
		t.Fatalf("peer response header %v %s", e, p.stderr.data)
	}
	size := binary.LittleEndian.Uint32(header[:])
	if size > 256*1024 {
		t.Fatal("peer response capacity")
	}
	data := make([]byte, size)
	if _, e := io.ReadFull(p.out, data); e != nil {
		t.Fatal(e)
	}
	r := bytes.NewReader(data)
	var out motionResponse
	read := func(v any) {
		if e := binary.Read(r, binary.LittleEndian, v); e != nil {
			t.Fatal(e)
		}
	}
	var active, grounded byte
	read(&active)
	out.active = active != 0
	read(&out.pose)
	read(&out.tick)
	read(&out.mode)
	read(&out.seq)
	read(&out.tickPublished)
	read(&out.cursor)
	read(&out.replayed)
	read(&out.baseline)
	read(&grounded)
	out.grounded = grounded != 0
	var count uint16
	read(&count)
	if count > 256 {
		t.Fatal("peer packet count")
	}
	for i := 0; i < int(count); i++ {
		var n uint16
		read(&n)
		if n > 1200 {
			t.Fatal("peer packet size")
		}
		b := make([]byte, n)
		if _, e := io.ReadFull(r, b); e != nil {
			t.Fatal(e)
		}
		out.packets = append(out.packets, b)
	}
	if r.Len() != 0 {
		t.Fatal("peer trailing response")
	}
	return out, data
}
func (p *motionPeer) finish(t *testing.T) {
	t.Helper()
	if e := p.in.Close(); e != nil {
		t.Fatal(e)
	}
	if e := p.cmd.Wait(); e != nil {
		t.Fatalf("peer exit %v %s", e, p.stderr.data)
	}
}

func TestMotionInterop(t *testing.T) {
	path := os.Getenv("MARQUE_MOTION_PEER")
	if path == "" {
		t.Skip("scripts/motion_interop.sh builds and requires actual native peer")
	}
	cases := []struct {
		name                       string
		profile                    netsim.Profile
		seed                       uint64
		airborne, blackout, rooted bool
	}{
		{"clean", netsim.Clean, 35920261002, false, false, false},
		{"bad_wifi", netsim.BadWifi, 35920261002, false, false, false},
		{"airborne_bad_wifi", netsim.BadWifi, 35920261003, true, false, false},
		{"bounded_history_recovery", netsim.Clean, 35920261004, false, true, false},
		{"actual_rooted_cast", netsim.Clean, 35920261005, false, false, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			run := func() [32]byte {
				w, sessions, plan := fixture(t)
				if tc.rooted {
					h := successFixture(t, []string{"cloth_hood", "cloth_robe", "cloth_skirt", "staff"}, 1)
					w, sessions, plan = h.w, h.s, h.owners[0].plan
					for slot := uint8(0); slot < 4; slot++ {
						if e := intents.Apply(w, sessions, 7, plan.Epoch, build((wire.EquipFields{Seq: uint32(slot) + 1, Slot: slot}).Build())); e != nil {
							t.Fatal(e)
						}
					}
					catalog, e := abilitydef.Parse([]byte(`{"abilities":[{"id":"fireball","name":"Fixture root","mana_cost":1,"cooldown_ticks":0,"cast_ticks":10,"range":0,"target":"self","locomotion":"rooted","effect":{"kind":"heal","amount":1},"ui":{"hotbar_slot":1,"color":"red"}}]}`))
					if e != nil {
						t.Fatal(e)
					}
					w.SetAbilities(catalog)
				}
				endpoint, e := transport.NewEndpoint(transport.Server, transport.DefaultConfig(wire.SchemaHash), transport.Plain{}, transport.Plain{}, 0)
				if e != nil {
					t.Fatal(e)
				}
				peer := startMotionPeer(t, path)
				sim := netsim.New(tc.profile, tc.seed)
				transcript := sha256.New()
				var localStop, serverStop, publishedStop, converged uint64
				var stopSeq uint32
				var previous motionResponse
				var latest uint16
				var haveWindow bool
				var maxMoving, maxTurning float64
				var sawAwaiting, sawRecovery bool
				var initial bool
				var sawRooted, resumedWish bool
				for step := 0; step < 340; step++ {
					now := uint64(step) * 40000
					if tc.rooted && step == 16 {
						if e := intents.Apply(w, sessions, 7, plan.Epoch, build((wire.CastSelfFields{Seq: 5, Ability: "fireball"}).Build())); e != nil {
							t.Fatal(e)
						}
					}
					deliveries := sim.Poll(netsim.AToB, now)
					var inputs []wire.Input
					for _, d := range deliveries {
						got, e := endpoint.Receive(d.Packet, now)
						if e == transport.ErrDuplicate {
							continue
						}
						if e == transport.ErrTooOld && len(d.Packet) >= 16 {
							seq := binary.LittleEndian.Uint16(d.Packet[12:])
							if haveWindow && uint16(seq-latest) >= 0x8000 && uint16(latest-seq) > transport.AckBits {
								continue
							}
						}
						if e != nil {
							t.Fatalf("seed%d step%d Go endpoint %v", tc.seed, step, e)
						}
						latest = got.OwnAck.Latest
						haveWindow = true
						if len(got.Unreliable.Items) != 0 {
							for _, data := range got.Unreliable.Items {
								msg, e := wire.DecodeInput(data)
								if e != nil {
									t.Fatal(e)
								}
								inputs = append(inputs, msg.(wire.Input))
							}
						}
					}
					if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, inputs); e != nil {
						t.Fatal(e)
					}
					if step != 0 {
						w.AdvanceTick()
					}
					baseline, e := intents.OwnerMotion(w, sessions, 7, plan.Epoch)
					if e != nil {
						t.Fatal(e)
					}
					if stopSeq != 0 && serverStop == 0 && baseline.InputSeq() >= stopSeq && baseline.Dx() == 0 && baseline.Dz() == 0 {
						serverStop = now
					}
					state := transport.Unreliable{Stamp: baseline.Tick()}
					if !tc.blackout || step < 10 || step > 280 {
						state.Items = [][]byte{build(baseline.Append(nil))}
					}
					flushed, e := endpoint.Flush(now, state)
					if e != nil || flushed.State != transport.Open {
						t.Fatalf("Go flush %v %v", flushed, e)
					}
					for _, d := range flushed.Datagrams {
						sim.Send(netsim.BToA, d, now)
					}
					if flushed.UnreliableSent == 1 {
						close := build((wire.TickCloseFields{Stream: baseline.Stream(), Epoch: baseline.Epoch(), Tick: baseline.Tick(), EventEnd: 0, StateItems: 1, NextIntent: 1}).Build())
						if e = endpoint.Send(build(close.Append(nil))); e != nil {
							t.Fatal(e)
						}
						reliable, e := endpoint.Flush(now, transport.Unreliable{})
						if e != nil {
							t.Fatal(e)
						}
						for _, d := range reliable.Datagrams {
							sim.Send(netsim.BToA, d, now)
						}
					}
					dx, dz := 0.0, 0.0
					start, turn, stop := 20, 40, 60
					if tc.airborne {
						turn = 30
						stop = 31
					}
					if step >= start && step < turn {
						dx = 1
					}
					if step >= turn && step < stop {
						dz = 1
					}
					response, data := peer.step(t, now, step >= start && step <= stop, dx, dz, tc.airborne && step == 30, nil, sim.Poll(netsim.BToA, now))
					transcript.Write(data)
					encoded := build(baseline.Append(nil))
					transcript.Write(encoded)
					if response.active {
						initial = true
					}
					if step == stop {
						if !response.active || response.seq == 0 {
							t.Fatal("prediction not initialized before local stop")
						}
						stopSeq = response.seq
						localStop = now
						if response.pose[4] != 0 || response.pose[5] != 0 {
							t.Fatalf("local horizontal stop waits on server seed%d pose%v", tc.seed, response.pose)
						}
					}
					if step > stop && publishedStop == 0 && response.cursor >= stopSeq && response.grounded {
						publishedStop = now
						error := math.Sqrt(math.Pow(response.pose[0]-response.baseline[0], 2) + math.Pow(response.pose[1]-response.baseline[1], 2) + math.Pow(response.pose[2]-response.baseline[2], 2))
						if error > 1e-6 {
							t.Fatalf("published acknowledged grounded stop fails convergence error%.15g seed%d", error, tc.seed)
						}
						converged = now
					}
					if tc.airborne && step == 32 && response.pose[1] <= 0 {
						t.Fatal("airborne zero wish canceled gravity instead of retaining full vertical motion")
					}
					if response.mode == 1 {
						sawAwaiting = true
					}
					if sawAwaiting && response.mode == 0 && step > 280 {
						sawRecovery = true
					}
					if response.active && step >= start && step < stop {
						error := math.Hypot(response.pose[0]-float64(baseline.X()), response.pose[2]-float64(baseline.Z()))
						if step < turn {
							maxMoving = max(maxMoving, error)
						} else {
							maxTurning = max(maxTurning, error)
						}
					}
					if response.tickPublished < previous.tickPublished || response.cursor < previous.cursor || response.replayed > 256 {
						t.Fatalf("publication or replay bound %v previous%v", response, previous)
					}
					previous = response
					if tc.rooted && baseline.Mode() == wire.MotionModeRooted && step >= 20 {
						sawRooted = true
						if baseline.CastEnd() <= baseline.Tick() || baseline.Dx() != 0 || response.pose[4] != 0 {
							t.Fatalf("actual rooted baseline or predictor policy %v pose%v", baseline, response.pose)
						}
					}
					if tc.rooted && sawRooted && baseline.Mode() == wire.MotionModeFree && step < 40 && baseline.Dx() == 1 && response.pose[4] == 1 {
						resumedWish = true
					}
					for _, d := range response.packets {
						sim.Send(netsim.AToB, d, now)
					}
				}
				peer.finish(t)
				if !initial || localStop == 0 || serverStop < localStop || publishedStop < serverStop || converged-publishedStop > 40000 {
					t.Fatalf("seed%d landmarks local%d server%d baseline%d convergence%d", tc.seed, localStop, serverStop, publishedStop, converged)
				}
				if tc.blackout && (!sawAwaiting || !sawRecovery) {
					t.Fatalf("actual typed baseline recovery awaiting%v recovered%v", sawAwaiting, sawRecovery)
				}
				if tc.rooted && (!sawRooted || !resumedWish) {
					t.Fatalf("rooted expiry proof rooted%v resumed%v", sawRooted, resumedWish)
				}
				t.Logf("seed=%d local_stop_us=%d server_stop_consumed_us=%d baseline_published_us=%d converged_us=%d complete_delay_us=%d max_moving_error=%.9g max_turning_error=%.9g recovery=%v", tc.seed, localStop, serverStop, publishedStop, converged, publishedStop-localStop, maxMoving, maxTurning, sawRecovery)
				var digest [32]byte
				copy(digest[:], transcript.Sum(nil))
				return digest
			}
			first, second := run(), run()
			if first != second {
				t.Fatalf("seed%d semantic transcript differs %x %x", tc.seed, first, second)
			}
			t.Log(fmt.Sprintf("repeat semantic transcript sha256=%x", first))
		})
	}
}

func TestMotionApproachInterop(t *testing.T) {
	path := os.Getenv("MARQUE_MOTION_PEER")
	if path == "" {
		t.Skip("scripts/motion_interop.sh builds and requires actual native peer")
	}
	cases := []struct {
		name                 string
		profile              netsim.Profile
		stopAt, secondPickup int
		dropStop, blackout   bool
		wantItem             bool
	}{
		{"passive_pickup_bad_wifi", netsim.BadWifi, -1, -1, false, false, true},
		{"deliberate_stop", netsim.Clean, 22, -1, false, false, false},
		{"consumed_stop_then_new_pickup", netsim.Clean, 22, 50, false, false, true},
		{"lost_stop_repeats_same_sequence", netsim.Clean, 22, -1, true, false, false},
		{"passive_recovery", netsim.Clean, -1, -1, false, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			run := func() [32]byte {
				const seed = 35920261006
				w, sessions, plan := fixture(t)
				if e := w.SeedGroundItem("logs", 2, 0); e != nil {
					t.Fatal(e)
				}
				endpoint, e := transport.NewEndpoint(transport.Server, transport.DefaultConfig(wire.SchemaHash), transport.Plain{}, transport.Plain{}, 0)
				if e != nil {
					t.Fatal(e)
				}
				peer := startMotionPeer(t, path)
				sim := netsim.New(tc.profile, seed)
				transcript := sha256.New()
				var haveWindow bool
				var latest uint16
				var stopSeq uint32
				var stopConsumed bool
				var itemReceived, predictApproach, sawAwaiting, sawRecovery bool
				var droppedCopies, receivedStopCopies int
				var final wire.OwnerMotion
				for step := 0; step < 340; step++ {
					now := uint64(step) * 40000
					var inputs []wire.Input
					for _, d := range sim.Poll(netsim.AToB, now) {
						got, e := endpoint.Receive(d.Packet, now)
						if e == transport.ErrDuplicate {
							continue
						}
						if e == transport.ErrTooOld && len(d.Packet) >= 16 {
							seq := binary.LittleEndian.Uint16(d.Packet[12:])
							if haveWindow && uint16(seq-latest) >= 0x8000 && uint16(latest-seq) > transport.AckBits {
								continue
							}
						}
						if e != nil {
							t.Fatal(e)
						}
						latest = got.OwnAck.Latest
						haveWindow = true
						for _, data := range got.Reliable {
							command, e := wire.DecodeIntents(data)
							if e != nil {
								t.Fatal(e)
							}
							if e = intents.Apply(w, sessions, 7, plan.Epoch, command); e != nil {
								t.Fatal(e)
							}
						}
						for _, data := range got.Unreliable.Items {
							msg, e := wire.DecodeInput(data)
							if e != nil {
								t.Fatal(e)
							}
							input := msg.(wire.Input)
							inputs = append(inputs, input)
							if input.Dx() == 0 && input.Dz() == 0 && input.Seq() == stopSeq {
								receivedStopCopies++
							}
						}
					}
					if e = intents.ApplyInputBatch(w, sessions, 7, plan.Epoch, inputs); e != nil {
						t.Fatal(e)
					}
					if step != 0 {
						w.AdvanceTick()
					}
					baseline, e := intents.OwnerMotion(w, sessions, 7, plan.Epoch)
					if e != nil {
						t.Fatal(e)
					}
					final = baseline
					for _, change := range w.TakeOwnerChanges() {
						if inventory, ok := change.Value.(game.InventoryValue); ok {
							for _, slot := range inventory.Slots {
								if slot.Kind == "logs" {
									itemReceived = true
									transcript.Write([]byte("actual-owner-inventory-logs"))
								}
							}
						}
					}
					if tc.secondPickup > 0 && step == tc.secondPickup-1 {
						if itemReceived || !stopConsumed || baseline.Dx() != 0 || baseline.X() > float32(.3) {
							t.Fatalf("first stop failed before second pickup item%v consumed%v baseline%v", itemReceived, stopConsumed, baseline)
						}
					}
					if stopSeq != 0 && baseline.InputSeq() >= stopSeq && baseline.Dx() == 0 && baseline.Dz() == 0 {
						stopConsumed = true
					}
					state := transport.Unreliable{Stamp: baseline.Tick()}
					if !tc.blackout || step < 10 || step > 280 {
						state.Items = [][]byte{build(baseline.Append(nil))}
					}
					flushed, e := endpoint.Flush(now, state)
					if e != nil || flushed.State != transport.Open {
						t.Fatalf("server flush %v %v", flushed, e)
					}
					for _, d := range flushed.Datagrams {
						sim.Send(netsim.BToA, d, now)
					}
					if flushed.UnreliableSent == 1 {
						close := build((wire.TickCloseFields{Stream: baseline.Stream(), Epoch: baseline.Epoch(), Tick: baseline.Tick(), StateItems: 1, NextIntent: 1}).Build())
						if e = endpoint.Send(build(close.Append(nil))); e != nil {
							t.Fatal(e)
						}
						out, e := endpoint.Flush(now, transport.Unreliable{})
						if e != nil {
							t.Fatal(e)
						}
						for _, d := range out.Datagrams {
							sim.Send(netsim.BToA, d, now)
						}
					}
					var command []byte
					if step == 20 {
						command = build(build((wire.PickupFields{Seq: 1, Item: wire.ItemId{Index: 1, Gen: 1}}).Build()).Append(nil))
					}
					if step == tc.secondPickup {
						command = build(build((wire.PickupFields{Seq: 2, Item: wire.ItemId{Index: 1, Gen: 1}}).Build()).Append(nil))
					}
					response, data := peer.step(t, now, step == tc.stopAt, 0, 0, false, command, sim.Poll(netsim.BToA, now))
					transcript.Write(data)
					transcript.Write(build(baseline.Append(nil)))
					if step == tc.stopAt {
						stopSeq = response.seq
						if stopSeq == 0 || response.pose[4] != 0 || response.pose[5] != 0 {
							t.Fatalf("explicit zero while passive did not stop immediately %v", response)
						}
					}
					if response.pose[4] == 1 {
						predictApproach = true
					}
					if tc.stopAt < 0 && response.seq != 0 {
						t.Fatalf("passive prediction manufactured movement command step%d seq%d", step, response.seq)
					}
					if tc.dropStop && step >= tc.stopAt && step < tc.stopAt+6 {
						if response.seq != stopSeq {
							t.Fatalf("lost stop allocated new sequence %d original%d", response.seq, stopSeq)
						}
						droppedCopies += len(response.packets)
					} else {
						for _, d := range response.packets {
							sim.Send(netsim.AToB, d, now)
						}
					}
					if response.mode == 1 {
						sawAwaiting = true
					}
					if sawAwaiting && step > 280 && response.mode == 0 {
						sawRecovery = true
					}
				}
				peer.finish(t)
				if itemReceived != tc.wantItem {
					t.Fatalf("actual pickup owner inventory item%v want%v final%v", itemReceived, tc.wantItem, final)
				}
				if tc.wantItem && (final.X() != float32(1.56) || final.Dx() != 0) {
					t.Fatalf("actual approach completion literal final %v", final)
				}
				if tc.stopAt >= 0 && !stopConsumed {
					t.Fatal("deliberate stop never consumed")
				}
				if tc.stopAt < 0 && !tc.blackout && !predictApproach {
					t.Fatal("passive predictor did not integrate received authoritative approach wish")
				}
				if tc.dropStop && (droppedCopies < 6 || receivedStopCopies == 0) {
					t.Fatalf("lost stop proof dropped%d received%d", droppedCopies, receivedStopCopies)
				}
				if tc.blackout && (!sawAwaiting || !sawRecovery) {
					t.Fatalf("passive recovery awaiting%v recovered%v", sawAwaiting, sawRecovery)
				}
				t.Logf("seed%d inventory_logs=%v final_x=%.9g consumed_input=%d deliberate_stop=%d passive_recovery=%v dropped_stop_copies=%d received_stop_copies=%d", seed, itemReceived, final.X(), final.InputSeq(), stopSeq, sawRecovery, droppedCopies, receivedStopCopies)
				var digest [32]byte
				copy(digest[:], transcript.Sum(nil))
				return digest
			}
			a, b := run(), run()
			if a != b {
				t.Fatalf("repeated approach transcript differs %x %x", a, b)
			}
			t.Logf("repeated approach transcript sha256=%x", a)
		})
	}
}

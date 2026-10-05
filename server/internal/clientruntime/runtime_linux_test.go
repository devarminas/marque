package clientruntime

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/devarminas/marque/server/internal/transport"
	"github.com/devarminas/marque/server/internal/wire"
	"github.com/devarminas/marque/server/internal/wire/codec"
)

type capturedOutput struct {
	mu    sync.Mutex
	bytes bytes.Buffer
}

func (o *capturedOutput) Write(value []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.bytes.Write(value)
}
func (o *capturedOutput) String() string { o.mu.Lock(); defer o.mu.Unlock(); return o.bytes.String() }

func encoded[M wire.Message](t *testing.T, message M, err error) []byte {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	value, err := message.Append(nil)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func TestGodotAutomaticRuntime(t *testing.T) {
	for _, mode := range []string{"positive", "nested", "arena", "unknown", "recovery"} {
		t.Run(mode, func(t *testing.T) { godotRuntime(t, mode) })
	}
}

func godotRuntime(t *testing.T, mode string) {
	client := os.Getenv("MARQUE_RUNTIME_CLIENT")
	if client == "" {
		t.Skip("MARQUE_RUNTIME_CLIENT is unset")
	}
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
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	script := "res://tests/core_runtime_probe.gd"
	if mode=="arena" || mode=="unknown" || mode=="recovery" { script="res://tests/core_map_probe.gd" }
	cmd := exec.CommandContext(ctx, "godot", "--headless", "--path", client, "--script", script, "--quit-after", "4000")
	cmd.Env = append(os.Environ(), "MARQUE_RUNTIME_TOKEN="+tokenPath, "MARQUE_RUNTIME_NEGATIVE="+mode)
	var output capturedOutput
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() { finished <- cmd.Wait() }()
	defer func() {
		cancel()
		select {
		case <-finished:
		default:
			_ = cmd.Process.Kill()
			<-finished
		}
	}()
	var endpoint *transport.Endpoint
	var peer *net.UDPAddr
	var expected = []string{
		"pickup{seq:1 item:ItemId(11/3)}", "drop{seq:2 slot:3}", "equip{seq:3 slot:4}", "unequip{seq:4 worn:\"helmet\"}",
		"gather{seq:5 node:NodeId(21/1)}", "use_self{seq:6 slot:5}", "attack_player{seq:7 target:PlayerId(7/1)}", "respawn{seq:8}",
		"cast_self{seq:9 ability:\"heal\"}", "talk{seq:10 npc:NpcId(1000001/1)}", "dialog_option{seq:11 npc:NpcId(1000001/1) option:\"accept\"}",
		"give{seq:12 npc:NpcId(1000001/1) slot:6}", "party_invite{seq:13 player:PlayerId(7/1)}", "party_accept{seq:14}",
		"party_decline{seq:15}", "party_leave{seq:16}", "party_kick{seq:17 player:PlayerId(7/1)}", "admin{seq:18 line:\"status\"}",
		"use_station{seq:19 slot:7 node:NodeId(21/1)}", "attack_npc{seq:20 target:NpcId(1000001/1)}",
		"cast_player{seq:21 ability:\"heal\" target:PlayerId(7/1)}", "cast_npc{seq:22 ability:\"fireball\" target:NpcId(1000001/1)}",
	}
	seen, commits, blockedPackets := 0, 0, 0
	extra := -1
	cursorSent := false
	inputSeen, jumpSeen := false, false
	var highestInput, stopInput uint32
	stoppedSent, passiveSent := false, false
	started := time.Now()
	clock := func() uint64 { return uint64(time.Since(started).Microseconds()) }
	send := func(u transport.Unreliable) {
		packets, e := endpoint.Flush(clock(), u)
		if e != nil {
			t.Fatal(e)
		}
		if packets.UnreliableSent != len(u.Items) {
			t.Fatalf("scheduled items trimmed got=%d want=%d", packets.UnreliableSent, len(u.Items))
		}
		for _, packet := range packets.Datagrams {
			if _, e := conn.WriteToUDP(packet, peer); e != nil {
				t.Fatal(e)
			}
		}
	}
	stateSent := false
	buffer := make([]byte, 1201)
	for {
		select {
		case err := <-finished:
			finished <- err
			if mode=="arena" || mode=="unknown" || mode=="recovery" {
				marker:="ARM360_AUTHORED_ARENA_MESH_PREDICTION_PASS"
				if mode=="unknown" { marker="ARM360_UNKNOWN_MAP_NOT_READY_PASS" }
				if mode=="recovery" { marker="ARM360_LIVE_PASSIVE_BOUNDED_RECOVERY_PASS" }
				if err!=nil || !strings.Contains(output.String(),marker) || mode=="arena" && !inputSeen { t.Fatalf("map err=%v input=%v\n%s",err,inputSeen,output.String()) }
				t.Log(marker)
				return
			}
			if mode == "nested" {
				log := output.String()
				if err != nil || !strings.Contains(log, "ARM360_NESTED_ARRAY_LOADED sword") || !strings.Contains(log, "Invalid assignment on read-only value") || strings.Contains(log, "ARM360_NESTED_ASSIGNMENT_UNEXPECTEDLY_SUCCEEDED") {
					t.Fatalf("nested read-only control err=%v\n%s", err, log)
				}
				t.Log("ARM360_REAL_NESTED_ARRAY_READ_ONLY_PASS")
				return
			}
			if err != nil || !strings.Contains(output.String(), "ARM360_REAL_UDP_TYPED_ACTIONS_AND_IMMUTABLE_STATE_PASS") {
				t.Fatalf("godot err=%v actions=%d extra=%d cursor_sent=%v commits=%d\n%s", err, seen, extra, cursorSent, commits, output.String())
			}
			if extra < 1 || seen != 23+extra || !inputSeen || !jumpSeen || commits < 3 || blockedPackets < 2 {
				t.Fatalf("actions=%d input=%v commits=%d blocked_packets=%d\n%s", seen, inputSeen, commits, blockedPackets, output.String())
			}
			t.Logf("real token/sealed UDP, 22 exact actions, %d queue pressure actions without sequence gaps, movement, %d commits, %d packets while main blocked; %s", extra, commits, blockedPackets, strings.TrimSpace(output.String()))
			return
		default:
		}
		if ctx.Err() != nil {
			t.Fatalf("deadline\n%s", output.String())
		}
		if err := conn.SetReadDeadline(time.Now().Add(10 * time.Millisecond)); err != nil {
			t.Fatal(err)
		}
		n, from, e := conn.ReadFromUDP(buffer)
		if e != nil {
			if ne, ok := e.(net.Error); ok && ne.Timeout() {
				if endpoint != nil {
					send(transport.Unreliable{})
				}
				continue
			}
			t.Fatal(e)
		}
		if endpoint == nil {
			result, e := gate.Handle(from.AddrPort(), buffer[:n], uint64(time.Now().Unix()))
			if e != nil {
				t.Fatal(e)
			}
			if len(result.Challenge) > 0 {
				if _, e := conn.WriteToUDP(result.Challenge, from); e != nil {
					t.Fatal(e)
				}
				continue
			}
			if result.Admission == nil {
				t.Fatal("missing admission")
			}
			peer = from
			open, seal := transport.NewSessionSeal(transport.Server, result.Admission.Keys)
			endpoint, e = transport.NewEndpoint(transport.Server, transport.DefaultConfig(wire.SchemaHash), open, seal, clock())
			if e != nil {
				t.Fatal(e)
			}
			send(transport.Unreliable{})
			continue
		}
		if from.AddrPort() != peer.AddrPort() {
			continue
		}
		packet, e := endpoint.Receive(buffer[:n], clock())
		if e != nil {
			if errors.Is(e, transport.ErrDuplicate) {
				continue
			}
			t.Fatal(e)
		}
		if extra < 0 {
			if value, e := os.ReadFile(tokenPath + ".admitted"); e == nil {
				extra, e = strconv.Atoi(string(value))
				if e != nil || extra < 1 || extra > 4096 {
					t.Fatal("admission count bounds")
				}
			}
		}
		if _, e := os.Stat(tokenPath + ".blocked"); e == nil {
			blockedPackets++
		}
		if !stateSent {
			transform, e := wire.TransformFields{X: 1, Y: 2, Z: 3}.Build()
			if e != nil {
				t.Fatal(e)
			}
			vitals, e := wire.VitalsFields{Hp: 90, MaxHp: 100, Mana: 10, MaxMana: 20}.Build()
			if e != nil {
				t.Fatal(e)
			}
			ids := []wire.EntityId{wire.PlayerId{Index: 7, Gen: 1}, wire.NpcId{Index: 1000001, Gen: 1}, wire.ItemId{Index: 11, Gen: 3}, wire.NodeId{Index: 21, Gen: 1}}
			var items [][]byte
			for _, id := range ids {
				m, e := wire.EntityFields{Id: id, Transform: codec.Some(transform), Vitals: codec.Some(vitals)}.Build()
				items = append(items, encoded(t, m, e))
			}
			entry, e := wire.BagEntryFields{Slot: 0, Kind: "sword"}.Build()
			if e != nil {
				t.Fatal(e)
			}
			inventory, e := wire.InventoryFields{Stream: 0xfedcba9876543210, EventSeq: 1, Tick: 1, Size: 28, Slots: []wire.BagEntry{entry}}.Build()
			if e := endpoint.Send(encoded(t, inventory, e)); e != nil {
				t.Fatal(e)
			}
			close, e := wire.TickCloseFields{Stream: 0xfedcba9876543210, Epoch: 1, Tick: 1, EventEnd: 1, StateItems: 4, NextIntent: 1}.Build()
			if e := endpoint.Send(encoded(t, close, e)); e != nil {
				t.Fatal(e)
			}
			send(transport.Unreliable{Stamp: 1, Items: items})
			transform, e = wire.TransformFields{X: 5, Y: 2, Z: 3}.Build()
			if e != nil {
				t.Fatal(e)
			}
			entity, e := wire.EntityFields{Id: wire.PlayerId{Index: 7, Gen: 1}, Transform: codec.Some(transform)}.Build()
			quest, e := wire.QuestEntryFields{Id: "quest_one", Title: "Quest", Objective: "Find sword", Status: "active"}.Build()
			if e != nil {
				t.Fatal(e)
			}
			quests, e := wire.QuestLogFields{Stream: 0xfedcba9876543210, EventSeq: 2, Tick: 2, Quests: []wire.QuestEntry{quest}}.Build()
			if e := endpoint.Send(encoded(t, quests, e)); e != nil {
				t.Fatal(e)
			}
			party, e := wire.PartyFields{Stream: 0xfedcba9876543210, EventSeq: 3, Tick: 2, Id: 0xffffffffffffffff, Leader: wire.PlayerId{Index: 7, Gen: 1}, Members: []wire.PlayerId{{Index: 7, Gen: 1}}}.Build()
			if e := endpoint.Send(encoded(t, party, e)); e != nil {
				t.Fatal(e)
			}
			fields:=wire.OwnerMotionFields{Stream:0xfedcba9876543210,Epoch:1,Player:wire.PlayerId{Index:7,Gen:1},Tick:2,MapId:"village",MapRevision:2,TickIntervalUs:40000,HalfExtent:128,Grounded:true,Mode:wire.MotionModeFree}
			if mode=="arena" { fields.MapId="arena_ring_of_trials";fields.MapRevision=3;fields.HalfExtent=84;fields.GroundY=0.4;fields.X=-26.26;fields.Y=5.8;fields.Z=-80.21 }
			if mode=="unknown" { fields.MapRevision=3 }
			motion,motionErr:=fields.Build()
			close, e = wire.TickCloseFields{Stream: 0xfedcba9876543210, Epoch: 1, Tick: 2, EventEnd: 3, StateItems: 2, NextIntent: 1}.Build()
			if e := endpoint.Send(encoded(t, close, e)); e != nil {
				t.Fatal(e)
			}
			send(transport.Unreliable{Stamp: 2, Items: [][]byte{encoded(t, entity, e), encoded(t, motion, motionErr)}})
			stateSent = true
		}
		for _, raw := range packet.Reliable {
			message, e := wire.DecodeIntents(raw)
			if e != nil {
				t.Fatal(e)
			}
			if _, ok := message.(wire.ApplicationCommit); ok {
				commits++
				continue
			}
			want := ""
			if seen < len(expected) {
				want = expected[seen]
			} else if extra >= 0 && seen == 22+extra {
				want = fmt.Sprintf("admin{seq:%d line:\"after_full\"}", seen+1)
			} else {
				want = fmt.Sprintf("respawn{seq:%d}", seen+1)
			}
			if message.String() != want {
				t.Fatalf("action%d got=%s want=%s", seen, message, want)
			}
			seen++
		}
		if len(packet.Unreliable.Items)>8 {t.Fatal("retained input copies exceed bound")}
		for _, raw := range packet.Unreliable.Items {
			message, e := wire.DecodeInput(raw)
			if e != nil {
				t.Fatal(e)
			}
			input := message.(wire.Input)
			if mode=="arena" { if input.Dx()!=0.5 || input.Dz()!=0 || input.Jump() {t.Fatal("arena input")};inputSeen=true;continue }
			if mode=="unknown" || mode=="recovery" { t.Fatal("passive or unknown map authored input") }
			if input.Seq() == 0 || (input.Dx()!=0.5 || input.Dz()!=-0.25) && (input.Dx()!=0 || input.Dz()!=0) || (input.Seq()>1 && input.Jump()) {
				t.Fatalf("input=%s", input)
			}
			if input.Seq()==1 { if !input.Jump(){t.Fatal("coalesced jump edge lost")};jumpSeen=true }
			if input.Dx()==0 && input.Dz()==0 {
				if stopInput!=0 && stopInput!=input.Seq() { t.Fatal("release minted multiple canonical sequences") }
				stopInput=input.Seq()
			} else if passiveSent && input.Seq()>highestInput { t.Fatal("passive server approach minted input") }
			if input.Seq()>highestInput { highestInput=input.Seq() }
			inputSeen = true
		}
		if extra >= 0 && seen == 22+extra && !cursorSent {
			close, e := wire.TickCloseFields{Stream: 0xfedcba9876543210, Epoch: 1, Tick: 3, EventEnd: 3, StateItems: 0, NextIntent: uint32(seen + 1)}.Build()
			if e := endpoint.Send(encoded(t, close, e)); e != nil {
				t.Fatal(e)
			}
			send(transport.Unreliable{Stamp: 3})
			cursorSent = true
		}
		if _,e:=os.Stat(tokenPath+".recovery");e==nil && !passiveSent {
			motion,e:=wire.OwnerMotionFields{Stream:0xfedcba9876543210,Epoch:1,Player:wire.PlayerId{Index:7,Gen:1},Tick:300,X:1,MapId:"village",MapRevision:2,TickIntervalUs:40000,HalfExtent:128,Grounded:true,Mode:wire.MotionModeFree}.Build()
			close,ce:=wire.TickCloseFields{Stream:0xfedcba9876543210,Epoch:1,Tick:300,EventEnd:3,StateItems:1,NextIntent:1}.Build()
			if e:=endpoint.Send(encoded(t,close,ce));e!=nil{t.Fatal(e)}
			send(transport.Unreliable{Stamp:300,Items:[][]byte{encoded(t,motion,e)}})
			passiveSent=true
		}
		if stopInput!=0 && !stoppedSent {
			if highestInput>15 { t.Fatal("render samples allocated canonical input sequences") }
			motion, e := wire.OwnerMotionFields{Stream: 0xfedcba9876543210, Epoch: 1, Player: wire.PlayerId{Index:7,Gen:1}, Tick:4, InputSeq:stopInput, MapId:"village", MapRevision:2, TickIntervalUs:40000, HalfExtent:128, Grounded:true, Mode:wire.MotionModeFree}.Build()
			close, closeErr := wire.TickCloseFields{Stream:0xfedcba9876543210, Epoch:1, Tick:4, EventEnd:3, StateItems:1, NextIntent:uint32(seen+1)}.Build()
			if e:=endpoint.Send(encoded(t,close,closeErr)); e!=nil { t.Fatal(e) }
			send(transport.Unreliable{Stamp:4,Items:[][]byte{encoded(t,motion,e)}})
			stoppedSent=true
		}
		if _,e:=os.Stat(tokenPath+".passive");e==nil && !passiveSent {
			motion, e := wire.OwnerMotionFields{Stream: 0xfedcba9876543210, Epoch:1, Player:wire.PlayerId{Index:7,Gen:1}, Tick:5, InputSeq:stopInput, X:1, Dx:1, MapId:"village", MapRevision:2, TickIntervalUs:40000, HalfExtent:128, Grounded:true, Mode:wire.MotionModeFree}.Build()
			close, closeErr := wire.TickCloseFields{Stream:0xfedcba9876543210, Epoch:1, Tick:5, EventEnd:3, StateItems:1, NextIntent:uint32(seen+1)}.Build()
			if e:=endpoint.Send(encoded(t,close,closeErr));e!=nil { t.Fatal(e) }
			send(transport.Unreliable{Stamp:5,Items:[][]byte{encoded(t,motion,e)}})
			passiveSent=true
		}
		send(transport.Unreliable{})
	}
}

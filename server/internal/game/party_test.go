package game

import (
	"slices"
	"testing"

	mnet "github.com/devarminas/marque/server/internal/net"
)

func TestPartyInviteAcceptLeaveHappyPath(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()

	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	if bob.pendingInviteFrom != alice.id {
		t.Fatalf("pendingInviteFrom=%d want %d", bob.pendingInviteFrom, alice.id)
	}
	if got := pw.events(EvPartyInvited); len(got) != 1 {
		t.Fatalf("party_invited=%d", len(got))
	}

	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)
	if alice.partyID == 0 || bob.partyID != alice.partyID {
		t.Fatalf("alice.party=%d bob.party=%d", alice.partyID, bob.partyID)
	}
	pt := pw.w.parties[alice.partyID]
	if pt == nil || pt.leader != alice.id {
		t.Fatalf("party=%+v", pt)
	}
	if !slices.Equal(pt.members, []mnet.PlayerID{alice.id, bob.id}) {
		t.Fatalf("members=%v", pt.members)
	}
	if bob.pendingInviteFrom != 0 {
		t.Fatal("pending invite survived accept")
	}
	if got := pw.events(EvPartyJoined); len(got) != 1 {
		t.Fatalf("party_joined=%d", len(got))
	}

	pw.w.partyLeave(bob, mnet.PartyLeave{}, 3)
	if bob.partyID != 0 {
		t.Fatalf("bob still in party %d", bob.partyID)
	}
	if alice.partyID == 0 {
		t.Fatal("solo alice party disbanded early")
	}
	if got := pw.events(EvPartyLeft); len(got) != 1 {
		t.Fatalf("party_left=%d", len(got))
	}
	if got := pw.events(EvPartyDisbanded); len(got) != 0 {
		t.Fatalf("disbanded while alice remains: %+v", got)
	}

	pw.w.partyLeave(alice, mnet.PartyLeave{}, 4)
	if alice.partyID != 0 || len(pw.w.parties) != 0 {
		t.Fatalf("alice.party=%d parties=%d", alice.partyID, len(pw.w.parties))
	}
	if got := pw.events(EvPartyDisbanded); len(got) != 1 {
		t.Fatalf("party_disbanded=%d", len(got))
	}
}

func TestPartyLeaderLeaveTransfersLeadership(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	carol := pw.join()

	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: carol.id}, 3)
	pw.w.partyAccept(carol, mnet.PartyAccept{}, 4)

	partyID := alice.partyID
	pw.w.partyLeave(alice, mnet.PartyLeave{}, 5)

	pt := pw.w.parties[partyID]
	if pt == nil {
		t.Fatal("party deleted on leader leave")
	}
	if pt.leader != bob.id {
		t.Fatalf("leader=%d want bob %d", pt.leader, bob.id)
	}
	if !slices.Equal(pt.members, []mnet.PlayerID{bob.id, carol.id}) {
		t.Fatalf("members=%v", pt.members)
	}
	if alice.partyID != 0 {
		t.Fatalf("alice still party %d", alice.partyID)
	}
	if got := pw.events(EvPartyLeader); len(got) != 1 {
		t.Fatalf("party_leader=%d", len(got))
	}
	if got := pw.events(EvPartyLeader)[0]["leader"]; got != float64(bob.id) {
		t.Fatalf("leader field=%v", got)
	}
}

func TestPartyKickRemovesMember(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)

	pw.w.partyKick(alice, mnet.PartyKick{Player: bob.id}, 3)
	if bob.partyID != 0 {
		t.Fatalf("bob party=%d", bob.partyID)
	}
	pt := pw.w.parties[alice.partyID]
	if pt == nil || !slices.Equal(pt.members, []mnet.PlayerID{alice.id}) {
		t.Fatalf("party=%+v", pt)
	}
	if got := pw.events(EvPartyKicked); len(got) != 1 {
		t.Fatalf("party_kicked=%d", len(got))
	}
}

func TestPartyDeclineClearsPending(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyDecline(bob, mnet.PartyDecline{}, 2)
	if bob.pendingInviteFrom != 0 {
		t.Fatalf("pending=%d", bob.pendingInviteFrom)
	}
	if len(pw.w.parties) != 0 {
		t.Fatalf("parties=%d after decline", len(pw.w.parties))
	}
}

func TestPartyInviteRefusesSelf(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: alice.id}, 1)
	assertRefuseReason(t, pw, EvPartyInviteRejected, mnet.ReasonSelf)
}

func TestPartyInviteRefusesUnknownPlayer(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: 999}, 1)
	assertRefuseReason(t, pw, EvPartyInviteRejected, mnet.ReasonUnknownPlayer)
}

func TestPartyInviteRefusesDuplicate(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 2)
	assertRefuseReason(t, pw, EvPartyInviteRejected, mnet.ReasonDuplicateInvite)
}

func TestPartyInviteRefusesAlreadyInParty(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	carol := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)
	pw.w.partyInvite(carol, mnet.PartyInvite{Player: bob.id}, 3)
	assertRefuseReason(t, pw, EvPartyInviteRejected, mnet.ReasonAlreadyInParty)
}

func TestPartyInviteRefusesFullParty(t *testing.T) {
	pw := newProbeWorld(t)
	leader := pw.join()
	var members []*player
	for range PartySize - 1 {
		m := pw.join()
		members = append(members, m)
		pw.w.partyInvite(leader, mnet.PartyInvite{Player: m.id}, mnet.Seq(len(members)))
		pw.w.partyAccept(m, mnet.PartyAccept{}, mnet.Seq(len(members)+10))
	}
	extra := pw.join()
	pw.w.partyInvite(leader, mnet.PartyInvite{Player: extra.id}, 99)
	assertRefuseReason(t, pw, EvPartyInviteRejected, mnet.ReasonPartyFull)
}

func TestPartyInviteRefusesNonLeader(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	carol := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)
	pw.w.partyInvite(bob, mnet.PartyInvite{Player: carol.id}, 3)
	assertRefuseReason(t, pw, EvPartyInviteRejected, mnet.ReasonNotLeader)
}

func TestPartyKickRefusesNonMember(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	carol := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)
	pw.w.partyKick(alice, mnet.PartyKick{Player: carol.id}, 3)
	assertRefuseReason(t, pw, EvPartyKickRejected, mnet.ReasonNotInParty)
}

func TestPartyKickRefusesNonLeader(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	carol := pw.join()
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)
	pw.w.partyInvite(alice, mnet.PartyInvite{Player: carol.id}, 3)
	pw.w.partyAccept(carol, mnet.PartyAccept{}, 4)
	pw.w.partyKick(bob, mnet.PartyKick{Player: carol.id}, 5)
	assertRefuseReason(t, pw, EvPartyKickRejected, mnet.ReasonNotLeader)
}

func TestPartyAcceptRefusesNoInvite(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.partyAccept(alice, mnet.PartyAccept{}, 1)
	assertRefuseReason(t, pw, EvPartyAcceptRejected, mnet.ReasonNoInvite)
}

func TestPartyLeaveRefusesNotInParty(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	pw.w.partyLeave(alice, mnet.PartyLeave{}, 1)
	assertRefuseReason(t, pw, EvPartyLeaveRejected, mnet.ReasonNotInParty)
}

func TestPartyRestatementIsPrivateToMembers(t *testing.T) {
	pw := newProbeWorld(t)
	alice := pw.join()
	bob := pw.join()
	outsider := pw.join()

	pw.w.partyInvite(alice, mnet.PartyInvite{Player: bob.id}, 1)
	pw.w.partyAccept(bob, mnet.PartyAccept{}, 2)

	pt := pw.w.parties[alice.partyID]
	msg := partyMessage(pt)
	if msg.ID == 0 || msg.Leader != alice.id {
		t.Fatalf("restatement=%+v", msg)
	}
	if outsider.partyID != 0 {
		t.Fatal("outsider gained party membership")
	}
	if _, ok := pw.w.parties[outsider.partyID]; outsider.partyID != 0 && ok {
		t.Fatal("outsider party lookup")
	}
	for _, id := range msg.Members {
		if id == outsider.id {
			t.Fatal("outsider listed in party members")
		}
	}
}

func assertRefuseReason(t *testing.T, pw *probeWorld, ev string, want mnet.RejectReason) {
	t.Helper()
	got := pw.events(ev)
	if len(got) != 1 {
		t.Fatalf("%s count=%d", ev, len(got))
	}
	if got[0]["reason"] != string(want) {
		t.Fatalf("%s reason=%v want %s", ev, got[0]["reason"], want)
	}
}

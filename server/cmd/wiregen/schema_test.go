package main

import (
	"strings"
	"testing"
)

const tidy = `handle PlayerId
quant pos min -8 max 8 per_unit 10
enum Mood {
  calm = 1
}
struct Tag {
  text string(4)
}
message hello = 9 on events s2c {
  who PlayerId
  at pos
  tags list(Tag, 2)
  mood Mood
}
`

const messy = `# a comment
handle   PlayerId   # trailing comment

quant pos min -8 max 8 per_unit 10
enum Mood{
	calm=1
}
struct Tag {
      text string( 4 )
}
message hello = 9 on events s2c {
  who PlayerId
  at pos
  tags list( Tag ,2 )
  mood Mood
}`

func mustParse(t *testing.T, src string) *Schema {
	t.Helper()
	s, err := Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestCanonicalIgnoresWhitespaceAndComments(t *testing.T) {
	a, b := mustParse(t, tidy), mustParse(t, messy)
	want := "wire 1\n" +
		"handle PlayerId\n" +
		"quant pos min -8 max 8 per_unit 10\n" +
		"enum Mood {\ncalm = 1\n}\n" +
		"struct Tag {\ntext string(4)\n}\n" +
		"message hello = 9 on events s2c {\nwho PlayerId\nat pos\ntags list(Tag, 2)\nmood Mood\n}\n"
	if a.Canonical() != want {
		t.Fatalf("canonical form:\n%s\nwant:\n%s", a.Canonical(), want)
	}
	if a.Hash() != b.Hash() {
		t.Fatalf("whitespace changed the hash: %#x vs %#x", a.Hash(), b.Hash())
	}
	if a.Hash() != 0x3796531fac0fb050 {
		t.Fatalf("hash %#x is not the first 8 bytes of sha256(canonical)", a.Hash())
	}
}

func TestHashChangesWithMeaning(t *testing.T) {
	base := mustParse(t, tidy).Hash()
	for _, edit := range [][2]string{
		{"string(4)", "string(5)"},
		{"= 9 on", "= 10 on"},
		{"per_unit 10", "per_unit 20"},
		{"calm = 1", "calm = 2"},
		{"at pos", "at_pos pos"},
	} {
		if h := mustParse(t, strings.Replace(tidy, edit[0], edit[1], 1)).Hash(); h == base {
			t.Errorf("%q -> %q kept hash %#x", edit[0], edit[1], h)
		}
	}
}

func TestParseRejects(t *testing.T) {
	cases := []struct{ src, want string }{
		{"message a = 1 on input c2s {\n}\nmessage b = 1 on input c2s {\n}", "message id 1 already used by a"},
		{"message a = 1 on state c2s {\n}", "channel state is s2c, message says c2s"},
		{"message a = 1 on lobby s2c {\n}", `unknown channel "lobby"`},
		{"message a = 1 on state s2c {\n  x Vec3\n}", `unknown type "Vec3"`},
		{"message a = 1 on state s2c {\n  x u8 where x < 3\n}", `unknown term "x < 3"`},
		{"message a = 1 on state s2c {\n  x u8\n  rule x < 3\n}", `rule names "3", which is not a field`},
		{"message a = 1 on state s2c {\n  channel u8\n}", `field name "channel"`},
		{"message a = 1 on state s2c {\n  s string(0)\n}", `bound "0"`},
		{"message a = 1 on state s2c {\n  x u8\n  x u16\n}", `duplicate field "x"`},
		{"enum E {\n  a = 1\n  b = 1\n}", "duplicate member or value"},
		{"handle playerId", "must be PascalCase"},
		{"quant p min 5 max 5 per_unit 1", "need min < max"},
		{"quant p min 0 max 100000 per_unit 100000", "more than 2^32 steps"},
		{"message a = 1 on state s2c {\n  x u8", "missing closing }"},
		{"message a = 1 on state s2c {\n  x list(\n}", "schema line 2: missing type"},
		{"message a = 1 on state s2c {\n  constexpr u8\n}", `field name "constexpr"`},
		{"enum E {\n  delete = 1\n}", `enum member "delete" must be snake_case and not a C++ keyword`},
		{"enum E {\n}", "schema line 1: enum E has no members"},
		{"handle Message", `name "Message" is reserved`},
		{"struct StateMsg {\n  x u8\n}", `name "StateMsg" is reserved`},
		{"message decode_next_state = 1 on state s2c {\n}", `name "DecodeNextState" is reserved`},
		{"struct Pair {\n  x u8\n}\nhandle PairFields", `duplicate name "PairFields"`},
		{"message hp = 1 on state s2c {\n}\nmessage hp_fields = 2 on state s2c {\n}", `duplicate name "HpFields"`},
		{"message a = 1 on state s2c {\n  build u8\n}", `field name "build"`},
		{"\nstruct Empty {\n}", "schema line 2: struct Empty has no fields"},
		{"quant p min 2000000000 max 2000000001 per_unit 2000000000", "exceeds 2^53"},
	}
	for _, c := range cases {
		_, err := Parse(c.src)
		if err == nil || !strings.Contains(err.Error(), c.want) || !strings.HasPrefix(err.Error(), "schema line ") {
			t.Errorf("Parse(%q) = %v, want error with a line number containing %q", c.src, err, c.want)
		}
	}
}

const ruled = `handle PlayerId
quant coord min -10 max 10 per_unit 4
enum Option {
  accept = 1
  decline = 2
  stop = 3
}
struct Item {
  slot u8 where 0..39
  owner PlayerId
}
message party = 4 on events s2c {
  leader PlayerId
  members list(PlayerId, 5) where unique
  rule leader in members
}
message bag = 5 on events s2c {
  size u8 where 1..40
  items list(Item, 40) where unique(slot)
  rule items.slot<size
  rule items.owner == leader
  leader PlayerId
}
message zone = 6 on state s2c {
  lo coord where -8.00..8
  hi coord where -10..5.25
  tilt i8 where -45..45
  pick Option where {accept,stop}
  picks list(Option, 3) where unique and {accept, decline}
  rule lo <= hi
  rule tilt != tilt
}
`

func TestCanonicalPrintsRules(t *testing.T) {
	want := "wire 1\n" +
		"handle PlayerId\n" +
		"quant coord min -10 max 10 per_unit 4\n" +
		"enum Option {\naccept = 1\ndecline = 2\nstop = 3\n}\n" +
		"struct Item {\nslot u8 where 0..39\nowner PlayerId\n}\n" +
		"message party = 4 on events s2c {\nleader PlayerId\nmembers list(PlayerId, 5) where unique\nrule leader in members\n}\n" +
		"message bag = 5 on events s2c {\nsize u8 where 1..40\nitems list(Item, 40) where unique(slot)\nleader PlayerId\n" +
		"rule items.slot < size\nrule items.owner == leader\n}\n" +
		"message zone = 6 on state s2c {\nlo coord where -8..8\nhi coord where -10..5.25\ntilt i8 where -45..45\n" +
		"pick Option where {accept, stop}\npicks list(Option, 3) where unique and {accept, decline}\n" +
		"rule lo <= hi\nrule tilt != tilt\n}\n"
	if got := mustParse(t, ruled).Canonical(); got != want {
		t.Fatalf("canonical form:\n%s\nwant:\n%s", got, want)
	}
}

func TestRangeBoundsBecomeWireSteps(t *testing.T) {
	s := mustParse(t, ruled)
	zone := s.Messages[2]
	lo, hi, tilt := zone.Fields[0].Where[0], zone.Fields[1].Where[0], zone.Fields[2].Where[0]
	if lo.LoStep != 8 || lo.HiStep != 72 || !lo.CheckLo || !lo.CheckHi {
		t.Errorf("lo -8..8 on coord (-10..10 per 4): steps %d..%d check %v/%v, want 8..72 true/true", lo.LoStep, lo.HiStep, lo.CheckLo, lo.CheckHi)
	}
	if hi.LoStep != 0 || hi.HiStep != 61 || hi.CheckLo || !hi.CheckHi {
		t.Errorf("hi -10..5.25: steps %d..%d check %v/%v, want 0..61 false/true", hi.LoStep, hi.HiStep, hi.CheckLo, hi.CheckHi)
	}
	if !tilt.CheckLo || !tilt.CheckHi {
		t.Errorf("tilt -45..45 on i8 must check both bounds")
	}
	if slot := s.Structs[0].Fields[0].Where[0]; slot.CheckLo || !slot.CheckHi {
		t.Errorf("slot 0..39 on u8: check %v/%v, want false/true (0 is u8's own floor)", slot.CheckLo, slot.CheckHi)
	}
}

func TestHashChangesWithRules(t *testing.T) {
	base := mustParse(t, ruled).Hash()
	for _, edit := range [][2]string{
		{"0..39", "0..38"},
		{"where unique\n", "\n"},
		{"unique(slot)", "unique(owner)"},
		{"{accept,stop}", "{accept}"},
		{"rule leader in members", ""},
		{"rule lo <= hi", "rule lo < hi"},
	} {
		if h := mustParse(t, strings.Replace(ruled, edit[0], edit[1], 1)).Hash(); h == base {
			t.Errorf("%q -> %q kept hash %#x", edit[0], edit[1], h)
		}
	}
}

func TestParseRejectsRules(t *testing.T) {
	head := "handle PlayerId\nhandle NpcId\nquant coord min -10 max 10 per_unit 4\nenum E {\n  a = 1\n  b = 2\n}\nstruct S {\n  n u8\n  w f32\n  xs list(u8, 2)\n}\n"
	msg := func(body string) string { return head + "message m = 1 on state s2c {\n  " + body + "\n}" }
	cases := []struct{ src, want string }{
		{msg("x u8 where 0..256"), "range bound 256 is outside u8"},
		{msg("x i8 where -129..0"), "range bound -129 is outside i8"},
		{msg("x u8 where 5..4"), "low bound above high bound"},
		{msg("x u8 where 1.5..4"), "range bound 1.5 is not an integer"},
		{msg("x u8 where 0x1..4"), `range bound "0x1" is not a decimal number`},
		{msg("x coord where 0.1..1"), "not on quant coord's grid of 1/4"},
		{msg("x coord where 0..11"), "range bound 11 is outside quant coord"},
		{msg("x f32 where 0..1"), "a range needs an integer or quant"},
		{msg("x string(3) where 0..1"), "a range needs an integer or quant"},
		{msg("x E where {a, c}"), `enum E has no member "c"`},
		{msg("x E where {a, a}"), `set names "a" twice`},
		{msg("x E where {}"), "want: {member, member, ...}"},
		{msg("x u8 where {a}"), "a {member, ...} set needs an enum"},
		{msg("x u8 where unique"), "unique needs a list"},
		{msg("xs list(u8, 257) where unique"), "list bound of at most 256"},
		{msg("xs list(S, 2) where unique"), "S cannot be compared (it holds a list or an f32)"},
		{msg("xs list(S, 2) where unique(w)"), "unique(w): f32 cannot be compared"},
		{"quant c min 0 max 1 per_unit 2\nstruct Q {\n  c c\n}\nmessage m = 1 on state s2c {\n  qs list(Q, 2) where unique\n}", "Q holds a quant"},
		{msg("xs list(S, 2) where unique(q)"), `struct S has no field "q"`},
		{msg("xs list(u8, 2) where unique(n)"), "unique(n) needs a list of structs"},
		{msg("xs list(u8, 2) where unique and unique"), "where clause repeats"},
		{msg("xs list(u8, 2) where unique and"), "want: where <term> [and <term>]"},
		{msg("x u8\n  rule x > x"), `rule operator ">" is not one of`},
		{msg("x u8\n  rule x <"), "want: rule <field>"},
		{msg("x u8\n  y u16\n  rule x < y"), "compares u8 with u16"},
		{msg("x PlayerId\n  y NpcId\n  rule x == y"), "compares PlayerId with NpcId"},
		{msg("x PlayerId\n  rule x < x"), "PlayerId has no order"},
		{msg("x f32\n  rule x == x"), "f32 cannot be compared"},
		{msg("s S\n  rule s == s"), "S cannot be compared"},
		{msg("xs list(u8, 2)\n  ys list(u8, 2)\n  rule xs < ys"), "at most one side may be a list"},
		{msg("x u8\n  xs list(u8, 2)\n  rule xs in x"), "in needs a single value on the left and a list on the right"},
		{msg("x u8\n  rule x.n == x"), "x is not a struct or a list of structs"},
		{msg("s S\n  rule s.q == s.n"), `struct S has no field "q"`},
		{"rule a < b", "a rule line belongs inside a struct or message"},
	}
	for _, c := range cases {
		_, err := Parse(c.src)
		if err == nil || !strings.Contains(err.Error(), c.want) || !strings.HasPrefix(err.Error(), "schema line ") {
			t.Errorf("Parse(%q) = %v, want error with a line number containing %q", c.src, err, c.want)
		}
	}
}

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
	want := "handle PlayerId\n" +
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
	if a.Hash() != 0x9c57fe2b9cb6198b {
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
		{"message a = 1 on state s2c {\n  x u8 where x < 3\n}", "where clauses are reserved"},
		{"message a = 1 on state s2c {\n  rule x < 3\n}", "rule lines are reserved"},
		{"message a = 1 on state s2c {\n  channel u8\n}", `field name "channel"`},
		{"message a = 1 on state s2c {\n  s string(0)\n}", `bound "0"`},
		{"message a = 1 on state s2c {\n  x u8\n  x u16\n}", `duplicate field "x"`},
		{"enum E {\n  a = 1\n  b = 1\n}", "duplicate member or value"},
		{"handle playerId", "must be PascalCase"},
		{"quant p min 5 max 5 per_unit 1", "need min < max"},
		{"quant p min 0 max 100000 per_unit 100000", "more than 2^32 steps"},
		{"message a = 1 on state s2c {\n  x u8", "missing closing }"},
	}
	for _, c := range cases {
		_, err := Parse(c.src)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("Parse(%q) = %v, want error containing %q", c.src, err, c.want)
		}
	}
}

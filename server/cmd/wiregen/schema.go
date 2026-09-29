package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

type Schema struct {
	Handles  []*Handle
	Quants   []*Quant
	Enums    []*Enum
	Structs  []*Struct
	Messages []*Message
}

type Handle struct{ Name string }

type Quant struct {
	Name              string
	Min, Max, PerUnit int64
}

// Steps is the largest encoded value; the wire value runs 0..Steps.
func (q *Quant) Steps() uint64 { return uint64((q.Max - q.Min) * q.PerUnit) }

func (q *Quant) Width() int {
	switch s := q.Steps(); {
	case s <= 0xff:
		return 1
	case s <= 0xffff:
		return 2
	default:
		return 4
	}
}

type Enum struct {
	Name    string
	Members []EnumMember
}

type EnumMember struct {
	Name  string
	Value uint32
}

type Struct struct {
	Name   string
	Fields []Field
}

type Message struct {
	Name      string
	ID        uint32
	Channel   string
	Direction string
	Fields    []Field
}

type Field struct {
	Name string
	Type Type
}

type Kind int

const (
	KindPrim Kind = iota
	KindQuant
	KindString
	KindEnum
	KindList
	KindHandle
	KindStruct
)

// Type is a field type. Prim is set for KindPrim, Bound for strings and lists,
// Elem for lists, and exactly one of the declaration pointers for named types.
type Type struct {
	Kind   Kind
	Prim   string
	Bound  int
	Elem   *Type
	Quant  *Quant
	Enum   *Enum
	Handle *Handle
	Struct *Struct
}

// MinSize is the fewest bytes any value of t encodes to. List decoders use it
// to refuse a count the remaining bytes cannot hold before allocating.
func (t Type) MinSize() int {
	switch t.Kind {
	case KindPrim:
		return primSize[t.Prim]
	case KindQuant:
		return t.Quant.Width()
	case KindString, KindEnum, KindList:
		return 1
	case KindHandle:
		return 2
	default:
		n := 0
		for _, f := range t.Struct.Fields {
			n += f.Type.MinSize()
		}
		return n
	}
}

func (t Type) Canonical() string {
	switch t.Kind {
	case KindPrim:
		return t.Prim
	case KindQuant:
		return t.Quant.Name
	case KindString:
		return fmt.Sprintf("string(%d)", t.Bound)
	case KindEnum:
		return t.Enum.Name
	case KindList:
		return fmt.Sprintf("list(%s, %d)", t.Elem.Canonical(), t.Bound)
	case KindHandle:
		return t.Handle.Name
	default:
		return t.Struct.Name
	}
}

// primSize is each primitive's encoded width in bytes.
var primSize = map[string]int{
	"u8": 1, "u16": 2, "u32": 4, "u64": 8,
	"i8": 1, "i16": 2, "i32": 4, "i64": 8,
	"bool": 1, "f32": 4,
}

// codecVersion opens the canonical form, so a change to the byte rules changes
// the hash even when the schema text does not. Bump it with any codec rule.
const codecVersion = 1

// channels lists the fixed channels in ADR 0018 section 1.3 order. Each one
// gets its own generated message interface and decoder.
var channels = []string{"state", "events", "input", "intents"}

var channelDirection = map[string]string{
	"state": "s2c", "events": "s2c", "input": "c2s", "intents": "c2s",
}

// cppKeywords is the C++23 keyword list. Fields and enum members are emitted
// verbatim as C++ identifiers, so none may be a keyword.
var cppKeywords = setOf(
	"alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor",
	"bool", "break", "case", "catch", "char", "char8_t", "char16_t",
	"char32_t", "class", "compl", "concept", "const", "consteval",
	"constexpr", "constinit", "const_cast", "continue", "co_await",
	"co_return", "co_yield", "decltype", "default", "delete", "do", "double",
	"dynamic_cast", "else", "enum", "explicit", "export", "extern", "false",
	"float", "for", "friend", "goto", "if", "inline", "int", "long",
	"mutable", "namespace", "new", "noexcept", "not", "not_eq", "nullptr",
	"operator", "or", "or_eq", "private", "protected", "public", "register",
	"reinterpret_cast", "requires", "return", "short", "signed", "sizeof",
	"static", "static_assert", "static_cast", "struct", "switch", "template",
	"this", "thread_local", "throw", "true", "try", "typedef", "typeid",
	"typename", "union", "unsigned", "using", "virtual", "void", "volatile",
	"wchar_t", "while", "xor", "xor_eq",
)

// generatedMembers collide with generated message members (Go methods
// MessageID, Channel, Append, String; C++ message_id, channel).
var generatedMembers = setOf("message_id", "channel", "append", "string")

// reservedTypes are the package-level names the Go generator emits.
var reservedTypes = func() map[string]bool {
	out := setOf("Message", "SchemaHash")
	for _, ch := range channels {
		c := goName(ch)
		out[c+"Msg"], out["Decode"+c], out["DecodeNext"+c] = true, true, true
	}
	return out
}()

func setOf(names ...string) map[string]bool {
	out := make(map[string]bool, len(names))
	for _, n := range names {
		out[n] = true
	}
	return out
}

var (
	snakeName  = regexp.MustCompile(`^[a-z][a-z0-9]*(_[a-z0-9]+)*$`)
	pascalName = regexp.MustCompile(`^[A-Z][A-Za-z0-9]*$`)
)

type parser struct {
	lines  [][]string
	lineNo []int
	pos    int
	schema *Schema
	types  map[string]Type
	names  map[string]bool
	msgIDs map[uint32]string
}

func Parse(src string) (*Schema, error) {
	p := &parser{
		schema: &Schema{},
		types:  map[string]Type{},
		names:  map[string]bool{},
		msgIDs: map[uint32]string{},
	}
	for i, raw := range strings.Split(src, "\n") {
		if j := strings.IndexByte(raw, '#'); j >= 0 {
			raw = raw[:j]
		}
		if toks := tokenize(raw); len(toks) > 0 {
			p.lines = append(p.lines, toks)
			p.lineNo = append(p.lineNo, i+1)
		}
	}
	for p.pos < len(p.lines) {
		if err := p.decl(); err != nil {
			return nil, err
		}
	}
	return p.schema, nil
}

func tokenize(line string) []string {
	for _, c := range "(){},=" {
		line = strings.ReplaceAll(line, string(c), " "+string(c)+" ")
	}
	return strings.Fields(line)
}

func (p *parser) errf(format string, args ...any) error {
	return p.errAt(p.lineNo[p.pos], format, args...)
}

func (p *parser) errAt(line int, format string, args ...any) error {
	return fmt.Errorf("schema line %d: %s", line, fmt.Sprintf(format, args...))
}

func (p *parser) declareType(name string, t Type, line int) error {
	if !pascalName.MatchString(name) {
		return p.errAt(line, "type name %q must be PascalCase", name)
	}
	if reservedTypes[name] {
		return p.errAt(line, "type name %q is reserved for generated code", name)
	}
	if p.names[name] {
		return p.errAt(line, "duplicate name %q", name)
	}
	p.names[name] = true
	p.types[name] = t
	return nil
}

func (p *parser) decl() error {
	toks := p.lines[p.pos]
	switch toks[0] {
	case "handle":
		if len(toks) != 2 {
			return p.errf("want: handle <Name>")
		}
		h := &Handle{Name: toks[1]}
		if err := p.declareType(h.Name, Type{Kind: KindHandle, Handle: h}, p.lineNo[p.pos]); err != nil {
			return err
		}
		p.schema.Handles = append(p.schema.Handles, h)
		p.pos++
		return nil
	case "quant":
		return p.quant(toks)
	case "enum":
		return p.enum(toks)
	case "struct":
		return p.structDecl(toks)
	case "message":
		return p.message(toks)
	case "rule":
		return p.errf("rule declarations are reserved for declared rules (ARM-350)")
	}
	return p.errf("unknown declaration %q", toks[0])
}

func (p *parser) quant(toks []string) error {
	if len(toks) != 8 || toks[2] != "min" || toks[4] != "max" || toks[6] != "per_unit" {
		return p.errf("want: quant <name> min <int> max <int> per_unit <int>")
	}
	q := &Quant{Name: toks[1]}
	var err error
	for _, f := range []struct {
		dst *int64
		tok string
	}{{&q.Min, toks[3]}, {&q.Max, toks[5]}, {&q.PerUnit, toks[7]}} {
		if *f.dst, err = strconv.ParseInt(f.tok, 10, 32); err != nil {
			return p.errf("quant %s: %q is not an integer", q.Name, f.tok)
		}
	}
	if !snakeName.MatchString(q.Name) {
		return p.errf("quant name %q must be snake_case", q.Name)
	}
	if _, dup := p.types[q.Name]; dup || primSize[q.Name] > 0 || q.Name == "string" || q.Name == "list" {
		return p.errf("duplicate name %q", q.Name)
	}
	if q.Min >= q.Max || q.PerUnit < 1 {
		return p.errf("quant %s: need min < max and per_unit >= 1", q.Name)
	}
	if q.Steps() > 0xffffffff {
		return p.errf("quant %s: more than 2^32 steps", q.Name)
	}
	if max(-q.Min, q.Max)*q.PerUnit > 1<<53 {
		return p.errf("quant %s: max(|min|, |max|) * per_unit exceeds 2^53, so v * per_unit is not exact in a double", q.Name)
	}
	p.types[q.Name] = Type{Kind: KindQuant, Quant: q}
	p.schema.Quants = append(p.schema.Quants, q)
	p.pos++
	return nil
}

func (p *parser) openBlock(toks []string, want int) error {
	if len(toks) != want || toks[want-1] != "{" {
		return p.errf("declaration header must end with {")
	}
	return nil
}

// block calls line for each body line until the closing brace.
func (p *parser) block(line func([]string) error) error {
	p.pos++
	for ; p.pos < len(p.lines); p.pos++ {
		toks := p.lines[p.pos]
		if len(toks) == 1 && toks[0] == "}" {
			p.pos++
			return nil
		}
		if err := line(toks); err != nil {
			return err
		}
	}
	p.pos--
	return p.errf("missing closing }")
}

func (p *parser) enum(toks []string) error {
	if err := p.openBlock(toks, 3); err != nil {
		return err
	}
	e := &Enum{Name: toks[1]}
	header := p.lineNo[p.pos]
	if err := p.declareType(e.Name, Type{Kind: KindEnum, Enum: e}, header); err != nil {
		return err
	}
	seenName, seenValue := map[string]bool{}, map[uint32]bool{}
	err := p.block(func(t []string) error {
		if len(t) != 3 || t[1] != "=" {
			return p.errf("want: <member> = <value>")
		}
		v, err := strconv.ParseUint(t[2], 10, 32)
		if err != nil {
			return p.errf("enum value %q is not a u32", t[2])
		}
		if !snakeName.MatchString(t[0]) || cppKeywords[t[0]] {
			return p.errf("enum member %q must be snake_case and not a C++ keyword", t[0])
		}
		if seenName[t[0]] || seenValue[uint32(v)] {
			return p.errf("enum %s: duplicate member or value in %q", e.Name, strings.Join(t, " "))
		}
		seenName[t[0]], seenValue[uint32(v)] = true, true
		e.Members = append(e.Members, EnumMember{Name: t[0], Value: uint32(v)})
		return nil
	})
	if err == nil && len(e.Members) == 0 {
		return p.errAt(header, "enum %s has no members", e.Name)
	}
	p.schema.Enums = append(p.schema.Enums, e)
	return err
}

func (p *parser) structDecl(toks []string) error {
	if err := p.openBlock(toks, 3); err != nil {
		return err
	}
	s := &Struct{Name: toks[1]}
	header := p.lineNo[p.pos]
	fields, err := p.fields()
	if err != nil {
		return err
	}
	if len(fields) == 0 {
		return p.errAt(header, "struct %s has no fields; a zero-byte list element would make any count free to send", s.Name)
	}
	s.Fields = fields
	if err := p.declareType(s.Name, Type{Kind: KindStruct, Struct: s}, header); err != nil {
		return err
	}
	p.schema.Structs = append(p.schema.Structs, s)
	return nil
}

func (p *parser) message(toks []string) error {
	if len(toks) != 8 || toks[2] != "=" || toks[4] != "on" || toks[7] != "{" {
		return p.errf("want: message <name> = <id> on <channel> <c2s|s2c> {")
	}
	m := &Message{Name: toks[1], Channel: toks[5], Direction: toks[6]}
	id, err := strconv.ParseUint(toks[3], 10, 32)
	if err != nil {
		return p.errf("message id %q is not a u32", toks[3])
	}
	m.ID = uint32(id)
	if !snakeName.MatchString(m.Name) {
		return p.errf("message name %q must be snake_case", m.Name)
	}
	if prev, dup := p.msgIDs[m.ID]; dup {
		return p.errf("message id %d already used by %s", m.ID, prev)
	}
	dir, ok := channelDirection[m.Channel]
	if !ok {
		return p.errf("unknown channel %q (state, events, input, intents)", m.Channel)
	}
	if m.Direction != dir {
		return p.errf("channel %s is %s, message says %s", m.Channel, dir, m.Direction)
	}
	pascal := goName(m.Name)
	if reservedTypes[pascal] {
		return p.errf("message name %q becomes %s, which is reserved for generated code", m.Name, pascal)
	}
	if p.names[pascal] {
		return p.errf("duplicate name %q", pascal)
	}
	p.names[pascal] = true
	p.msgIDs[m.ID] = m.Name
	if m.Fields, err = p.fields(); err != nil {
		return err
	}
	p.schema.Messages = append(p.schema.Messages, m)
	return nil
}

func (p *parser) fields() ([]Field, error) {
	var out []Field
	seen := map[string]bool{}
	err := p.block(func(t []string) error {
		if t[0] == "rule" {
			return p.errf("rule lines are reserved for declared rules (ARM-350)")
		}
		if len(t) < 2 {
			return p.errf("want: <field> <type>")
		}
		name := t[0]
		if !snakeName.MatchString(name) || cppKeywords[name] || generatedMembers[name] {
			return p.errf("field name %q must be snake_case and not reserved", name)
		}
		if seen[name] {
			return p.errf("duplicate field %q", name)
		}
		seen[name] = true
		typ, rest, err := p.typ(t[1:])
		if err != nil {
			return err
		}
		if len(rest) > 0 {
			if rest[0] == "where" {
				return p.errf("where clauses are reserved for declared rules (ARM-350)")
			}
			return p.errf("unexpected %q after field type", strings.Join(rest, " "))
		}
		out = append(out, Field{Name: name, Type: typ})
		return nil
	})
	return out, err
}

// typ parses one type from the front of toks and returns the unread tail.
func (p *parser) typ(toks []string) (Type, []string, error) {
	if len(toks) == 0 {
		return Type{}, nil, p.errf("missing type")
	}
	head := toks[0]
	switch {
	case primSize[head] > 0:
		return Type{Kind: KindPrim, Prim: head}, toks[1:], nil
	case head == "string":
		if len(toks) < 4 || toks[1] != "(" || toks[3] != ")" {
			return Type{}, nil, p.errf("want: string(<max bytes>)")
		}
		n, err := p.bound(toks[2])
		return Type{Kind: KindString, Bound: n}, toks[4:], err
	case head == "list":
		if len(toks) < 2 || toks[1] != "(" {
			return Type{}, nil, p.errf("want: list(<type>, <max count>)")
		}
		elem, rest, err := p.typ(toks[2:])
		if err != nil {
			return Type{}, nil, err
		}
		if elem.Kind == KindList {
			return Type{}, nil, p.errf("list of list is not supported; wrap the inner list in a struct")
		}
		if len(rest) < 3 || rest[0] != "," || rest[2] != ")" {
			return Type{}, nil, p.errf("want: list(<type>, <max count>)")
		}
		n, err := p.bound(rest[1])
		return Type{Kind: KindList, Bound: n, Elem: &elem}, rest[3:], err
	}
	if t, ok := p.types[head]; ok {
		return t, toks[1:], nil
	}
	return Type{}, nil, p.errf("unknown type %q (declare it before use)", head)
}

func (p *parser) bound(tok string) (int, error) {
	n, err := strconv.ParseUint(tok, 10, 16)
	if err != nil || n == 0 {
		return 0, p.errf("bound %q must be an integer in 1..65535", tok)
	}
	return int(n), nil
}

// Canonical is the hashed form of the schema: a "wire <codecVersion>" line,
// then every declaration in a fixed category order (handles, quants, enums,
// structs, messages), each category in source order, one line per declaration
// header, member, or field, with single spaces and no comments.
func (s *Schema) Canonical() string {
	var b strings.Builder
	fmt.Fprintf(&b, "wire %d\n", codecVersion)
	for _, h := range s.Handles {
		fmt.Fprintf(&b, "handle %s\n", h.Name)
	}
	for _, q := range s.Quants {
		fmt.Fprintf(&b, "quant %s min %d max %d per_unit %d\n", q.Name, q.Min, q.Max, q.PerUnit)
	}
	for _, e := range s.Enums {
		fmt.Fprintf(&b, "enum %s {\n", e.Name)
		for _, m := range e.Members {
			fmt.Fprintf(&b, "%s = %d\n", m.Name, m.Value)
		}
		b.WriteString("}\n")
	}
	writeFields := func(fs []Field) {
		for _, f := range fs {
			fmt.Fprintf(&b, "%s %s\n", f.Name, f.Type.Canonical())
		}
		b.WriteString("}\n")
	}
	for _, st := range s.Structs {
		fmt.Fprintf(&b, "struct %s {\n", st.Name)
		writeFields(st.Fields)
	}
	for _, m := range s.Messages {
		fmt.Fprintf(&b, "message %s = %d on %s %s {\n", m.Name, m.ID, m.Channel, m.Direction)
		writeFields(m.Fields)
	}
	return b.String()
}

// Hash is the first 8 bytes of SHA-256(Canonical()), read big-endian, so its
// hex spelling equals the first 16 hex digits of `wiregen canon | sha256sum`.
func (s *Schema) Hash() uint64 {
	sum := sha256.Sum256([]byte(s.Canonical()))
	return binary.BigEndian.Uint64(sum[:8])
}

func (s *Schema) MessagesOn(channel string) []*Message {
	var out []*Message
	for _, m := range s.Messages {
		if m.Channel == channel {
			out = append(out, m)
		}
	}
	return out
}

// goName turns snake_case into PascalCase: max_hp -> MaxHp.
func goName(snake string) string {
	var b strings.Builder
	for _, part := range strings.Split(snake, "_") {
		b.WriteString(strings.ToUpper(part[:1]) + part[1:])
	}
	return b.String()
}

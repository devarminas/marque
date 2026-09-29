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

var prims = map[string]bool{
	"u8": true, "u16": true, "u32": true, "u64": true,
	"i8": true, "i16": true, "i32": true, "i64": true,
	"bool": true, "f32": true,
}

var channelDirection = map[string]string{
	"state": "s2c", "events": "s2c", "input": "c2s", "intents": "c2s",
}

// Reserved field names collide with generated members (Go methods MessageID,
// Channel, Append, String; C++ message_id, channel) or with C++ keywords.
var reservedFields = map[string]bool{
	"message_id": true, "channel": true, "append": true, "string": true,
	"alignas": true, "alignof": true, "and": true, "asm": true, "auto": true,
	"bool": true, "break": true, "case": true, "catch": true, "char": true,
	"class": true, "const": true, "continue": true, "default": true,
	"delete": true, "do": true, "double": true, "else": true, "enum": true,
	"explicit": true, "export": true, "extern": true, "false": true,
	"float": true, "for": true, "friend": true, "goto": true, "if": true,
	"inline": true, "int": true, "long": true, "mutable": true,
	"namespace": true, "new": true, "noexcept": true, "not": true,
	"nullptr": true, "operator": true, "or": true, "private": true,
	"protected": true, "public": true, "register": true, "return": true,
	"short": true, "signed": true, "sizeof": true, "static": true,
	"struct": true, "switch": true, "template": true, "this": true,
	"throw": true, "true": true, "try": true, "typedef": true,
	"typeid": true, "typename": true, "union": true, "unsigned": true,
	"using": true, "virtual": true, "void": true, "volatile": true,
	"while": true, "xor": true,
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
	return fmt.Errorf("schema line %d: %s", p.lineNo[p.pos], fmt.Sprintf(format, args...))
}

func (p *parser) declareType(name string, t Type) error {
	if !pascalName.MatchString(name) {
		return p.errf("type name %q must be PascalCase", name)
	}
	if p.names[name] {
		return p.errf("duplicate name %q", name)
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
		if err := p.declareType(h.Name, Type{Kind: KindHandle, Handle: h}); err != nil {
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
	if _, dup := p.types[q.Name]; dup || prims[q.Name] || q.Name == "string" || q.Name == "list" {
		return p.errf("duplicate name %q", q.Name)
	}
	if q.Min >= q.Max || q.PerUnit < 1 {
		return p.errf("quant %s: need min < max and per_unit >= 1", q.Name)
	}
	if q.Steps() > 0xffffffff {
		return p.errf("quant %s: more than 2^32 steps", q.Name)
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
	if err := p.declareType(e.Name, Type{Kind: KindEnum, Enum: e}); err != nil {
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
		if !snakeName.MatchString(t[0]) {
			return p.errf("enum member %q must be snake_case", t[0])
		}
		if seenName[t[0]] || seenValue[uint32(v)] {
			return p.errf("enum %s: duplicate member or value in %q", e.Name, strings.Join(t, " "))
		}
		seenName[t[0]], seenValue[uint32(v)] = true, true
		e.Members = append(e.Members, EnumMember{Name: t[0], Value: uint32(v)})
		return nil
	})
	if err == nil && len(e.Members) == 0 {
		return fmt.Errorf("enum %s has no members", e.Name)
	}
	p.schema.Enums = append(p.schema.Enums, e)
	return err
}

func (p *parser) structDecl(toks []string) error {
	if err := p.openBlock(toks, 3); err != nil {
		return err
	}
	s := &Struct{Name: toks[1]}
	fields, err := p.fields()
	if err != nil {
		return err
	}
	s.Fields = fields
	if err := p.declareType(s.Name, Type{Kind: KindStruct, Struct: s}); err != nil {
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
		if !snakeName.MatchString(name) || reservedFields[name] {
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
	head := toks[0]
	switch {
	case prims[head]:
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

// Canonical is the hashed form of the schema: every declaration in a fixed
// category order (handles, quants, enums, structs, messages), each category in
// source order, one line per declaration header, member, or field, with single
// spaces and no comments.
func (s *Schema) Canonical() string {
	var b strings.Builder
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

func (s *Schema) MessagesTo(dir string) []*Message {
	var out []*Message
	for _, m := range s.Messages {
		if m.Direction == dir {
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

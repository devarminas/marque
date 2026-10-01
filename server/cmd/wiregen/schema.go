package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
)

type Schema struct {
	Handles  []*Handle
	Quants   []*Quant
	Enums    []*Enum
	Unions   []*Union
	Structs  []*Struct
	Messages []*Message
}

type Handle struct{ Name string }

type Quant struct {
	Name              string
	Min, Max, PerUnit int64
}

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

type Union struct {
	Name    string
	Members []UnionMember
}

type UnionMember struct {
	Name   string
	Handle *Handle
	Tag    uint32
}

type Struct struct {
	Name   string
	Fields []Field
	Rules  []Relation
}

type Message struct {
	Name      string
	ID        uint32
	Channel   string
	Direction string
	Fields    []Field
	Rules     []Relation
}

type Field struct {
	Name  string
	Type  Type
	Where []Term
}

type TermKind int

const (
	TermRange TermKind = iota
	TermSet
	TermUnique
)

type Term struct {
	Kind             TermKind
	Lo, Hi           string
	CheckLo, CheckHi bool
	LoStep, HiStep   uint64
	Members          []EnumMember
	By               *Field
}

func (t Term) Canonical() string {
	switch t.Kind {
	case TermRange:
		return t.Lo + ".." + t.Hi
	case TermSet:
		names := make([]string, len(t.Members))
		for i, m := range t.Members {
			names[i] = m.Name
		}
		return "{" + strings.Join(names, ", ") + "}"
	}
	if t.By != nil {
		return "unique(" + t.By.Name + ")"
	}
	return "unique"
}

type Relation struct {
	Left, Right Operand
	Op          string
}

func (r Relation) Canonical() string {
	return fmt.Sprintf("rule %s %s %s", r.Left, r.Op, r.Right)
}

type Operand struct {
	Field *Field
	Sub   *Field
}

func (o Operand) Each() bool { return o.Field.Type.Kind == KindList }

func (o Operand) Leaf() Type {
	if o.Sub != nil {
		return o.Sub.Type
	}
	return o.Field.Type.each()
}

func (t Type) present() Type {
	if t.Kind == KindOpt {
		return *t.Elem
	}
	return t
}

func (t Type) each() Type {
	if t.Kind == KindList {
		return *t.Elem
	}
	return t
}

func (o Operand) String() string {
	if o.Sub != nil {
		return o.Field.Name + "." + o.Sub.Name
	}
	return o.Field.Name
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
	KindUnion
	KindOpt
)

type Type struct {
	Kind   Kind
	Prim   string
	Bound  int
	Elem   *Type
	Quant  *Quant
	Enum   *Enum
	Handle *Handle
	Struct *Struct
	Union  *Union
}

func (t Type) MinSize() int {
	switch t.Kind {
	case KindPrim:
		return primSize[t.Prim]
	case KindQuant:
		return t.Quant.Width()
	case KindString, KindEnum, KindList, KindOpt:
		return 1
	case KindHandle:
		return 2
	case KindUnion:
		return 3
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
	case KindUnion:
		return t.Union.Name
	case KindOpt:
		return fmt.Sprintf("opt(%s)", t.Elem.Canonical())
	default:
		return t.Struct.Name
	}
}

func (t Type) ordered() bool {
	return t.Kind == KindQuant || t.Kind == KindPrim && t.Prim != "bool" && t.Prim != "f32"
}

func (t Type) comparable() bool {
	switch t.Kind {
	case KindPrim:
		return t.Prim != "f32"
	case KindList:
		return false
	case KindOpt:
		return t.Elem.comparable()
	case KindStruct:
		for _, f := range t.Struct.Fields {
			if !f.Type.comparable() {
				return false
			}
		}
	}
	return true
}

func (t Type) scalar() bool { return t.comparable() && t.Kind != KindStruct && t.Kind != KindOpt }

// primSize is each primitive's encoded width in bytes.
var primSize = map[string]int{
	"u8": 1, "u16": 2, "u32": 4, "u64": 8,
	"i8": 1, "i16": 2, "i32": 4, "i64": 8,
	"bool": 1, "f32": 4,
}

const uniqueMaxBound = 256

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

var generatedMembers = setOf("message_id", "channel", "append", "string", "build")

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
	decimal    = regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?$`)
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

var operators = []string{"..", "<=", "==", "!="}

const punctuation = "(){},=<"

func tokenAt(line string, i int) string {
	for _, op := range operators {
		if strings.HasPrefix(line[i:], op) {
			return op
		}
	}
	if strings.IndexByte(punctuation, line[i]) >= 0 {
		return line[i : i+1]
	}
	return ""
}

func tokenize(line string) []string {
	var out []string
	for i := 0; i < len(line); {
		if c := line[i]; c == ' ' || c == '\t' || c == '\r' {
			i++
			continue
		}
		if tok := tokenAt(line, i); tok != "" {
			out = append(out, tok)
			i += len(tok)
			continue
		}
		j := i
		for j < len(line) && !strings.ContainsRune(" \t\r", rune(line[j])) && tokenAt(line, j) == "" {
			j++
		}
		out = append(out, line[i:j])
		i = j
	}
	return out
}

func (p *parser) errf(format string, args ...any) error {
	return p.errAt(p.lineNo[p.pos], format, args...)
}

func (p *parser) errAt(line int, format string, args ...any) error {
	return fmt.Errorf("schema line %d: %s", line, fmt.Sprintf(format, args...))
}

func (p *parser) claim(name string, record bool, line int) error {
	names := []string{name}
	if record {
		names = append(names, name+"Fields")
	}
	for _, n := range names {
		if reservedTypes[n] {
			return p.errAt(line, "name %q is reserved for generated code", n)
		}
		if p.names[n] {
			return p.errAt(line, "duplicate name %q", n)
		}
	}
	for _, n := range names {
		p.names[n] = true
	}
	return nil
}

func (p *parser) declareType(name string, t Type, line int) error {
	if !pascalName.MatchString(name) {
		return p.errAt(line, "type name %q must be PascalCase", name)
	}
	if err := p.claim(name, t.Kind == KindStruct, line); err != nil {
		return err
	}
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
	case "union":
		return p.union(toks)
	case "struct":
		return p.structDecl(toks)
	case "message":
		return p.message(toks)
	case "rule":
		return p.errf("a rule line belongs inside a struct or message")
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
	if _, dup := p.types[q.Name]; dup || primSize[q.Name] > 0 || q.Name == "string" || q.Name == "list" || q.Name == "opt" {
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

func (p *parser) union(toks []string) error {
	if err := p.openBlock(toks, 3); err != nil {
		return err
	}
	u := &Union{Name: toks[1]}
	header := p.lineNo[p.pos]
	if err := p.declareType(u.Name, Type{Kind: KindUnion, Union: u}, header); err != nil {
		return err
	}
	seenName, seenTag, seenHandle := map[string]bool{}, map[uint32]bool{}, map[*Handle]bool{}
	err := p.block(func(t []string) error {
		if len(t) != 4 || t[2] != "=" {
			return p.errf("want: <member> <Handle> = <tag>")
		}
		v, err := strconv.ParseUint(t[3], 10, 32)
		if err != nil {
			return p.errf("union tag %q is not a u32", t[3])
		}
		if !snakeName.MatchString(t[0]) || cppKeywords[t[0]] {
			return p.errf("union member %q must be snake_case and not a C++ keyword", t[0])
		}
		h := p.types[t[1]]
		if h.Kind != KindHandle {
			return p.errf("union member %s: %q is not a handle; union members are handles", t[0], t[1])
		}
		if seenName[t[0]] || seenTag[uint32(v)] || seenHandle[h.Handle] {
			return p.errf("union %s: duplicate member, tag, or handle in %q", u.Name, strings.Join(t, " "))
		}
		seenName[t[0]], seenTag[uint32(v)], seenHandle[h.Handle] = true, true, true
		u.Members = append(u.Members, UnionMember{Name: t[0], Handle: h.Handle, Tag: uint32(v)})
		return nil
	})
	if err != nil {
		return err
	}
	if len(u.Members) == 0 {
		return p.errAt(header, "union %s has no members", u.Name)
	}
	for _, prev := range p.schema.Unions {
		if sameHandles(prev, u) {
			return p.errAt(header, "union %s has the same handles in the same order as union %s, so C++ would see one std::variant type", u.Name, prev.Name)
		}
	}
	p.schema.Unions = append(p.schema.Unions, u)
	return nil
}

func sameHandles(a, b *Union) bool {
	if len(a.Members) != len(b.Members) {
		return false
	}
	for i := range a.Members {
		if a.Members[i].Handle != b.Members[i].Handle {
			return false
		}
	}
	return true
}

func (p *parser) structDecl(toks []string) error {
	if err := p.openBlock(toks, 3); err != nil {
		return err
	}
	s := &Struct{Name: toks[1]}
	header := p.lineNo[p.pos]
	fields, rules, err := p.fields()
	if err != nil {
		return err
	}
	if len(fields) == 0 {
		return p.errAt(header, "struct %s has no fields; a zero-byte list element would make any count free to send", s.Name)
	}
	s.Fields, s.Rules = fields, rules
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
	if err := p.claim(goName(m.Name), true, p.lineNo[p.pos]); err != nil {
		return err
	}
	p.msgIDs[m.ID] = m.Name
	if m.Fields, m.Rules, err = p.fields(); err != nil {
		return err
	}
	p.schema.Messages = append(p.schema.Messages, m)
	return nil
}

func (p *parser) fields() ([]Field, []Relation, error) {
	var out []Field
	type pending struct {
		toks []string
		line int
	}
	var rules []pending
	seen := map[string]bool{}
	err := p.block(func(t []string) error {
		if t[0] == "rule" {
			rules = append(rules, pending{t[1:], p.lineNo[p.pos]})
			return nil
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
		f := Field{Name: name, Type: typ}
		if len(rest) > 0 {
			if rest[0] != "where" {
				return p.errf("unexpected %q after field type", strings.Join(rest, " "))
			}
			if f.Where, err = p.where(typ.present(), rest[1:]); err != nil {
				return err
			}
		}
		out = append(out, f)
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	var rels []Relation
	for _, r := range rules {
		rel, err := p.relation(out, r.toks, r.line)
		if err != nil {
			return nil, nil, err
		}
		rels = append(rels, rel)
	}
	return out, rels, nil
}

func (p *parser) where(t Type, toks []string) ([]Term, error) {
	var terms []Term
	seen := map[TermKind]bool{}
	for {
		term, rest, err := p.term(t, toks)
		if err != nil {
			return nil, err
		}
		if seen[term.Kind] {
			return nil, p.errf("where clause repeats %q; give each kind of term once", term.Canonical())
		}
		seen[term.Kind] = true
		terms = append(terms, term)
		if len(rest) == 0 {
			return terms, nil
		}
		if rest[0] != "and" || len(rest) == 1 {
			return nil, p.errf("want: where <term> [and <term>]..., got %q", strings.Join(rest, " "))
		}
		toks = rest[1:]
	}
}

func (p *parser) term(t Type, toks []string) (Term, []string, error) {
	elem := t.each()
	switch {
	case len(toks) == 0:
		return Term{}, nil, p.errf("missing term after where")
	case toks[0] == "unique":
		return p.unique(t, toks)
	case toks[0] == "{":
		if elem.Kind != KindEnum {
			return Term{}, nil, p.errf("a {member, ...} set needs an enum or a list of enums, not %s", t.Canonical())
		}
		return p.set(elem.Enum, toks)
	case len(toks) >= 3 && toks[1] == "..":
		if !elem.ordered() {
			return Term{}, nil, p.errf("a range needs an integer or quant, or a list of them, not %s", t.Canonical())
		}
		term, err := p.rangeTerm(elem, toks[0], toks[2])
		return term, toks[3:], err
	}
	return Term{}, nil, p.errf("unknown term %q (want <lo>..<hi>, {member, ...}, unique, or unique(<field>))", strings.Join(toks, " "))
}

func (p *parser) unique(t Type, toks []string) (Term, []string, error) {
	if t.Kind != KindList {
		return Term{}, nil, p.errf("unique needs a list, not %s", t.Canonical())
	}
	if t.Bound > uniqueMaxBound {
		return Term{}, nil, p.errf("unique needs a list bound of at most %d, because the check compares every pair", uniqueMaxBound)
	}
	term := Term{Kind: TermUnique}
	if len(toks) >= 4 && toks[1] == "(" && toks[3] == ")" {
		if t.Elem.Kind != KindStruct {
			return Term{}, nil, p.errf("unique(%s) needs a list of structs", toks[2])
		}
		by := findField(t.Elem.Struct.Fields, toks[2])
		if by == nil {
			return Term{}, nil, p.errf("struct %s has no field %q", t.Elem.Struct.Name, toks[2])
		}
		if !by.Type.scalar() {
			return Term{}, nil, p.errf("unique(%s): %s cannot be compared", by.Name, by.Type.Canonical())
		}
		term.By = by
		return term, toks[4:], nil
	}
	if !t.Elem.comparable() {
		return Term{}, nil, p.errf("unique: %s cannot be compared (it holds a list or an f32); use unique(<field>)", t.Elem.Canonical())
	}
	if t.Elem.Kind == KindStruct && holdsQuant(t.Elem.Struct) {
		return Term{}, nil, p.errf("unique: %s holds a quant, which compares by wire step only one field at a time; use unique(<field>)", t.Elem.Canonical())
	}
	return term, toks[1:], nil
}

func (p *parser) set(e *Enum, toks []string) (Term, []string, error) {
	term := Term{Kind: TermSet}
	seen := map[string]bool{}
	i := 1
	for ; i < len(toks) && toks[i] != "}"; i++ {
		if len(term.Members) > 0 {
			if toks[i] != "," || i+1 >= len(toks) {
				return Term{}, nil, p.errf("want: {member, member, ...}")
			}
			i++
		}
		m, ok := findMember(e, toks[i])
		if !ok {
			return Term{}, nil, p.errf("enum %s has no member %q", e.Name, toks[i])
		}
		if seen[m.Name] {
			return Term{}, nil, p.errf("set names %q twice", m.Name)
		}
		seen[m.Name] = true
		term.Members = append(term.Members, m)
	}
	if i >= len(toks) || len(term.Members) == 0 {
		return Term{}, nil, p.errf("want: {member, member, ...}")
	}
	return term, toks[i+1:], nil
}

func holdsQuant(s *Struct) bool {
	for _, f := range s.Fields {
		if t := f.Type.present(); t.Kind == KindQuant || t.Kind == KindStruct && holdsQuant(t.Struct) {
			return true
		}
	}
	return false
}

func findMember(e *Enum, name string) (EnumMember, bool) {
	for _, m := range e.Members {
		if m.Name == name {
			return m, true
		}
	}
	return EnumMember{}, false
}

func findField(fs []Field, name string) *Field {
	for i := range fs {
		if fs[i].Name == name {
			return &fs[i]
		}
	}
	return nil
}

var intLimits = map[string][2]*big.Int{
	"u8": {big.NewInt(0), big.NewInt(math.MaxUint8)}, "u16": {big.NewInt(0), big.NewInt(math.MaxUint16)},
	"u32": {big.NewInt(0), big.NewInt(math.MaxUint32)}, "u64": {big.NewInt(0), new(big.Int).SetUint64(math.MaxUint64)},
	"i8": {big.NewInt(math.MinInt8), big.NewInt(math.MaxInt8)}, "i16": {big.NewInt(math.MinInt16), big.NewInt(math.MaxInt16)},
	"i32": {big.NewInt(math.MinInt32), big.NewInt(math.MaxInt32)}, "i64": {big.NewInt(math.MinInt64), big.NewInt(math.MaxInt64)},
}

func (p *parser) rangeTerm(t Type, loTok, hiTok string) (Term, error) {
	lo, err := p.rangeBound(loTok)
	if err != nil {
		return Term{}, err
	}
	hi, err := p.rangeBound(hiTok)
	if err != nil {
		return Term{}, err
	}
	if lo.Cmp(hi) > 0 {
		return Term{}, p.errf("range %s..%s: low bound above high bound", loTok, hiTok)
	}
	term := Term{Kind: TermRange, Lo: canonDecimal(lo), Hi: canonDecimal(hi)}
	if t.Kind == KindQuant {
		q := t.Quant
		perUnit, min := big.NewRat(q.PerUnit, 1), big.NewRat(q.Min*q.PerUnit, 1)
		steps := [2]uint64{}
		for i, v := range []*big.Rat{lo, hi} {
			s := new(big.Rat).Sub(new(big.Rat).Mul(v, perUnit), min)
			if !s.IsInt() {
				return Term{}, p.errf("range bound %s is not on quant %s's grid of 1/%d", canonDecimal(v), q.Name, q.PerUnit)
			}
			if s.Sign() < 0 || !s.Num().IsUint64() || s.Num().Uint64() > q.Steps() {
				return Term{}, p.errf("range bound %s is outside quant %s (%d..%d)", canonDecimal(v), q.Name, q.Min, q.Max)
			}
			steps[i] = s.Num().Uint64()
		}
		term.LoStep, term.HiStep = steps[0], steps[1]
		term.CheckLo, term.CheckHi = steps[0] > 0, steps[1] < q.Steps()
		return term, nil
	}
	limits := intLimits[t.Prim]
	for _, v := range []*big.Rat{lo, hi} {
		if !v.IsInt() {
			return Term{}, p.errf("range bound %s is not an integer, and %s is", canonDecimal(v), t.Prim)
		}
		if v.Num().Cmp(limits[0]) < 0 || v.Num().Cmp(limits[1]) > 0 {
			return Term{}, p.errf("range bound %s is outside %s", canonDecimal(v), t.Prim)
		}
	}
	term.CheckLo, term.CheckHi = lo.Num().Cmp(limits[0]) != 0, hi.Num().Cmp(limits[1]) != 0
	return term, nil
}

func (p *parser) rangeBound(tok string) (*big.Rat, error) {
	r, ok := new(big.Rat).SetString(tok)
	if !decimal.MatchString(tok) || !ok {
		return nil, p.errf("range bound %q is not a decimal number", tok)
	}
	return r, nil
}

func canonDecimal(r *big.Rat) string {
	prec, _ := r.FloatPrec()
	if s := r.FloatString(prec); s != "-0" {
		return s
	}
	return "0"
}

func (p *parser) relation(fields []Field, toks []string, line int) (Relation, error) {
	if len(toks) != 3 {
		return Relation{}, p.errAt(line, "want: rule <field>[.<field>] <op> <field>[.<field>] with op <, <=, ==, !=, or in")
	}
	var rel Relation
	var err error
	if rel.Left, err = p.operand(fields, toks[0], line); err != nil {
		return Relation{}, err
	}
	if rel.Right, err = p.operand(fields, toks[2], line); err != nil {
		return Relation{}, err
	}
	rel.Op = toks[1]
	l, r := rel.Left.Leaf(), rel.Right.Leaf()
	if rel.Op == "in" {
		if rel.Left.Each() || !rel.Right.Each() {
			return Relation{}, p.errAt(line, "rule %s: in needs a single value on the left and a list on the right", strings.Join(toks, " "))
		}
	} else if rel.Left.Each() && rel.Right.Each() {
		return Relation{}, p.errAt(line, "rule %s: at most one side may be a list", strings.Join(toks, " "))
	}
	if l.Canonical() != r.Canonical() {
		return Relation{}, p.errAt(line, "rule %s compares %s with %s; both sides need the same type", strings.Join(toks, " "), l.Canonical(), r.Canonical())
	}
	switch rel.Op {
	case "<", "<=":
		if !l.ordered() {
			return Relation{}, p.errAt(line, "rule %s: %s has no order; < and <= need integers or quants", strings.Join(toks, " "), l.Canonical())
		}
	case "==", "!=", "in":
		if !l.scalar() {
			return Relation{}, p.errAt(line, "rule %s: %s cannot be compared", strings.Join(toks, " "), l.Canonical())
		}
	default:
		return Relation{}, p.errAt(line, "rule operator %q is not one of <, <=, ==, !=, in", rel.Op)
	}
	return rel, nil
}

func (p *parser) operand(fields []Field, tok string, line int) (Operand, error) {
	head, sub, dotted := strings.Cut(tok, ".")
	f := findField(fields, head)
	if f == nil {
		return Operand{}, p.errAt(line, "rule names %q, which is not a field of this block", head)
	}
	if f.Type.Kind == KindOpt {
		return Operand{}, p.errAt(line, "rule names %q, an opt field; a rule sees only fields that are always present", head)
	}
	o := Operand{Field: f}
	if !dotted {
		return o, nil
	}
	st := f.Type.each()
	if st.Kind != KindStruct {
		return Operand{}, p.errAt(line, "rule operand %q: %s is not a struct or a list of structs", tok, head)
	}
	if o.Sub = findField(st.Struct.Fields, sub); o.Sub == nil {
		return Operand{}, p.errAt(line, "rule operand %q: struct %s has no field %q", tok, st.Struct.Name, sub)
	}
	if o.Sub.Type.Kind == KindOpt {
		return Operand{}, p.errAt(line, "rule operand %q: %s is an opt field; a rule sees only fields that are always present", tok, sub)
	}
	return o, nil
}

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
	case head == "opt":
		if len(toks) < 2 || toks[1] != "(" {
			return Type{}, nil, p.errf("want: opt(<type>)")
		}
		elem, rest, err := p.typ(toks[2:])
		if err != nil {
			return Type{}, nil, err
		}
		switch elem.Kind {
		case KindOpt:
			return Type{}, nil, p.errf("opt of opt is not supported")
		case KindList:
			return Type{}, nil, p.errf("opt of list is not supported; an empty list already says none, or wrap the list in a struct")
		}
		if len(rest) < 1 || rest[0] != ")" {
			return Type{}, nil, p.errf("want: opt(<type>)")
		}
		return Type{Kind: KindOpt, Elem: &elem}, rest[1:], nil
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
	for _, u := range s.Unions {
		fmt.Fprintf(&b, "union %s {\n", u.Name)
		for _, m := range u.Members {
			fmt.Fprintf(&b, "%s %s = %d\n", m.Name, m.Handle.Name, m.Tag)
		}
		b.WriteString("}\n")
	}
	writeBody := func(fs []Field, rules []Relation) {
		for _, f := range fs {
			fmt.Fprintf(&b, "%s %s", f.Name, f.Type.Canonical())
			for i, t := range f.Where {
				if i == 0 {
					b.WriteString(" where ")
				} else {
					b.WriteString(" and ")
				}
				b.WriteString(t.Canonical())
			}
			b.WriteString("\n")
		}
		for _, r := range rules {
			b.WriteString(r.Canonical() + "\n")
		}
		b.WriteString("}\n")
	}
	for _, st := range s.Structs {
		fmt.Fprintf(&b, "struct %s {\n", st.Name)
		writeBody(st.Fields, st.Rules)
	}
	for _, m := range s.Messages {
		fmt.Fprintf(&b, "message %s = %d on %s %s {\n", m.Name, m.ID, m.Channel, m.Direction)
		writeBody(m.Fields, m.Rules)
	}
	return b.String()
}

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

func goName(snake string) string {
	var b strings.Builder
	for _, part := range strings.Split(snake, "_") {
		b.WriteString(strings.ToUpper(part[:1]) + part[1:])
	}
	return b.String()
}

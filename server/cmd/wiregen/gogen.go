package main

import (
	"fmt"
	"go/format"
	"strings"
)

const codecImport = "github.com/devarminas/marque/server/internal/wire/codec"

var goPrim = map[string]string{
	"u8": "uint8", "u16": "uint16", "u32": "uint32", "u64": "uint64",
	"i8": "int8", "i16": "int16", "i32": "int32", "i64": "int64",
	"bool": "bool", "f32": "float32",
}

var goWire = map[string][2]string{
	"u8": {"U8", ""}, "u16": {"U16", ""}, "u32": {"U32", ""}, "u64": {"U64", ""},
	"i8": {"U8", "uint8"}, "i16": {"U16", "uint16"}, "i32": {"U32", "uint32"}, "i64": {"U64", "uint64"},
	"bool": {"Bool", ""}, "f32": {"F32", ""},
}

func goType(t Type) string {
	switch t.Kind {
	case KindPrim:
		return goPrim[t.Prim]
	case KindQuant:
		return "float64"
	case KindString:
		return "string"
	case KindList:
		return "[]" + goType(*t.Elem)
	case KindEnum:
		return t.Enum.Name
	case KindHandle:
		return t.Handle.Name
	default:
		return t.Struct.Name
	}
}

func goQuantVar(q *Quant) string { return "quant" + goName(q.Name) }

func goEncode(t Type, expr string) string {
	switch t.Kind {
	case KindPrim:
		wire := goWire[t.Prim]
		if wire[1] != "" {
			return fmt.Sprintf("w.%s(%s(%s))", wire[0], wire[1], expr)
		}
		return fmt.Sprintf("w.%s(%s)", wire[0], expr)
	case KindQuant:
		return fmt.Sprintf("w.Quant(%s, %s)", expr, goQuantVar(t.Quant))
	case KindString:
		return fmt.Sprintf("w.String(%s, %d)", expr, t.Bound)
	case KindList:
		return fmt.Sprintf("w.Count(len(%s), %d)\nfor _, e := range %s {\n%s\n}", expr, t.Bound, expr, goEncode(*t.Elem, "e"))
	case KindStruct:
		return fmt.Sprintf("%s.f.encode(w)", expr)
	default:
		return fmt.Sprintf("%s.encode(w)", expr)
	}
}

func goDecode(t Type) string {
	switch t.Kind {
	case KindPrim:
		wire := goWire[t.Prim]
		if wire[1] != "" {
			return fmt.Sprintf("%s(r.%s())", goPrim[t.Prim], wire[0])
		}
		return fmt.Sprintf("r.%s()", wire[0])
	case KindQuant:
		return fmt.Sprintf("r.Quant(%s)", goQuantVar(t.Quant))
	case KindString:
		return fmt.Sprintf("r.String(%d)", t.Bound)
	default:
		return fmt.Sprintf("decode%s(r)", goType(t))
	}
}

func goDecodeField(f Field) string {
	dst := "f." + goName(f.Name)
	if f.Type.Kind != KindList {
		return fmt.Sprintf("%s = %s", dst, goDecode(f.Type))
	}
	return fmt.Sprintf("if n := r.Count(%d, %d); n > 0 {\n%s = make(%s, n)\nfor i := range %s {\n%s[i] = %s\n}\n}",
		f.Type.Bound, f.Type.Elem.MinSize(), dst, goType(f.Type), dst, dst, goDecode(*f.Type.Elem))
}

func goText(t Type, expr string) string {
	switch t.Kind {
	case KindPrim:
		switch {
		case t.Prim == "bool":
			return fmt.Sprintf("b = strconv.AppendBool(b, %s)", expr)
		case t.Prim == "f32":
			return fmt.Sprintf("b = strconv.AppendFloat(b, float64(%s), 'g', -1, 32)", expr)
		case t.Prim[0] == 'u':
			return fmt.Sprintf("b = strconv.AppendUint(b, uint64(%s), 10)", expr)
		}
		return fmt.Sprintf("b = strconv.AppendInt(b, int64(%s), 10)", expr)
	case KindQuant:
		return fmt.Sprintf("b = strconv.AppendFloat(b, %s, 'g', -1, 64)", expr)
	case KindString:
		return fmt.Sprintf("b = strconv.AppendQuoteToASCII(b, %s)", expr)
	case KindEnum:
		return fmt.Sprintf("b = append(b, %s.String()...)", expr)
	case KindHandle:
		return fmt.Sprintf("b = %s.appendText(b)", expr)
	case KindStruct:
		return fmt.Sprintf("b = %s.f.appendText(b)", expr)
	}
	return fmt.Sprintf("b = append(b, '[')\nfor i, e := range %s {\nif i > 0 {\nb = append(b, ' ')\n}\n%s\n}\nb = append(b, ']')", expr, goText(*t.Elem, "e"))
}

func goValue(t Type, expr string) string {
	if t.Kind == KindQuant {
		return fmt.Sprintf("%s.Step(%s)", goQuantVar(t.Quant), expr)
	}
	return expr
}

func goTermCond(term Term, t Type, v string) string {
	var parts []string
	switch term.Kind {
	case TermRange:
		lo, hi := term.Lo, term.Hi
		if t.Kind == KindQuant {
			lo, hi = fmt.Sprint(term.LoStep), fmt.Sprint(term.HiStep)
		}
		v = goValue(t, v)
		if term.CheckLo {
			parts = append(parts, v+" >= "+lo)
		}
		if term.CheckHi {
			parts = append(parts, v+" <= "+hi)
		}
		return strings.Join(parts, " && ")
	case TermSet:
		for _, m := range term.Members {
			parts = append(parts, v+" == "+t.Enum.Name+goName(m.Name))
		}
		return strings.Join(parts, " || ")
	}
	return ""
}

func goChecks(x string, f Field) string {
	var b strings.Builder
	fail := fmt.Sprintf("{\n%s.Fail(codec.ErrRule)\n}\n", x)
	list := "f." + goName(f.Name)
	for _, term := range f.Where {
		if term.Kind == TermUnique {
			key, by := *f.Type.Elem, ""
			if term.By != nil {
				key, by = term.By.Type, ".f."+goName(term.By.Name)
			}
			fmt.Fprintf(&b, "if %s.Err() == nil && !codec.Unique(len(%s), func(i, j int) bool { return %s == %s }) %s",
				x, list, goValue(key, list+"[i]"+by), goValue(key, list+"[j]"+by), fail)
			continue
		}
		if f.Type.Kind == KindList {
			if cond := goTermCond(term, *f.Type.Elem, "e"); cond != "" {
				fmt.Fprintf(&b, "if %s.Err() == nil && slices.ContainsFunc(%s, func(e %s) bool { return !(%s) }) %s",
					x, list, goType(*f.Type.Elem), cond, fail)
			}
			continue
		}
		if cond := goTermCond(term, f.Type, list); cond != "" {
			fmt.Fprintf(&b, "if %s.Err() == nil && !(%s) %s", x, cond, fail)
		}
	}
	return b.String()
}

func goOperand(o Operand) string {
	expr := "f." + goName(o.Field.Name)
	if o.Each() {
		expr = "e"
	}
	if o.Sub != nil {
		expr += ".f." + goName(o.Sub.Name)
	}
	return goValue(o.Leaf(), expr)
}

func goRelation(x string, r Relation) string {
	fail := fmt.Sprintf("{\n%s.Fail(codec.ErrRule)\n}\n", x)
	l, rt := goOperand(r.Left), goOperand(r.Right)
	switch {
	case r.Op == "in":
		return fmt.Sprintf("if %s.Err() == nil && !slices.ContainsFunc(f.%s, func(e %s) bool { return %s == %s }) %s",
			x, goName(r.Right.Field.Name), goType(*r.Right.Field.Type.Elem), rt, l, fail)
	case r.Left.Each() || r.Right.Each():
		list := r.Left.Field
		if r.Right.Each() {
			list = r.Right.Field
		}
		return fmt.Sprintf("if %s.Err() == nil && slices.ContainsFunc(f.%s, func(e %s) bool { return !(%s %s %s) }) %s",
			x, goName(list.Name), goType(*list.Type.Elem), l, r.Op, rt, fail)
	}
	return fmt.Sprintf("if %s.Err() == nil && !(%s %s %s) %s", x, l, r.Op, rt, fail)
}

func goRecord(b *strings.Builder, name, textName string, fields []Field, rules []Relation) {
	fmt.Fprintf(b, "type %[1]sFields struct {\n", name)
	for _, f := range fields {
		fmt.Fprintf(b, "%s %s\n", goName(f.Name), goType(f.Type))
	}
	b.WriteString("}\n\n")
	fmt.Fprintf(b, "type %[1]s struct {\nf %[1]sFields\n}\n\n", name)

	fmt.Fprintf(b, "func (f %[1]sFields) Build() (%[1]s, error) {\n", name)
	for _, f := range fields {
		if f.Type.Kind == KindList {
			fmt.Fprintf(b, "f.%[1]s = codec.Clone(f.%[1]s)\n", goName(f.Name))
		}
	}
	fmt.Fprintf(b, "w := codec.NewChecker()\nf.encode(&w)\nif err := w.Err(); err != nil {\nreturn %[1]s{}, err\n}\nreturn %[1]s{f}, nil\n}\n\n", name)

	for _, f := range fields {
		if f.Type.Kind == KindList {
			fmt.Fprintf(b, "func (v %s) %s() codec.List[%s] { return codec.ListOf(v.f.%[2]s) }\n\n", name, goName(f.Name), goType(*f.Type.Elem))
			continue
		}
		fmt.Fprintf(b, "func (v %s) %s() %s { return v.f.%[2]s }\n\n", name, goName(f.Name), goType(f.Type))
	}

	fmt.Fprintf(b, "func (f %sFields) encode(w *codec.Writer) {\n", name)
	for _, f := range fields {
		b.WriteString(goEncode(f.Type, "f."+goName(f.Name)) + "\n")
		b.WriteString(goChecks("w", f))
	}
	for _, r := range rules {
		b.WriteString(goRelation("w", r))
	}
	b.WriteString("}\n\n")

	fmt.Fprintf(b, "func decode%[1]s(r *codec.Reader) %[1]s {\nvar f %[1]sFields\n", name)
	for _, f := range fields {
		b.WriteString(goDecodeField(f) + "\n")
		b.WriteString(goChecks("r", f))
	}
	for _, r := range rules {
		b.WriteString(goRelation("r", r))
	}
	fmt.Fprintf(b, "return %s{f}\n}\n\n", name)

	fmt.Fprintf(b, "func (f %sFields) appendText(b []byte) []byte {\n", name)
	for i, f := range fields {
		sep := " "
		if i == 0 {
			sep = textName + "{"
		}
		fmt.Fprintf(b, "b = append(b, %q...)\n%s\n", sep+f.Name+":", goText(f.Type, "f."+goName(f.Name)))
	}
	b.WriteString("return append(b, '}')\n}\n\n")
	fmt.Fprintf(b, "func (v %s) String() string { return string(v.f.appendText(nil)) }\n\n", name)
}

func genGo(s *Schema, schemaPath, pkg string) ([]byte, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "const SchemaHash uint64 = 0x%016x\n\n", s.Hash())

	b.WriteString(`type Message interface {
	MessageID() uint32
	Channel() codec.Channel
	Append(dst []byte) ([]byte, error)
	String() string
}

`)
	for _, ch := range channels {
		fmt.Fprintf(&b, "type %[1]sMsg interface {\nMessage\n%[2]sMsg()\n}\n\n", goName(ch), ch)
	}

	for _, q := range s.Quants {
		fmt.Fprintf(&b, "var %s = codec.Quant{Min: %d, Max: %d, PerUnit: %d, Steps: %d, Width: %d}\n\n",
			goQuantVar(q), q.Min, q.Max, q.PerUnit, q.Steps(), q.Width())
	}

	for _, h := range s.Handles {
		fmt.Fprintf(&b, `type %[1]s struct {
	Index uint32
	Gen   uint32
}

func (v %[1]s) encode(w *codec.Writer) {
	w.Varint(v.Index)
	w.Varint(v.Gen)
}

func decode%[1]s(r *codec.Reader) (v %[1]s) {
	v.Index = r.Varint()
	v.Gen = r.Varint()
	return v
}

func (v %[1]s) appendText(b []byte) []byte {
	b = append(b, "%[1]s("...)
	b = strconv.AppendUint(b, uint64(v.Index), 10)
	b = append(b, '/')
	b = strconv.AppendUint(b, uint64(v.Gen), 10)
	return append(b, ')')
}

func (v %[1]s) String() string { return string(v.appendText(nil)) }

`, h.Name)
	}

	for _, e := range s.Enums {
		fmt.Fprintf(&b, "type %s uint32\n\nconst (\n", e.Name)
		for _, m := range e.Members {
			fmt.Fprintf(&b, "%s%s %s = %d\n", e.Name, goName(m.Name), e.Name, m.Value)
		}
		b.WriteString(")\n\n")
		fmt.Fprintf(&b, "func (v %s) String() string {\nswitch v {\n", e.Name)
		for _, m := range e.Members {
			fmt.Fprintf(&b, "case %s%s:\nreturn %q\n", e.Name, goName(m.Name), m.Name)
		}
		fmt.Fprintf(&b, "}\nreturn fmt.Sprintf(\"%s(%%d)\", uint32(v))\n}\n\n", e.Name)
		fmt.Fprintf(&b, "func (v %s) valid() bool {\nswitch v {\ncase ", e.Name)
		for i, m := range e.Members {
			if i > 0 {
				b.WriteString(", ")
			}
			b.WriteString(e.Name + goName(m.Name))
		}
		b.WriteString(":\nreturn true\n}\nreturn false\n}\n\n")
		fmt.Fprintf(&b, `func (v %[1]s) encode(w *codec.Writer) {
	if !v.valid() {
		w.Fail(codec.ErrBadEnum)
		return
	}
	w.Varint(uint32(v))
}

func decode%[1]s(r *codec.Reader) %[1]s {
	v := %[1]s(r.Varint())
	if r.Err() == nil && !v.valid() {
		r.Fail(codec.ErrBadEnum)
	}
	return v
}

`, e.Name)
	}

	for _, st := range s.Structs {
		goRecord(&b, st.Name, st.Name, st.Fields, st.Rules)
	}

	for _, m := range s.Messages {
		name := goName(m.Name)
		goRecord(&b, name, m.Name, m.Fields, m.Rules)
		fmt.Fprintf(&b, `func (%[1]s) MessageID() uint32 { return %[2]d }

func (%[1]s) Channel() codec.Channel { return codec.Channel%[3]s }

func (%[1]s) %[4]sMsg() {}

func (v %[1]s) Append(dst []byte) ([]byte, error) {
	w := codec.NewWriter(dst)
	w.Varint(%[2]d)
	v.f.encode(&w)
	return w.Result()
}

`, name, m.ID, goName(m.Channel), m.Channel)
	}

	for _, ch := range channels {
		c := goName(ch)
		fmt.Fprintf(&b, "func DecodeNext%[1]s(r *codec.Reader) (%[1]sMsg, error) {\nvar m %[1]sMsg\nswitch r.Varint() {\n", c, ch)
		for _, m := range s.MessagesOn(ch) {
			fmt.Fprintf(&b, "case %d:\nm = decode%s(r)\n", m.ID, goName(m.Name))
		}
		b.WriteString("default:\nr.Fail(codec.ErrUnknownMessage)\n}\nif err := r.Err(); err != nil {\nreturn nil, err\n}\nreturn m, nil\n}\n\n")
		fmt.Fprintf(&b, `func Decode%[1]s(b []byte) (%[1]sMsg, error) {
	r := codec.NewReader(b)
	m, err := DecodeNext%[1]s(r)
	if err != nil {
		return nil, err
	}
	if err := r.Finish(); err != nil {
		return nil, err
	}
	return m, nil
}

`, c, ch)
	}

	body := b.String()
	var head strings.Builder
	fmt.Fprintf(&head, "// Code generated by wiregen from %s. DO NOT EDIT.\n\npackage %s\n\nimport (\n", schemaPath, pkg)
	for _, std := range []string{"fmt", "slices", "strconv"} {
		if strings.Contains(body, std+".") {
			fmt.Fprintf(&head, "%q\n", std)
		}
	}
	fmt.Fprintf(&head, "\n%q\n)\n\n", codecImport)
	src := head.String() + body
	out, err := format.Source([]byte(src))
	if err != nil {
		return nil, fmt.Errorf("gofmt generated Go: %w\n%s", err, src)
	}
	return out, nil
}

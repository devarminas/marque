package main

import (
	"fmt"
	"strings"
)

var cppPrim = map[string]string{
	"u8": "std::uint8_t", "u16": "std::uint16_t", "u32": "std::uint32_t", "u64": "std::uint64_t",
	"i8": "std::int8_t", "i16": "std::int16_t", "i32": "std::int32_t", "i64": "std::int64_t",
	"bool": "bool", "f32": "float",
}

// cppWire maps each primitive to the Writer/Reader method that carries it and
// the unsigned type a signed value converts through.
var cppWire = map[string][2]string{
	"u8": {"u8", ""}, "u16": {"u16", ""}, "u32": {"u32", ""}, "u64": {"u64", ""},
	"i8": {"u8", "std::uint8_t"}, "i16": {"u16", "std::uint16_t"}, "i32": {"u32", "std::uint32_t"}, "i64": {"u64", "std::uint64_t"},
	"bool": {"boolean", ""}, "f32": {"f32", ""},
}

func cppType(t Type) string {
	switch t.Kind {
	case KindPrim:
		return cppPrim[t.Prim]
	case KindQuant:
		return "double"
	case KindString:
		return "std::string"
	case KindList:
		return "std::vector<" + cppType(*t.Elem) + ">"
	case KindEnum:
		return t.Enum.Name
	case KindHandle:
		return t.Handle.Name
	default:
		return t.Struct.Name
	}
}

func cppInit(t Type) string {
	switch t.Kind {
	case KindPrim:
		if t.Prim == "bool" {
			return " = false"
		}
		return " = 0"
	case KindQuant:
		return " = 0"
	default:
		return "{}"
	}
}

func cppQuantVar(q *Quant) string { return "quant_" + q.Name }

func cppEncode(t Type, expr string) string {
	switch t.Kind {
	case KindPrim:
		wire := cppWire[t.Prim]
		if wire[1] != "" {
			return fmt.Sprintf("w.%s(static_cast<%s>(%s));", wire[0], wire[1], expr)
		}
		return fmt.Sprintf("w.%s(%s);", wire[0], expr)
	case KindQuant:
		return fmt.Sprintf("w.quant(%s, %s);", expr, cppQuantVar(t.Quant))
	case KindString:
		return fmt.Sprintf("w.string(%s, %d);", expr, t.Bound)
	case KindList:
		return fmt.Sprintf("w.count(%s.size(), %d);\n    for (const auto& e : %s) {\n        %s\n    }", expr, t.Bound, expr, cppEncode(*t.Elem, "e"))
	default:
		return fmt.Sprintf("write(w, %s);", expr)
	}
}

func cppDecode(t Type) string {
	switch t.Kind {
	case KindPrim:
		wire := cppWire[t.Prim]
		if wire[1] != "" {
			return fmt.Sprintf("static_cast<%s>(r.%s())", cppPrim[t.Prim], wire[0])
		}
		return fmt.Sprintf("r.%s()", wire[0])
	case KindQuant:
		return fmt.Sprintf("r.quant(%s)", cppQuantVar(t.Quant))
	case KindString:
		return fmt.Sprintf("r.string(%d)", t.Bound)
	default:
		return fmt.Sprintf("read_%s(r)", cppType(t))
	}
}

func cppDecodeField(f Field) string {
	dst := "f." + f.Name
	if f.Type.Kind != KindList {
		return fmt.Sprintf("    %s = %s;\n", dst, cppDecode(f.Type))
	}
	return fmt.Sprintf("    %s.resize(r.count(%d, %d));\n    for (std::size_t i = 0; i < %s.size(); ++i) {\n        %s[i] = %s;\n    }\n",
		dst, f.Type.Bound, f.Type.Elem.MinSize(), dst, dst, cppDecode(*f.Type.Elem))
}

// cppText returns statements that append the text form of expr to out, the
// same text the Go String() methods produce.
func cppText(t Type, expr string) string {
	switch t.Kind {
	case KindPrim:
		switch {
		case t.Prim == "bool":
			return fmt.Sprintf("out += %s ? \"true\" : \"false\";", expr)
		case t.Prim == "f32":
			return fmt.Sprintf("codec::text_f32(out, %s);", expr)
		case t.Prim[0] == 'u':
			return fmt.Sprintf("out += std::to_string(static_cast<unsigned long long>(%s));", expr)
		}
		return fmt.Sprintf("out += std::to_string(static_cast<long long>(%s));", expr)
	case KindQuant:
		return fmt.Sprintf("codec::text_f64(out, %s);", expr)
	case KindString:
		return fmt.Sprintf("codec::text_quoted(out, %s);", expr)
	case KindList:
		return fmt.Sprintf("out += '[';\n    for (std::size_t i = 0; i < %s.size(); ++i) {\n        if (i > 0) out += ' ';\n        %s\n    }\n    out += ']';",
			expr, cppText(*t.Elem, expr+"[i]"))
	}
	return fmt.Sprintf("text(out, %s);", expr)
}

// cppValue is the expression a rule compares: quants by wire integer.
func cppValue(t Type, expr string) string {
	if t.Kind == KindQuant {
		return fmt.Sprintf("%s.step(%s)", cppQuantVar(t.Quant), expr)
	}
	return expr
}

// cppLiteral spells an integer bound in the field's own type, so comparisons
// never mix signedness.
func cppLiteral(prim, v string) string {
	switch prim {
	case "u64":
		v += "ULL"
	case "i64":
		v += "LL"
	}
	return cppPrim[prim] + "{" + v + "}"
}

func cppTermCond(term Term, t Type, v string) string {
	var parts []string
	switch term.Kind {
	case TermRange:
		lo, hi := cppLiteral(t.Prim, term.Lo), cppLiteral(t.Prim, term.Hi)
		if t.Kind == KindQuant {
			lo, hi = fmt.Sprintf("std::uint64_t{%d}", term.LoStep), fmt.Sprintf("std::uint64_t{%d}", term.HiStep)
		}
		v = cppValue(t, v)
		if term.CheckLo {
			parts = append(parts, v+" >= "+lo)
		}
		if term.CheckHi {
			parts = append(parts, v+" <= "+hi)
		}
		return strings.Join(parts, " && ")
	case TermSet:
		for _, m := range term.Members {
			parts = append(parts, v+" == "+t.Enum.Name+"::"+m.Name)
		}
		return strings.Join(parts, " || ")
	}
	return ""
}

// cppChecks mirrors goChecks: the same rules in the same order.
func cppChecks(x string, f Field) string {
	var b strings.Builder
	fail := fmt.Sprintf(") %s.fail(codec::Error::rule);\n", x)
	list := "f." + f.Name
	for _, term := range f.Where {
		if term.Kind == TermUnique {
			key, by := *f.Type.Elem, ""
			if term.By != nil {
				key, by = term.By.Type, "."+term.By.Name+"()"
			}
			fmt.Fprintf(&b, "    if (!%s.error() && !codec::unique(%s.size(), [&](std::size_t i, std::size_t j) { return %s == %s; })%s",
				x, list, cppValue(key, list+"[i]"+by), cppValue(key, list+"[j]"+by), fail)
			continue
		}
		if f.Type.Kind == KindList {
			if cond := cppTermCond(term, *f.Type.Elem, "e"); cond != "" {
				fmt.Fprintf(&b, "    if (!%s.error() && std::ranges::any_of(%s, [&](const auto& e) { return !(%s); })%s", x, list, cond, fail)
			}
			continue
		}
		if cond := cppTermCond(term, f.Type, list); cond != "" {
			fmt.Fprintf(&b, "    if (!%s.error() && !(%s)%s", x, cond, fail)
		}
	}
	return b.String()
}

func cppOperand(o Operand) string {
	expr := "f." + o.Field.Name
	if o.Each() {
		expr = "e"
	}
	if o.Sub != nil {
		expr += "." + o.Sub.Name + "()"
	}
	return cppValue(o.Leaf(), expr)
}

func cppRelation(x string, r Relation) string {
	fail := fmt.Sprintf(") %s.fail(codec::Error::rule);\n", x)
	l, rt := cppOperand(r.Left), cppOperand(r.Right)
	switch {
	case r.Op == "in":
		return fmt.Sprintf("    if (!%s.error() && !std::ranges::any_of(f.%s, [&](const auto& e) { return %s == %s; })%s",
			x, r.Right.Field.Name, rt, l, fail)
	case r.Left.Each() || r.Right.Each():
		list := r.Left.Field
		if r.Right.Each() {
			list = r.Right.Field
		}
		return fmt.Sprintf("    if (!%s.error() && std::ranges::any_of(f.%s, [&](const auto& e) { return !(%s %s %s); })%s",
			x, list.Name, l, r.Op, rt, fail)
	}
	return fmt.Sprintf("    if (!%s.error() && !(%s %s %s)%s", x, l, r.Op, rt, fail)
}

type cppRecordDecl struct {
	name, textName string
	fields         []Field
	rules          []Relation
	msg            *Message
}

func cppRecords(s *Schema) []cppRecordDecl {
	var out []cppRecordDecl
	for _, st := range s.Structs {
		out = append(out, cppRecordDecl{st.Name, st.Name, st.Fields, st.Rules, nil})
	}
	for _, m := range s.Messages {
		out = append(out, cppRecordDecl{goName(m.Name), m.Name, m.Fields, m.Rules, m})
	}
	return out
}

// cppClass emits <Name>Fields, the aggregate a caller fills, and <Name>, which
// holds a validated copy behind const getters. A default-constructed <Name>
// is the zero value, which encode refuses when it breaks a rule.
func cppClass(b *strings.Builder, r cppRecordDecl) {
	fmt.Fprintf(b, "struct %sFields {\n", r.name)
	for _, f := range r.fields {
		fmt.Fprintf(b, "    %s %s%s;\n", cppType(f.Type), f.Name, cppInit(f.Type))
	}
	fmt.Fprintf(b, "\n    bool operator==(const %sFields&) const = default;\n};\n\n", r.name)

	fmt.Fprintf(b, "// Read-only. Decoding and build() are the only ways to fill a %[1]s, so it\n// holds a value the schema allows.\nclass %[1]s {\npublic:\n", r.name)
	if r.msg != nil {
		fmt.Fprintf(b, "    static constexpr std::uint32_t message_id = %d;\n    static constexpr codec::Channel channel = codec::Channel::%s;\n\n", r.msg.ID, r.msg.Channel)
	}
	fmt.Fprintf(b, "    // Refuses f with the error a decoder gives for the same value's bytes.\n    static std::expected<%[1]s, codec::Error> build(%[1]sFields f);\n\n", r.name)
	for _, f := range r.fields {
		fmt.Fprintf(b, "    const %s& %s() const { return f_.%[2]s; }\n", cppType(f.Type), f.Name)
	}
	fmt.Fprintf(b, "\n    bool operator==(const %s&) const = default;\n\nprivate:\n    friend struct detail::Access;\n    %[1]sFields f_;\n};\n\n", r.name)
}

func genCppHeader(s *Schema, schemaPath, ns string) []byte {
	var b strings.Builder
	fmt.Fprintf(&b, "// Code generated by wiregen from %s. DO NOT EDIT.\n\n#pragma once\n\n", schemaPath)
	b.WriteString("#include <cstdint>\n#include <expected>\n#include <span>\n#include <string>\n#include <variant>\n#include <vector>\n\n#include \"marque/wire/codec.hpp\"\n\n")
	fmt.Fprintf(&b, "namespace %s {\n\n", ns)
	fmt.Fprintf(&b, "inline constexpr std::uint64_t schema_hash = 0x%016xULL;\n\n", s.Hash())
	b.WriteString("namespace detail {\nstruct Access;\n}\n\n")

	for _, h := range s.Handles {
		fmt.Fprintf(&b, "// Pairs a slot index with the generation that slot had when the entity was\n// created, so a reused index never names the old entity.\nstruct %s {\n    std::uint32_t index = 0;\n    std::uint32_t gen = 0;\n\n    bool operator==(const %s&) const = default;\n};\n\n", h.Name, h.Name)
	}
	for _, e := range s.Enums {
		fmt.Fprintf(&b, "enum class %s : std::uint32_t {\n", e.Name)
		for _, m := range e.Members {
			fmt.Fprintf(&b, "    %s = %d,\n", m.Name, m.Value)
		}
		b.WriteString("};\n\n")
	}
	records := cppRecords(s)
	for _, r := range records {
		cppClass(&b, r)
	}
	for _, c := range cppChannels(s) {
		if len(c.names) == 0 {
			fmt.Fprintf(&b, "// No %s messages yet. std::variant<> is ill-formed, so the channel holds\n// std::monostate, which its decoder never returns.\n", c.name)
			fmt.Fprintf(&b, "using %s = std::variant<std::monostate>;\n", c.alias)
			continue
		}
		fmt.Fprintf(&b, "using %s = std::variant<%s>;\n", c.alias, strings.Join(c.names, ", "))
	}
	b.WriteString("\n")
	for _, m := range s.Messages {
		fmt.Fprintf(&b, "std::expected<void, codec::Error> encode(const %s& m, std::vector<std::uint8_t>& out);\n", goName(m.Name))
	}
	b.WriteString("\n// Text forms, identical to the Go String() methods.\n")
	for _, r := range records {
		fmt.Fprintf(&b, "std::string to_text(const %s& v);\n", r.name)
	}
	b.WriteString("\n")
	for _, c := range cppChannels(s) {
		fmt.Fprintf(&b, "// Reads one %[1]s message and leaves r after it. An id from another channel\n// fails with codec::Error::unknown_message.\nstd::expected<%[2]s, codec::Error> decode_next_%[1]s(codec::Reader& r);\n", c.name, c.alias)
		fmt.Fprintf(&b, "// Decodes exactly one %[1]s message; any byte left over is an error.\nstd::expected<%[2]s, codec::Error> decode_%[1]s(std::span<const std::uint8_t> bytes);\n", c.name, c.alias)
		fmt.Fprintf(&b, "std::expected<void, codec::Error> encode_%[1]s(const %[2]s& m, std::vector<std::uint8_t>& out);\nstd::string text_%[1]s(const %[2]s& m);\n\n", c.name, c.alias)
	}
	b.WriteString("}\n")
	return []byte(b.String())
}

type cppChannel struct {
	name, alias string
	names       []string
}

func cppChannels(s *Schema) []cppChannel {
	var out []cppChannel
	for _, ch := range channels {
		c := cppChannel{name: ch, alias: goName(ch) + "Msg"}
		for _, m := range s.MessagesOn(ch) {
			c.names = append(c.names, goName(m.Name))
		}
		out = append(out, c)
	}
	return out
}

func cppRecordCodec(b *strings.Builder, r cppRecordDecl) {
	fmt.Fprintf(b, "[[maybe_unused]] void write(codec::Writer& w, const %sFields& f) {\n", r.name)
	for _, f := range r.fields {
		fmt.Fprintf(b, "    %s\n", cppEncode(f.Type, "f."+f.Name))
		b.WriteString(cppChecks("w", f))
	}
	for _, rel := range r.rules {
		b.WriteString(cppRelation("w", rel))
	}
	b.WriteString("}\n\n")
	fmt.Fprintf(b, "[[maybe_unused]] void write(codec::Writer& w, const %s& v) { write(w, detail::Access::fields(v)); }\n\n", r.name)

	fmt.Fprintf(b, "[[maybe_unused]] %[1]s read_%[1]s(codec::Reader& r) {\n    %[1]sFields f;\n", r.name)
	for _, f := range r.fields {
		b.WriteString(cppDecodeField(f))
		b.WriteString(cppChecks("r", f))
	}
	for _, rel := range r.rules {
		b.WriteString(cppRelation("r", rel))
	}
	fmt.Fprintf(b, "    return detail::Access::make<%s>(std::move(f));\n}\n\n", r.name)

	fmt.Fprintf(b, "[[maybe_unused]] void text(std::string& out, const %sFields& f) {\n", r.name)
	for i, f := range r.fields {
		sep := " "
		if i == 0 {
			sep = r.textName + "{"
		}
		fmt.Fprintf(b, "    out += %q;\n    %s\n", sep+f.Name+":", cppText(f.Type, "f."+f.Name))
	}
	b.WriteString("    out += '}';\n}\n\n")
	fmt.Fprintf(b, "[[maybe_unused]] void text(std::string& out, const %s& v) { text(out, detail::Access::fields(v)); }\n\n", r.name)
}

func genCppSource(s *Schema, schemaPath, ns, header string) []byte {
	var b strings.Builder
	fmt.Fprintf(&b, "// Code generated by wiregen from %s. DO NOT EDIT.\n\n#include \"%s\"\n\n#include <algorithm>\n#include <utility>\n\n", schemaPath, header)
	fmt.Fprintf(&b, "namespace %s {\n\n", ns)
	b.WriteString(`// The one door into a record's fields: generated readers fill them, and
// writers and text forms read them.
struct detail::Access {
    template <typename T>
    static const auto& fields(const T& v) {
        return v.f_;
    }

    template <typename T, typename F>
    static T make(F&& f) {
        T v;
        v.f_ = std::forward<F>(f);
        return v;
    }
};

namespace {

`)
	for _, q := range s.Quants {
		fmt.Fprintf(&b, "[[maybe_unused]] constexpr codec::Quant %s{%d, %d, %d, %d, %d};\n", cppQuantVar(q), q.Min, q.Max, q.PerUnit, q.Steps(), q.Width())
	}
	if len(s.Quants) > 0 {
		b.WriteString("\n")
	}
	for _, h := range s.Handles {
		fmt.Fprintf(&b, `[[maybe_unused]] void write(codec::Writer& w, const %[1]s& v) {
    w.varint(v.index);
    w.varint(v.gen);
}

[[maybe_unused]] %[1]s read_%[1]s(codec::Reader& r) {
    %[1]s v;
    v.index = r.varint();
    v.gen = r.varint();
    return v;
}

[[maybe_unused]] void text(std::string& out, const %[1]s& v) {
    out += "%[1]s(";
    out += std::to_string(v.index);
    out += '/';
    out += std::to_string(v.gen);
    out += ')';
}

`, h.Name)
	}
	for _, e := range s.Enums {
		fmt.Fprintf(&b, "[[maybe_unused]] bool valid(%s v) {\n    switch (v) {\n", e.Name)
		for _, m := range e.Members {
			fmt.Fprintf(&b, "    case %s::%s:\n", e.Name, m.Name)
		}
		b.WriteString("        return true;\n    }\n    return false;\n}\n\n")
		fmt.Fprintf(&b, "[[maybe_unused]] void write(codec::Writer& w, %[1]s v) {\n    if (!valid(v)) {\n        w.fail(codec::Error::bad_enum);\n        return;\n    }\n    w.varint(static_cast<std::uint32_t>(v));\n}\n\n[[maybe_unused]] %[1]s read_%[1]s(codec::Reader& r) {\n    const auto v = static_cast<%[1]s>(r.varint());\n    if (!r.error() && !valid(v)) r.fail(codec::Error::bad_enum);\n    return v;\n}\n\n", e.Name)
		fmt.Fprintf(&b, "[[maybe_unused]] void text(std::string& out, %s v) {\n    switch (v) {\n", e.Name)
		for _, m := range e.Members {
			fmt.Fprintf(&b, "    case %s::%s:\n        out += %q;\n        return;\n", e.Name, m.Name, m.Name)
		}
		fmt.Fprintf(&b, "    }\n    out += \"%s(\" + std::to_string(static_cast<std::uint32_t>(v)) + \")\";\n}\n\n", e.Name)
	}
	records := cppRecords(s)
	for _, r := range records {
		cppRecordCodec(&b, r)
	}
	b.WriteString("}\n\n")
	for _, r := range records {
		fmt.Fprintf(&b, "std::expected<%[1]s, codec::Error> %[1]s::build(%[1]sFields f) {\n    codec::Writer w;\n    write(w, f);\n    if (auto err = w.error()) return std::unexpected(*err);\n    %[1]s v;\n    v.f_ = std::move(f);\n    return v;\n}\n\n", r.name)
		fmt.Fprintf(&b, "std::string to_text(const %s& v) {\n    std::string out;\n    text(out, v);\n    return out;\n}\n\n", r.name)
	}
	for _, m := range s.Messages {
		name := goName(m.Name)
		fmt.Fprintf(&b, "std::expected<void, codec::Error> encode(const %[1]s& m, std::vector<std::uint8_t>& out) {\n    codec::Writer w{out};\n    w.varint(%[1]s::message_id);\n    write(w, m);\n    return w.finish();\n}\n\n", name)
	}
	for _, c := range cppChannels(s) {
		fmt.Fprintf(&b, "std::expected<%s, codec::Error> decode_next_%s(codec::Reader& r) {\n    %s m;\n    switch (r.varint()) {\n", c.alias, c.name, c.alias)
		for _, name := range c.names {
			fmt.Fprintf(&b, "    case %[1]s::message_id:\n        m = read_%[1]s(r);\n        break;\n", name)
		}
		b.WriteString("    default:\n        r.fail(codec::Error::unknown_message);\n        break;\n    }\n    if (auto err = r.error()) return std::unexpected(*err);\n    return m;\n}\n\n")
		fmt.Fprintf(&b, "std::expected<%[1]s, codec::Error> decode_%[2]s(std::span<const std::uint8_t> bytes) {\n    codec::Reader r{bytes};\n    auto m = decode_next_%[2]s(r);\n    if (!m) return m;\n    if (auto err = r.finish()) return std::unexpected(*err);\n    return m;\n}\n\n", c.alias, c.name)
		if len(c.names) == 0 {
			fmt.Fprintf(&b, "std::expected<void, codec::Error> encode_%[2]s(const %[1]s&, std::vector<std::uint8_t>&) {\n    return std::unexpected(codec::Error::unknown_message);\n}\n\nstd::string text_%[2]s(const %[1]s&) { return {}; }\n\n", c.alias, c.name)
			continue
		}
		fmt.Fprintf(&b, "std::expected<void, codec::Error> encode_%[2]s(const %[1]s& m, std::vector<std::uint8_t>& out) {\n    return std::visit([&](const auto& v) { return encode(v, out); }, m);\n}\n\nstd::string text_%[2]s(const %[1]s& m) {\n    return std::visit([](const auto& v) { return to_text(v); }, m);\n}\n\n", c.alias, c.name)
	}
	b.WriteString("}\n")
	return []byte(b.String())
}

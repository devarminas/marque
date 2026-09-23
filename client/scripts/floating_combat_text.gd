extends Label3D


## Whether floating combat text spawns at all.
@export var fct_enabled := true

## How long the float lives before being freed, in milliseconds.
@export var fct_lifetime_msec := 1200

## Base font size for a normal white hit.
@export var fct_scale := 64


const KIND_WHITE := "white"
const KIND_MISS := "miss"
const KIND_SPELL := "spell"
const KIND_HEAL := "heal"

## Rise distance in world units over the float's lifetime.
const RISE_DISTANCE := 1.2

## Style table keyed by kind+crit. Each entry: {color, size_mul, prefix, suffix}.
const STYLES := {
	"white_false": {"color": Color(1.0, 1.0, 1.0, 1.0), "size_mul": 1.0, "prefix": "", "suffix": ""},
	"white_true":  {"color": Color(1.0, 0.85, 0.15, 1.0), "size_mul": 1.5, "prefix": "", "suffix": "!"},
	"miss_false":  {"color": Color(0.6, 0.6, 0.6, 1.0), "size_mul": 0.9, "prefix": "", "suffix": ""},
	"miss_true":   {"color": Color(0.6, 0.6, 0.6, 1.0), "size_mul": 0.9, "prefix": "", "suffix": ""},
	"spell_false": {"color": Color(0.55, 0.7, 1.0, 1.0), "size_mul": 1.0, "prefix": "", "suffix": ""},
	"spell_true":  {"color": Color(0.55, 0.7, 1.0, 1.0), "size_mul": 1.5, "prefix": "", "suffix": "!"},
	"heal_false":  {"color": Color(0.35, 0.95, 0.45, 1.0), "size_mul": 1.0, "prefix": "+", "suffix": ""},
	"heal_true":   {"color": Color(0.35, 0.95, 0.45, 1.0), "size_mul": 1.5, "prefix": "+", "suffix": "!"},
}


## The kind that was last shown (for test inspection).
var last_kind := ""

## The crit flag of the last show_hit call.
var last_crit := false


static func style_for(kind: String, crit: bool) -> Dictionary:
	var key := "%s_%s" % [kind, str(crit).to_lower()]
	return STYLES.get(key, STYLES["white_false"])


static func format_text(amount: int, kind: String, crit: bool) -> String:
	var style := style_for(kind, crit)
	if kind == KIND_MISS:
		return "Miss"
	return "%s%d%s" % [style["prefix"], amount, style["suffix"]]


func show_hit(amount: int, kind: String, crit: bool) -> void:
	last_kind = kind
	last_crit = crit
	var style := style_for(kind, crit)
	text = format_text(amount, kind, crit)
	modulate = style["color"]
	font_size = int(fct_scale * style["size_mul"])
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	visible = true

	var lifetime_sec := fct_lifetime_msec / 1000.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position:y", position.y + RISE_DISTANCE, lifetime_sec)
	tween.tween_property(self, "modulate:a", 0.0, lifetime_sec)
	tween.chain().tween_callback(queue_free)

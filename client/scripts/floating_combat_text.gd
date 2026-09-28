extends Label3D


@export var fct_enabled := true
@export var fct_lifetime_msec := 1200
@export var fct_scale := 64


const KIND_WHITE := "white"
const KIND_MISS := "miss"
const KIND_SPELL := "spell"
const KIND_HEAL := "heal"

const RISE_DISTANCE := 1.2

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


var last_kind := ""
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
	_print_demo()
	_print_lifetime("present")

	var lifetime_sec := fct_lifetime_msec / 1000.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position:y", position.y + RISE_DISTANCE, lifetime_sec)
	tween.tween_property(self, "modulate:a", 0.0, lifetime_sec)
	tween.chain().tween_callback(_finish_lifetime)


func _finish_lifetime() -> void:
	_print_lifetime("gone")
	queue_free()


func _print_lifetime(state: String) -> void:
	print("DEMO fct lifetime %s kind=%s text=%s scale=%d" % [state, last_kind, text, font_size])


func _print_demo() -> void:
	match last_kind:
		KIND_MISS:
			print("DEMO fct miss text=%s scale=%d color=%s" % [text, font_size, modulate.to_html()])
		KIND_HEAL:
			print("DEMO fct heal=%s scale=%d text=%s" % [text, font_size, text])
		KIND_WHITE:
			var amount := text.trim_suffix("!")
			if last_crit:
				print("DEMO fct crit=%s scale=%d text=%s" % [amount, font_size, text])
			else:
				print("DEMO fct white=%s scale=%d text=%s" % [amount, font_size, text])
		KIND_SPELL:
			print("DEMO fct spell=%s scale=%d text=%s" % [text, font_size, text])

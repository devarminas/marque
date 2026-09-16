extends PanelContainer


const CraftRecipes := preload("res://scripts/craft_recipes.gd")

@export var heading: Label
@export var recipes_label: Label
@export var close_button: Button

var _station_id := 0
var _station_kind := ""


func _ready() -> void:
	if heading == null or recipes_label == null or close_button == null:
		push_error(
			"StationRecipeSheet: the scene did not assign heading, recipes_label, and close_button"
		)
		return
	close_button.pressed.connect(clear)


func apply(station_id: int, station_kind: String, rows: Array) -> void:
	if station_id <= 0:
		push_error("StationRecipeSheet.apply: station ids start at 1, got %d" % station_id)
		return
	_station_id = station_id
	_station_kind = station_kind
	visible = true
	if heading != null:
		heading.text = CraftRecipes.display_name(station_kind)
	if recipes_label == null:
		return
	if rows.is_empty():
		recipes_label.text = "No recipes."
		return
	var lines := PackedStringArray()
	for row: Dictionary in rows:
		var line := String(row.get("text", ""))
		if bool(row.get("ready", false)):
			lines.append(line)
		else:
			lines.append("%s (missing)" % line)
	recipes_label.text = "\n".join(lines)


func clear() -> void:
	_station_id = 0
	_station_kind = ""
	visible = false
	if heading != null:
		heading.text = ""
	if recipes_label != null:
		recipes_label.text = ""


func is_open() -> bool:
	return visible and _station_id > 0


func station_id() -> int:
	return _station_id


func station_kind() -> String:
	return _station_kind


func recipe_text() -> String:
	return "" if recipes_label == null else recipes_label.text

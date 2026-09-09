extends PanelContainer


const TOGGLE_ACTION := "toggle_quest_log"

@export var empty_label: Label
@export var entries_label: Label


func toggle() -> void:
	visible = not visible


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed(TOGGLE_ACTION):
		return
	toggle()
	get_viewport().set_input_as_handled()


func apply(
	ids: PackedStringArray,
	titles: PackedStringArray,
	objectives: PackedStringArray,
	statuses: PackedStringArray,
) -> void:
	if (
		ids.size() != titles.size()
		or ids.size() != objectives.size()
		or ids.size() != statuses.size()
	):
		push_error(
			"QuestLogPanel.apply: mismatched quest field counts %d/%d/%d/%d"
			% [ids.size(), titles.size(), objectives.size(), statuses.size()]
		)
		return

	if empty_label == null or entries_label == null:
		push_error("QuestLogPanel: the scene did not assign empty_label and entries_label")
		return

	if ids.is_empty():
		empty_label.visible = true
		entries_label.visible = false
		entries_label.text = ""
		return

	var blocks := PackedStringArray()
	for index in ids.size():
		var heading: String = titles[index]
		if heading.is_empty():
			heading = ids[index]
		blocks.append("%s\n%s\n%s" % [heading, objectives[index], statuses[index]])

	empty_label.visible = false
	entries_label.visible = true
	entries_label.text = "\n\n".join(blocks)

extends PanelContainer


signal line_submitted(line: String)

@export var scrollback: RichTextLabel
@export var line_edit: LineEdit

var _history: PackedStringArray = PackedStringArray()
var _history_index := -1
var _draft := ""


func _ready() -> void:
	if scrollback == null or line_edit == null:
		push_error("AdminConsole: the scene did not assign scrollback and line_edit")
		return
	line_edit.text_submitted.connect(_on_text_submitted)
	line_edit.gui_input.connect(_on_line_gui_input)
	visible = false


func is_open() -> bool:
	return visible


func open_console() -> void:
	if visible:
		return
	visible = true
	_history_index = -1
	_draft = ""
	if line_edit != null:
		line_edit.clear()
		line_edit.call_deferred("grab_focus")


func close_console() -> void:
	if not visible:
		return
	visible = false
	_history_index = -1
	_draft = ""
	if line_edit != null:
		line_edit.release_focus()
		line_edit.clear()


func toggle() -> void:
	if visible:
		close_console()
	else:
		open_console()


func append_line(text: String) -> void:
	if scrollback == null:
		return
	if scrollback.get_parsed_text().is_empty():
		scrollback.append_text(text)
	else:
		scrollback.append_text("\n" + text)
	scrollback.scroll_to_line(scrollback.get_line_count() - 1)


func scrollback_text() -> String:
	if scrollback == null:
		return ""
	return scrollback.get_parsed_text()


func history() -> PackedStringArray:
	return _history.duplicate()


func _on_text_submitted(text: String) -> void:
	var line := text.strip_edges()
	if line.is_empty():
		if line_edit != null:
			line_edit.clear()
		return
	append_line("> " + line)
	_history.append(line)
	_history_index = -1
	_draft = ""
	if line_edit != null:
		line_edit.clear()
	line_submitted.emit(line)


func _on_line_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_UP:
		_history_older()
		accept_event()
	elif key.keycode == KEY_DOWN:
		_history_newer()
		accept_event()


func _history_older() -> void:
	if _history.is_empty() or line_edit == null:
		return
	if _history_index < 0:
		_draft = line_edit.text
		_history_index = _history.size() - 1
	elif _history_index > 0:
		_history_index -= 1
	line_edit.text = _history[_history_index]
	line_edit.caret_column = line_edit.text.length()


func _history_newer() -> void:
	if line_edit == null or _history_index < 0:
		return
	if _history_index + 1 >= _history.size():
		_history_index = -1
		line_edit.text = _draft
	else:
		_history_index += 1
		line_edit.text = _history[_history_index]
	line_edit.caret_column = line_edit.text.length()

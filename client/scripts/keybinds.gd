extends Object

## Remappable chrome actions. Hotbar and movement stay fixed in project.godot.
## Conflict policy: swap when the new key belongs to another managed action;
## refuse when it belongs to any other InputMap action or is Escape.

const DEFAULT_PATH := "user://input_map.cfg"
const SECTION := "actions"

const ACTIONS: PackedStringArray = ["toggle_inventory", "toggle_quest_log"]

const DEFAULTS := {
	"toggle_inventory": KEY_I,
	"toggle_quest_log": KEY_J,
}

static var path: String = DEFAULT_PATH


static func is_managed(action: StringName) -> bool:
	return ACTIONS.has(String(action))


static func physical_keycode(action: StringName) -> int:
	var fallback := int(DEFAULTS.get(String(action), 0))
	if not InputMap.has_action(action):
		return fallback
	for event in InputMap.action_get_events(action):
		var key := event as InputEventKey
		if key != null and key.physical_keycode != KEY_NONE:
			return int(key.physical_keycode)
	return fallback


static func display_name(physical: int) -> String:
	if physical <= 0:
		return "?"
	return OS.get_keycode_string(physical as Key)


static func apply_saved() -> void:
	if not FileAccess.file_exists(path):
		return
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		_restore_and_overwrite()
		return
	var applied := false
	for action in ACTIONS:
		if not cfg.has_section_key(SECTION, action):
			continue
		var code := int(cfg.get_value(SECTION, action))
		if code <= 0:
			_restore_and_overwrite()
			return
		_set_physical(action, code)
		applied = true
	if not applied:
		_restore_and_overwrite()


static func restore_defaults() -> void:
	for action in ACTIONS:
		_set_physical(action, int(DEFAULTS[action]))


static func save() -> Error:
	var cfg := ConfigFile.new()
	for action in ACTIONS:
		cfg.set_value(SECTION, action, physical_keycode(action))
	return cfg.save(path)


static func rebind(action: StringName, physical: int) -> String:
	var action_s := String(action)
	if not is_managed(action):
		return "that action is not remappable"
	if physical == KEY_NONE or physical == KEY_ESCAPE:
		return "that key is reserved"
	var owner := _owner_of(physical)
	if owner != "" and owner != action_s:
		if is_managed(owner):
			var previous := physical_keycode(action)
			_set_physical(action, physical)
			_set_physical(owner, previous)
			if save() != OK:
				return "could not save keybinds"
			return ""
		return "that key is already bound to %s" % owner
	_set_physical(action, physical)
	if save() != OK:
		return "could not save keybinds"
	return ""


static func _restore_and_overwrite() -> void:
	restore_defaults()
	save()


static func _owner_of(physical: int) -> String:
	for action in InputMap.get_actions():
		for event in InputMap.action_get_events(action):
			var key := event as InputEventKey
			if key != null and int(key.physical_keycode) == physical:
				return String(action)
	return ""


static func _set_physical(action: StringName, physical: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)
	var event := InputEventKey.new()
	event.physical_keycode = physical as Key
	InputMap.action_add_event(action, event)

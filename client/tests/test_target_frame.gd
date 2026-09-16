extends Node3D

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const TargetFrameScript := preload("res://scripts/target_frame.gd")
const Assertions := preload("res://tests/assertions.gd")

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _frame: TargetFrameScript = null


func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	print("== target frame: select, hp bind, clear ==")

	_root = MainScene.instantiate() as Node3D
	_root.name = "TargetFrameClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_frame = _root.get_node("UI/TargetFrame") as TargetFrameScript

	await get_tree().process_frame
	await get_tree().process_frame

	_test_authored_layout()
	await _test_select_shows_name_and_hp()
	await _test_missing_name_still_shows_hp()
	await _test_live_hp_updates_selected()
	await _test_death_clears_frame()
	await _test_deselect_clears_frame()
	await _test_despawn_clears_frame()
	await _test_player_select_keeps_frame_hidden()
	await _test_hostile_cast_shows_name_and_progress()
	await _test_mid_select_shows_in_progress_cast()
	await _test_cast_cancel_clears_bar()
	await _test_cast_resolve_clears_bar()
	await _test_deselect_hides_cast_bar()
	await _test_player_cast_does_not_fill_target_bar()
	await _test_instant_heal_has_no_stuck_bar()

	print(
		"TARGET FRAME RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


func _test_authored_layout() -> void:
	_check(_frame != null, "main.tscn authors UI/TargetFrame")
	_check(not _frame.visible, "target frame starts hidden")
	_check(
		_frame.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"TargetFrame IGNORE so world clicks pass through, got filter %d" % _frame.mouse_filter,
	)
	var tray := _frame.get_node_or_null("Frame") as NinePatchRect
	_check(
		tray != null
		and tray.texture != null
		and String(tray.texture.resource_path).contains("basic_bar2"),
		"TargetFrame tray uses basic_bar2 like HpHud",
	)
	var portrait := _frame.get_node_or_null("Portrait") as Control
	var portrait_bg := _frame.get_node_or_null("Portrait/Bg") as TextureRect
	var portrait_ring := _frame.get_node_or_null("Portrait/Ring") as TextureRect
	_check(portrait != null, "TargetFrame authors a left Portrait")
	_check(
		portrait_bg != null
		and portrait_bg.texture != null
		and String(portrait_bg.texture.resource_path).contains("hero_icon_frame_bg"),
		"Portrait bg uses hero_icon_frame_bg",
	)
	_check(
		portrait_ring != null
		and portrait_ring.texture != null
		and String(portrait_ring.texture.resource_path).ends_with("hero_icon_frame.png"),
		"Portrait ring uses hero_icon_frame",
	)
	var hp_border := _frame.get_node_or_null("Stack/HpRow/Border") as NinePatchRect
	_check(
		hp_border != null
		and hp_border.texture != null
		and String(hp_border.texture.resource_path).contains("hp_frame"),
		"HP row has Hp_frame border",
	)
	var source := FileAccess.get_file_as_string("res://scripts/target_frame.gd")
	var add_child := RegEx.new()
	add_child.compile("add_child\\s*\\(")
	_check(
		add_child.search(source) == null,
		"target_frame.gd never builds its tree with add_child",
	)
	var cast_row := _frame.get_node_or_null("Stack/CastRow") as Control
	_check(cast_row != null, "TargetFrame authors Stack/CastRow")
	_check(
		cast_row != null and not cast_row.visible,
		"cast row starts hidden",
	)
	_check(
		_frame.cast_bar == cast_row,
		"cast_bar export points at authored CastRow",
	)
	var session_src := FileAccess.get_file_as_string("res://scripts/session.gd")
	_check(
		not session_src.contains("interruptible"),
		"hostile cast bar has no interruptible-only filter",
	)


func _test_select_shows_name_and_hp() -> void:
	await _feed_welcome()
	_check(not _frame.visible, "frame stays hidden until an enemy is selected")
	_check(_session.select_player(1000004), "select hostile imp")
	_check(_session.selected_player_id() == 1000004, "selection matches combat target id")
	_check(_frame.visible, "selecting an enemy shows the target frame")
	_check(
		_frame.name_text == "Imp",
		'target name reads "Imp", got "%s"' % _frame.name_text,
	)
	_check(
		_frame.text == "50/50",
		'target HP reads "50/50", got "%s"' % _frame.text,
	)
	var bar: ProgressBar = _frame.get_node_or_null("Stack/HpRow/Bar") as ProgressBar
	_check(
		bar != null and is_equal_approx(bar.max_value, 50.0) and is_equal_approx(bar.value, 50.0),
		"HP bar binds to server max and current",
	)


func _test_missing_name_still_shows_hp() -> void:
	_session.clear_selection()
	_check(_session.select_player(1000002), "select hostile dummy with no name")
	_check(_frame.visible, "missing name still shows the frame")
	_check(
		_frame.name_text == "",
		'missing name leaves the name blank, got "%s"' % _frame.name_text,
	)
	_check(
		_frame.text == "100/100",
		'HP still reads from server cache, got "%s"' % _frame.text,
	)


func _test_live_hp_updates_selected() -> void:
	_check(_session.select_player(1000004), "reselect imp for live hp")
	await _feed('{"hp":{"id":1000004,"hp":20,"max_hp":50}}')
	_check(
		_frame.visible and _frame.text == "20/50",
		'live hp restatement updates target frame to 20/50, got "%s"' % _frame.text,
	)
	_check(
		_frame.name_text == "Imp",
		"name stays across an hp frame",
	)


func _test_death_clears_frame() -> void:
	await _feed('{"hp":{"id":1000004,"hp":0,"max_hp":50}}')
	_check(_session.selected_player_id() == 0, "death clears the combat selection")
	_check(not _frame.visible, "death clears the target frame")


func _test_deselect_clears_frame() -> void:
	await _feed('{"hp":{"id":1000004,"hp":50,"max_hp":50}}')
	_check(_session.select_player(1000004), "select imp again after revive")
	_check(_frame.visible, "precondition: frame visible")
	_check(_session.clear_selection(), "deselect clears selection")
	_check(not _frame.visible, "deselect clears the target frame")


func _test_despawn_clears_frame() -> void:
	_check(_session.select_player(1000002), "select hostile dummy")
	_check(_frame.visible, "precondition: dummy frame visible")
	await _feed('{"despawn":{"id":1000002}}')
	_check(_session.selected_player_id() == 0, "despawn clears selection")
	_check(not _frame.visible, "despawn clears the target frame")


func _test_player_select_keeps_frame_hidden() -> void:
	_check(_session.select_player(2), "select a remote player")
	_check(_session.selected_player_id() == 2, "remote is selected")
	_check(not _frame.visible, "player selection does not open the enemy target frame")
	_session.clear_selection()


func _test_hostile_cast_shows_name_and_progress() -> void:
	await _feed_welcome()
	_check(_session.select_player(1000004), "select imp for hostile cast")
	_check(not _frame.cast_visible, "cast bar hidden until CastPhase begin")
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"begin"}}')
	_check(_frame.cast_visible, "Imp fireball begin shows the target cast bar")
	_check(
		_frame.cast_text == "Fireball",
		'target cast name reads "Fireball", got "%s"' % _frame.cast_text,
	)
	var bar := _cast_progress_bar()
	_check(bar != null, "CastRow authors a ProgressBar")
	if bar == null:
		return
	_check(
		bar.max_value > 0.0,
		"cast bar total is catalog cast_ticks × tick_ms, got max %s" % bar.max_value,
	)
	var first := bar.value
	await get_tree().create_timer(0.12).timeout
	await get_tree().process_frame
	_check(
		_frame.cast_visible and bar.value > first,
		"cast bar advances from begin toward resolve, %s then %s" % [first, bar.value],
	)


func _test_mid_select_shows_in_progress_cast() -> void:
	_session.clear_selection()
	_check(not _frame.visible, "deselect hides the frame before mid-select")
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"cancel"}}')
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"begin"}}')
	_check(not _frame.cast_visible, "unselected Imp does not show a cast bar")
	_check(_session.select_player(1000004), "select Imp already casting")
	_check(
		_frame.visible and _frame.cast_visible and _frame.cast_text == "Fireball",
		"selecting a casting hostile still shows Fireball",
	)
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"cancel"}}')


func _test_cast_cancel_clears_bar() -> void:
	_check(_session.select_player(1000004), "select imp for cancel")
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"begin"}}')
	_check(_frame.cast_visible, "precondition: bar visible before cancel")
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"cancel"}}')
	_check(_frame.visible, "cancel keeps the target frame")
	_check(not _frame.cast_visible, "cancel phase clears the cast bar")
	_check(
		_frame.cast_text == "",
		'cancel leaves the cast label empty, got "%s"' % _frame.cast_text,
	)


func _test_cast_resolve_clears_bar() -> void:
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"begin"}}')
	_check(_frame.cast_visible, "precondition: bar visible before resolve")
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"resolve"}}')
	_check(_frame.visible, "resolve keeps the target frame")
	_check(not _frame.cast_visible, "resolve phase clears the cast bar")


func _test_deselect_hides_cast_bar() -> void:
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"begin"}}')
	_check(_frame.cast_visible, "precondition: bar visible before deselect")
	_check(_session.clear_selection(), "deselect while Imp is casting")
	_check(not _frame.visible, "deselect hides the target frame")
	_check(not _frame.cast_visible, "no target hides the cast bar")
	await _feed('{"cast_phase":{"id":1000004,"ability":"fireball","target":1,"phase":"cancel"}}')


func _test_player_cast_does_not_fill_target_bar() -> void:
	_check(_session.select_player(1000004), "select imp while the local player casts")
	await _feed('{"cast_phase":{"id":1,"ability":"fireball","target":1000004,"phase":"begin"}}')
	_check(_frame.visible, "hostile stays selected during the player's own cast")
	_check(not _frame.cast_visible, "the player's CastPhase does not fill the hostile bar")
	await _feed('{"cast_phase":{"id":1,"ability":"fireball","target":1000004,"phase":"cancel"}}')


func _test_instant_heal_has_no_stuck_bar() -> void:
	await _feed('{"cast_phase":{"id":1000004,"ability":"heal","target":1,"phase":"begin"}}')
	_check(not _frame.cast_visible, "instant heal (no cast_ticks) does not open a bar")
	await _feed('{"cast_phase":{"id":1000004,"ability":"heal","target":1,"phase":"resolve"}}')
	_check(not _frame.cast_visible, "instant heal resolve leaves the bar hidden")


func _cast_progress_bar() -> ProgressBar:
	return _frame.get_node_or_null("Stack/CastRow/Bar") as ProgressBar


func _feed_welcome() -> void:
	await _feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"heartbeat_ticks":10,'
		+ '"players":[{"id":1,"x":0,"z":0,"hp":100,"max_hp":100,"mana":100,"max_mana":100},'
		+ '{"id":2,"x":5,"z":5,"hp":70,"max_hp":100,"mana":40,"max_mana":100}],'
		+ '"items":[],"nodes":[],'
		+ '"npcs":['
		+ '{"id":1000002,"kind":"dummy","faction":"hostile","x":3.0,"z":0.0,"hp":100,"max_hp":100},'
		+ '{"id":1000004,"kind":"imp","faction":"hostile","name":"Imp","x":12.0,"z":8.0,"hp":50,"max_hp":50}'
		+ "]}}"
	)


func _feed(text: String) -> void:
	_net.ingest_text_frame(text)
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	_assertions.check(condition, message)

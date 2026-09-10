extends Node3D


const SessionScript := preload("res://scripts/session.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const CastBarScript := preload("res://scripts/cast_bar.gd")
const PickupDemoScript := preload("res://scripts/pickup_demo.gd")
const EquipDemoScript := preload("res://scripts/equip_demo.gd")
const GatherCraftDemoScript := preload("res://scripts/gather_craft_demo.gd")
const GatherErrorDemoScript := preload("res://scripts/gather_error_demo.gd")
const CraftCastDemoScript := preload("res://scripts/craft_cast_demo.gd")
const CombatDemoScript := preload("res://scripts/combat_demo.gd")
const DummyCastDemoScript := preload("res://scripts/dummy_cast_demo.gd")
const DummyAttackDemoScript := preload("res://scripts/dummy_attack_demo.gd")
const WasdDemoScript := preload("res://scripts/wasd_demo.gd")
const TabCombatDemoScript := preload("res://scripts/tab_combat_demo.gd")
const QuestDemoScript := preload("res://scripts/quest_demo.gd")
const EnemyQuestDemoScript := preload("res://scripts/enemy_quest_demo.gd")
const DeathOverlayScript := preload("res://scripts/death_overlay.gd")
const HpHudScript := preload("res://scripts/hp_hud.gd")
const DialogPanelScript := preload("res://scripts/dialog_panel.gd")
const GivePanelScript := preload("res://scripts/give_panel.gd")
const QuestLogPanelScript := preload("res://scripts/quest_log_panel.gd")

const SCREENSHOT_FLAG := "--screenshot"
const SCREENSHOT_PATH := "user://shot.png"

const FEED_FLAG := "--feed"

const SHOTS_FLAG := "--shots"

const CLICK_FLAG := "--click"

const PHASE_FLAG := "--phase"

const PICKUP_SHOTS_FLAG := "--pickup-shots"

const DROP_CLICK_FLAG := "--drop-click"

const EQUIP_SHOTS_FLAG := "--equip-shots"

const GATHER_CRAFT_SHOTS_FLAG := "--gather-craft-shots"

const GATHER_ERROR_SHOTS_FLAG := "--gather-error-shots"
const CRAFT_CAST_SHOTS_FLAG := "--craft-cast-shots"

const COMBAT_SHOTS_FLAG := "--combat-shots"
const DUMMY_CAST_FLAG := "--dummy-cast"
const DUMMY_ATTACK_FLAG := "--dummy-attack"
const COMBAT_ROLE_FLAG := "--combat-role"
const WASD_SHOTS_FLAG := "--wasd-shots"
const TAB_COMBAT_SHOTS_FLAG := "--tab-combat-shots"
const QUEST_SHOTS_FLAG := "--quest-shots"
const ENEMY_QUEST_SHOTS_FLAG := "--enemy-quest-shots"
const ENEMY_QUEST_ROLE_FLAG := "--enemy-quest-role"

const DEMO_PHASES := 2

const SCREENSHOT_WARMUP_FRAMES := 15

const DEMO_MIN_PLAYERS := 2

const DEMO_JOIN_TIMEOUT_MSEC := 20000

const DEMO_GROUND_CLICK_PROBE_MSEC := 1500

const DEMO_STILL_EPSILON := 0.05

const DEMO_SETTLE_MSEC := 400

const DEMO_WALK_MSEC := 1400

const DEMO_PHASE_GAP_MSEC := 1200

const DEMO_HOLD_MSEC := 2000


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_feed_scripted_frames(args)
	if PICKUP_SHOTS_FLAG in args:
		await _run_pickup_demo(args)
		return
	if EQUIP_SHOTS_FLAG in args:
		await _run_equip_demo(args)
		return
	if GATHER_CRAFT_SHOTS_FLAG in args:
		await _run_gather_craft_demo(args)
		return
	if GATHER_ERROR_SHOTS_FLAG in args:
		await _run_gather_error_demo(args)
		return
	if CRAFT_CAST_SHOTS_FLAG in args:
		await _run_craft_cast_demo(args)
		return
	if COMBAT_SHOTS_FLAG in args:
		await _run_combat_demo(args)
		return
	if DUMMY_CAST_FLAG in args:
		await _run_dummy_cast_demo()
		return
	if DUMMY_ATTACK_FLAG in args:
		await _run_dummy_attack_demo()
		return
	if TAB_COMBAT_SHOTS_FLAG in args:
		await _run_tab_combat_demo(args)
		return
	if WASD_SHOTS_FLAG in args:
		await _run_wasd_demo(args)
		return
	if QUEST_SHOTS_FLAG in args:
		await _run_quest_demo(args)
		return
	if ENEMY_QUEST_SHOTS_FLAG in args:
		await _run_enemy_quest_demo(args)
		return
	if SHOTS_FLAG in args:
		await _run_demo(args)
		return
	if SCREENSHOT_FLAG in args:
		await _capture_and_quit()


func _feed_scripted_frames(args: Array) -> int:
	var path := _argument_after(args, FEED_FLAG)
	if path.is_empty():
		return 0

	var net := get_node_or_null("Session/Net") as NetClientScript
	if net == null:
		push_error("main.tscn has no Session/Net node to feed")
		get_tree().quit(1)
		return 0

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error(
			"%s could not open %s: %d" % [FEED_FLAG, path, FileAccess.get_open_error()]
		)
		get_tree().quit(1)
		return 0

	var count := 0
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		net.ingest_text_frame(line)
		count += 1
	print("main: fed %d scripted frame(s) from %s" % [count, path])
	_print_world_contents()
	return count


func _print_world_contents() -> void:
	var session := get_node_or_null("Session") as SessionScript
	if session == null:
		push_error("main.tscn has no Session node to report")
		return
	var panel := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var slots := -1 if panel == null else panel.slot_count()
	var carried := -1 if panel == null else panel.occupied_slot_count()
	print(
		"main: world holds %d player body(s), %d item body(s), %d/%d inventory slot(s) filled"
		% [session.known_ids().size(), session.known_item_ids().size(), carried, slots]
	)


func _run_pickup_demo(args: Array) -> void:
	var prefix := _argument_after(args, PICKUP_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % PICKUP_SHOTS_FLAG)
		get_tree().quit(1)
		return
	var drop_click := _argument_after(args, DROP_CLICK_FLAG)
	if drop_click.split(",").size() != 2:
		push_error("%s needs a viewport fraction after it, like 0.30,0.62" % DROP_CLICK_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var panel := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var dock := get_node_or_null("UI/RightDock") as EquipmentPanelScript
	if session == null or panel == null or dock == null:
		push_error("main.tscn is missing the Session or UI/RightDock inventory panel to drive")
		get_tree().quit(1)
		return

	var demo := PickupDemoScript.new()
	var code: int = await demo.run(
		self, session, panel, dock, prefix, _parse_fraction(drop_click)
	)
	get_tree().quit(code)


func _run_equip_demo(args: Array) -> void:
	var prefix := _argument_after(args, EQUIP_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % EQUIP_SHOTS_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var inventory := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var equipment := get_node_or_null("UI/RightDock") as EquipmentPanelScript
	if session == null or inventory == null or equipment == null:
		push_error("main.tscn is missing Session or UI/RightDock")
		get_tree().quit(1)
		return

	var demo := EquipDemoScript.new()
	var code: int = await demo.run(self, session, inventory, equipment, prefix)
	get_tree().quit(code)


func _run_gather_craft_demo(args: Array) -> void:
	var prefix := _argument_after(args, GATHER_CRAFT_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % GATHER_CRAFT_SHOTS_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var inventory := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var equipment := get_node_or_null("UI/RightDock") as EquipmentPanelScript
	if session == null or inventory == null or equipment == null:
		push_error("main.tscn is missing Session or UI/RightDock")
		get_tree().quit(1)
		return

	var demo := GatherCraftDemoScript.new()
	var code: int = await demo.run(self, session, inventory, equipment, prefix)
	get_tree().quit(code)


func _run_gather_error_demo(args: Array) -> void:
	var prefix := _argument_after(args, GATHER_ERROR_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % GATHER_ERROR_SHOTS_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var inventory := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var equipment := get_node_or_null("UI/RightDock") as EquipmentPanelScript
	var error_hud := get_node_or_null("UI/ErrorHud")
	if session == null or inventory == null or equipment == null or error_hud == null:
		push_error("main.tscn is missing Session, UI/RightDock, or UI/ErrorHud")
		get_tree().quit(1)
		return

	var demo := GatherErrorDemoScript.new()
	var code: int = await demo.run(self, session, inventory, equipment, error_hud, prefix)
	get_tree().quit(code)


func _run_craft_cast_demo(args: Array) -> void:
	var prefix := _argument_after(args, CRAFT_CAST_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % CRAFT_CAST_SHOTS_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var inventory := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var equipment := get_node_or_null("UI/RightDock") as EquipmentPanelScript
	var cast_bar := get_node_or_null("UI/CastBar") as CastBarScript
	if session == null or inventory == null or equipment == null or cast_bar == null:
		push_error("main.tscn is missing Session, UI/RightDock, or UI/CastBar")
		get_tree().quit(1)
		return

	var demo := CraftCastDemoScript.new()
	var code: int = await demo.run(self, session, inventory, equipment, cast_bar, prefix)
	get_tree().quit(code)


func _run_combat_demo(args: Array) -> void:
	var prefix := _argument_after(args, COMBAT_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % COMBAT_SHOTS_FLAG)
		get_tree().quit(1)
		return
	var role := _argument_after(args, COMBAT_ROLE_FLAG)
	if role.is_empty():
		push_error("%s needs attacker or victim after it" % COMBAT_ROLE_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var death := get_node_or_null("UI/DeathOverlay") as DeathOverlayScript
	var hp_hud := get_node_or_null("UI/HpHud") as HpHudScript
	if session == null or death == null or hp_hud == null:
		push_error("main.tscn is missing Session, UI/DeathOverlay, or UI/HpHud")
		get_tree().quit(1)
		return

	var demo := CombatDemoScript.new()
	var code: int = await demo.run(self, session, death, hp_hud, prefix, role)
	get_tree().quit(code)


func _run_wasd_demo(args: Array) -> void:
	var prefix := _argument_after(args, WASD_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % WASD_SHOTS_FLAG)
		get_tree().quit(1)
		return
	var session := get_node_or_null("Session") as SessionScript
	if session == null:
		push_error("main.tscn is missing Session")
		get_tree().quit(1)
		return
	var demo := WasdDemoScript.new()
	var code: int = await demo.run(self, session, prefix)
	get_tree().quit(code)


func _run_dummy_cast_demo() -> void:
	var session := get_node_or_null("Session") as SessionScript
	if session == null:
		push_error("main.tscn is missing Session")
		get_tree().quit(1)
		return
	var demo := DummyCastDemoScript.new()
	var code: int = await demo.run(self, session)
	get_tree().quit(code)


func _run_dummy_attack_demo() -> void:
	var session := get_node_or_null("Session") as SessionScript
	if session == null:
		push_error("main.tscn is missing Session")
		get_tree().quit(1)
		return
	var demo := DummyAttackDemoScript.new()
	var code: int = await demo.run(self, session)
	get_tree().quit(code)


func _run_tab_combat_demo(args: Array) -> void:
	var prefix := _argument_after(args, TAB_COMBAT_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % TAB_COMBAT_SHOTS_FLAG)
		get_tree().quit(1)
		return
	var session := get_node_or_null("Session") as SessionScript
	if session == null:
		push_error("main.tscn is missing Session")
		get_tree().quit(1)
		return
	var demo := TabCombatDemoScript.new()
	var code: int = await demo.run(self, session, prefix)
	get_tree().quit(code)


func _run_enemy_quest_demo(args: Array) -> void:
	var prefix := _argument_after(args, ENEMY_QUEST_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % ENEMY_QUEST_SHOTS_FLAG)
		get_tree().quit(1)
		return
	var role := _argument_after(args, ENEMY_QUEST_ROLE_FLAG)
	if role.is_empty():
		push_error("%s needs leader or member after it" % ENEMY_QUEST_ROLE_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var inventory := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var dialog := get_node_or_null("UI/DialogPanel") as DialogPanelScript
	var party := get_node_or_null("UI/PartyPanel")
	if session == null or inventory == null or dialog == null or party == null:
		push_error("main.tscn is missing Session, inventory, DialogPanel, or PartyPanel")
		get_tree().quit(1)
		return

	var demo := EnemyQuestDemoScript.new()
	var code: int = await demo.run(self, session, inventory, dialog, party, prefix, role)
	get_tree().quit(code)

func _run_quest_demo(args: Array) -> void:
	var prefix := _argument_after(args, QUEST_SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % QUEST_SHOTS_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var inventory := get_node_or_null("UI/RightDock/Margin/Rows/InventoryPanel") as InventoryPanelScript
	var dialog := get_node_or_null("UI/DialogPanel") as DialogPanelScript
	var give := get_node_or_null("UI/GivePanel") as GivePanelScript
	var quest_log := get_node_or_null("UI/QuestLogPanel") as QuestLogPanelScript
	if session == null or inventory == null or dialog == null or give == null or quest_log == null:
		push_error("main.tscn is missing Session, inventory, DialogPanel, GivePanel, or QuestLogPanel")
		get_tree().quit(1)
		return

	var demo := QuestDemoScript.new()
	var code: int = await demo.run(self, session, inventory, dialog, give, prefix)
	get_tree().quit(code)


func _run_demo(args: Array) -> void:
	var prefix := _argument_after(args, SHOTS_FLAG)
	if prefix.is_empty():
		push_error("%s needs an output path prefix after it" % SHOTS_FLAG)
		get_tree().quit(1)
		return

	var session := get_node_or_null("Session") as SessionScript
	var picker := get_node_or_null("GroundPicker") as GroundPickerScript
	if session == null or picker == null:
		push_error("main.tscn has no Session or GroundPicker node to drive")
		get_tree().quit(1)
		return

	if not await _wait_for_players(session):
		printerr("DEMO TIMEOUT: fewer than %d players after %dms" % [
			DEMO_MIN_PLAYERS, DEMO_JOIN_TIMEOUT_MSEC
		])
		get_tree().quit(1)
		return
	print("DEMO joined %d" % session.own_id())

	var click := _argument_after(args, CLICK_FLAG)
	var my_phase := _argument_after(args, PHASE_FLAG).to_int()
	var shot := 0

	if not click.is_empty():
		if not await _probe_ground_click_ignored(session, picker, _parse_fraction(click)):
			get_tree().quit(1)
			return

	for phase in range(1, DEMO_PHASES + 1):
		if phase > 1:
			await _wait_msec(DEMO_PHASE_GAP_MSEC)
		if phase == my_phase and not click.is_empty():
			if not _walk_to_fraction(session, picker, _parse_fraction(click)):
				get_tree().quit(1)
				return

		await _wait_msec(DEMO_SETTLE_MSEC)
		shot += 1
		if not await _capture(session, prefix, shot):
			get_tree().quit(1)
			return

		await _wait_msec(DEMO_WALK_MSEC)
		shot += 1
		if not await _capture(session, prefix, shot):
			get_tree().quit(1)
			return

	await _wait_msec(DEMO_HOLD_MSEC)
	print("DEMO done")
	get_tree().quit(0)


func _wait_for_players(session: SessionScript) -> bool:
	var deadline := Time.get_ticks_msec() + DEMO_JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if session.known_ids().size() >= DEMO_MIN_PLAYERS:
			return true
		await get_tree().process_frame
	return false


func _capture(session: SessionScript, prefix: String, index: int) -> bool:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var path := "%s_%d.png" % [prefix, index]
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [path, error])
		return false

	print("DEMO shot %d %s" % [index, path])
	for id: int in session.known_ids():
		var avatar: PlayerAvatarScript = session.avatar_for(id)
		if avatar == null:
			continue
		print("DEMO pos %d %d %f %f" % [index, id, avatar.position.x, avatar.position.z])
	return true


func _walk_to_fraction(
	session: SessionScript, picker: GroundPickerScript, fraction: Vector2
) -> bool:
	var pixel := get_viewport().get_visible_rect().size * fraction
	var found: Variant = picker.pick_ground(pixel)
	if found == null:
		push_error(
			"%s %s puts the walk at (%f, %f), where no ray meets the ground"
			% [CLICK_FLAG, fraction, pixel.x, pixel.y]
		)
		return false

	var point: Vector2 = found
	session.request_move_to(point.x, point.y)
	print("DEMO walkto %f %f %f %f" % [pixel.x, pixel.y, point.x, point.y])
	return true


func _probe_ground_click_ignored(
	session: SessionScript, picker: GroundPickerScript, fraction: Vector2
) -> bool:
	var viewport := get_viewport()
	var pixel := viewport.get_visible_rect().size * fraction
	var picked := picker.pick(pixel)
	if picked["target"] != GroundPickerScript.Target.GROUND:
		push_error(
			"the ray at (%f, %f) met target %d rather than bare ground, so a ground-click "
			% [pixel.x, pixel.y, picked["target"]]
			+ "probe there would pass no matter what a ground click does"
		)
		return false

	var avatar := session.avatar_for(session.own_id())
	if avatar == null:
		push_error("this client has no body of its own to watch, so it cannot tell whether it moved")
		return false
	var before := avatar.position
	var ground: Vector2 = picked["ground"]
	print("DEMO groundclick %f %f %f %f" % [pixel.x, pixel.y, ground.x, ground.y])

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pixel
	viewport.push_input(press)
	print("DEMO clicked %f %f" % [press.position.x, press.position.y])

	await _wait_msec(DEMO_GROUND_CLICK_PROBE_MSEC)
	var after := avatar.position
	if before.distance_to(after) > DEMO_STILL_EPSILON:
		push_error(
			"a left click on bare ground at (%f, %f) walked this client from (%f, %f) to "
			% [pixel.x, pixel.y, before.x, before.z]
			+ "(%f, %f) in %dms; the gesture is still wired to move_to"
			% [after.x, after.z, DEMO_GROUND_CLICK_PROBE_MSEC]
		)
		return false

	print("DEMO groundclick_ignored %f %f" % [ground.x, ground.y])
	return true


func _wait_msec(duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _capture_and_quit() -> void:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(SCREENSHOT_PATH)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [SCREENSHOT_PATH, error])
		get_tree().quit(1)
		return

	print("screenshot: ", ProjectSettings.globalize_path(SCREENSHOT_PATH))
	get_tree().quit(0)


static func _argument_after(args: Array, flag: String) -> String:
	var index := args.find(flag)
	if index == -1 or index + 1 >= args.size():
		return ""
	return args[index + 1]


static func _parse_fraction(text: String) -> Vector2:
	var parts := text.split(",")
	if parts.size() != 2 or not parts[0].is_valid_float() or not parts[1].is_valid_float():
		push_error("%s wants two floats like 0.30,0.72, got %s" % [CLICK_FLAG, text])
		return Vector2(0.5, 0.5)
	return Vector2(float(parts[0]), float(parts[1]))

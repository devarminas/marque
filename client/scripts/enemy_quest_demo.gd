extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const DialogPanelScript := preload("res://scripts/dialog_panel.gd")
const PartyPanelScript := preload("res://scripts/party_panel.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const DemoNpcCapture := preload("res://scripts/demo_npc_capture.gd")

const QUEST_ID := "slay_imps"
const QUEST_TITLE := "Imp Patrol"
const ROLE_LEADER := "leader"
const ROLE_MEMBER := "member"
const NEED_KILLS := 5
const REQUIRED_PLAYERS := 2
const REQUIRED_IMPS := 5
const CLICK_HEIGHT := 0.8

const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 25000
const STEP_TIMEOUT_MSEC := 45000
const KILL_TIMEOUT_MSEC := 150000
const HOLD_MSEC := 800
const CLASS_ID := "knight"

const REWARD_KINDS := [
	"plate_helm",
	"plate_chest",
	"plate_legs",
	"sword",
	"shield",
]


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _inventory: InventoryPanelScript
var _dialog: DialogPanelScript
var _party: PartyPanelScript
var _prefix: String
var _role: String


func run(
	root: Node,
	session: SessionScript,
	inventory: InventoryPanelScript,
	dialog: DialogPanelScript,
	party: Node,
	prefix: String,
	role: String,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_inventory = inventory
	_dialog = dialog
	_party = party as PartyPanelScript
	if _party == null:
		return _fail("PartyPanel missing party_panel.gd")
	_prefix = prefix
	_role = role

	if _role != ROLE_LEADER and _role != ROLE_MEMBER:
		return _fail("role must be leader or member, got %s" % _role)

	if not await _wait_for_join():
		return _fail(
			"need %d players, %d imps, imp_quest_giver, and sword kit after %dms"
			% [REQUIRED_PLAYERS, REQUIRED_IMPS, JOIN_TIMEOUT_MSEC]
		)
	print("DEMO joined %d" % _session.own_id())
	print("DEMO role %s" % _role)

	if not await _equip_knight_kit():
		return 1
	print("DEMO class %s" % _session.active_class_id())

	var giver_id := _find_imp_quest_giver()
	if giver_id <= 0:
		return _fail("welcome lacked an imp_quest_giver")
	print("DEMO npc %d imp_quest_giver" % giver_id)

	if _role == ROLE_LEADER:
		if not await _party_as_leader():
			return 1
	else:
		if not await _party_as_member():
			return 1
	print("DEMO party %d members=%d" % [_party.party_id(), _party.members().size()])

	_session.request_talk(giver_id)
	print("DEMO talk %d" % giver_id)
	if not await _wait_dialog_option(giver_id, DialogPanelScript.OPTION_ACCEPT):
		return _fail("accept dialog never opened on npc %d" % giver_id)
	_session.request_dialog_option(giver_id, DialogPanelScript.OPTION_ACCEPT)
	print("DEMO accept %d" % giver_id)
	if not await _wait_quest_status("active"):
		return _fail("quest_log never showed %s as active" % QUEST_ID)
	print("DEMO accepted %s active" % QUEST_ID)

	if not await _capture(1):
		return 1
	_print_quest_log(1)
	_print_party(1)

	if not await _mid_chase_capture():
		return 1

	if not await _kill_until_ready():
		return 1
	print("DEMO killsready %s" % QUEST_ID)

	if not await _capture(3):
		return 1
	_print_quest_log(3)

	_session.request_talk(giver_id)
	print("DEMO talkturnin %d" % giver_id)
	if not await _wait_dialog_option(giver_id, DialogPanelScript.OPTION_TURN_IN):
		return _fail("turn-in dialog never opened on npc %d" % giver_id)
	_session.request_dialog_option(giver_id, DialogPanelScript.OPTION_TURN_IN)
	print("DEMO turnin %d" % giver_id)

	if not await _wait_quest_status("complete"):
		return _fail("quest_log never showed %s as complete" % QUEST_ID)
	if not await _wait_rewards():
		return _fail("bag never held the knight reward kinds after turn-in")
	print("DEMO complete %s" % QUEST_ID)

	if not await _capture(4):
		return 1
	_print_quest_log(4)
	_print_inventory(4)

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _wait_for_join() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if (
			_session.own_id() > 0
			and _session.known_ids().size() >= REQUIRED_PLAYERS
			and _count_imps() >= REQUIRED_IMPS
			and _find_imp_quest_giver() > 0
			and _find_bag_kind("sword") >= 0
		):
			return true
		await _tree.process_frame
	return false


func _equip_knight_kit() -> bool:
	var indices: PackedInt32Array = _session.get("_bag_indices")
	if indices.is_empty():
		_fail("knight join kit never arrived in the bag")
		return false
	for slot: int in indices:
		_session.request_equip(slot)
		await _tree.process_frame
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.active_class_id() == CLASS_ID:
			return true
		await _tree.process_frame
	_fail("worn set never activated knight")
	return false


func _party_as_leader() -> bool:
	var other := _other_player_id()
	if other <= 0:
		return _fail_bool("leader never saw the other player")
	if not _session.select_player(other):
		return _fail_bool("leader could not select player %d" % other)
	_session.request_party_invite(other)
	print("DEMO invite %d" % other)
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _party.party_id() > 0 and _party.members().size() >= REQUIRED_PLAYERS:
			return true
		await _tree.process_frame
	return _fail_bool("party never formed after invite")


func _party_as_member() -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _party.invite_from() > 0:
			break
		await _tree.process_frame
	if _party.invite_from() <= 0:
		return _fail_bool("member never received a party invite")
	print("DEMO invitefrom %d" % _party.invite_from())
	_session.request_party_accept()
	print("DEMO acceptparty")
	deadline = Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _party.party_id() > 0 and _party.members().size() >= REQUIRED_PLAYERS:
			return true
		await _tree.process_frame
	return _fail_bool("member never joined the party")


func _mid_chase_capture() -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	var attacked := false
	while Time.get_ticks_msec() < deadline:
		if await _maybe_respawn():
			pass
		if not attacked:
			var imp_id := _nearest_living_imp()
			if imp_id > 0 and _session.select_player(imp_id):
				if not await _right_click_npc(imp_id):
					_session.request_attack(imp_id)
				print("DEMO attack %d" % imp_id)
				attacked = true
		if _any_imp_chasing():
			print("DEMO midchase")
			return await _capture(2)
		await _tree.process_frame
	return _fail_bool("no mid-chase NPC walking or has_path before timeout")


func _any_imp_chasing() -> bool:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind != NpcDummyScript.KindImp:
			continue
		if body.is_walking() or body.has_path():
			return true
	return false


func _kill_until_ready() -> bool:
	var deadline := Time.get_ticks_msec() + KILL_TIMEOUT_MSEC
	var kills_seen := 0
	while Time.get_ticks_msec() < deadline:
		if await _maybe_respawn():
			pass
		if _quest_objective_ready():
			return true
		var imp_id := _nearest_living_imp()
		if imp_id <= 0:
			await _tree.process_frame
			continue
		if not _session.select_player(imp_id):
			await _tree.process_frame
			continue
		if not await _right_click_npc(imp_id):
			_session.request_attack(imp_id)
		print("DEMO attack %d" % imp_id)
		var died := await _wait_imp_gone(imp_id, 20000)
		if died:
			kills_seen += 1
			print("DEMO kill %d total=%d" % [imp_id, kills_seen])
		await _tree.process_frame
	return _fail_bool("quest never reached %d/%d before timeout" % [NEED_KILLS, NEED_KILLS])


func _maybe_respawn() -> bool:
	var hp := _session.hit_points_for(_session.own_id())
	if hp.x != 0:
		return false
	print("DEMO death")
	_session.request_respawn()
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		hp = _session.hit_points_for(_session.own_id())
		if hp.x > 0:
			print("DEMO respawn %d" % hp.x)
			return true
		await _tree.process_frame
	_fail("respawn never restored hp")
	return false


func _wait_imp_gone(imp_id: int, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if await _maybe_respawn():
			return false
		var npcs: Dictionary = _session.get("_npcs")
		if not npcs.has(imp_id):
			return true
		var hp := _session.hit_points_for(imp_id)
		if hp.x == 0:
			# Despawn follows death; keep waiting briefly.
			pass
		await _tree.process_frame
	return false


func _right_click_npc(npc_id: int) -> bool:
	var npcs: Dictionary = _session.get("_npcs")
	var body: NpcDummyScript = npcs.get(npc_id)
	if body == null:
		return false
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		return false
	var world_pos := body.global_position + Vector3(0, CLICK_HEIGHT, 0)
	var screen := camera.unproject_position(world_pos)
	var picker := _root.get_node_or_null("GroundPicker") as GroundPickerScript
	if picker == null:
		return false
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	press.position = screen
	press.global_position = screen
	_root.get_viewport().push_input(press)
	await _tree.process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_RIGHT
	release.pressed = false
	release.position = screen
	release.global_position = screen
	_root.get_viewport().push_input(release)
	await _tree.process_frame
	await _tree.physics_frame
	return true


func _find_imp_quest_giver() -> int:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind == NpcDummyScript.KindImpQuestGiver:
			return id
	return 0


func _count_imps() -> int:
	var n := 0
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind == NpcDummyScript.KindImp:
			n += 1
	return n


func _nearest_living_imp() -> int:
	var avatar: PlayerAvatarScript = _session.avatar_for(_session.own_id())
	if avatar == null:
		return 0
	var best_id := 0
	var best_dist := INF
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind != NpcDummyScript.KindImp:
			continue
		var hp := _session.hit_points_for(id)
		if hp.x == 0:
			continue
		var d := Vector2(avatar.position.x, avatar.position.z).distance_to(
			Vector2(body.position.x, body.position.z)
		)
		if d < best_dist:
			best_dist = d
			best_id = id
	return best_id


func _other_player_id() -> int:
	for id: int in _session.known_ids():
		if id != _session.own_id():
			return id
	return 0


func _find_bag_kind(kind: String) -> int:
	for slot in _inventory.slot_count():
		if _inventory.kind_in_slot(slot) == kind:
			return slot
	return -1


func _wait_dialog_option(npc_id: int, option_id: String) -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _dialog.visible and _dialog.npc_id() == npc_id and _dialog.has_option(option_id):
			return true
		await _tree.process_frame
	return false


func _wait_quest_status(status: String) -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _quest_status_for(QUEST_ID) == status:
			return true
		await _tree.process_frame
	return false


func _quest_status_for(quest_id: String) -> String:
	var ids: PackedStringArray = _session.get("_quest_ids")
	var statuses: PackedStringArray = _session.get("_quest_statuses")
	for i in ids.size():
		if ids[i] == quest_id and i < statuses.size():
			return statuses[i]
	return ""


func _quest_objective_for(quest_id: String) -> String:
	var ids: PackedStringArray = _session.get("_quest_ids")
	var objectives: PackedStringArray = _session.get("_quest_objectives")
	for i in ids.size():
		if ids[i] == quest_id and i < objectives.size():
			return objectives[i]
	return ""


func _quest_objective_ready() -> bool:
	var objective := _quest_objective_for(QUEST_ID)
	if objective.contains("(%d/%d)" % [NEED_KILLS, NEED_KILLS]):
		return true
	# Fall back: status stays active until turn-in, so also accept explicit 5/5 text.
	return objective.ends_with("(5/5)")


func _wait_rewards() -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var ok := true
		for kind: String in REWARD_KINDS:
			if _find_bag_kind(kind) < 0:
				ok = false
				break
		if ok:
			return true
		await _tree.process_frame
	return false


func _print_inventory(shot: int) -> void:
	print(
		"DEMO inv %d %d %d"
		% [shot, _inventory.occupied_slot_count(), _inventory.slot_count()]
	)
	for slot in _inventory.slot_count():
		var kind := _inventory.kind_in_slot(slot)
		if not kind.is_empty():
			print("DEMO invslot %d %d %s" % [shot, slot, kind])


func _print_quest_log(shot: int) -> void:
	var ids: PackedStringArray = _session.get("_quest_ids")
	var titles: PackedStringArray = _session.get("_quest_titles")
	var objectives: PackedStringArray = _session.get("_quest_objectives")
	var statuses: PackedStringArray = _session.get("_quest_statuses")
	if ids.is_empty():
		print("DEMO questlog %d empty" % shot)
		return
	for i in ids.size():
		var title := QUEST_TITLE
		if i < titles.size() and not titles[i].is_empty():
			title = titles[i]
		var objective := ""
		if i < objectives.size():
			objective = objectives[i]
		var status := ""
		if i < statuses.size():
			status = statuses[i]
		print("DEMO questlog %d %s %s %s | %s" % [shot, ids[i], title, status, objective])


func _print_party(shot: int) -> void:
	print(
		"DEMO partyinfo %d %d %d %d"
		% [shot, _party.party_id(), _party.leader_id(), _party.members().size()]
	)
	for member_id in _party.members():
		print("DEMO partymember %d %d" % [shot, member_id])


func _capture(index: int) -> bool:
	for _frame in SCREENSHOT_WARMUP_FRAMES:
		await RenderingServer.frame_post_draw
	var path := "%s_%d.png" % [_prefix, index]
	var image := _root.get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("screenshot failed to save to %s: %d" % [path, error])
		return false
	print("DEMO shot %d %s" % [index, path])
	DemoNpcCapture.dump(_session)
	return true


func _wait_msec(msec: int) -> void:
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		await _tree.process_frame


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	return 1


func _fail_bool(reason: String) -> bool:
	print("DEMO FAIL %s" % reason)
	return false
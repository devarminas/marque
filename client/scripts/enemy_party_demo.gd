extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const DialogPanelScript := preload("res://scripts/dialog_panel.gd")
const PartyPanelScript := preload("res://scripts/party_panel.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const DemoAdminGive := preload("res://scripts/demo_admin_give.gd")

const QUEST_ID := "slay_imps"
const ROLE_LEADER := "leader"
const ROLE_MEMBER := "member"
const REQUIRED_PLAYERS := 2
const REQUIRED_IMPS := 5

const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 25000
const STEP_TIMEOUT_MSEC := 45000
const HOLD_MSEC := 800
const OUTGOING_READY_MSEC := 1200
const CLASS_ID := "knight"

const KNIGHT_KIT := [
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
var _outgoing_only := false
var _remote_targets := {}
var _remote_swings: Array[Dictionary] = []
var _local_swings: Array[Dictionary] = []


func run(
	root: Node,
	session: SessionScript,
	inventory: InventoryPanelScript,
	dialog: DialogPanelScript,
	party: Node,
	prefix: String,
	role: String,
	outgoing_only: bool = false,
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
	_outgoing_only = outgoing_only
	var net: Node = _session.get("_net")
	net.swing_observed.connect(_on_swing_observed)
	net.swing_hit_observed.connect(_on_swing_hit_observed)

	if _role != ROLE_LEADER and _role != ROLE_MEMBER:
		return _fail("role must be leader or member, got %s" % _role)

	if not await _wait_for_join():
		return _fail(
			"need %d players, %d imps, and imp_quest_giver after %dms"
			% [REQUIRED_PLAYERS, REQUIRED_IMPS, JOIN_TIMEOUT_MSEC]
		)
	print("DEMO joined %d" % _session.own_id())
	print("DEMO role %s" % _role)

	var giver := DemoAdminGive.new()
	var give_err: String = await giver.grant(
		_session, _tree, KNIGHT_KIT, JOIN_TIMEOUT_MSEC
	)
	if not give_err.is_empty():
		return _fail(give_err)
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

	if _outgoing_only:
		return await _prove_outgoing_only()

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
		):
			return true
		await _tree.process_frame
	return false


func _equip_knight_kit() -> bool:
	var indices: PackedInt32Array = _session.get("_bag_indices")
	if indices.is_empty():
		_fail("knight kit never arrived in the bag after /give")
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


func _on_swing_observed(id: int, target: int, _weapon: String) -> void:
	if id != _session.own_id():
		_remote_targets[id] = target


func _on_swing_hit_observed(id: int, amount: int, crit: bool, miss: bool) -> void:
	if id == _session.own_id():
		_local_swings.append({"actor": id, "amount": amount, "crit": crit, "miss": miss})
		return
	if not _remote_targets.has(id):
		return
	var target := int(_remote_targets[id])
	var npcs: Dictionary = _session.get("_npcs")
	if not npcs.has(target):
		return
	_remote_swings.append({
		"actor": id, "target": target, "amount": amount, "crit": crit, "miss": miss,
	})
	print(
		"DEMO remote_swing actor=%d target=%d amount=%d crit=%s miss=%s"
		% [id, target, amount, str(crit).to_lower(), str(miss).to_lower()]
	)


func _prove_outgoing_only() -> int:
	await _wait_msec(OUTGOING_READY_MSEC)
	if _role == ROLE_LEADER:
		var target := _first_hostile_imp()
		if target <= 0:
			return _fail("no hostile imp available for outgoing-only proof")
		_session.request_attack(target)
		print("DEMO outgoing_attack actor=%d target=%d" % [_session.own_id(), target])
		if not await _wait_local_swing():
			return _fail("no local server swing in outgoing-only proof")
	else:
		if not await _wait_remote_swing():
			return _fail("no remote server swing in outgoing-only proof")
	print("DEMO outgoing_only role=%s" % _role)
	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _first_hostile_imp() -> int:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body != null and body.kind == NpcDummyScript.KindImp and body.faction == NpcDummyScript.FactionHostile:
			return id
	return 0


func _wait_local_swing() -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if not _local_swings.is_empty():
			return true
		await _tree.process_frame
	return false


func _wait_remote_swing() -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if not _remote_swings.is_empty():
			return true
		await _tree.process_frame
	return false


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


func _other_player_id() -> int:
	for id: int in _session.known_ids():
		if id != _session.own_id():
			return id
	return 0


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


func _print_quest_log(shot: int) -> void:
	var ids: PackedStringArray = _session.get("_quest_ids")
	var titles: PackedStringArray = _session.get("_quest_titles")
	var objectives: PackedStringArray = _session.get("_quest_objectives")
	var statuses: PackedStringArray = _session.get("_quest_statuses")
	if ids.is_empty():
		print("DEMO questlog %d empty" % shot)
		return
	for i in ids.size():
		var title := ""
		if i < titles.size():
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

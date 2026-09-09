extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const DialogPanelScript := preload("res://scripts/dialog_panel.gd")
const GivePanelScript := preload("res://scripts/give_panel.gd")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")

const STICK_KIND := "stick"
const QUEST_ID := "bring_a_stick"
const QUEST_TITLE := "Bring a Stick"
const REWARD_KINDS := [
	"prospector_jacket",
	"prospector_boots",
	"prospector_helm",
	"prospector_legs",
	"pickaxe",
]

const SCREENSHOT_WARMUP_FRAMES := 15
const JOIN_TIMEOUT_MSEC := 20000
const STEP_TIMEOUT_MSEC := 30000
const HOLD_MSEC := 800


var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _inventory: InventoryPanelScript
var _dialog: DialogPanelScript
var _give: GivePanelScript
var _prefix: String


func run(
	root: Node,
	session: SessionScript,
	inventory: InventoryPanelScript,
	dialog: DialogPanelScript,
	give: GivePanelScript,
	prefix: String,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_inventory = inventory
	_dialog = dialog
	_give = give
	_prefix = prefix

	if not await _wait_for_join():
		return _fail("no join-kit %s in inventory after %dms" % [STICK_KIND, JOIN_TIMEOUT_MSEC])
	print("DEMO joined %d" % _session.own_id())

	var stick_slot := _find_bag_kind(STICK_KIND)
	if stick_slot < 0:
		return _fail("the join kit never placed a %s in the bag" % STICK_KIND)
	print("DEMO stickslot %d" % stick_slot)

	var npc_id := _find_quest_giver()
	if npc_id <= 0:
		return _fail("welcome lacked a quest_giver npc")
	print("DEMO npc %d quest_giver" % npc_id)

	if not await _capture(1):
		return 1
	_print_inventory(1)
	_print_quest_log(1)

	_session.request_talk(npc_id)
	print("DEMO talk %d" % npc_id)
	if not await _wait_dialog_open(npc_id, true):
		return _fail("dialog never opened for accept on npc %d" % npc_id)
	print("DEMO dialogopen %d accept" % npc_id)

	_session.request_dialog_option(npc_id, DialogPanelScript.OPTION_ACCEPT)
	print("DEMO accept %d" % npc_id)

	if not await _wait_quest_status("active"):
		return _fail("quest_log never showed %s as active" % QUEST_ID)
	print("DEMO accepted %s active" % QUEST_ID)

	if not await _capture(2):
		return 1
	_print_inventory(2)
	_print_quest_log(2)

	_session.request_talk(npc_id)
	print("DEMO talkagain %d" % npc_id)
	if not await _wait_dialog_open(npc_id, false):
		return _fail("re-talk dialog never opened on npc %d" % npc_id)
	if not await _wait_give_open(npc_id):
		return _fail("give panel never opened for active quest on npc %d" % npc_id)
	print("DEMO giveopen %d" % npc_id)

	stick_slot = _find_bag_kind(STICK_KIND)
	if stick_slot < 0:
		return _fail("bag lost the %s before give" % STICK_KIND)
	if _give.kind_in_slot(stick_slot) != STICK_KIND:
		return _fail("give panel slot %d is not the %s" % [stick_slot, STICK_KIND])
	_session.request_give(npc_id, stick_slot)
	print("DEMO give %d %d" % [npc_id, stick_slot])

	if not await _wait_quest_status("complete"):
		return _fail("quest_log never showed %s as complete" % QUEST_ID)
	if not await _wait_rewards():
		return _fail("bag never held the miner reward kinds after give")
	if _find_bag_kind(STICK_KIND) >= 0:
		return _fail("%s remained in the bag after give" % STICK_KIND)
	print("DEMO complete %s" % QUEST_ID)

	if not await _capture(3):
		return 1
	_print_inventory(3)
	_print_quest_log(3)

	await _wait_msec(HOLD_MSEC)
	print("DEMO done")
	return 0


func _wait_for_join() -> bool:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _session.own_id() > 0 and _find_bag_kind(STICK_KIND) >= 0 and _find_quest_giver() > 0:
			return true
		await _tree.process_frame
	return false


func _find_quest_giver() -> int:
	var npcs: Dictionary = _session.get("_npcs")
	for id: int in npcs.keys():
		var body: NpcDummyScript = npcs[id]
		if body.kind == NpcDummyScript.KindQuestGiver:
			return id
	return 0


func _find_bag_kind(kind: String) -> int:
	for slot in _inventory.slot_count():
		if _inventory.kind_in_slot(slot) == kind:
			return slot
	return -1


func _wait_dialog_open(npc_id: int, want_accept: bool) -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if (
			_dialog.visible
			and _dialog.npc_id() == npc_id
			and _dialog.accept_button.visible == want_accept
		):
			return true
		await _tree.process_frame
	return false


func _wait_give_open(npc_id: int) -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _give.visible and _give.npc_id() == npc_id:
			return true
		await _tree.process_frame
	return false


func _wait_quest_status(status: String) -> bool:
	var deadline := Time.get_ticks_msec() + STEP_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _quest_has_status(status):
			return true
		await _tree.process_frame
	return false


func _quest_has_status(status: String) -> bool:
	var statuses: PackedStringArray = _session.get("_quest_statuses")
	for value: String in statuses:
		if value == status:
			return true
	return false


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
	var statuses: PackedStringArray = _session.get("_quest_statuses")
	if statuses.is_empty():
		print("DEMO questlog %d empty" % shot)
		return
	for status: String in statuses:
		print("DEMO questlog %d %s %s %s" % [shot, QUEST_ID, QUEST_TITLE, status])


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

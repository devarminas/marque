extends RefCounted


const SessionScript := preload("res://scripts/session.gd")
const TickClock := preload("res://scripts/tick_clock.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")

const SCREENSHOT_WARMUP_FRAMES := 15

const REQUIRED_PLAYERS := 2
const REQUIRED_ITEMS := 1

const JOIN_TIMEOUT_MSEC := 20000

const USEC_PER_MSEC := 1000

# Tick budgets were authored against ~150ms ticks. At 40ms / 3.0 u/s (0.12 u/tick),
# wall-scale them so wish walk-away covers the ~5.57u drop click (old 38-tick
# window only reached 4.56u and never printed DEMO walkaway_arrived). Approach
# origin→(-5,-5) is ~59 ticks; fail-closed path/move_to stays in the harness.
const CLICK_LEAD_TICKS := 75
# Capture 1 is uncoupled from the click. After both finish capture they run a
# two-phase barrier on a shared Unix wall deadline. Freezing start_usec_of(aim)
# still leaves per-process TickClock anchors free to diverge under GLES and was
# landing pickup intents 5–15 server ticks apart; wall clock is cross-process.
const SHOT_BEFORE_LEAD_TICKS := 40
const CLICK_AFTER_READY_TICKS := 25
const POST_CAPTURE_LEAD_TICKS := 100 # retained for unit tests / DEMO aim logging
const POST_CAPTURE_LEAD_MSEC := 4000
const BARRIER_MIN_LEAD_TICKS := 40 # retained for unit tests
const BARRIER_MAX_ROUNDS := 12
const BARRIER_MIN_SLACK_MSEC := 200
const SHOT_RESOLVED_OFFSET_TICKS := 98
const WALK_AWAY_OFFSET_TICKS := 113
const WALK_AWAY_DEADLINE_TICKS := 255
# Remaining walk budget after the walk-away offset (255 - 113). Arrival waits on
# wall-clock from the moment the wish starts so a late/corrected estimated_tick
# cannot make the deadline already past before the first step.
const WALK_AWAY_BUDGET_TICKS := WALK_AWAY_DEADLINE_TICKS - WALK_AWAY_OFFSET_TICKS
const SHOT_DROPPED_OFFSET_TICKS := 285
const HOLD_UNTIL_OFFSET_TICKS := 330

const TICK_WAIT_BACKSTOP_MSEC := 60000
const ARRIVAL_RADIUS := 0.75
# After stop, soft-pull display can still lag sim/server by up to ~HARD_ERROR_M;
# settle so DEMO walkaway_arrived is closer to the authoritative drop pose.
const WALK_ARRIVAL_SETTLE_MSEC := 600
const WISH_RESEND_MSEC := 100

const BAG_LAYOUT_DEADLINE_MSEC := 2000

const SPIN_USEC := 20000

# Written under the --pickup-shots directory so both clients share one Unix fire
# deadline. Per-process usec quanta are not comparable across Godots.
# Propose and commit use separate files: overwriting propose with commit made a
# slow settler lose its peer and deadlock across generations under llvmpipe.
const SYNC_BARRIER_PREFIX := "marque-pickup-sync-"
const COMMIT_BARRIER_PREFIX := "marque-pickup-commit-"
const GO_BARRIER_PREFIX := "marque-pickup-go-"

var _tree: SceneTree
var _root: Node
var _session: SessionScript
var _panel: InventoryPanelScript
var _dock: EquipmentPanelScript
var _prefix: String
var _drop_click: Vector2


func run(
	root: Node,
	session: SessionScript,
	panel: InventoryPanelScript,
	dock: EquipmentPanelScript,
	prefix: String,
	drop_click: Vector2,
) -> int:
	_root = root
	_tree = root.get_tree()
	_session = session
	_panel = panel
	_dock = dock
	_prefix = prefix
	_drop_click = drop_click

	var scenario_usec := await _wait_for_scenario()
	if scenario_usec < 0:
		return _fail(
			"fewer than %d player(s) or %d item(s) after %dms"
			% [REQUIRED_PLAYERS, REQUIRED_ITEMS, JOIN_TIMEOUT_MSEC]
		)
	print("DEMO joined %d" % _session.own_id())

	var item_id: int = _session.known_item_ids()[0]
	var item := _session.item_for(item_id)
	print("DEMO seeditem %d %s %f %f" % [item_id, item.kind, item.position.x, item.position.z])

	var clock := _session.tick_clock()
	if not clock.is_anchored():
		return _fail("the tick clock is not anchored; there is no shared moment to click on")
	var sync_tick := clock.estimated_tick_at(scenario_usec)

	# Capture before the click barrier so a slow 15-frame warm-up cannot eat the
	# shared lead. Shot 1 only needs both bodies + the seed visible.
	if not await _await_tick(sync_tick + 10):
		return _fail("the clock stalled before the first capture")
	if not await _capture(1):
		return _fail("capture 1 failed")

	# Capture under dual llvmpipe can starve the socket long enough to abandon
	# and resume; the pre-capture GroundItem node is then freed. Re-resolve by id.
	item = _session.item_for(item_id)
	if item == null or not is_instance_valid(item):
		return _fail("seed item %d missing after capture 1" % item_id)
	var picked: Variant = _screen_position_of(item)
	if picked == null:
		return 1
	var screen: Vector2 = picked

	var planned: Variant = await _plan_shared_click()
	if planned == null:
		return 1
	var fire_unix_msec: int = planned["fire_unix_msec"]
	var fire_generation: int = planned["generation"]
	# DEMO sync second field is the shared wall deadline (msec); harness requires match.
	print("DEMO sync %d %d" % [sync_tick, fire_unix_msec])

	if not await _await_unix_msec(fire_unix_msec):
		return _fail("frames stopped before the shared wall-clock click")
	# Final go-file gate: the early arriver waits briefly for the peer so both
	# fire after the slower wake, not one frame-overshoot apart.
	await _final_go_rendezvous(fire_generation, fire_unix_msec)
	# Wire the pickup now. push_input/_click_at only reaches the session on a
	# later frame under software GL and was splitting server intent ticks even
	# when both processes woke on the same wall deadline. Screen projection
	# above already proved the item is clickable.
	_session.request_pickup(item_id)
	var click_tick := clock.estimated_tick()
	print("DEMO pickupclick %d %d %f %f" % [click_tick, item_id, screen.x, screen.y])

	if not await _await_tick(click_tick + SHOT_RESOLVED_OFFSET_TICKS):
		return _fail("the clock stalled before the second capture")
	if not await _capture(2):
		return _fail("capture 2 failed")

	var won := _panel.occupied_slot_count() > 0
	print("DEMO outcome %d" % (1 if won else 0))
	if won and not await _walk_away_and_drop(click_tick):
		return 1

	if not await _await_tick(click_tick + SHOT_DROPPED_OFFSET_TICKS):
		return _fail("the clock stalled before the third capture")
	if not await _capture(3):
		return _fail("capture 3 failed")

	if not await _await_tick(click_tick + HOLD_UNTIL_OFFSET_TICKS):
		return _fail("the clock stalled during the hold")
	print("DEMO done")
	return 0


static func click_guard_usec(tick_usec: int) -> int:
	return tick_usec / 3


static func click_quantum_usec(tick_usec: int) -> int:
	return tick_usec * 8


static func ready_deadline_usec(scenario_usec: int, clock: TickClock) -> int:
	var tick_usec := clock.tick_ms() * USEC_PER_MSEC
	var quantum := click_quantum_usec(tick_usec)
	var quantized: int = ceili(float(scenario_usec) / float(quantum)) * quantum
	return quantized + CLICK_LEAD_TICKS * tick_usec


static func click_deadline_usec(scenario_usec: int, clock: TickClock) -> int:
	var tick_usec := clock.tick_ms() * USEC_PER_MSEC
	return clock.next_guard_usec(
		ready_deadline_usec(scenario_usec, clock) + CLICK_AFTER_READY_TICKS * tick_usec,
		click_guard_usec(tick_usec),
	)


static func aim_tick_from_max_sync(max_sync_tick: int) -> int:
	return max_sync_tick + POST_CAPTURE_LEAD_TICKS


static func fire_unix_msec_from_max_ready(max_ready_msec: int) -> int:
	return max_ready_msec + POST_CAPTURE_LEAD_MSEC


static func unix_msec_now() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func _plan_shared_click() -> Variant:
	for generation in range(1, BARRIER_MAX_ROUNDS + 1):
		var fire_msec: int = await _propose_fire_unix_msec(generation)
		if fire_msec == -2:
			print("DEMO barrier_retry %d peer_ahead" % generation)
			continue
		if fire_msec < 0:
			return null
		var can_make := fire_msec - unix_msec_now() >= BARRIER_MIN_SLACK_MSEC
		if not await _commit_fire_unix_msec(generation, fire_msec, can_make):
			print("DEMO barrier_retry %d %d" % [generation, fire_msec])
			continue
		if unix_msec_now() + 50 >= fire_msec:
			print("DEMO barrier_retry %d %d missed_after_commit" % [generation, fire_msec])
			continue
		print("DEMO clickplan %d %d" % [generation, fire_msec])
		return {"fire_unix_msec": fire_msec, "generation": generation}
	_fail("could not lock a shared wall-clock click after %d barrier round(s)" % BARRIER_MAX_ROUNDS)
	return null


func _barrier_dir() -> String:
	var dir := _prefix.get_base_dir()
	if dir.is_empty():
		_fail("pickup shots prefix has no directory for the sync barrier")
	return dir


func _write_barrier_file(prefix: String, line: String) -> bool:
	var dir := _barrier_dir()
	if dir.is_empty():
		return false
	var path := dir.path_join("%s%d.txt" % [prefix, _session.own_id()])
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		_fail("could not write sync barrier %s: %s" % [path, FileAccess.get_open_error()])
		return false
	out.store_line(line)
	out.close()
	return true


func _read_barrier_rows(prefix: String, generation: int, want_phase: String) -> Array:
	var rows: Array = []
	var dir := _barrier_dir()
	if dir.is_empty():
		return rows
	var names := DirAccess.get_files_at(dir)
	for name in names:
		if not str(name).begins_with(prefix) or not str(name).ends_with(".txt"):
			continue
		var body := FileAccess.get_file_as_string(dir.path_join(str(name))).strip_edges()
		var parts := body.split(" ")
		if want_phase == "propose":
			# propose <gen> <ready_unix_msec> [fire_unix_msec]
			if parts.size() < 3 or parts[0] != "propose":
				continue
			if not parts[1].is_valid_int() or not parts[2].is_valid_int():
				continue
			if int(parts[1]) != generation:
				continue
			var row := {"ready": int(parts[2]), "fire": -1}
			if parts.size() >= 4 and parts[3].is_valid_int():
				row["fire"] = int(parts[3])
			rows.append(row)
		elif want_phase == "commit":
			# commit <gen> <fire_unix_msec> <ready 0|1>
			if parts.size() != 4 or parts[0] != "commit":
				continue
			if not parts[1].is_valid_int() or not parts[2].is_valid_int() or not parts[3].is_valid_int():
				continue
			if int(parts[1]) != generation:
				continue
			rows.append({"fire": int(parts[2]), "ready": int(parts[3])})
	return rows


func _propose_fire_unix_msec(generation: int) -> int:
	if not _write_barrier_file(SYNC_BARRIER_PREFIX, "propose %d %d" % [generation, unix_msec_now()]):
		return -1

	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if _peer_generation_ahead(generation):
			print("DEMO propose_abort %d" % generation)
			return -2
		if not _write_barrier_file(SYNC_BARRIER_PREFIX, "propose %d %d" % [generation, unix_msec_now()]):
			return -1
		var rows := _read_barrier_rows(SYNC_BARRIER_PREFIX, generation, "propose")
		if rows.size() < REQUIRED_PLAYERS:
			await _tree.process_frame
			continue

		# Publish a fire candidate from the shared max ready, then converge so
		# both clients lock the *same* fire (split candidates made every commit
		# return ready=0 under llvmpipe).
		var max_ready := unix_msec_now()
		for row in rows:
			max_ready = maxi(max_ready, int(row["ready"]))
		var fire := fire_unix_msec_from_max_ready(max_ready)
		if not _write_barrier_file(
			SYNC_BARRIER_PREFIX, "propose %d %d %d" % [generation, unix_msec_now(), fire]
		):
			return -1
		for _i in 4:
			await _tree.process_frame
			if not _write_barrier_file(
				SYNC_BARRIER_PREFIX, "propose %d %d %d" % [generation, unix_msec_now(), fire]
			):
				return -1

		rows = _read_barrier_rows(SYNC_BARRIER_PREFIX, generation, "propose")
		if rows.size() < REQUIRED_PLAYERS:
			continue
		var agreed := fire
		var all_have_fire := true
		for row in rows:
			if int(row["fire"]) < 0:
				all_have_fire = false
				break
			agreed = maxi(agreed, int(row["fire"]))
		if not all_have_fire:
			continue
		# Republish the max so a peer that proposed an earlier fire adopts it.
		if not _write_barrier_file(
			SYNC_BARRIER_PREFIX, "propose %d %d %d" % [generation, unix_msec_now(), agreed]
		):
			return -1
		for _i in 3:
			await _tree.process_frame

		rows = _read_barrier_rows(SYNC_BARRIER_PREFIX, generation, "propose")
		if rows.size() < REQUIRED_PLAYERS:
			continue
		var matched := true
		for row in rows:
			if int(row["fire"]) != agreed:
				matched = false
				break
		if matched and agreed - unix_msec_now() >= BARRIER_MIN_SLACK_MSEC:
			print("DEMO barrier %d %d %d %d" % [generation, rows.size(), max_ready, agreed])
			return agreed
		await _tree.process_frame
	_fail(
		"sync barrier gen %d never locked a fresh wall fire within %dms"
		% [generation, JOIN_TIMEOUT_MSEC]
	)
	return -1


func _commit_fire_unix_msec(generation: int, fire_msec: int, can_make: bool) -> bool:
	var ready_flag := 1 if can_make else 0
	if not _write_barrier_file(
		COMMIT_BARRIER_PREFIX, "commit %d %d %d" % [generation, fire_msec, ready_flag]
	):
		return false

	var slack_msec := maxi(fire_msec - unix_msec_now(), 0)
	var wait_msec := mini(JOIN_TIMEOUT_MSEC, maxi(slack_msec - BARRIER_MIN_SLACK_MSEC, 200))
	var deadline := Time.get_ticks_msec() + wait_msec
	while Time.get_ticks_msec() < deadline:
		if _peer_generation_ahead(generation):
			print("DEMO commit_abort %d" % generation)
			return false
		var still_ready := fire_msec - unix_msec_now() >= BARRIER_MIN_SLACK_MSEC
		var flag := 1 if still_ready else 0
		if flag != ready_flag:
			ready_flag = flag
		if not _write_barrier_file(
			COMMIT_BARRIER_PREFIX, "commit %d %d %d" % [generation, fire_msec, ready_flag]
		):
			return false
		var rows := _read_barrier_rows(COMMIT_BARRIER_PREFIX, generation, "commit")
		if rows.size() >= REQUIRED_PLAYERS:
			var all_ready := true
			for row in rows:
				if int(row["fire"]) != fire_msec or int(row["ready"]) != 1:
					all_ready = false
					break
			print(
				"DEMO commit %d %d %d %d"
				% [generation, rows.size(), fire_msec, 1 if all_ready else 0]
			)
			return all_ready
		await _tree.process_frame
	print("DEMO commit_timeout %d %d" % [generation, wait_msec])
	return false


func _peer_generation_ahead(generation: int) -> bool:
	var dir := _barrier_dir()
	if dir.is_empty():
		return false
	for name in DirAccess.get_files_at(dir):
		var body := FileAccess.get_file_as_string(dir.path_join(str(name))).strip_edges()
		var parts := body.split(" ")
		if parts.size() < 2 or not parts[1].is_valid_int():
			continue
		if parts[0] in ["propose", "commit"] and int(parts[1]) > generation:
			return true
	return false


func _await_unix_msec(deadline_msec: int) -> bool:
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while unix_msec_now() < deadline_msec:
		if Time.get_ticks_msec() > backstop:
			return false
		# llvmpipe frames often take 50–150ms. Only await a frame when the
		# remaining lead is larger than a worst-case frame; otherwise a single
		# await overshoots the shared deadline and splits server ticks.
		if deadline_msec - unix_msec_now() > 250:
			await _tree.process_frame
	return true


# After the wall deadline, both write a go file and the early arriver waits for
# the peer (bounded) so clicks leave the process together.
func _final_go_rendezvous(generation: int, fire_msec: int) -> void:
	if not _write_barrier_file(GO_BARRIER_PREFIX, "go %d %d" % [generation, unix_msec_now()]):
		return
	var wait_until := maxi(fire_msec + 150, unix_msec_now() + 150)
	var backstop := Time.get_ticks_msec() + 500
	while unix_msec_now() < wait_until and Time.get_ticks_msec() < backstop:
		var rows := _read_go_rows(generation)
		if rows.size() >= REQUIRED_PLAYERS:
			print("DEMO go %d %d" % [generation, rows.size()])
			return
		# Busy-spin — do not await frames here.
	print("DEMO go_timeout %d" % generation)


func _read_go_rows(generation: int) -> Array:
	var rows: Array = []
	var dir := _barrier_dir()
	if dir.is_empty():
		return rows
	for name in DirAccess.get_files_at(dir):
		if not str(name).begins_with(GO_BARRIER_PREFIX) or not str(name).ends_with(".txt"):
			continue
		var body := FileAccess.get_file_as_string(dir.path_join(str(name))).strip_edges()
		var parts := body.split(" ")
		if parts.size() != 3 or parts[0] != "go":
			continue
		if not parts[1].is_valid_int() or not parts[2].is_valid_int():
			continue
		if int(parts[1]) != generation:
			continue
		rows.append({"at": int(parts[2])})
	return rows


func _walk_away_and_drop(click_tick: int) -> bool:
	if not await _await_tick(click_tick + WALK_AWAY_OFFSET_TICKS):
		_fail("the clock stalled before the walk away")
		return false

	var picker := _root.get_node_or_null("GroundPicker") as GroundPickerScript
	if picker == null:
		_fail("main.tscn has no GroundPicker to resolve the drop-walk destination with")
		return false

	var pixel := _root.get_viewport().get_visible_rect().size * _drop_click
	var found: Variant = picker.pick_ground(pixel)
	if found == null:
		_fail(
			"the drop-walk fraction puts the destination at (%f, %f), where no ray meets the "
			% [pixel.x, pixel.y]
			+ "ground; the winner would drop the item where it already stands"
		)
		return false

	var destination: Vector2 = found
	print("DEMO walkaway %d %f %f %f %f" % [
		_session.tick_clock().estimated_tick(), pixel.x, pixel.y, destination.x, destination.y
	])
	var avatar := _session.avatar_for(_session.own_id())
	if avatar == null:
		_fail("no local avatar to walk away with")
		return false
	var here := Vector2(avatar.position.x, avatar.position.z)
	var wish := (destination - here).normalized()
	print("DEMO wish %f %f" % [wish.x, wish.y])
	_session.request_move(wish.x, wish.y)

	var walk_budget_msec := WALK_AWAY_BUDGET_TICKS * _session.tick_clock().tick_ms()
	if not await _await_arrival(walk_budget_msec, destination):
		_fail(
			"this client's own body was still walking after %dms of wish steer; dropping now "
			% walk_budget_msec
			+ "would land the item under a walker rather than at a destination it reached"
		)
		return false
	# Stop and settle so display soft-pull catches sim/server before we claim arrived.
	# Keep emitting zero through settle and bag layout so sticky wish cannot restart.
	if not await _hold_zero_wish(WALK_ARRIVAL_SETTLE_MSEC):
		return false
	avatar = _session.avatar_for(_session.own_id())
	if avatar == null:
		_fail("local avatar vanished after walk-away settle")
		return false
	var arrived_here := Vector2(avatar.position.x, avatar.position.z)
	print("DEMO walkaway_arrived %f %f" % [arrived_here.x, arrived_here.y])

	var slot := _first_occupied_slot()
	if slot < 0:
		_fail("this client won the item but has no occupied slot to drop from")
		return false
	var widget := _panel.slot_at(slot)
	if widget == null:
		_fail("the panel draws no widget for slot %d" % slot)
		return false

	var opened: Variant = await _open_the_bag_onto(slot, widget)
	if opened == null:
		return false
	var centre: Vector2 = opened
	_session.request_move(0.0, 0.0)
	print("DEMO dropclick %d %d %f %f" % [
		_session.tick_clock().estimated_tick(), slot, centre.x, centre.y
	])
	_click_at(centre, true)
	_session.request_move(0.0, 0.0)
	return true


func _open_the_bag_onto(slot: int, widget: Control) -> Variant:
	var key := InputEventKey.new()
	key.physical_keycode = KEY_I
	key.pressed = true
	_root.get_viewport().push_input(key)
	if not _dock.visible:
		_fail(
			"the toggle_inventory key left the bag closed; a slot that is not visible in the "
			+ "tree takes no click, so the drop would go nowhere"
		)
		return null

	var deadline := Time.get_ticks_msec() + BAG_LAYOUT_DEADLINE_MSEC
	var settled := widget.get_global_rect()
	await _tree.process_frame
	while widget.get_global_rect() != settled:
		if Time.get_ticks_msec() > deadline:
			_fail(
				"slot %d was still moving after %dms, %s then %s; the bag never finished "
				% [slot, BAG_LAYOUT_DEADLINE_MSEC, settled, widget.get_global_rect()]
				+ "laying out and any rect read now is stale"
			)
			return null
		_session.request_move(0.0, 0.0)
		settled = widget.get_global_rect()
		await _tree.process_frame

	var centre := settled.get_center()
	var screen := _root.get_viewport().get_visible_rect()
	if not screen.has_point(centre):
		_fail(
			"the open bag settled slot %d at %s, outside the viewport %s; the drop click would "
			% [slot, settled, screen]
			+ "land on the world behind it"
		)
		return null

	print("DEMO bagopen %d" % _session.tick_clock().estimated_tick())
	return centre


func _wait_for_scenario() -> int:
	var deadline := Time.get_ticks_msec() + JOIN_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if (_session.known_ids().size() >= REQUIRED_PLAYERS
				and _session.known_item_ids().size() >= REQUIRED_ITEMS):
			return Time.get_ticks_usec()
		await _tree.process_frame
	return -1


func _await_usec(deadline_usec: int) -> bool:
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while Time.get_ticks_usec() < deadline_usec:
		if Time.get_ticks_msec() > backstop:
			return false
		if deadline_usec - Time.get_ticks_usec() > SPIN_USEC:
			await _tree.process_frame
	return true


func _await_tick(target: int) -> bool:
	var clock := _session.tick_clock()
	var backstop := Time.get_ticks_msec() + TICK_WAIT_BACKSTOP_MSEC
	while clock.estimated_tick() < target:
		if Time.get_ticks_msec() > backstop:
			return false
		await _tree.process_frame
	return true


func _await_arrival(budget_msec: int, destination: Vector2) -> bool:
	var avatar := _session.avatar_for(_session.own_id())
	if avatar == null:
		return false
	var deadline_msec := Time.get_ticks_msec() + maxi(budget_msec, 0)
	var next_wish_msec := 0
	while Time.get_ticks_msec() < deadline_msec:
		avatar = _session.avatar_for(_session.own_id())
		if avatar == null:
			return false
		var here := Vector2(avatar.position.x, avatar.position.z)
		if here.distance_to(destination) <= ARRIVAL_RADIUS:
			_session.request_move(0.0, 0.0)
			return true
		var now := Time.get_ticks_msec()
		if now >= next_wish_msec:
			var wish := (destination - here).normalized()
			_session.request_move(wish.x, wish.y)
			next_wish_msec = now + WISH_RESEND_MSEC
		await _tree.process_frame
	return false


func _hold_zero_wish(msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + maxi(msec, 0)
	while Time.get_ticks_msec() < deadline:
		_session.request_move(0.0, 0.0)
		await _tree.create_timer(WISH_RESEND_MSEC / 1000.0).timeout
	_session.request_move(0.0, 0.0)
	return true


func _wait_msec(msec: int) -> void:
	if msec <= 0:
		return
	await _tree.create_timer(msec / 1000.0).timeout


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

	var ids := _session.known_ids()
	print("DEMO players %d %d" % [index, ids.size()])
	for id: int in ids:
		var avatar: PlayerAvatarScript = _session.avatar_for(id)
		if avatar == null:
			continue
		print("DEMO pos %d %d %f %f" % [index, id, avatar.position.x, avatar.position.z])

	var item_ids := _session.known_item_ids()
	print("DEMO items %d %d" % [index, item_ids.size()])
	for id: int in item_ids:
		var body: GroundItemScript = _session.item_for(id)
		if body == null:
			continue
		print("DEMO item %d %d %s %f %f" % [index, id, body.kind, body.position.x, body.position.z])

	print("DEMO inv %d %d %d" % [index, _panel.occupied_slot_count(), _panel.slot_count()])
	for slot in _panel.slot_count():
		var kind := _panel.kind_in_slot(slot)
		if not kind.is_empty():
			print("DEMO invslot %d %d %s" % [index, slot, kind])
	return true


func _screen_position_of(body: Node3D) -> Variant:
	var camera := _root.get_viewport().get_camera_3d()
	if camera == null:
		_fail("the scene has no active camera to project from")
		return null
	if camera.is_position_behind(body.global_position):
		_fail("item %s is behind the camera; nothing on screen to click" % body.name)
		return null

	var screen := camera.unproject_position(body.global_position)
	var rect := _root.get_viewport().get_visible_rect()
	if not rect.has_point(screen):
		_fail("item %s draws at (%f, %f), outside the viewport %s" % [body.name, screen.x, screen.y, rect])
		return null
	if _panel.visible and _panel.get_global_rect().has_point(screen):
		_fail(
			"item %s draws at (%f, %f), under the inventory panel %s, which is opaque "
			% [body.name, screen.x, screen.y, _panel.get_global_rect()]
			+ "(M1k): the click would stop at the panel and never reach the item"
		)
		return null
	print("DEMO itemscreen %f %f %f %f" % [screen.x, screen.y, rect.size.x, rect.size.y])
	return screen


func _first_occupied_slot() -> int:
	for slot in _panel.slot_count():
		if not _panel.kind_in_slot(slot).is_empty():
			return slot
	return -1


func _click_at(position: Vector2, shift := false) -> void:
	var viewport := _root.get_viewport()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.shift_pressed = shift
		event.position = position
		viewport.push_input(event)


func _fail(reason: String) -> int:
	print("DEMO FAIL %s" % reason)
	printerr("DEMO FAIL %s" % reason)
	return 1

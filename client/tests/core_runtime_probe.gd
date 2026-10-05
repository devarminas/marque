extends SceneTree

var runtime: Node
var core: RefCounted
var old_world: RefCounted
var inventory_seen := false
var quests_seen := false
var stopped := false

func _initialize() -> void:
	call_deferred("exercise")

func fail(message: String) -> void:
	push_error(message)
	quit(1)
	stopped = true

func check(value: bool, message: String) -> bool:
	if not value:
		fail(message)
	return value

func exercise() -> void:
	runtime = load("res://tests/core_runtime.tscn").instantiate()
	root.add_child(runtime)
	core = runtime.core
	core.tick_applied.connect(func(tick):
		check(core.world.tick == tick.tick, "signal world and owner are latched together")
		if tick.tick == 1:
			old_world = core.world
	)
	core.inventory_changed.connect(func(value):
		inventory_seen = value.slots[0].kind == "sword" and core.owner.inventory.slots[0].kind == "sword"
	)
	core.quests_changed.connect(func(value):
		quests_seen = value.quests[0].id == "quest_one" and core.owner.quests.quests[0].status == "active"
	)
	var token_path := OS.get_environment("MARQUE_RUNTIME_TOKEN")
	if not check(runtime.connect_token(FileAccess.get_file_as_bytes(token_path)), "token connection admitted"):
		return
	paused = true
	var deadline := Time.get_ticks_msec() + 10000
	while core.tick.tick < 2 and not stopped and Time.get_ticks_msec() < deadline:
		await process_frame
	if stopped or not check(core.tick.tick == 2, "automatic core publication while tree paused"):
		return
	if not check(inventory_seen and quests_seen, "typed inventory and quest signals"):
		return
	if not check(old_world != null and old_world.tick == 1, "previous immutable view retained"):
		return
	await create_timer(0.1, true).timeout
	var entities: Array = core.world.entities
	var player: RefCounted
	var npc: RefCounted
	var item: RefCounted
	var node: RefCounted
	for entity in entities:
		if entity.handle.kind == 1:
			player = entity.handle
			if not check(entity.vitals.hp == 90 and entity.transform.x == 5.0, "literal retained health and authoritative transform"):
				return
		elif entity.handle.kind == 2:
			npc = entity.handle
		elif entity.handle.kind == 3:
			item = entity.handle
		elif entity.handle.kind == 4:
			node = entity.handle
	if not check(core.tick.stream.high == 4275878552 and core.tick.stream.low == 1985229328 and core.owner.party.id.high == 4294967295 and core.owner.party.id.low == 4294967295, "unsigned identities retain every bit"):
		return
	if not check(player != null and npc != null and item != null and node != null, "all full-kind handles exposed"):
		return
	if not check(core.prediction_available and core.predicted_local_pose != null, "actual worker prediction ready from complete known-map baseline"):
		return
	if not check(not core.pickup(ClassDB.instantiate("MarqueItemHandle")), "default handle is invalid"):
		return
	if not check(not core.drop(-1) and not core.move(NAN, 0, false), "invalid request refused before admission"):
		return
	item.set_meta("generation", 999)
	var copied_slots: Array = core.owner.inventory.slots.duplicate()
	copied_slots.clear()
	var copied_entities: Array = core.world.entities.duplicate()
	copied_entities.clear()
	if not check(core.owner.inventory.slots.size() == 1 and core.world.entities.size() == 4 and item.generation == 3, "copies and metadata cannot mutate authoritative values"):
		return
	if OS.get_environment("MARQUE_RUNTIME_NEGATIVE") == "nested":
		print("ARM360_NESTED_ARRAY_LOADED sword")
		create_timer(0.1, true).timeout.connect(func(): quit(0))
		core.owner.inventory.slots[0] = core.owner.inventory.slots[0]
		print("ARM360_NESTED_ASSIGNMENT_UNEXPECTEDLY_SUCCEEDED")
		return
	var pinned_pose: RefCounted = core.predicted_local_pose
	if not check(pinned_pose.x == 0 and pinned_pose.dx == 0, "prediction is distinct from authoritative world transform"):
		return
	var accepted := [core.pickup(item), core.drop(3), core.equip(4), core.unequip("helmet"), core.gather(node), core.use_self(5), core.attack_player(player), core.respawn(), core.cast_self("heal"), core.talk(npc), core.dialog_option(npc,"accept"), core.give(npc,6), core.party_invite(player), core.party_accept(), core.party_decline(), core.party_leave(), core.party_kick(player), core.admin("status"), core.use_station(7,node), core.attack_npc(npc), core.cast_player("heal",player), core.cast_npc("fireball",npc), core.move(0.5,-0.25,true)]
	if not check(accepted.all(func(value): return value), "all public typed actions admitted"):
		return
	for frame_sample in range(100):
		if not check(core.move(0.503, -0.251, false), "render samples coalesce without new canonical ticks"):
			return
	var extra := 0
	while extra < 4096 and core.respawn():
		extra += 1
	if not check(extra > 0 and extra < 4096, "bounded action queue refuses admission"):
		return
	FileAccess.open(token_path + ".admitted", FileAccess.WRITE).store_string(str(extra))
	FileAccess.open(token_path + ".blocked", FileAccess.WRITE).store_string("blocked")
	OS.delay_msec(300)
	DirAccess.remove_absolute(token_path + ".blocked")
	while core.tick.tick < 3 and Time.get_ticks_msec() < deadline and not stopped:
		await process_frame
	if not check(core.tick.tick == 3 and core.admin("after_full"), "consumed cursor frees canonical command admission"):
		return
	if not check(core.move(0,0,false), "explicit horizontal release admitted"):
		return
	var stop_deadline := Time.get_ticks_msec() + 150
	while core.predicted_local_pose.dx != 0 and Time.get_ticks_msec() < stop_deadline:
		await process_frame
	if not check(core.predicted_local_pose.dx == 0 and core.predicted_local_pose.dz == 0, "local horizontal release applies on next canonical tick"):
		return
	var stopped_pose: RefCounted = core.predicted_local_pose
	while core.tick.tick < 4 and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(core.tick.tick == 4 and core.predicted_local_pose.dx == 0 and core.predicted_local_pose.y == 0, "complete stopped grounded baseline converges"):
			return
	FileAccess.open(token_path + ".passive", FileAccess.WRITE).store_string("passive")
	while core.tick.tick < 5 and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(0.12, true).timeout
	if not check(core.tick.tick == 5 and core.predicted_local_pose.dx == 1 and core.predicted_local_pose.x > 1.0, "consumed release leaves passive server approach free to advance"):
		return
	if not check(pinned_pose.x == 0 and pinned_pose.dx == 0 and stopped_pose.dx == 0 and core.world.entities[0].transform.x == 5.0, "pinned prediction and authoritative tables stay independent"):
		return
	var retained := core
	runtime.free()
	if not check(retained.connection == 0 and not retained.respawn(), "retained facade is disconnected after node exit"):
		return
	print("ARM360_REAL_UDP_TYPED_ACTIONS_AND_IMMUTABLE_STATE_PASS")
	quit(0)

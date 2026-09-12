extends RefCounted


const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.welcomed.connect(_on_welcomed)
		net.welcome_items.connect(_on_welcome_items)
		net.welcome_nodes.connect(_on_welcome_nodes)
		net.welcome_npcs.connect(_on_welcome_npcs)
		net.item_spawned.connect(_on_item_spawned)
		net.item_despawned.connect(_on_item_despawned)
		net.node_spawned.connect(_on_node_spawned)
		net.node_despawned.connect(_on_node_despawned)
		net.node_state_changed.connect(_on_node_state_changed)
		net.inventory_changed.connect(_on_inventory_changed)
		net.equipment_changed.connect(_on_equipment_changed)
		net.unknown_message.connect(_on_unknown_message)
		net.disconnected.connect(_on_disconnected)

	func feed(text: String) -> void:
		net.ingest_text_frame(text)

	func clear() -> void:
		events.clear()

	func of(signal_name: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for event in events:
			if event["signal"] == signal_name:
				out.append(event)
		return out

	func names() -> Array:
		var out := []
		for event in events:
			out.append(event["signal"])
		return out

	func release() -> void:
		net.free()

	func _on_welcomed(
		you: int,
		tick_ms: int,
		tick: int,
		heartbeat_ticks: int,
		player_ids: PackedInt64Array,
		player_positions: PackedVector2Array,
	) -> void:
		events.append({
			"signal": "welcomed",
			"you": you,
			"tick_ms": tick_ms,
			"tick": tick,
			"heartbeat_ticks": heartbeat_ticks,
			"player_ids": player_ids,
			"player_positions": player_positions,
		})

	func _on_welcome_items(
		item_ids: PackedInt64Array,
		item_kinds: PackedStringArray,
		item_positions: PackedVector2Array,
	) -> void:
		events.append({
			"signal": "welcome_items",
			"ids": item_ids,
			"kinds": item_kinds,
			"positions": item_positions,
		})

	func _on_welcome_nodes(
		node_ids: PackedInt64Array,
		node_kinds: PackedStringArray,
		node_positions: PackedVector2Array,
		node_states: PackedStringArray,
	) -> void:
		events.append({
			"signal": "welcome_nodes",
			"ids": node_ids,
			"kinds": node_kinds,
			"positions": node_positions,
			"states": node_states,
		})

	func _on_welcome_npcs(
		npc_ids: PackedInt64Array,
		npc_kinds: PackedStringArray,
		npc_factions: PackedStringArray,
		npc_names: PackedStringArray,
		npc_positions: PackedVector2Array,
		npc_hps: PackedInt32Array,
		npc_max_hps: PackedInt32Array,
	) -> void:
		events.append({
			"signal": "welcome_npcs",
			"ids": npc_ids,
			"kinds": npc_kinds,
			"factions": npc_factions,
			"names": npc_names,
			"positions": npc_positions,
			"hps": npc_hps,
			"max_hps": npc_max_hps,
		})

	func _on_item_spawned(id: int, kind: String, item_position: Vector2) -> void:
		events.append({
			"signal": "item_spawned", "id": id, "kind": kind, "position": item_position
		})

	func _on_item_despawned(id: int) -> void:
		events.append({"signal": "item_despawned", "id": id})

	func _on_node_spawned(id: int, kind: String, node_position: Vector2, state: String) -> void:
		events.append({
			"signal": "node_spawned",
			"id": id,
			"kind": kind,
			"position": node_position,
			"state": state,
		})

	func _on_node_despawned(id: int) -> void:
		events.append({"signal": "node_despawned", "id": id})

	func _on_node_state_changed(
		id: int, kind: String, node_position: Vector2, state: String
	) -> void:
		events.append({
			"signal": "node_state_changed",
			"id": id,
			"kind": kind,
			"position": node_position,
			"state": state,
		})

	func _on_inventory_changed(
		size: int, slot_indices: PackedInt32Array, slot_kinds: PackedStringArray
	) -> void:
		events.append({
			"signal": "inventory_changed",
			"size": size,
			"slots": slot_indices,
			"kinds": slot_kinds,
		})

	func _on_equipment_changed(
		worn_names: PackedStringArray,
		slot_names: PackedStringArray,
		slot_kinds: PackedStringArray,
	) -> void:
		events.append({
			"signal": "equipment_changed",
			"worn": worn_names,
			"slots": slot_names,
			"kinds": slot_kinds,
		})

	func _on_unknown_message(key: String) -> void:
		events.append({"signal": "unknown_message", "key": key})

	func _on_disconnected(code: int, reason: String) -> void:
		events.append({"signal": "disconnected", "code": code, "reason": reason})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions

	_test_welcome_carries_items()
	_test_welcome_without_items()
	_test_welcome_carries_nodes()
	_test_welcome_carries_npcs()
	_test_node_spawn_state_and_despawn()
	_test_item_spawn_and_despawn()
	_test_inventory()
	_test_equipment()
	_test_a_null_list_means_empty()
	_test_malformed_frames_are_dropped_and_the_connection_survives()
	_test_unknown_keys_are_still_ignored()
	_test_integers_arrive_as_integers()
	_test_intent_frames()
	_test_seq_stamping()

	assertions.finish()


func _test_welcome_carries_items() -> void:
	var recorder := Recorder.new()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":142,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"items":[{"id":7,"kind":"acorn","x":3.0,"z":-2.0},'
		+ '{"id":9,"kind":"acorn","x":-1.5,"z":4.25}]}}'
	)

	_check(
		recorder.names() == ["welcomed", "welcome_items", "welcome_nodes", "welcome_npcs"],
		"welcome emits welcomed, welcome_items, then welcome_nodes, got %s" % [recorder.names()],
	)
	var items := recorder.of("welcome_items")
	if not _check(items.size() == 1, "one welcome_items per welcome"):
		recorder.release()
		return
	var listed: Dictionary = items[0]
	_check(
		Array(listed["ids"]) == [7, 9],
		"both listed items arrive, got %s" % [Array(listed["ids"])],
	)
	_check(
		Array(listed["kinds"]) == ["acorn", "acorn"],
		"with their kinds, got %s" % [Array(listed["kinds"])],
	)
	_check(
		listed["positions"][0] == Vector2(3.0, -2.0)
		and listed["positions"][1] == Vector2(-1.5, 4.25),
		"and their ground positions, got %s" % [Array(listed["positions"])],
	)
	recorder.release()


func _test_welcome_without_items() -> void:
	var recorder := Recorder.new()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":10,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],"items":[]}}'
	)
	var empty := recorder.of("welcome_items")
	if _check(empty.size() == 1, "an empty items array still emits welcome_items"):
		_check(
			(empty[0]["ids"] as PackedInt64Array).is_empty(),
			"carrying no items, got %s" % [Array(empty[0]["ids"])],
		)

	recorder.clear()
	recorder.feed(
		'{"welcome":{"you":2,"tick_ms":150,"tick":11,"players":[{"id":2,"x":1.0,"z":1.0}]}}'
	)
	_check(
		recorder.names() == ["welcomed", "welcome_items", "welcome_nodes", "welcome_npcs"],
		"a welcome with no items key is still a complete welcome, got %s" % [recorder.names()],
	)
	var absent := recorder.of("welcome_items")
	if _check(absent.size() == 1, "and still emits welcome_items"):
		_check(
			(absent[0]["ids"] as PackedInt64Array).is_empty(),
			"carrying no items, got %s" % [Array(absent[0]["ids"])],
		)
	var welcomes := recorder.of("welcomed")
	_check(
		welcomes.size() == 1 and welcomes[0]["you"] == 2,
		"and the players in it land unchanged",
	)
	recorder.release()


func _test_welcome_carries_nodes() -> void:
	var recorder := Recorder.new()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":10,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"nodes":[{"id":1,"kind":"tree","x":5.0,"z":0.0,"state":"full"},'
		+ '{"id":2,"kind":"tree","x":-3.0,"z":4.0,"state":"depleted"}]}}'
	)
	var nodes := recorder.of("welcome_nodes")
	if not _check(nodes.size() == 1, "one welcome_nodes per welcome"):
		recorder.release()
		return
	var listed: Dictionary = nodes[0]
	_check(Array(listed["ids"]) == [1, 2], "both listed nodes arrive, got %s" % [Array(listed["ids"])])
	_check(
		Array(listed["kinds"]) == ["tree", "tree"],
		"with their kinds, got %s" % [Array(listed["kinds"])],
	)
	_check(
		Array(listed["states"]) == ["full", "depleted"],
		"and their states, got %s" % [Array(listed["states"])],
	)
	_check(
		listed["positions"][0] == Vector2(5.0, 0.0)
		and listed["positions"][1] == Vector2(-3.0, 4.0),
		"and their ground positions, got %s" % [Array(listed["positions"])],
	)
	recorder.release()


func _test_welcome_carries_npcs() -> void:
	var recorder := Recorder.new()
	recorder.feed(
		'{"welcome":{"you":3,"tick_ms":150,"tick":10,'
		+ '"players":[{"id":3,"x":0.0,"z":0.0}],'
		+ '"npcs":['
		+ '{"id":1000001,"kind":"dummy","faction":"friendly","x":-3.0,"z":0.0,"hp":100,"max_hp":100},'
		+ '{"id":1000002,"kind":"dummy","faction":"hostile","x":3.0,"z":0.0,"hp":80,"max_hp":100}'
		+ "]}}"
	)
	var npcs := recorder.of("welcome_npcs")
	if not _check(npcs.size() == 1, "one welcome_npcs per welcome"):
		recorder.release()
		return
	var listed: Dictionary = npcs[0]
	_check(
		Array(listed["ids"]) == [1000001, 1000002],
		"both listed npcs arrive, got %s" % [Array(listed["ids"])],
	)
	_check(
		Array(listed["factions"]) == ["friendly", "hostile"],
		"with their factions, got %s" % [Array(listed["factions"])],
	)
	_check(
		Array(listed["kinds"]) == ["dummy", "dummy"],
		"and kinds, got %s" % [Array(listed["kinds"])],
	)
	_check(
		Array(listed["names"]) == ["", ""],
		"missing name fields become empty strings, got %s" % [Array(listed["names"])],
	)
	_check(Array(listed["hps"]) == [100, 80], "and hit points, got %s" % [Array(listed["hps"])])
	recorder.release()


func _test_node_spawn_state_and_despawn() -> void:
	var recorder := Recorder.new()
	recorder.feed('{"node_spawn":{"id":1,"kind":"tree","x":5.0,"z":0.0,"state":"full"}}')
	var spawns := recorder.of("node_spawned")
	if _check(spawns.size() == 1, "node_spawn emits once, got %d" % spawns.size()):
		_check(spawns[0]["id"] == 1 and spawns[0]["kind"] == "tree", "carrying id and kind")
		_check(spawns[0]["state"] == "full", 'and state "full"')
		_check(spawns[0]["position"] == Vector2(5.0, 0.0), "and position")

	recorder.clear()
	recorder.feed('{"node_state":{"id":1,"kind":"tree","x":5.0,"z":0.0,"state":"depleted"}}')
	var states := recorder.of("node_state_changed")
	if _check(states.size() == 1, "node_state emits once, got %d" % states.size()):
		_check(states[0]["state"] == "depleted", 'carrying state "depleted"')

	recorder.clear()
	recorder.feed('{"node_despawn":{"id":1}}')
	var gone := recorder.of("node_despawned")
	_check(gone.size() == 1 and gone[0]["id"] == 1, "node_despawn emits the id")
	recorder.release()


func _test_item_spawn_and_despawn() -> void:
	var recorder := Recorder.new()
	recorder.feed('{"item_spawn":{"id":7,"kind":"acorn","x":3.0,"z":-2.0}}')
	var spawns := recorder.of("item_spawned")
	if _check(spawns.size() == 1, "item_spawn emits once, got %d" % spawns.size()):
		_check(spawns[0]["id"] == 7, "with the item id, got %s" % spawns[0]["id"])
		_check(spawns[0]["kind"] == "acorn", "with the kind, got %s" % spawns[0]["kind"])
		_check(
			spawns[0]["position"] == Vector2(3.0, -2.0),
			"and the ground position, got %v" % spawns[0]["position"],
		)

	recorder.clear()
	recorder.feed('{"item_spawn":{"id":8,"kind":"sextant","x":0.0,"z":0.0}}')
	var unknown := recorder.of("item_spawned")
	if _check(unknown.size() == 1, "an unknown kind still decodes"):
		_check(
			unknown[0]["kind"] == "sextant",
			"and is handed on verbatim, got %s" % unknown[0]["kind"],
		)

	recorder.clear()
	recorder.feed('{"item_despawn":{"id":7}}')
	var despawns := recorder.of("item_despawned")
	if _check(despawns.size() == 1, "item_despawn emits once, got %d" % despawns.size()):
		_check(despawns[0]["id"] == 7, "naming the item, got %s" % despawns[0]["id"])
	recorder.release()


func _test_inventory() -> void:
	var recorder := Recorder.new()

	recorder.feed('{"inventory":{"size":28,"slots":[]}}')
	var empty := recorder.of("inventory_changed")
	if _check(empty.size() == 1, "an empty inventory is a message, not a silence"):
		_check(empty[0]["size"] == 28, "size survives, got %s" % empty[0]["size"])
		_check(
			(empty[0]["slots"] as PackedInt32Array).is_empty(),
			"with nothing occupied, got %s" % [Array(empty[0]["slots"])],
		)

	recorder.clear()
	recorder.feed('{"inventory":{"size":28,"slots":[{"slot":1,"kind":"acorn"}]}}')
	var one := recorder.of("inventory_changed")
	if _check(one.size() == 1, "one occupied slot decodes"):
		_check(
			Array(one[0]["slots"]) == [1],
			"as the index the server gave it, not as position zero, got %s"
			% [Array(one[0]["slots"])],
		)
		_check(
			Array(one[0]["kinds"]) == ["acorn"], "with its kind, got %s" % [Array(one[0]["kinds"])]
		)
		_check(one[0]["size"] == 28, "and 28 slots to draw, got %s" % one[0]["size"])

	var full := PackedStringArray()
	for slot in 28:
		full.append('{"slot":%d,"kind":"acorn"}' % slot)
	recorder.clear()
	recorder.feed('{"inventory":{"size":28,"slots":[%s]}}' % ",".join(full))
	var packed := recorder.of("inventory_changed")
	if _check(packed.size() == 1, "a full inventory decodes"):
		var slots: PackedInt32Array = packed[0]["slots"]
		_check(slots.size() == 28, "with 28 occupied slots, got %d" % slots.size())
		_check(Array(slots) == range(28), "covering every index 0..27")
		_check(
			(packed[0]["kinds"] as PackedStringArray).size() == 28,
			"and 28 kinds index aligned with them",
		)
	recorder.release()


func _test_equipment() -> void:
	var recorder := Recorder.new()

	recorder.feed('{"equipment":{"worn":["helmet","left hand","chest","right hand","trousers"],"slots":[]}}')
	var empty := recorder.of("equipment_changed")
	if _check(empty.size() == 1, "an empty equipment frame is a message, not a silence"):
		_check(Array(empty[0]["worn"]) == ["helmet", "left hand", "chest", "right hand", "trousers"], "worn survives, got %s" % [Array(empty[0]["worn"])])
		_check(
			(empty[0]["slots"] as PackedStringArray).is_empty(),
			"with nothing worn, got %s" % [Array(empty[0]["slots"])],
		)

	recorder.clear()
	recorder.feed('{"equipment":{"worn":["helmet","left hand","chest","right hand","trousers"],"slots":[{"slot":"right hand","kind":"sword"}]}}')
	var one := recorder.of("equipment_changed")
	if _check(one.size() == 1, "one occupied worn slot decodes"):
		_check(
			Array(one[0]["slots"]) == ["right hand"],
			"as the slot name the server gave it, got %s" % [Array(one[0]["slots"])],
		)
		_check(Array(one[0]["kinds"]) == ["sword"], "with its kind, got %s" % [Array(one[0]["kinds"])])
	recorder.release()


func _test_a_null_list_means_empty() -> void:
	print("-- expect exactly three 'is null, which is a server bug' errors below")

	const PLAYERS := '"players":[{"id":1,"x":0.0,"z":0.0}]'
	var absent := _replay(
		'{"welcome":{"you":1,"tick_ms":150,"tick":5,' + PLAYERS + "}}"
	)
	var listed := _replay(
		'{"welcome":{"you":1,"tick_ms":150,"tick":5,' + PLAYERS + ',"items":[]}}'
	)
	var nulled := _replay(
		'{"welcome":{"you":1,"tick_ms":150,"tick":5,' + PLAYERS + ',"items":null}}'
	)
	_check(
		absent == listed,
		"welcome.items absent and [] are the same state (%s vs %s)" % [absent, listed],
	)
	_check(
		nulled == listed,
		"welcome.items null and [] are the same state (%s vs %s)" % [nulled, listed],
	)
	_check(
		nulled == [
			["welcomed", "welcome_items", "welcome_nodes", "welcome_npcs"],
			["welcomed", 1, 5, [1]],
			["welcome_items", [], [], []],
			["welcome_nodes", [], [], [], []],
			["welcome_npcs", [], [], [], [], [], [], []],
		],
		"a welcome whose items are null still joins the client, got %s" % [nulled],
	)

	var empty_slots := _replay('{"inventory":{"size":28,"slots":[]}}')
	var null_slots := _replay('{"inventory":{"size":28,"slots":null}}')
	_check(
		null_slots == empty_slots,
		"inventory.slots null and [] are the same state (%s vs %s)" % [null_slots, empty_slots],
	)
	_check(
		null_slots == [["inventory_changed"], ["inventory_changed", 28, [], []]],
		"and that state is 28 slots with nothing in them, got %s" % [null_slots],
	)

	var absent_slots := _replay('{"inventory":{"size":28}}')
	_check(
		absent_slots == [[]],
		"an inventory with no slots key at all is still dropped, got %s" % [absent_slots],
	)

	var still_strict := [
		'{"welcome":{"you":1,"tick_ms":150,"tick":5,"players":null}}',
		'{"welcome":{"you":1,"tick_ms":150,"tick":5,"players":[],"items":{"id":7}}}',
		'{"welcome":null}',
		'{"path":{"id":1,"start_tick":1,"points":null,"speed":3.0}}',
		'{"inventory":null}',
		'{"inventory":{"size":null,"slots":[]}}',
		'{"inventory":{"size":28,"slots":{}}}',
		'{"inventory":{"size":28,"slots":[null]}}',
		'{"item_spawn":{"id":7,"kind":null,"x":0.0,"z":0.0}}',
		'{"item_spawn":{"id":7,"kind":"acorn","x":null,"z":0.0}}',
		'{"item_despawn":{"id":null}}',
	]
	for frame: String in still_strict:
		_check(
			_replay(frame) == [[]],
			"a null outside welcome.items and inventory.slots is still refused: %s" % frame,
		)

	var recorder := Recorder.new()
	recorder.feed('{"welcome":{"you":1,"tick_ms":150,"tick":6,' + PLAYERS + ',"items":null}}')
	recorder.feed('{"item_spawn":{"id":7,"kind":"acorn","x":3.0,"z":-2.0}}')
	_check(
		recorder.of("item_spawned").size() == 1,
		"the frame after an accommodated null decodes normally",
	)
	_check(
		recorder.of("disconnected").is_empty(),
		"and a null list never closes the connection",
	)
	recorder.release()


func _replay(frame: String) -> Array:
	var recorder := Recorder.new()
	recorder.feed(frame)
	var out: Array = [recorder.names()]
	for event: Dictionary in recorder.events:
		match event["signal"]:
			"welcomed":
				out.append([
					"welcomed", event["you"], event["tick"], Array(event["player_ids"])
				])
			"welcome_items":
				out.append([
					"welcome_items",
					Array(event["ids"]),
					Array(event["kinds"]),
					Array(event["positions"]),
				])
			"welcome_nodes":
				out.append([
					"welcome_nodes",
					Array(event["ids"]),
					Array(event["kinds"]),
					Array(event["positions"]),
					Array(event["states"]),
				])
			"welcome_npcs":
				out.append([
					"welcome_npcs",
					Array(event["ids"]),
					Array(event["kinds"]),
					Array(event["factions"]),
					Array(event["names"]),
					Array(event["positions"]),
					Array(event["hps"]),
					Array(event["max_hps"]),
				])
			"inventory_changed":
				out.append([
					"inventory_changed",
					event["size"],
					Array(event["slots"]),
					Array(event["kinds"]),
				])
			_:
				out.append([event["signal"]])
	recorder.release()
	return out


func _test_malformed_frames_are_dropped_and_the_connection_survives() -> void:
	var recorder := Recorder.new()
	var bad := [
		'{"item_spawn":{"id":7,"x":3.0,"z":-2.0}}',
		'{"item_spawn":{"id":7,"kind":42,"x":3.0,"z":-2.0}}',
		'{"item_spawn":{"id":7,"kind":"acorn","z":-2.0}}',
		'{"item_spawn":{"id":"seven","kind":"acorn","x":3.0,"z":-2.0}}',
		'{"item_spawn":[7,"acorn",3.0,-2.0]}',
		'{"item_despawn":{"item":7}}',
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"players":[],"items":{"id":7}}}',
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,"players":[],"items":[{"id":7,"x":1.0}]}}',
		'{"inventory":{"size":28}}',
		'{"inventory":{"slots":[]}}',
		'{"inventory":{"size":28,"slots":[{"slot":28,"kind":"acorn"}]}}',
		'{"inventory":{"size":28,"slots":[{"slot":-1,"kind":"acorn"}]}}',
		'{"inventory":{"size":28,"slots":[{"slot":1,"kind":"acorn"},{"slot":1,"kind":"acorn"}]}}',
		'{"inventory":{"size":28,"slots":[{"slot":1}]}}',
		'{"inventory":{"size":28,"slots":["acorn"]}}',
		'{"inventory":{"size":-1,"slots":[]}}',
	]
	for frame: String in bad:
		recorder.clear()
		recorder.feed(frame)
		_check(recorder.events.is_empty(), "a malformed frame emits nothing: %s" % frame)

	recorder.clear()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],"items":[{"id":7,"kind":true,"x":0,"z":0}]}}'
	)
	_check(
		recorder.of("welcomed").is_empty(),
		"a welcome with unparseable items applies none of itself, not just no items",
	)

	recorder.clear()
	recorder.feed('{"item_spawn":{"id":7,"kind":"acorn","x":3.0,"z":-2.0}}')
	_check(
		recorder.of("item_spawned").size() == 1,
		"and the next good frame is decoded, so the connection was kept",
	)
	_check(
		recorder.of("disconnected").is_empty(),
		"a malformed frame never closes the connection",
	)
	recorder.release()


func _test_unknown_keys_are_still_ignored() -> void:
	var recorder := Recorder.new()
	recorder.feed('{"item_moved":{"id":7,"x":1.0,"z":2.0}}')
	var unknown := recorder.of("unknown_message")
	if _check(unknown.size() == 1, "an unknown top-level key is reported once"):
		_check(unknown[0]["key"] == "item_moved", "naming it, got %s" % unknown[0]["key"])
	_check(
		recorder.of("disconnected").is_empty(), "and is not a reason to close the connection"
	)
	recorder.release()


func _test_integers_arrive_as_integers() -> void:
	var recorder := Recorder.new()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":142,"players":[],'
		+ '"items":[{"id":7,"kind":"acorn","x":0.0,"z":0.0}]}}'
	)
	var welcomes := recorder.of("welcomed")
	if _check(welcomes.size() == 1, "welcome decoded"):
		_check(
			typeof(welcomes[0]["tick"]) == TYPE_INT and welcomes[0]["tick"] == 142,
			"welcome.tick is an int, got %s (%d)"
			% [welcomes[0]["tick"], typeof(welcomes[0]["tick"])],
		)
	var listed := recorder.of("welcome_items")
	if _check(listed.size() == 1, "welcome_items decoded"):
		var ids: PackedInt64Array = listed[0]["ids"]
		_check(
			typeof(ids[0]) == TYPE_INT and ids[0] == 7,
			"a welcome item id is an int, got %s (%d)" % [ids[0], typeof(ids[0])],
		)

	recorder.clear()
	recorder.feed('{"item_spawn":{"id":12,"kind":"acorn","x":0.0,"z":0.0}}')
	var spawn: Dictionary = recorder.of("item_spawned")[0]
	_check(
		typeof(spawn["id"]) == TYPE_INT and spawn["id"] == 12,
		"an item_spawn id is an int, got %s (%d)" % [spawn["id"], typeof(spawn["id"])],
	)

	recorder.clear()
	recorder.feed('{"item_despawn":{"id":12}}')
	var despawn: Dictionary = recorder.of("item_despawned")[0]
	_check(
		typeof(despawn["id"]) == TYPE_INT and despawn["id"] == 12,
		"an item_despawn id is an int, got %s (%d)" % [despawn["id"], typeof(despawn["id"])],
	)

	recorder.clear()
	recorder.feed('{"inventory":{"size":28,"slots":[{"slot":3,"kind":"acorn"}]}}')
	var inventory: Dictionary = recorder.of("inventory_changed")[0]
	_check(
		typeof(inventory["size"]) == TYPE_INT and inventory["size"] == 28,
		"inventory.size is an int, got %s" % inventory["size"],
	)
	_check(
		Array(inventory["slots"]) == [3],
		"and a slot index is an int, got %s" % [Array(inventory["slots"])],
	)
	recorder.release()


func _test_intent_frames() -> void:
	_check(
		JSON.stringify(NetClientScript.pickup_frame(7)) == '{"pickup":{"item":7}}',
		'pickup frames as {"pickup":{"item":7}}, got %s'
		% JSON.stringify(NetClientScript.pickup_frame(7)),
	)
	_check(
		JSON.stringify(NetClientScript.gather_frame(1)) == '{"gather":{"node":1}}',
		'gather frames as {"gather":{"node":1}}, got %s'
		% JSON.stringify(NetClientScript.gather_frame(1)),
	)
	_check(
		JSON.stringify(NetClientScript.drop_frame(3)) == '{"drop":{"slot":3}}',
		'drop frames as {"drop":{"slot":3}}, got %s'
		% JSON.stringify(NetClientScript.drop_frame(3)),
	)
	_check(
		JSON.stringify(NetClientScript.move_to_frame(42.3, 17.8))
		== '{"move_to":{"x":42.3,"z":17.8}}',
		"move_to is unchanged by M1, got %s"
		% JSON.stringify(NetClientScript.move_to_frame(42.3, 17.8)),
	)
	_check(
		JSON.stringify(NetClientScript.move_frame(0.0, -1.0))
		== '{"move":{"dx":0.0,"dz":-1.0}}',
		"move carries world dx/dz, got %s"
		% JSON.stringify(NetClientScript.move_frame(0.0, -1.0)),
	)
	_check(
		JSON.stringify(NetClientScript.equip_frame(3)) == '{"equip":{"slot":3}}',
		'equip frames as {"equip":{"slot":3}}, got %s'
		% JSON.stringify(NetClientScript.equip_frame(3)),
	)
	_check(
		JSON.stringify(NetClientScript.unequip_frame("right hand")) == '{"unequip":{"worn":"right hand"}}',
		'unequip frames as {"unequip":{"worn":"right hand"}}, got %s'
		% JSON.stringify(NetClientScript.unequip_frame("right hand")),
	)
	_check(
		JSON.stringify(NetClientScript.use_frame(3, 7)) == '{"use":{"on":7,"slot":3}}',
		'use frames as {"use":{"on":7,"slot":3}}, got %s'
		% JSON.stringify(NetClientScript.use_frame(3, 7)),
	)
	_check(
		JSON.stringify(NetClientScript.use_frame(3, 3)) == '{"use":{"on":3,"slot":3}}',
		'self-use frames as {"use":{"on":3,"slot":3}}, got %s'
		% JSON.stringify(NetClientScript.use_frame(3, 3)),
	)
	_check(
		(NetClientScript.pickup_frame(1)["pickup"] as Dictionary).has("item")
		and (NetClientScript.drop_frame(1)["drop"] as Dictionary).has("slot")
		and (NetClientScript.gather_frame(1)["gather"] as Dictionary).has("node"),
		"pickup names an item id, drop a slot index, gather a node id",
	)
	_check(
		(NetClientScript.equip_frame(1)["equip"] as Dictionary).has("slot")
		and (NetClientScript.unequip_frame("right hand")["unequip"] as Dictionary).has("worn")
		and (NetClientScript.use_frame(1, 2)["use"] as Dictionary).has("on"),
		"equip names a bag slot, unequip a worn slot, use names slot and on",
	)


func _test_seq_stamping() -> void:
	var net: NetClientScript = NetClientScript.new()
	_check(net.next_seq() == 1, "before any welcome the next seq is 1")
	var first: Dictionary = NetClientScript.move_to_frame(42.3, 17.8, net.take_seq())
	_check(
		typeof((first["move_to"] as Dictionary)["seq"]) == TYPE_INT
		and (first["move_to"] as Dictionary)["seq"] == 1,
		"the first stamped move_to carries seq 1, got %s" % JSON.stringify(first),
	)
	var second: Dictionary = NetClientScript.pickup_frame(7, net.take_seq())
	_check(
		(second["pickup"] as Dictionary)["seq"] == 2,
		"the second stamped frame carries seq 2, got %s" % JSON.stringify(second),
	)
	var third: Dictionary = NetClientScript.drop_frame(3, net.take_seq())
	_check(
		(third["drop"] as Dictionary)["seq"] == 3,
		"the third stamped frame carries seq 3, got %s" % JSON.stringify(third),
	)

	net.ingest_text_frame(
		'{"welcome":{"you":1,"tick_ms":150,"tick":0,"last_seq":7,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)
	_check(net.next_seq() == 8, "after welcome.last_seq 7 the next seq is 8")
	_check(
		(NetClientScript.move_to_frame(1.0, 2.0, net.take_seq())["move_to"] as Dictionary)["seq"]
		== 8,
		"the first intent after last_seq 7 is 8",
	)

	net.ingest_text_frame(
		'{"welcome":{"you":1,"tick_ms":150,"tick":0,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)
	_check(net.next_seq() == 1, "after a welcome without last_seq the next seq is 1")
	net.free()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition

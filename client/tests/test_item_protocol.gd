extends RefCounted

## The M1 wire layer, with no scene tree and no server.
##
## Everything here goes through [code]net_client.gd[/code]'s public
## [code]ingest_text_frame[/code], which exists so that a test can inject a frame
## the server cannot be made to send. That is the whole point of this suite: the
## Go half of M1 does not exist on `main` yet, and this file is what makes the
## client half independently verifiable before it does.
##
## [b]Tree-free on purpose.[/b] A decoder that needs a viewport to decode is a
## decoder with a dependency nobody wrote down. Running it as a [RefCounted]
## suite from [method SceneTree._initialize] is the practical proof it has none.
## The [Node] under test is created and freed here and never enters a tree.
##
## The registry and the bodies are the other half and live in
## [code]test_items.gd[/code], which needs a tree because bodies do.

const NetClientScript := preload("res://scripts/net_client.gd")


## Every signal one client emitted, in order, as
## [code]{"signal": name, ...}[/code] records.
##
## A recorder rather than a set of booleans because two of the assertions here
## are about ordering — `welcome_items` after `welcomed`, and a malformed frame
## emitting nothing at all — and a boolean cannot express either.
class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.welcomed.connect(_on_welcomed)
		net.welcome_items.connect(_on_welcome_items)
		net.item_spawned.connect(_on_item_spawned)
		net.item_despawned.connect(_on_item_despawned)
		net.inventory_changed.connect(_on_inventory_changed)
		net.equipment_changed.connect(_on_equipment_changed)
		net.unknown_message.connect(_on_unknown_message)
		net.disconnected.connect(_on_disconnected)

	## Hands one frame to the decoder as if it had arrived on the socket.
	func feed(text: String) -> void:
		net.ingest_text_frame(text)

	## Drops everything recorded so far, so the next assertion reads a fresh
	## slate rather than an offset into a growing log.
	func clear() -> void:
		events.clear()

	## Every recorded event naming [param signal_name], oldest first.
	func of(signal_name: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for event in events:
			if event["signal"] == signal_name:
				out.append(event)
		return out

	## The names of the signals recorded, in order.
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

	func _on_item_spawned(id: int, kind: String, item_position: Vector2) -> void:
		events.append({
			"signal": "item_spawned", "id": id, "kind": kind, "position": item_position
		})

	func _on_item_despawned(id: int) -> void:
		events.append({"signal": "item_despawned", "id": id})

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


## `welcome.items` is the world's ground items, stated alongside its players.
func _test_welcome_carries_items() -> void:
	var recorder := Recorder.new()
	recorder.feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":142,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],'
		+ '"items":[{"id":7,"kind":"acorn","x":3.0,"z":-2.0},'
		+ '{"id":9,"kind":"acorn","x":-1.5,"z":4.25}]}}'
	)

	_check(
		recorder.names() == ["welcomed", "welcome_items"],
		"welcome emits welcomed and then welcome_items, got %s" % [recorder.names()],
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


## Two ways of saying "the world has no items on the ground", and one is a
## pre-M1 server that has never heard of the field. Neither may crash a post-M1
## client, and both have to reach the listener, or a client that already had
## items could never be told they are gone.
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
	# A pre-M1 server. The key is absent, not null.
	recorder.feed(
		'{"welcome":{"you":2,"tick_ms":150,"tick":11,"players":[{"id":2,"x":1.0,"z":1.0}]}}'
	)
	_check(
		recorder.names() == ["welcomed", "welcome_items"],
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

	# An unknown kind is not the decoder's problem. It goes through verbatim and
	# the body decides what to draw (PROTOCOL.md, `item_spawn`).
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


## `inventory.slots` is sparse: occupied slots only, each carrying its own index,
## with `size` saying how many slots exist. There are no nulls in it by design,
## so the number of entries is the number of items held and never the number of
## slots to draw.
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

	# A full inventory: 28 occupied slots, RuneScape's number and the server's
	# one constant. The sparse encoding's worst case is still every slot named.
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


## `equipment.slots` is sparse like `inventory.slots`: occupied worn slots only.
func _test_equipment() -> void:
	var recorder := Recorder.new()

	recorder.feed('{"equipment":{"worn":["weapon"],"slots":[]}}')
	var empty := recorder.of("equipment_changed")
	if _check(empty.size() == 1, "an empty equipment frame is a message, not a silence"):
		_check(Array(empty[0]["worn"]) == ["weapon"], "worn survives, got %s" % [Array(empty[0]["worn"])])
		_check(
			(empty[0]["slots"] as PackedStringArray).is_empty(),
			"with nothing worn, got %s" % [Array(empty[0]["slots"])],
		)

	recorder.clear()
	recorder.feed('{"equipment":{"worn":["weapon"],"slots":[{"slot":"weapon","kind":"axe"}]}}')
	var one := recorder.of("equipment_changed")
	if _check(one.size() == 1, "one occupied worn slot decodes"):
		_check(
			Array(one[0]["slots"]) == ["weapon"],
			"as the slot name the server gave it, got %s" % [Array(one[0]["slots"])],
		)
		_check(Array(one[0]["kinds"]) == ["axe"], "with its kind, got %s" % [Array(one[0]["kinds"])])
	recorder.release()


## The receiver's half of the null-list rule (`PROTOCOL.md`, `inventory`): "A
## receiver treats `null` as an absent key, meaning empty, and logs loudly."
##
## A Go server holding a slice that was never appended to marshals it as `null`,
## not `[]`, and it does so silently. A client that read `null` as "not an array"
## would drop the whole frame, and for `welcome` that means it never joins and
## sits frozen forever, with nothing looking wrong on either side. So `null`,
## `[]`, and — for `welcome.items` — an absent key have to be indistinguishable
## in the state they produce.
##
## [b]Loudness is printed here, not asserted.[/b] `push_error` is what "loudly"
## means in `net_client.gd`, and a GDScript suite has no way to capture one; the
## same limitation is why `test_polyline_walker.gd` prints a banner instead. What
## makes the log checkable is that this function is the only source of
## `net_client: ... is null, which is a server bug` in the whole suite, and it
## produces exactly three of them: two `welcome.items` and one
## `inventory.slots`, one per null frame fed below. A run with fewer has lost
## the accommodation's log line; a run with more has spread the leniency
## somewhere it does not belong.
func _test_a_null_list_means_empty() -> void:
	print("-- expect exactly three 'is null, which is a server bug' errors below")

	# `welcome.items`, three ways of saying the ground is bare. The player list
	# is identical in all three, because what is being compared is the whole
	# resulting state and not just the items.
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
	# Stated positively as well, so that three frames all failing the same way
	# cannot pass the comparison above.
	_check(
		nulled == [
			["welcomed", "welcome_items"],
			["welcomed", 1, 5, [1]],
			["welcome_items", [], [], []],
		],
		"a welcome whose items are null still joins the client, got %s" % [nulled],
	)

	# `inventory.slots`. `[]` and `null` are one empty inventory.
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

	# The third shape, and the one place this client stays strict: an absent
	# `slots` is still a missing field. `inventory` is an M1 message with no
	# earlier form to be compatible with, so no sender legitimately omits
	# `slots`, and a frame that lost the field is a frame that lost a field —
	# not a server saying "empty". Dropping it is unchanged from before this
	# unit and `_test_malformed_frames_are_dropped_and_the_connection_survives`
	# asserts the same thing from the other side.
	var absent_slots := _replay('{"inventory":{"size":28}}')
	_check(
		absent_slots == [[]],
		"an inventory with no slots key at all is still dropped, got %s" % [absent_slots],
	)

	# The leniency is exactly two fields wide. Everywhere else a `null` is what
	# it was before: a value of the wrong type, and a dropped frame.
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

	# And the connection is intact after all of it, which is the rule the
	# leniency exists to serve: this client never closes on a server's bug.
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


## Feeds one frame to a fresh decoder and returns everything it emitted, as one
## value that [code]==[/code] can compare.
##
## The first element is the signal names in order, so an empty result reads as
## [code][[]][/code] and a dropped frame is distinguishable from a frame that
## emitted the right signals carrying the wrong payload.
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


## `PROTOCOL.md`, "Compatibility": a client logs loudly, drops the single
## offending frame, and keeps the connection. It never closes, because the
## server is its only peer and `error` is server-to-client only, so there is
## nothing to reply with and nothing to reconnect to.
##
## The proof that the connection survived is that the frame after each bad one
## is decoded normally, and that nothing ever emitted `disconnected`.
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

	# The frame that matters: a `welcome` whose items will not parse must lose
	# its players too. Half a world applied is worse than none, and this file's
	# rule is that one bad frame is dropped entire.
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


## Compatibility rule 1, unchanged by M1: an unknown top-level key is logged and
## ignored rather than treated as an error. M2's `{"tick":{"t":N}}` is the reason
## it exists.
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


## `JSON.parse_string` returns every JSON number as a float, so every integer on
## the wire arrives as one. `welcome.tick` was the known case; every id and slot
## index M1 adds has the same problem (PROTOCOL.md, "Decoding notes").
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


## The two M1 intents, asserted as the exact bytes they put on the wire.
##
## Nothing calls the senders yet — turning a click into a `pickup` and drawing
## an inventory are M1d — so this is the only check that the frames match
## `PROTOCOL.md` before a server exists to reject them. `move_to` is here beside
## them so that one file owns the whole client-to-server surface.
func _test_intent_frames() -> void:
	_check(
		JSON.stringify(NetClientScript.pickup_frame(7)) == '{"pickup":{"item":7}}',
		'pickup frames as {"pickup":{"item":7}}, got %s'
		% JSON.stringify(NetClientScript.pickup_frame(7)),
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
		JSON.stringify(NetClientScript.equip_frame(3)) == '{"equip":{"slot":3}}',
		'equip frames as {"equip":{"slot":3}}, got %s'
		% JSON.stringify(NetClientScript.equip_frame(3)),
	)
	_check(
		JSON.stringify(NetClientScript.unequip_frame("weapon")) == '{"unequip":{"worn":"weapon"}}',
		'unequip frames as {"unequip":{"worn":"weapon"}}, got %s'
		% JSON.stringify(NetClientScript.unequip_frame("weapon")),
	)
	# `drop` names a slot and `pickup` names an item id, and the two are
	# different spaces. A sender that swapped them would still frame as valid
	# JSON, so the field names are asserted rather than assumed.
	_check(
		(NetClientScript.pickup_frame(1)["pickup"] as Dictionary).has("item")
		and (NetClientScript.drop_frame(1)["drop"] as Dictionary).has("slot"),
		"pickup names an item id and drop names a slot index",
	)
	_check(
		(NetClientScript.equip_frame(1)["equip"] as Dictionary).has("slot")
		and (NetClientScript.unequip_frame("weapon")["unequip"] as Dictionary).has("worn"),
		"equip names a bag slot and unequip names a worn slot",
	)


## Three consecutive stamped frames are 1, 2, 3. A welcome with last_seq 7
## restarts at 8. A welcome without last_seq restarts at 1.
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

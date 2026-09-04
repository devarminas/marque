extends Node

## The client half of the Marque wire protocol (`PROTOCOL.md`).
##
## It moves frames and emits signals. It knows nothing about avatars, cameras,
## the scene tree's contents, or any game rule: everything it hands out is a
## plain value, and what a caller builds from that is the caller's business.
##
## [b]Not an autoload.[/b] Instantiate it, [method Node.add_child] it so it gets
## a frame, and connect the signals:
##
## [codeblock]
## const NetClient := preload("res://scripts/net_client.gd")
##
## var net := NetClient.new()
## add_child(net)
## net.welcomed.connect(_on_welcomed)
## net.connect_to_server("ws://127.0.0.1:8080/ws")
## [/codeblock]
##
## Typed by [code]preload[/code] rather than a global [code]class_name[/code]:
## global class names resolve through a cache only the editor scan writes, and
## the headless suite has to run from a clone that has never opened the editor
## (`NOTES.md`, "Godot authoring traps").
##
## [b]Coordinates.[/b] Every position this script emits is a [Vector2] holding
## ground-plane [code](x, z)[/code], so [code]Vector2.y[/code] is world
## [b]Z[/b], never world Y. `y` never crosses the wire (`PROTOCOL.md`,
## "Coordinates").
##
## [b]Ticks.[/b] `tick` and `start_tick` are 64-bit integers on the wire that
## arrive from [method JSON.parse_string] as floats. They are converted to
## [int] here so nothing downstream compares a float to an int.
##
## [b]Reconnect.[/b] After the socket is closed or abandoned, [method connect_to_server]
## may be called again. Sequence numbers restart from `welcome.last_seq` on every
## welcome. A click in flight when the socket dies is lost (`PROTOCOL.md`,
## "Sequence numbers"). The token from the last `welcome.session` is kept here so
## a caller can present it on the next URL.

## Emitted once, when the socket reaches [constant WebSocketPeer.STATE_OPEN].
## No frame has been received yet; `welcome` follows.
signal connected()

## Emitted once, when the socket reaches [constant WebSocketPeer.STATE_CLOSED].
## It fires whether or not [signal connected] ever did, so a connection that
## failed during the handshake is reported here with no [signal connected]
## before it. `code` and `reason` are the WebSocket close frame's, and are 0 and
## "" when the connection died without one.
signal disconnected(code: int, reason: String)

## `welcome`: the first frame on every connection.
##
## `you` is this client's own id. `player_ids` and `player_positions` are index
## aligned and describe every player in the world [i]including this one[/i], at
## its position as of `tick`.
##
## `heartbeat_ticks` is the interval, in ticks, at which the server intends to
## send `tick`. It is [code]0[/code] when the field was absent, and 0 means the
## receiver runs no liveness timer (`PROTOCOL.md`, "Clock").
signal welcomed(
	you: int,
	tick_ms: int,
	tick: int,
	heartbeat_ticks: int,
	player_ids: PackedInt64Array,
	player_positions: PackedVector2Array,
)

## `tick`: the server's heartbeat, carrying the tick it was current at.
signal tick_received(t: int)

## The ground items `welcome` listed, emitted immediately after [signal welcomed]
## and out of the same frame. **M1.**
##
## Split from [signal welcomed] rather than folded into it because the handler
## for the players has to have run first: `welcome` is the world restated, so a
## listener frees everything it believed on [signal welcomed] and then rebuilds,
## and one signal carrying both would leave the order of those two jobs to the
## listener. Emission here is synchronous and in that order, so it does not.
##
## Emitted on every `welcome`: one carrying items, one carrying an empty `items`
## array, one from a pre-M1 server with no `items` key at all, and one whose
## `items` is `null` because a server marshalled an empty slice badly. The last
## three mean the same thing — the world has no ground items — and a listener
## that only heard about items when there were some could never clear the ones
## it already had. Only the `null` one logs; see [method _is_null_list].
##
## The three arrays are index aligned.
signal welcome_items(
	item_ids: PackedInt64Array,
	item_kinds: PackedStringArray,
	item_positions: PackedVector2Array,
)

## `spawn`: a player joined. Never carries this client's own id, which arrives
## in `welcome` instead.
signal spawned(id: int, position: Vector2)

## `despawn`: a player left. Never carries this client's own id.
signal despawned(id: int)

## `path`: a player was assigned a polyline, including this client's own.
##
## `points[0]` is that player's position at `start_tick` and `points` always has
## at least one element; a one-element path means "halt here". `speed` is world
## units per second, constant across the whole polyline.
signal path_assigned(id: int, start_tick: int, points: PackedVector2Array, speed: float)

## `item_spawn`: a ground item appeared. **M1.**
##
## Broadcast to everyone including whoever caused it, which is `path`'s rule and
## not `spawn`'s: a dropper who did not hear this would have to conjure the body
## out of its own intent, which is the client inventing state the server never
## announced (`PROTOCOL.md`, `item_spawn`).
##
## `kind` is handed over verbatim, including a kind this client has never heard
## of. Deciding what to draw for one is the body's job, not this file's.
signal item_spawned(id: int, kind: String, position: Vector2)

## `item_despawn`: a ground item left the world. **M1.**
signal item_despawned(id: int)

## `inventory`: this client's own inventory, restated in full. **M1.**
##
## Sent to one player, never broadcast, and never a patch. `size` is how many
## slots exist; slot indices run `0` to `size - 1`.
##
## [b]`slot_indices` and `slot_kinds` are sparse and index aligned.[/b] They list
## only the occupied slots, each carrying its own index, in the order the server
## sent them — which is not promised to be sorted, so a reader that wants order
## sorts. An empty slot is absent rather than null (`PROTOCOL.md`, `inventory`),
## so `slot_indices.size()` is the number of items held and never the number of
## slots drawn.
signal inventory_changed(
	size: int, slot_indices: PackedInt32Array, slot_kinds: PackedStringArray
)

## `equipment`: this client's own worn equipment, restated in full. **M3c.**
##
## [b]`slot_names` and `slot_kinds` are sparse and index aligned.[/b] They list
## only occupied worn slots, each carrying its own name. An empty worn slot is
## absent rather than null (`PROTOCOL.md`, `equipment`).
signal equipment_changed(
	worn_names: PackedStringArray, slot_names: PackedStringArray, slot_kinds: PackedStringArray
)

## `error`: the server refused something this client sent. `re` names the
## rejected message and is [code]""[/code] when the frame could not be
## attributed to one. `message` is for a log, not for display and not for
## branching on.
signal server_error(re: String, message: String)

## A frame naming a message this client does not know. It is logged loudly and
## ignored, the connection survives, and this signal exists so that the
## ignoring is observable rather than invisible.
##
## This is compatibility rule 1 in `PROTOCOL.md`, the one place the project's
## fail-fast doctrine is deliberately relaxed.
signal unknown_message(key: String)

const CONNECT_TIMEOUT_MSEC := 5000

var _peer: WebSocketPeer = null
var _opened := false
var _closed := false
var _connect_deadline_msec := 0
## Next `seq` to stamp on an outbound intent. Restarts from
## `welcome.last_seq + 1` on every applied welcome, and is 1 before the first.
var _next_seq := 1
var _session := ""


## Opens a connection. Returns [constant OK] when the socket started
## connecting, which is not the same as connected: wait for [signal connected].
##
## Calling this while a connection is already open or in flight is a caller bug
## and is refused. After [signal disconnected], this may be called again.
func connect_to_server(url: String) -> Error:
	if _peer != null and not _closed:
		var state := _peer.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CONNECTING:
			push_error("net_client: already connected to a server; wait for disconnected")
			return ERR_ALREADY_IN_USE

	_peer = null
	_opened = false
	_closed = false
	_connect_deadline_msec = 0

	var peer := WebSocketPeer.new()
	var status := peer.connect_to_url(url)
	if status != OK:
		push_error("net_client: connect_to_url failed: %d" % status)
		return status

	_peer = peer
	_connect_deadline_msec = Time.get_ticks_msec() + CONNECT_TIMEOUT_MSEC
	return OK


## `welcome.session` from the last applied welcome, or "" when none named one.
func session_token() -> String:
	return _session


## The same URL with `session` set to [param token], or stripped when [param token]
## is empty. Other query parameters are kept. The token is never logged.
static func url_with_session(url: String, token: String) -> String:
	var base := url
	var query := ""
	var mark := url.find("?")
	if mark != -1:
		base = url.substr(0, mark)
		query = url.substr(mark + 1)
	var parts: PackedStringArray = []
	if not query.is_empty():
		for part: String in query.split("&"):
			if part.begins_with("session=") or part.is_empty():
				continue
			parts.append(part)
	if not token.is_empty():
		parts.append("session=" + token)
	if parts.is_empty():
		return base
	return base + "?" + "&".join(parts)


## Closes the connection. [signal disconnected] follows on a later frame, once
## the peer has finished its closing handshake.
func close(code: int = 1000, reason: String = "") -> void:
	if _peer == null:
		return
	_peer.close(code, reason)


## Drops the transport without sending a close frame, so the server sees a read
## error and records `peer_gone` rather than `closed` (`PROTOCOL.md`, "Clock").
##
## Safe on a client that never connected, and idempotent with [method close]:
## [signal disconnected] is emitted here, synchronously, and only once.
##
## The mechanism is [method WebSocketPeer.close] with a [b]negative[/b] code,
## which closes the transport immediately without notifying the peer. Verified
## against 4.7.2: a peer in [constant WebSocketPeer.STATE_CONNECTING] reads back
## [constant WebSocketPeer.STATE_CLOSED] on the next line, with no polling and
## no closing handshake in between.
func abandon() -> void:
	if _peer != null:
		_peer.close(-1)
	_announce_disconnected(0, "")


## True between [signal connected] and [signal disconnected].
func is_open() -> bool:
	return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


## Sends `move_to`: a request to walk to a ground-plane point.
##
## An intent, never a fact. Nothing is validated here on purpose: the server
## owns what is legal, and a client-side bounds check would only hide the
## `error` reply that proves the server is doing its job.
func send_move_to(x: float, z: float, seq: int = 0) -> Error:
	return _send(move_to_frame(x, z, _intent_seq(seq)))


## Sends `pickup`: a request to take a ground item. **M1.**
##
## `item` is an item id, never a player id (`PROTOCOL.md`, "Entity naming").
## Taking an item is a walk followed by a pending action on the server, so
## nothing here happens immediately and the reply is a `path` like any other.
func send_pickup(item_id: int, seq: int = 0) -> Error:
	return _send(pickup_frame(item_id, _intent_seq(seq)))


## Sends `drop`: a request to drop whatever is in an inventory slot. **M1.**
##
## [param slot] is a position in this client's cached inventory, [b]not[/b] an
## item id. The server looks up what is actually there, which is the
## intents-never-facts rule at its most load-bearing: a client that could name
## the item id could name one it does not own (`PROTOCOL.md`, `drop`).
func send_drop(slot: int, seq: int = 0) -> Error:
	return _send(drop_frame(slot, _intent_seq(seq)))


## Sends `equip`: a request to wear whatever is in a bag slot. **M3c.**
func send_equip(slot: int, seq: int = 0) -> Error:
	return _send(equip_frame(slot, _intent_seq(seq)))


## Sends `unequip`: a request to take off a worn slot. **M3c.**
func send_unequip(worn: String, seq: int = 0) -> Error:
	return _send(unequip_frame(worn, _intent_seq(seq)))


## The next `seq` this client will stamp, after the last welcome.
func next_seq() -> int:
	return _next_seq


## Consumes one `seq` and advances the counter. A test that asserts the exact
## bytes of a stamped frame without an open socket uses this with the static
## builders below.
func take_seq() -> int:
	var n := _next_seq
	_next_seq += 1
	return n


## The three client-to-server frames, as the dictionaries [method _send] would
## encode.
##
## Public and static so that a test can assert on the exact bytes a call would
## put on the wire without needing a socket to be open, which is the only way to
## check a sender against `PROTOCOL.md` before the server that answers it exists.
##
## [param seq] of 0 (the default) omits the field, which is the unsequenced
## form. A number of at least 1 is written onto the body.
static func move_to_frame(x: float, z: float, seq: int = 0) -> Dictionary:
	return {"move_to": _intent_body({"x": x, "z": z}, seq)}


static func pickup_frame(item_id: int, seq: int = 0) -> Dictionary:
	return {"pickup": _intent_body({"item": item_id}, seq)}


static func drop_frame(slot: int, seq: int = 0) -> Dictionary:
	return {"drop": _intent_body({"slot": slot}, seq)}


static func equip_frame(slot: int, seq: int = 0) -> Dictionary:
	return {"equip": _intent_body({"slot": slot}, seq)}


static func unequip_frame(worn: String, seq: int = 0) -> Dictionary:
	return {"unequip": _intent_body({"worn": worn}, seq)}


static func _intent_body(body: Dictionary, seq: int) -> Dictionary:
	if seq >= 1:
		body["seq"] = seq
	return body


## Allocates the next number, or adopts an explicit one and advances past it.
func _intent_seq(seq: int) -> int:
	if seq < 1:
		return take_seq()
	if seq >= _next_seq:
		_next_seq = seq + 1
	return seq


func _process(_delta: float) -> void:
	if _peer == null:
		return

	# Every frame, unconditionally. The peer drives its own handshake inside
	# poll(), so a client that polls only when it believes itself connected
	# never connects at all.
	_peer.poll()

	if not _opened and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_opened = true
		_connect_deadline_msec = 0
		connected.emit()

	_drain()

	# Checked after draining: frames that arrived in the same poll as the close
	# are still delivered, in order, before the disconnect is announced.
	if not _closed and _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_announce_disconnected(_peer.get_close_code(), _peer.get_close_reason())
		return

	if (
		not _closed
		and not _opened
		and _connect_deadline_msec != 0
		and Time.get_ticks_msec() >= _connect_deadline_msec
		and _peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING
	):
		abandon()


## Emits [signal disconnected] exactly once per client, whoever noticed first.
func _announce_disconnected(code: int, reason: String) -> void:
	if _closed:
		return
	_closed = true
	_connect_deadline_msec = 0
	disconnected.emit(code, reason)


func _drain() -> void:
	while _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		# was_string_packet() describes the packet just taken, so it is only
		# meaningful here, after get_packet().
		if not _peer.was_string_packet():
			push_error("net_client: binary frame from the server; the protocol is text only")
			continue
		ingest_text_frame(packet.get_string_from_utf8())


## Decodes one text frame and emits its signal. The single entry point for
## everything that arrives, and public so a test can inject a frame the server
## cannot be made to send.
##
## Every rejection below logs loudly and drops the one frame. The connection
## survives all of them: the server is authoritative and has no client-to-server
## error channel to be told about its own bug, so tearing the session down would
## destroy the evidence and cost the player the game. Revisitable.
func ingest_text_frame(text: String) -> void:
	# JSON.parse_string returns null on malformed input rather than raising, so
	# an unchecked parse turns a protocol bug into a silent no-op.
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		push_error("net_client: frame is not valid JSON: %s" % text)
		return
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("net_client: frame is not a JSON object: %s" % text)
		return

	var frame: Dictionary = parsed
	# Compatibility rule 3: zero or more than one top-level key is a malformed
	# frame, not a forward-compatibility question, and is never interpreted.
	if frame.size() != 1:
		push_error(
			"net_client: frame must have exactly one top-level key, got %d: %s"
			% [frame.size(), text]
		)
		return

	var key: String = frame.keys()[0]
	var body: Variant = frame[key]
	if typeof(body) != TYPE_DICTIONARY:
		push_error("net_client: body of %s is not a JSON object: %s" % [key, text])
		return

	match key:
		"welcome":
			_on_welcome(body, text)
		"spawn":
			_on_spawn(body, text)
		"despawn":
			_on_despawn(body, text)
		"path":
			_on_path(body, text)
		"item_spawn":
			_on_item_spawn(body, text)
		"item_despawn":
			_on_item_despawn(body, text)
		"inventory":
			_on_inventory(body, text)
		"equipment":
			_on_equipment(body, text)
		"tick":
			_on_tick(body, text)
		"error":
			_on_error(body, text)
		_:
			# Compatibility rule 1. Loud, ignored, connection intact.
			push_warning("net_client: ignoring unknown message %s: %s" % [key, text])
			unknown_message.emit(key)


func _on_welcome(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["you", "tick_ms", "tick"], text):
		return
	if typeof(body.get("players")) != TYPE_ARRAY:
		push_error("net_client: welcome.players is missing or not an array: %s" % text)
		return

	var ids := PackedInt64Array()
	var positions := PackedVector2Array()
	for entry: Variant in body["players"] as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("net_client: welcome.players entry is not an object: %s" % text)
			return
		var state: Dictionary = entry
		if not _has_numbers(state, ["id", "x", "z"], text):
			return
		ids.append(int(state["id"]))
		# Object form: {"id":..,"x":..,"z":..}. path.points uses [x, z] instead.
		# Two encodings for one idea, deliberate and documented in PROTOCOL.md.
		positions.append(Vector2(state["x"], state["z"]))

	# M1. `items` is absent from every pre-M1 server and that is not an error:
	# no items on the wire and no items in the world are the same statement.
	# Parsed before anything is emitted, so a malformed `items` drops the whole
	# frame rather than applying half of it — this file's rule is that one bad
	# frame is dropped entire, and a `welcome` that landed its players and lost
	# its items would leave a world nobody described.
	var item_ids := PackedInt64Array()
	var item_kinds := PackedStringArray()
	var item_positions := PackedVector2Array()
	if body.has("items"):
		var raw: Variant = body["items"]
		if _is_null_list(raw, "welcome.items", text):
			# Logged and accommodated: `null` means empty, exactly as an absent
			# key does.
			raw = []
		if typeof(raw) != TYPE_ARRAY:
			push_error("net_client: welcome.items is not an array: %s" % text)
			return
		for entry: Variant in raw as Array:
			var item := _item_state(entry, "welcome.items entry", text)
			if item.is_empty():
				return
			item_ids.append(item["id"])
			item_kinds.append(item["kind"])
			item_positions.append(item["position"])

	var heartbeat_ticks := _heartbeat_ticks_of(body, text)
	_session = _session_of(body, text)
	# Every applied welcome, including a second one. A click that was on the
	# wire when the last socket died is not replayed (`PROTOCOL.md`,
	# "Sequence numbers").
	_next_seq = _last_seq_of(body, text) + 1

	welcomed.emit(
		int(body["you"]),
		int(body["tick_ms"]),
		int(body["tick"]),
		heartbeat_ticks,
		ids,
		positions,
	)
	# After `welcomed`, always: a listener rebuilds its world on that signal, so
	# items announced before it would be freed by the very frame that announced
	# them.
	welcome_items.emit(item_ids, item_kinds, item_positions)


## `welcome.heartbeat_ticks`, or 0 when it was absent, unreadable, or negative.
## Zero means liveness off, and a present-but-wrong field costs a log line
## rather than the whole `welcome` (`PROTOCOL.md`, "Clock").
static func _heartbeat_ticks_of(body: Dictionary, text: String) -> int:
	if not body.has("heartbeat_ticks"):
		return 0
	var raw: Variant = body["heartbeat_ticks"]
	if not _is_number(raw):
		push_error(
			"net_client: welcome.heartbeat_ticks is not a number; read as 0: %s" % text
		)
		return 0
	var ticks := int(raw)
	if ticks < 0:
		push_error(
			"net_client: welcome.heartbeat_ticks is negative (%d); read as 0: %s" % [ticks, text]
		)
		return 0
	return ticks


static func _session_of(body: Dictionary, text: String) -> String:
	if not body.has("session"):
		return ""
	var raw: Variant = body["session"]
	if typeof(raw) != TYPE_STRING:
		push_error("net_client: welcome.session is not a string; ignored: %s" % text)
		return ""
	return raw


## `welcome.last_seq`, or 0 when it was absent, unreadable, or negative.
## Zero means this player has never spent a sequence number.
static func _last_seq_of(body: Dictionary, text: String) -> int:
	if not body.has("last_seq"):
		return 0
	var raw: Variant = body["last_seq"]
	if not _is_number(raw):
		push_error(
			"net_client: welcome.last_seq is not a number; read as 0: %s" % text
		)
		return 0
	var last := int(raw)
	if last < 0:
		push_error(
			"net_client: welcome.last_seq is negative (%d); read as 0: %s" % [last, text]
		)
		return 0
	return last


func _on_spawn(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id", "x", "z"], text):
		return
	spawned.emit(int(body["id"]), Vector2(body["x"], body["z"]))


func _on_despawn(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id"], text):
		return
	despawned.emit(int(body["id"]))


func _on_path(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id", "start_tick", "speed"], text):
		return
	if typeof(body.get("points")) != TYPE_ARRAY:
		push_error("net_client: path.points is missing or not an array: %s" % text)
		return

	var raw: Array = body["points"]
	# A zero-point path has no position to place a walker at. One point is
	# legal and means "halt here" (PROTOCOL.md, "path").
	if raw.is_empty():
		push_error("net_client: path.points is empty: %s" % text)
		return

	var points := PackedVector2Array()
	for entry: Variant in raw:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 2:
			push_error("net_client: path.points entry is not an [x, z] pair: %s" % text)
			return
		var pair: Array = entry
		if not _is_number(pair[0]) or not _is_number(pair[1]):
			push_error("net_client: path.points entry is not numeric: %s" % text)
			return
		points.append(Vector2(pair[0], pair[1]))

	path_assigned.emit(int(body["id"]), int(body["start_tick"]), points, float(body["speed"]))


## `item_spawn`. **M1.** Same id-carrying encoding as `spawn` and
## `welcome.players`; nothing about an item is a polyline, so the packed
## `[x, z]` form never appears here (`PROTOCOL.md`, "Decoding notes").
func _on_item_spawn(body: Dictionary, text: String) -> void:
	var item := _item_state(body, "item_spawn", text)
	if item.is_empty():
		return
	item_spawned.emit(item["id"], item["kind"], item["position"])


## `item_despawn`. **M1.**
func _on_item_despawn(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id"], text):
		return
	item_despawned.emit(int(body["id"]))


## `inventory`. **M1.** A full restatement, never a patch.
##
## The two invariants checked below — an index inside `0..size - 1`, and one
## entry per slot — are the server's, stated in `PROTOCOL.md`. They are checked
## rather than assumed because a frame breaking either would put an item outside
## the very grid the same frame told this client to draw, and because a sparse
## list makes both failures invisible until something reads the slot.
func _on_inventory(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["size"], text):
		return
	var size := int(body["size"])
	if size < 0:
		push_error("net_client: inventory.size is negative (%d): %s" % [size, text])
		return
	var raw: Variant = body.get("slots")
	# `null` means empty and is logged. An absent `slots` is still missing: no
	# sender legitimately omits it, `inventory` has no pre-M1 form to be
	# compatible with, and the guard on `has` is what keeps the two apart —
	# `Dictionary.get` hands back the null rather than its default.
	if body.has("slots") and _is_null_list(raw, "inventory.slots", text):
		raw = []
	if typeof(raw) != TYPE_ARRAY:
		push_error("net_client: inventory.slots is missing or not an array: %s" % text)
		return

	var indices := PackedInt32Array()
	var kinds := PackedStringArray()
	for entry: Variant in raw as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("net_client: inventory.slots entry is not an object: %s" % text)
			return
		var occupied: Dictionary = entry
		if not _has_numbers(occupied, ["slot"], text):
			return
		if typeof(occupied.get("kind")) != TYPE_STRING:
			push_error("net_client: inventory.slots entry has no kind string: %s" % text)
			return
		var slot := int(occupied["slot"])
		if slot < 0 or slot >= size:
			push_error(
				"net_client: inventory slot %d is outside 0..%d: %s" % [slot, size - 1, text]
			)
			return
		if indices.has(slot):
			push_error("net_client: inventory names slot %d twice: %s" % [slot, text])
			return
		indices.append(slot)
		kinds.append(occupied["kind"])

	inventory_changed.emit(size, indices, kinds)


## `equipment`. **M3c.** A full restatement, never a patch.
func _on_equipment(body: Dictionary, text: String) -> void:
	var raw_worn: Variant = body.get("worn")
	if body.has("worn") and _is_null_list(raw_worn, "equipment.worn", text):
		raw_worn = []
	if typeof(raw_worn) != TYPE_ARRAY:
		push_error("net_client: equipment.worn is missing or not an array: %s" % text)
		return

	var worn_names := PackedStringArray()
	for entry: Variant in raw_worn as Array:
		if typeof(entry) != TYPE_STRING:
			push_error("net_client: equipment.worn entry is not a string: %s" % text)
			return
		worn_names.append(entry)

	var raw_slots: Variant = body.get("slots")
	if body.has("slots") and _is_null_list(raw_slots, "equipment.slots", text):
		raw_slots = []
	if typeof(raw_slots) != TYPE_ARRAY:
		push_error("net_client: equipment.slots is missing or not an array: %s" % text)
		return

	var slot_names := PackedStringArray()
	var slot_kinds := PackedStringArray()
	for entry: Variant in raw_slots as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("net_client: equipment.slots entry is not an object: %s" % text)
			return
		var occupied: Dictionary = entry
		if typeof(occupied.get("slot")) != TYPE_STRING:
			push_error("net_client: equipment.slots entry has no slot string: %s" % text)
			return
		if typeof(occupied.get("kind")) != TYPE_STRING:
			push_error("net_client: equipment.slots entry has no kind string: %s" % text)
			return
		var name: String = occupied["slot"]
		if not worn_names.has(name):
			push_error('net_client: equipment names unknown worn slot "%s": %s' % [name, text])
			return
		if slot_names.has(name):
			push_error('net_client: equipment names worn slot "%s" twice: %s' % [name, text])
			return
		slot_names.append(name)
		slot_kinds.append(occupied["kind"])

	equipment_changed.emit(worn_names, slot_names, slot_kinds)


## One `{"id":..,"kind":..,"x":..,"z":..}` object, decoded.
##
## Returns an empty dictionary when it will not parse, having logged which field
## was wrong. A successful parse is never empty, so the caller checks
## [method Dictionary.is_empty] rather than comparing against null.
func _item_state(entry: Variant, where: String, text: String) -> Dictionary:
	if typeof(entry) != TYPE_DICTIONARY:
		push_error("net_client: %s is not a JSON object: %s" % [where, text])
		return {}
	var state: Dictionary = entry
	if not _has_numbers(state, ["id", "x", "z"], text):
		return {}
	if typeof(state.get("kind")) != TYPE_STRING:
		push_error("net_client: %s has no kind string: %s" % [where, text])
		return {}
	# `id` is a 64-bit integer on the wire that arrives as a float, like every
	# other integer here.
	return {
		"id": int(state["id"]),
		"kind": state["kind"],
		"position": Vector2(state["x"], state["z"]),
	}


## `tick`. The server's heartbeat, decoded into a plain integer.
func _on_tick(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["t"], text):
		return
	tick_received.emit(int(body["t"]))


func _on_error(body: Dictionary, text: String) -> void:
	if typeof(body.get("msg")) != TYPE_STRING:
		push_error("net_client: error.msg is missing or not a string: %s" % text)
		return
	# "re" is absent rather than null when the frame could not be attributed to
	# a message, so the default is what the caller sees.
	var re: Variant = body.get("re", "")
	if typeof(re) != TYPE_STRING:
		push_error("net_client: error.re is not a string: %s" % text)
		return
	server_error.emit(re, body["msg"])


## Frames one message as text and sends it.
##
## [b]The write mode is named at every call site on purpose.[/b] The protocol is
## text frames carrying JSON; the server answers a binary frame with an error
## and closes the connection. Godot 4.7's [WebSocketPeer] has no `write_mode`
## property to set once (it was removed; the [enum WebSocketPeer.WriteMode] enum
## survives), and both [method PacketPeer.put_packet] and the default argument
## of [method WebSocketPeer.send] frame as [b]binary[/b]. So the mode is passed
## here rather than configured, and nothing in this file may use
## [method PacketPeer.put_packet].
func _send(message: Dictionary) -> Error:
	if not is_open():
		push_error("net_client: send while the socket is not open: %s" % JSON.stringify(message))
		return ERR_UNCONFIGURED
	var payload := JSON.stringify(message).to_utf8_buffer()
	return _peer.send(payload, WebSocketPeer.WRITE_MODE_TEXT)


## True when a list-valued field arrived as JSON [code]null[/code], which means
## empty. Logs loudly when it does, and is silent otherwise.
##
## [b]`null` is a server bug, and this is the one place it is accommodated.[/b]
## A Go server holding a slice that was never appended to marshals it as
## [code]null[/code] rather than [code][][/code], and it does so silently. A
## receiver that read that as "not an array" would drop the whole frame, and for
## `welcome` that means the client never joins and sits frozen forever with
## nothing wrong on either side. `PROTOCOL.md`, `inventory`, binds both halves:
## a sender never emits `null` for a list, and a receiver treats it as an absent
## key, meaning empty, and logs. That is the same call this file already makes
## about a malformed frame — the server is this client's only peer and M0 has no
## reconnect, so strictness costs the whole session and leniency costs a log line
## naming somebody else's defect.
##
## It buys nothing else. Every non-array that is not `null` returns false here
## and the caller refuses it exactly as before.
##
## [b]The check has to be this one.[/b] A JSON `null` reaches GDScript from
## [method JSON.parse_string] as a key that is [i]present[/i] and holds
## [constant TYPE_NIL], so [method Dictionary.has] is true and the default
## argument of [method Dictionary.get] is never reached. Verified against 4.7.2:
## for `{"items":null}`, `has("items")` is `true`, `typeof(d["items"])` is
## `TYPE_NIL`, and `d.get("items", [])` returns the null, not the `[]`.
static func _is_null_list(value: Variant, where: String, text: String) -> bool:
	if typeof(value) != TYPE_NIL:
		return false
	push_error(
		(
			"net_client: %s is null, which is a server bug; an empty list is []"
			+ " and never null. Read as empty: %s"
		) % [where, text]
	)
	return true


## True when every named key is present and numeric. Logs which one was not.
func _has_numbers(body: Dictionary, keys: Array, text: String) -> bool:
	for key: String in keys:
		if not body.has(key):
			push_error("net_client: %s is missing: %s" % [key, text])
			return false
		if not _is_number(body[key]):
			push_error("net_client: %s is not a number: %s" % [key, text])
			return false
	return true


## JSON numbers reach GDScript as float, but an int is accepted too rather than
## depending on which of the two a given parser build hands back.
static func _is_number(value: Variant) -> bool:
	var kind := typeof(value)
	return kind == TYPE_FLOAT or kind == TYPE_INT

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
## [b]No reconnect, no heartbeat, no sequence numbers.[/b] Those are M2 and
## `PROTOCOL.md` says so.

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
signal welcomed(
	you: int,
	tick_ms: int,
	tick: int,
	player_ids: PackedInt64Array,
	player_positions: PackedVector2Array,
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
## fail-fast doctrine is deliberately relaxed. M2 adds `{"tick":{"t":N}}` to a
## server talking to clients built today; treating that as an error would break
## every one of them.
signal unknown_message(key: String)

var _peer: WebSocketPeer = null
var _opened := false
var _closed := false


## Opens a connection. Returns [constant OK] when the socket started
## connecting, which is not the same as connected: wait for [signal connected].
##
## Calling this while a connection is already open or in flight is a caller bug
## and is refused; this object handles one connection in its lifetime, because
## reconnect is M2.
func connect_to_server(url: String) -> Error:
	if _peer != null:
		push_error("net_client: already connected to a server; use one client per connection")
		return ERR_ALREADY_IN_USE

	var peer := WebSocketPeer.new()
	var status := peer.connect_to_url(url)
	if status != OK:
		push_error("net_client: connect_to_url(%s) failed: %d" % [url, status])
		return status

	_peer = peer
	return OK


## Closes the connection. [signal disconnected] follows on a later frame, once
## the peer has finished its closing handshake.
func close(code: int = 1000, reason: String = "") -> void:
	if _peer == null:
		return
	_peer.close(code, reason)


## True between [signal connected] and [signal disconnected].
func is_open() -> bool:
	return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


## Sends `move_to`: a request to walk to a ground-plane point.
##
## An intent, never a fact. Nothing is validated here on purpose: the server
## owns what is legal, and a client-side bounds check would only hide the
## `error` reply that proves the server is doing its job.
func send_move_to(x: float, z: float) -> Error:
	return _send({"move_to": {"x": x, "z": z}})


func _process(_delta: float) -> void:
	if _peer == null:
		return

	# Every frame, unconditionally. The peer drives its own handshake inside
	# poll(), so a client that polls only when it believes itself connected
	# never connects at all.
	_peer.poll()

	if not _opened and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_opened = true
		connected.emit()

	_drain()

	# Checked after draining: frames that arrived in the same poll as the close
	# are still delivered, in order, before the disconnect is announced.
	if not _closed and _peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_closed = true
		disconnected.emit(_peer.get_close_code(), _peer.get_close_reason())


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

	welcomed.emit(int(body["you"]), int(body["tick_ms"]), int(body["tick"]), ids, positions)


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

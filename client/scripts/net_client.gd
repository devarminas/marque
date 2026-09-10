extends Node


signal connected()

signal disconnected(code: int, reason: String)

signal welcomed(
	you: int,
	tick_ms: int,
	tick: int,
	heartbeat_ticks: int,
	player_ids: PackedInt64Array,
	player_positions: PackedVector2Array,
)

signal tick_received(t: int)

signal welcome_items(
	item_ids: PackedInt64Array,
	item_kinds: PackedStringArray,
	item_positions: PackedVector2Array,
)

signal welcome_nodes(
	node_ids: PackedInt64Array,
	node_kinds: PackedStringArray,
	node_positions: PackedVector2Array,
	node_states: PackedStringArray,
)

signal welcome_npcs(
	npc_ids: PackedInt64Array,
	npc_kinds: PackedStringArray,
	npc_factions: PackedStringArray,
	npc_positions: PackedVector2Array,
	npc_hps: PackedInt32Array,
	npc_max_hps: PackedInt32Array,
)

signal spawned(id: int, position: Vector2)

signal despawned(id: int)

signal path_assigned(id: int, start_tick: int, points: PackedVector2Array, speed: float)

signal pose_received(id: int, tick: int, x: float, y: float, z: float)

signal item_spawned(id: int, kind: String, position: Vector2)

signal item_despawned(id: int)

signal node_spawned(id: int, kind: String, position: Vector2, state: String)

signal node_despawned(id: int)

signal node_state_changed(id: int, kind: String, position: Vector2, state: String)

signal npc_spawned(
	id: int,
	kind: String,
	faction: String,
	position: Vector2,
	hp: int,
	max_hp: int,
)

signal inventory_changed(
	size: int, slot_indices: PackedInt32Array, slot_kinds: PackedStringArray
)

signal equipment_changed(
	worn_names: PackedStringArray, slot_names: PackedStringArray, slot_kinds: PackedStringArray
)

signal class_changed(
	player: int,
	class_id: String,
	missing_slot_names: PackedStringArray,
	missing_slot_kinds: PackedStringArray,
	missing_tools: PackedStringArray,
)

signal skills_changed(player: int, skill_ids: PackedStringArray, levels: PackedInt32Array)

signal hp_changed(id: int, hp: int, max_hp: int)

signal mana_changed(id: int, mana: int, max_mana: int)

signal casting_changed(ability: String, progress: int, total: int)

signal dialog_changed(npc_id: int, lines: PackedStringArray, option_ids: PackedStringArray)

signal quest_log_changed(
	ids: PackedStringArray,
	titles: PackedStringArray,
	objectives: PackedStringArray,
	statuses: PackedStringArray,
)

signal party_changed(party_id: int, leader_id: int, members: PackedInt32Array)

signal party_invite_notice_changed(from_player: int)

signal server_error(re: String, message: String)

signal unknown_message(key: String)

const CONNECT_TIMEOUT_MSEC := 5000

var _peer: WebSocketPeer = null
var _opened := false
var _closed := false
var _connect_deadline_msec := 0
var _next_seq := 1
var _session := ""


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


func session_token() -> String:
	return _session


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


func close(code: int = 1000, reason: String = "") -> void:
	if _peer == null:
		return
	_peer.close(code, reason)


func abandon() -> void:
	if _peer != null:
		_peer.close(-1)
	_announce_disconnected(0, "")


func is_open() -> bool:
	return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func send_move_to(x: float, z: float, seq: int = 0) -> Error:
	return _send(move_to_frame(x, z, _intent_seq(seq)))


func send_move(dx: float, dz: float, seq: int = 0, jump: bool = false) -> Error:
	return _send(move_frame(dx, dz, _intent_seq(seq), jump))


func send_pickup(item_id: int, seq: int = 0) -> Error:
	return _send(pickup_frame(item_id, _intent_seq(seq)))


func send_gather(node_id: int, seq: int = 0) -> Error:
	return _send(gather_frame(node_id, _intent_seq(seq)))


func send_drop(slot: int, seq: int = 0) -> Error:
	return _send(drop_frame(slot, _intent_seq(seq)))


func send_equip(slot: int, seq: int = 0) -> Error:
	return _send(equip_frame(slot, _intent_seq(seq)))


func send_unequip(worn: String, seq: int = 0) -> Error:
	return _send(unequip_frame(worn, _intent_seq(seq)))


func send_use(slot: int, on: int, seq: int = 0) -> Error:
	return _send(use_frame(slot, on, _intent_seq(seq)))


func send_attack(player_id: int, seq: int = 0) -> Error:
	return _send(attack_frame(player_id, _intent_seq(seq)))


func send_cast(ability_id: String, target_id: int = 0, seq: int = 0) -> Error:
	return _send(cast_frame(ability_id, target_id, _intent_seq(seq)))


func send_respawn(seq: int = 0) -> Error:
	return _send(respawn_frame(_intent_seq(seq)))


func send_talk(npc_id: int, seq: int = 0) -> Error:
	return _send(talk_frame(npc_id, _intent_seq(seq)))


func send_dialog_option(npc_id: int, option: String, seq: int = 0) -> Error:
	return _send(dialog_option_frame(npc_id, option, _intent_seq(seq)))


func send_give(npc_id: int, slot: int, seq: int = 0) -> Error:
	return _send(give_frame(npc_id, slot, _intent_seq(seq)))


func send_party_invite(player_id: int, seq: int = 0) -> Error:
	return _send(party_invite_frame(player_id, _intent_seq(seq)))


func send_party_accept(seq: int = 0) -> Error:
	return _send(party_accept_frame(_intent_seq(seq)))


func send_party_decline(seq: int = 0) -> Error:
	return _send(party_decline_frame(_intent_seq(seq)))


func send_party_leave(seq: int = 0) -> Error:
	return _send(party_leave_frame(_intent_seq(seq)))


func next_seq() -> int:
	return _next_seq


func take_seq() -> int:
	var n := _next_seq
	_next_seq += 1
	return n


static func move_to_frame(x: float, z: float, seq: int = 0) -> Dictionary:
	return {"move_to": _intent_body({"x": x, "z": z}, seq)}


static func move_frame(dx: float, dz: float, seq: int = 0, jump: bool = false) -> Dictionary:
	var body := {"dx": dx, "dz": dz}
	if jump:
		body["jump"] = true
	return {"move": _intent_body(body, seq)}


static func pickup_frame(item_id: int, seq: int = 0) -> Dictionary:
	return {"pickup": _intent_body({"item": item_id}, seq)}


static func gather_frame(node_id: int, seq: int = 0) -> Dictionary:
	return {"gather": _intent_body({"node": node_id}, seq)}


static func drop_frame(slot: int, seq: int = 0) -> Dictionary:
	return {"drop": _intent_body({"slot": slot}, seq)}


static func equip_frame(slot: int, seq: int = 0) -> Dictionary:
	return {"equip": _intent_body({"slot": slot}, seq)}


static func unequip_frame(worn: String, seq: int = 0) -> Dictionary:
	return {"unequip": _intent_body({"worn": worn}, seq)}


static func use_frame(slot: int, on: int, seq: int = 0) -> Dictionary:
	return {"use": _intent_body({"slot": slot, "on": on}, seq)}


static func attack_frame(player_id: int, seq: int = 0) -> Dictionary:
	return {"attack": _intent_body({"player": player_id}, seq)}


static func cast_frame(ability_id: String, target_id: int = 0, seq: int = 0) -> Dictionary:
	var body := {"ability": ability_id}
	if target_id >= 1:
		body["player"] = target_id
	return {"cast": _intent_body(body, seq)}


static func respawn_frame(seq: int = 0) -> Dictionary:
	return {"respawn": _intent_body({}, seq)}


static func talk_frame(npc_id: int, seq: int = 0) -> Dictionary:
	return {"talk": _intent_body({"npc": npc_id}, seq)}


static func dialog_option_frame(npc_id: int, option: String, seq: int = 0) -> Dictionary:
	return {"dialog_option": _intent_body({"npc": npc_id, "option": option}, seq)}


static func give_frame(npc_id: int, slot: int, seq: int = 0) -> Dictionary:
	return {"give": _intent_body({"npc": npc_id, "slot": slot}, seq)}


static func party_invite_frame(player_id: int, seq: int = 0) -> Dictionary:
	return {"party_invite": _intent_body({"player": player_id}, seq)}


static func party_accept_frame(seq: int = 0) -> Dictionary:
	return {"party_accept": _intent_body({}, seq)}


static func party_decline_frame(seq: int = 0) -> Dictionary:
	return {"party_decline": _intent_body({}, seq)}


static func party_leave_frame(seq: int = 0) -> Dictionary:
	return {"party_leave": _intent_body({}, seq)}


static func _intent_body(body: Dictionary, seq: int) -> Dictionary:
	if seq >= 1:
		body["seq"] = seq
	return body


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
		"pose":
			_on_pose(body, text)
		"item_spawn":
			_on_item_spawn(body, text)
		"item_despawn":
			_on_item_despawn(body, text)
		"node_spawn":
			_on_node_spawn(body, text)
		"node_despawn":
			_on_node_despawn(body, text)
		"node_state":
			_on_node_state(body, text)
		"npc_spawn":
			_on_npc_spawn(body, text)
		"inventory":
			_on_inventory(body, text)
		"equipment":
			_on_equipment(body, text)
		"class":
			_on_class(body, text)
		"skills":
			_on_skills(body, text)
		"hp":
			_on_hp(body, text)
		"mana":
			_on_mana(body, text)
		"casting":
			_on_casting(body, text)
		"dialog":
			_on_dialog(body, text)
		"quest_log":
			_on_quest_log(body, text)
		"party":
			_on_party(body, text)
		"party_invite_notice":
			_on_party_invite_notice(body, text)
		"tick":
			_on_tick(body, text)
		"error":
			_on_error(body, text)
		_:
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
	var hp_ids := PackedInt64Array()
	var hps := PackedInt32Array()
	var max_hps := PackedInt32Array()
	var mana_ids := PackedInt64Array()
	var manas := PackedInt32Array()
	var max_manas := PackedInt32Array()
	for entry: Variant in body["players"] as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("net_client: welcome.players entry is not an object: %s" % text)
			return
		var state: Dictionary = entry
		if not _has_numbers(state, ["id", "x", "z"], text):
			return
		ids.append(int(state["id"]))
		positions.append(Vector2(state["x"], state["z"]))
		var pair: Array = []
		var hp_status := _read_hit_points(state, text, pair)
		if hp_status == ERR_INVALID_DATA:
			return
		if hp_status == OK:
			var hit: Vector2i = pair[0]
			hp_ids.append(int(state["id"]))
			hps.append(hit.x)
			max_hps.append(hit.y)
		var mana_pair: Array = []
		var mana_status := _read_mana(state, text, mana_pair)
		if mana_status == ERR_INVALID_DATA:
			return
		if mana_status == OK:
			var mana_hit: Vector2i = mana_pair[0]
			mana_ids.append(int(state["id"]))
			manas.append(mana_hit.x)
			max_manas.append(mana_hit.y)

	var item_ids := PackedInt64Array()
	var item_kinds := PackedStringArray()
	var item_positions := PackedVector2Array()
	if body.has("items"):
		var raw: Variant = body["items"]
		if _is_null_list(raw, "welcome.items", text):
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

	var node_ids := PackedInt64Array()
	var node_kinds := PackedStringArray()
	var node_positions := PackedVector2Array()
	var node_states := PackedStringArray()
	if body.has("nodes"):
		var raw_nodes: Variant = body["nodes"]
		if _is_null_list(raw_nodes, "welcome.nodes", text):
			raw_nodes = []
		if typeof(raw_nodes) != TYPE_ARRAY:
			push_error("net_client: welcome.nodes is not an array: %s" % text)
			return
		for entry: Variant in raw_nodes as Array:
			var node := _node_state(entry, "welcome.nodes entry", text)
			if node.is_empty():
				return
			node_ids.append(node["id"])
			node_kinds.append(node["kind"])
			node_positions.append(node["position"])
			node_states.append(node["state"])

	var npc_ids := PackedInt64Array()
	var npc_kinds := PackedStringArray()
	var npc_factions := PackedStringArray()
	var npc_positions := PackedVector2Array()
	var npc_hps := PackedInt32Array()
	var npc_max_hps := PackedInt32Array()
	if body.has("npcs"):
		var raw_npcs: Variant = body["npcs"]
		if _is_null_list(raw_npcs, "welcome.npcs", text):
			raw_npcs = []
		if typeof(raw_npcs) != TYPE_ARRAY:
			push_error("net_client: welcome.npcs is not an array: %s" % text)
			return
		for entry: Variant in raw_npcs as Array:
			var npc := _npc_state(entry, "welcome.npcs entry", text)
			if npc.is_empty():
				return
			npc_ids.append(npc["id"])
			npc_kinds.append(npc["kind"])
			npc_factions.append(npc["faction"])
			npc_positions.append(npc["position"])
			npc_hps.append(npc["hp"])
			npc_max_hps.append(npc["max_hp"])

	var heartbeat_ticks := _heartbeat_ticks_of(body, text)
	_session = _session_of(body, text)
	_next_seq = _last_seq_of(body, text) + 1

	welcomed.emit(
		int(body["you"]),
		int(body["tick_ms"]),
		int(body["tick"]),
		heartbeat_ticks,
		ids,
		positions,
	)
	for index in hp_ids.size():
		hp_changed.emit(int(hp_ids[index]), hps[index], max_hps[index])
	for index in mana_ids.size():
		mana_changed.emit(int(mana_ids[index]), manas[index], max_manas[index])
	welcome_items.emit(item_ids, item_kinds, item_positions)
	welcome_nodes.emit(node_ids, node_kinds, node_positions, node_states)
	welcome_npcs.emit(npc_ids, npc_kinds, npc_factions, npc_positions, npc_hps, npc_max_hps)


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
	var id := int(body["id"])
	spawned.emit(id, Vector2(body["x"], body["z"]))
	var pair: Array = []
	var hp_status := _read_hit_points(body, text, pair)
	if hp_status == ERR_INVALID_DATA:
		return
	if hp_status == OK:
		var hit: Vector2i = pair[0]
		hp_changed.emit(id, hit.x, hit.y)
	var mana_pair: Array = []
	var mana_status := _read_mana(body, text, mana_pair)
	if mana_status == ERR_INVALID_DATA:
		return
	if mana_status == OK:
		var mana_hit: Vector2i = mana_pair[0]
		mana_changed.emit(id, mana_hit.x, mana_hit.y)


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


func _on_pose(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id", "tick", "x", "y", "z"], text):
		return
	pose_received.emit(
		int(body["id"]),
		int(body["tick"]),
		float(body["x"]),
		float(body["y"]),
		float(body["z"]),
	)


func _on_item_spawn(body: Dictionary, text: String) -> void:
	var item := _item_state(body, "item_spawn", text)
	if item.is_empty():
		return
	item_spawned.emit(item["id"], item["kind"], item["position"])


func _on_item_despawn(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id"], text):
		return
	item_despawned.emit(int(body["id"]))


func _on_node_spawn(body: Dictionary, text: String) -> void:
	var node := _node_state(body, "node_spawn", text)
	if node.is_empty():
		return
	node_spawned.emit(node["id"], node["kind"], node["position"], node["state"])


func _on_node_despawn(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id"], text):
		return
	node_despawned.emit(int(body["id"]))


func _on_node_state(body: Dictionary, text: String) -> void:
	var node := _node_state(body, "node_state", text)
	if node.is_empty():
		return
	node_state_changed.emit(node["id"], node["kind"], node["position"], node["state"])


func _on_npc_spawn(body: Dictionary, text: String) -> void:
	var npc := _npc_state(body, "npc_spawn", text)
	if npc.is_empty():
		return
	npc_spawned.emit(
		npc["id"],
		npc["kind"],
		npc["faction"],
		npc["position"],
		npc["hp"],
		npc["max_hp"],
	)


func _on_inventory(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["size"], text):
		return
	var size := int(body["size"])
	if size < 0:
		push_error("net_client: inventory.size is negative (%d): %s" % [size, text])
		return
	var raw: Variant = body.get("slots")
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


func _on_class(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["player"], text):
		return
	if not body.has("class") or typeof(body["class"]) != TYPE_STRING:
		push_error("net_client: class.class is missing or not a string: %s" % text)
		return

	var missing_slot_names := PackedStringArray()
	var missing_slot_kinds := PackedStringArray()
	var missing_tools := PackedStringArray()
	if body.has("missing"):
		if typeof(body["missing"]) != TYPE_DICTIONARY:
			push_error("net_client: class.missing is not an object: %s" % text)
			return
		var missing: Dictionary = body["missing"]
		var raw_slots: Variant = missing.get("slots", [])
		if _is_null_list(raw_slots, "class.missing.slots", text):
			return
		if typeof(raw_slots) != TYPE_ARRAY:
			push_error("net_client: class.missing.slots is missing or not an array: %s" % text)
			return
		for entry: Variant in raw_slots as Array:
			if typeof(entry) != TYPE_DICTIONARY:
				push_error("net_client: class.missing.slots entry is not an object: %s" % text)
				return
			var slot_entry: Dictionary = entry
			if typeof(slot_entry.get("slot", null)) != TYPE_STRING:
				push_error("net_client: class.missing.slots entry has no slot string: %s" % text)
				return
			if typeof(slot_entry.get("kind", null)) != TYPE_STRING:
				push_error("net_client: class.missing.slots entry has no kind string: %s" % text)
				return
			missing_slot_names.append(String(slot_entry["slot"]))
			missing_slot_kinds.append(String(slot_entry["kind"]))
		var raw_tools: Variant = missing.get("tools", [])
		if _is_null_list(raw_tools, "class.missing.tools", text):
			return
		if typeof(raw_tools) != TYPE_ARRAY:
			push_error("net_client: class.missing.tools is missing or not an array: %s" % text)
			return
		for entry: Variant in raw_tools as Array:
			if typeof(entry) != TYPE_STRING:
				push_error("net_client: class.missing.tools entry is not a string: %s" % text)
				return
			missing_tools.append(String(entry))

	class_changed.emit(
		int(body["player"]),
		String(body["class"]),
		missing_slot_names,
		missing_slot_kinds,
		missing_tools,
	)


func _on_skills(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["player"], text):
		return
	if typeof(body.get("skills")) != TYPE_ARRAY:
		push_error("net_client: skills.skills is missing or not an array: %s" % text)
		return

	var skill_ids := PackedStringArray()
	var levels := PackedInt32Array()
	for entry: Variant in body["skills"] as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("net_client: skills.skills entry is not an object: %s" % text)
			return
		var skill_entry: Dictionary = entry
		if typeof(skill_entry.get("id", null)) != TYPE_STRING:
			push_error("net_client: skills.skills entry has no id string: %s" % text)
			return
		if not _has_numbers(skill_entry, ["xp", "level"], text):
			return
		skill_ids.append(String(skill_entry["id"]))
		levels.append(int(skill_entry["level"]))

	skills_changed.emit(int(body["player"]), skill_ids, levels)


func _on_hp(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id", "hp", "max_hp"], text):
		return
	hp_changed.emit(int(body["id"]), int(body["hp"]), int(body["max_hp"]))


func _on_mana(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id", "mana", "max_mana"], text):
		return
	mana_changed.emit(int(body["id"]), int(body["mana"]), int(body["max_mana"]))


func _on_casting(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["progress", "total"], text):
		return
	if typeof(body.get("ability", null)) != TYPE_STRING:
		push_error("net_client: casting.ability must be a string: %s" % text)
		return
	casting_changed.emit(String(body["ability"]), int(body["progress"]), int(body["total"]))


static func _read_hit_points(state: Dictionary, text: String, out: Array) -> Error:
	out.clear()
	var has_hp := state.has("hp")
	var has_max := state.has("max_hp")
	if not has_hp and not has_max:
		return ERR_DOES_NOT_EXIST
	if not has_hp or not has_max:
		push_error("net_client: hp and max_hp must both be present: %s" % text)
		return ERR_INVALID_DATA
	if not _is_number(state["hp"]) or not _is_number(state["max_hp"]):
		push_error("net_client: hp and max_hp must be numbers: %s" % text)
		return ERR_INVALID_DATA
	out.append(Vector2i(int(state["hp"]), int(state["max_hp"])))
	return OK


static func _read_mana(state: Dictionary, text: String, out: Array) -> Error:
	out.clear()
	var has_mana := state.has("mana")
	var has_max := state.has("max_mana")
	if not has_mana and not has_max:
		return ERR_DOES_NOT_EXIST
	if not has_mana or not has_max:
		push_error("net_client: mana and max_mana must both be present: %s" % text)
		return ERR_INVALID_DATA
	if not _is_number(state["mana"]) or not _is_number(state["max_mana"]):
		push_error("net_client: mana and max_mana must be numbers: %s" % text)
		return ERR_INVALID_DATA
	out.append(Vector2i(int(state["mana"]), int(state["max_mana"])))
	return OK


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
	return {
		"id": int(state["id"]),
		"kind": state["kind"],
		"position": Vector2(state["x"], state["z"]),
	}


func _node_state(entry: Variant, where: String, text: String) -> Dictionary:
	if typeof(entry) != TYPE_DICTIONARY:
		push_error("net_client: %s is not a JSON object: %s" % [where, text])
		return {}
	var state: Dictionary = entry
	if not _has_numbers(state, ["id", "x", "z"], text):
		return {}
	if typeof(state.get("kind")) != TYPE_STRING:
		push_error("net_client: %s has no kind string: %s" % [where, text])
		return {}
	if typeof(state.get("state")) != TYPE_STRING:
		push_error("net_client: %s has no state string: %s" % [where, text])
		return {}
	var node_state: String = state["state"]
	if node_state != "full" and node_state != "depleted":
		push_error(
			'net_client: %s state must be "full" or "depleted", got "%s": %s'
			% [where, node_state, text]
		)
		return {}
	return {
		"id": int(state["id"]),
		"kind": state["kind"],
		"position": Vector2(state["x"], state["z"]),
		"state": node_state,
	}


func _npc_state(entry: Variant, where: String, text: String) -> Dictionary:
	if typeof(entry) != TYPE_DICTIONARY:
		push_error("net_client: %s is not a JSON object: %s" % [where, text])
		return {}
	var state: Dictionary = entry
	if not _has_numbers(state, ["id", "x", "z", "hp", "max_hp"], text):
		return {}
	if typeof(state.get("kind")) != TYPE_STRING:
		push_error("net_client: %s has no kind string: %s" % [where, text])
		return {}
	if typeof(state.get("faction")) != TYPE_STRING:
		push_error("net_client: %s has no faction string: %s" % [where, text])
		return {}
	var faction: String = state["faction"]
	if faction != "friendly" and faction != "hostile" and faction != "neutral":
		push_error(
			'net_client: %s faction must be "friendly", "hostile", or "neutral", got "%s": %s'
			% [where, faction, text]
		)
		return {}
	return {
		"id": int(state["id"]),
		"kind": state["kind"],
		"faction": faction,
		"position": Vector2(state["x"], state["z"]),
		"hp": int(state["hp"]),
		"max_hp": int(state["max_hp"]),
	}


func _on_dialog(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["npc"], text):
		return
	var npc_id := int(body["npc"])
	if npc_id <= 0:
		push_error("net_client: dialog.npc must be >= 1, got %d: %s" % [npc_id, text])
		return

	var raw_lines: Variant = body.get("lines")
	if body.has("lines") and _is_null_list(raw_lines, "dialog.lines", text):
		raw_lines = []
	if typeof(raw_lines) != TYPE_ARRAY:
		push_error("net_client: dialog.lines is missing or not an array: %s" % text)
		return
	var lines := PackedStringArray()
	for entry: Variant in raw_lines as Array:
		if typeof(entry) != TYPE_STRING:
			push_error("net_client: dialog.lines entry is not a string: %s" % text)
			return
		lines.append(String(entry))

	var raw_options: Variant = body.get("options")
	if body.has("options") and _is_null_list(raw_options, "dialog.options", text):
		raw_options = []
	if typeof(raw_options) != TYPE_ARRAY:
		push_error("net_client: dialog.options is missing or not an array: %s" % text)
		return
	var option_ids := PackedStringArray()
	for entry: Variant in raw_options as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("net_client: dialog.options entry is not an object: %s" % text)
			return
		var option: Dictionary = entry
		if typeof(option.get("id")) != TYPE_STRING:
			push_error("net_client: dialog.options entry has no id string: %s" % text)
			return
		var option_id: String = option["id"]
		if option_id.is_empty():
			push_error("net_client: dialog.options entry has an empty id: %s" % text)
			return
		if option_ids.has(option_id):
			push_error('net_client: dialog.options names id "%s" twice: %s' % [option_id, text])
			return
		option_ids.append(option_id)

	dialog_changed.emit(npc_id, lines, option_ids)


func _on_quest_log(body: Dictionary, text: String) -> void:
	var raw_quests: Variant = body.get("quests")
	if body.has("quests") and _is_null_list(raw_quests, "quest_log.quests", text):
		raw_quests = []
	if typeof(raw_quests) != TYPE_ARRAY:
		push_error("net_client: quest_log.quests is missing or not an array: %s" % text)
		return

	var ids := PackedStringArray()
	var titles := PackedStringArray()
	var objectives := PackedStringArray()
	var statuses := PackedStringArray()
	for entry: Variant in raw_quests as Array:
		if typeof(entry) != TYPE_DICTIONARY:
			push_error("net_client: quest_log.quests entry is not an object: %s" % text)
			return
		var quest: Dictionary = entry
		if typeof(quest.get("id")) != TYPE_STRING:
			push_error("net_client: quest_log.quests entry has no id string: %s" % text)
			return
		var quest_id: String = quest["id"]
		if quest_id.is_empty():
			push_error("net_client: quest_log.quests entry has an empty id: %s" % text)
			return
		if ids.has(quest_id):
			push_error('net_client: quest_log.quests names id "%s" twice: %s' % [quest_id, text])
			return
		if typeof(quest.get("title")) != TYPE_STRING:
			push_error("net_client: quest_log.quests entry has no title string: %s" % text)
			return
		if typeof(quest.get("objective")) != TYPE_STRING:
			push_error("net_client: quest_log.quests entry has no objective string: %s" % text)
			return
		if typeof(quest.get("status")) != TYPE_STRING:
			push_error("net_client: quest_log.quests entry has no status string: %s" % text)
			return
		var status: String = quest["status"]
		if status != "active" and status != "complete":
			push_error(
				'net_client: quest_log.quests status must be "active" or "complete", got "%s": %s'
				% [status, text]
			)
			return
		ids.append(quest_id)
		titles.append(quest["title"])
		objectives.append(quest["objective"])
		statuses.append(status)

	quest_log_changed.emit(ids, titles, objectives, statuses)


func _on_party(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["id", "leader"], text):
		return
	var raw_members: Variant = body.get("members")
	if body.has("members") and _is_null_list(raw_members, "party.members", text):
		raw_members = []
	if typeof(raw_members) != TYPE_ARRAY:
		push_error("net_client: party.members is missing or not an array: %s" % text)
		return

	var party_id := int(body["id"])
	var leader_id := int(body["leader"])
	var members := PackedInt32Array()
	var seen := {}
	for entry: Variant in raw_members as Array:
		if not _is_number(entry):
			push_error("net_client: party.members entry is not a number: %s" % text)
			return
		var member_id := int(entry)
		if member_id < 1:
			push_error("net_client: party.members entry must be >= 1, got %d: %s" % [member_id, text])
			return
		if seen.has(member_id):
			push_error("net_client: party.members names id %d twice: %s" % [member_id, text])
			return
		seen[member_id] = true
		members.append(member_id)

	if party_id == 0 and leader_id == 0 and members.is_empty():
		party_changed.emit(0, 0, members)
		return
	if party_id < 1:
		push_error("net_client: party.id must be >= 1 when membership is set: %s" % text)
		return
	if leader_id < 1:
		push_error("net_client: party.leader must be >= 1 when membership is set: %s" % text)
		return
	if members.is_empty():
		push_error("net_client: party.members is empty while id/leader are set: %s" % text)
		return
	if not seen.has(leader_id):
		push_error("net_client: party.leader %d is not in members: %s" % [leader_id, text])
		return

	party_changed.emit(party_id, leader_id, members)


func _on_party_invite_notice(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["from"], text):
		return
	var from_player := int(body["from"])
	if from_player < 0:
		push_error("net_client: party_invite_notice.from must be >= 0: %s" % text)
		return
	party_invite_notice_changed.emit(from_player)


func _on_tick(body: Dictionary, text: String) -> void:
	if not _has_numbers(body, ["t"], text):
		return
	tick_received.emit(int(body["t"]))


func _on_error(body: Dictionary, text: String) -> void:
	if typeof(body.get("msg")) != TYPE_STRING:
		push_error("net_client: error.msg is missing or not a string: %s" % text)
		return
	var re: Variant = body.get("re", "")
	if typeof(re) != TYPE_STRING:
		push_error("net_client: error.re is not a string: %s" % text)
		return
	server_error.emit(re, body["msg"])


func _send(message: Dictionary) -> Error:
	if not is_open():
		push_error("net_client: send while the socket is not open: %s" % JSON.stringify(message))
		return ERR_UNCONFIGURED
	var payload := JSON.stringify(message).to_utf8_buffer()
	return _peer.send(payload, WebSocketPeer.WRITE_MODE_TEXT)


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


func _has_numbers(body: Dictionary, keys: Array, text: String) -> bool:
	for key: String in keys:
		if not body.has(key):
			push_error("net_client: %s is missing: %s" % [key, text])
			return false
		if not _is_number(body[key]):
			push_error("net_client: %s is not a number: %s" % [key, text])
			return false
	return true


static func _is_number(value: Variant) -> bool:
	var kind := typeof(value)
	return kind == TYPE_FLOAT or kind == TYPE_INT

extends Node

## The join: network state drives avatars, and a ground click sends an intent.
##
## Everything under this node already existed. `net_client.gd` moves frames,
## `tick_clock.gd` estimates the server's tick, `polyline_walker.gd` turns a
## path into a position, `player_avatar.tscn` is a body that walks one, and
## `ground_picker.gd` turns a cursor into a ground coordinate. None of them
## knows about any of the others. This script is the only place that does.
##
## [b]It is authored in [code]main.tscn[/code], not an autoload and not built in
## [method Node._ready].[/b] There is exactly one of it per world, so it is
## static content and belongs in the scene file (CLAUDE.md, "Scene authoring").
## An autoload would be worse for three separate reasons: the connection's
## lifetime is the scene's, not the process's; a process-global socket would
## survive [method SceneTree.change_scene_to_file] into the next test suite; and
## a singleton makes a two-client test impossible in one process, which is
## exactly the test this unit exists to write.
##
## [b]The local player is not special.[/b] The server broadcasts `path` to
## everyone including the mover (PROTOCOL.md, `path`), so this client's own
## avatar is server-driven exactly like anybody else's. The only difference is
## where the node comes from: the local body is authored in [code]main.tscn[/code]
## as [code]Player[/code] because there is always exactly one of it and the
## camera rig has to have something to follow from frame zero, while remote
## bodies are instanced here because how many players are online is genuine
## runtime information. Once [code]welcome[/code] arrives, both are ordinary
## entries in the same registry and every applier below treats them alike.
##
## [b]Connecting.[/b] Nothing is connected unless a server is named on the
## command line:
##
## [codeblock]
## godot --path client -- --server ws://127.0.0.1:8080/ws
## [/codeblock]
##
## There is deliberately no default endpoint and no environment-variable
## fallback. `main.tscn` is instanced by three different test scenes, and a
## scene that dials a socket the moment it is instanced would have every one of
## them join the world behind the suite's back. Revisitable the moment there is
## a launcher or a connect screen; M0 has neither, and STANDING-ORDERS.md
## forbids adding one.
##
## [b]Two registries, and they share nothing.[/b] Players live in
## [member _avatars] and ground items in [member _items]. Item ids and player
## ids are separate sequences in separate spaces (PROTOCOL.md, "Identity"), so
## item 1 and player 1 are unrelated things and no lookup here is reachable from
## the wrong one. One dictionary keyed by a bare integer would have made that
## bug free to write and expensive to find.
##
## Typed by [code]preload[/code] rather than by global [code]class_name[/code]
## throughout, per NOTES.md, "Godot authoring traps".

const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const GroundItemScene := preload("res://scenes/ground_item.tscn")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const TickClock := preload("res://scripts/tick_clock.gd")

## Command-line flag naming the websocket URL, as `--server <url>` after the
## engine's own `--` separator.
const SERVER_ARG := "--server"

## Heartbeats of silence tolerated before the socket is abandoned
## (`PROTOCOL.md`, "Clock").
const LIVENESS_HEARTBEATS := 3

## First reconnect wait after the socket dies (`PROTOCOL.md`, "Clock").
const RECONNECT_BACKOFF_START_MSEC := 500
## Cap of the doubling backoff (`PROTOCOL.md`, "Clock").
const RECONNECT_BACKOFF_CAP_MSEC := 5000

## Emitted once `welcome` has been applied: the clock is anchored, this client
## knows its own id, and every player the server listed has a body.
signal joined(you: int)

## Emitted whenever a heartbeat moved the clock.
##
## [param delta] is `t` minus this client's own estimate at receipt, so it is
## positive when the client was running behind the server.
signal clock_corrected(delta: int, at_tick: int)

## Emitted when the server went silent past the liveness window and the socket
## was abandoned.
##
## [param silent_msec] is the configured window, not a measured elapsed time.
signal server_unresponsive(silent_msec: int)

## Emitted when a reconnect attempt is scheduled. [param delay_msec] is the wait
## before the next [method connect_to_server], not a measured elapsed time.
signal reconnect_scheduled(delay_msec: int)

## Emitted when a second `welcome` names the same player this session already was.
signal resumed(you: int)

## Emitted when a `welcome` names a different player than this session held.
signal identity_lost(was: int, now: int)

## Emitted whenever a ground click is forwarded as a `move_to`, whether or not
## the socket was open to carry it.
##
## The intent is observable so that the click path can be asserted without a
## server. Proving the click actually moves the player needs a server and is a
## different test.
signal move_to_requested(x: float, z: float)

## Emitted whenever a click on an item is forwarded as a `pickup`. **M1.**
##
## [param item_id] is an item id, and it is a key of [member _items] rather than
## anything read off the node the click landed on: see [method _on_item_clicked].
## A click on a body this session has no registry entry for emits nothing at
## all, so this signal firing is itself the claim that the id is one the server
## named.
signal pickup_requested(item_id: int)

## Emitted whenever a click on an occupied inventory slot is forwarded as a
## `drop`. **M1.**
##
## [param slot] is a slot index, never an item id (`PROTOCOL.md`, `drop`).
signal drop_requested(slot: int)

## Emitted whenever a bag slot is forwarded as `equip`. **M3c.**
signal equip_requested(slot: int)

## Emitted whenever an occupied worn slot is forwarded as `unequip`. **M3c.**
signal unequip_requested(worn: String)

## The [code]net_client.gd[/code] node. Authored as this node's child in
## [code]main.tscn[/code]; it needs to be in the tree because it polls its
## socket from [method Node._process].
@export var net: Node
## The authored local body, an instance of [code]player_avatar.tscn[/code].
## [code]CameraRig.target[/code] points at the same node.
@export var local_player: Node3D
## Container the remote bodies are instanced into.
@export var remote_players: Node3D
## Container the ground item bodies are instanced into. Authored in
## [code]main.tscn[/code] alongside [member remote_players], because there is
## exactly one of it per world and static content belongs in the scene file
## (CLAUDE.md). Its [i]children[/i] are runtime, which is why they are instanced.
@export var ground_items: Node3D
## The [code]ground_picker.gd[/code] node whose clicks become intents.
@export var ground_picker: Node
## The [code]inventory_panel.gd[/code] node the `inventory` message drives.
## Authored in [code]main.tscn[/code] under the [code]UI[/code] layer, because
## there is exactly one inventory panel per world (CLAUDE.md). Only its slots
## are runtime, and the panel builds those itself.
@export var inventory_panel: Node
## The [code]equipment_panel.gd[/code] node the `equipment` message drives.
@export var equipment_panel: Node

var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _panel: InventoryPanelScript = null
var _equipment: EquipmentPanelScript = null
var _local: PlayerAvatarScript = null
var _clock := TickClock.new()
## This client's own player id, or 0 before `welcome`.
var _you := 0
## `welcome.tick_ms`, or 0 before `welcome`. Every walker is built from it.
var _tick_ms := 0
## `welcome.heartbeat_ticks`, or 0 when the server named none.
var _heartbeat_ticks := 0
## Monotonic milliseconds by which a `tick` must have arrived, or 0 when no
## liveness timer is armed.
var _liveness_deadline_msec := 0
var _connection_over := false
var _base_url := ""
var _token := ""
var _backoff_steps := 0
var _reconnect_at_msec := 0
var _logout_requested := false
## Player id to [code]player_avatar.gd[/code]. The local player is in here too,
## under its own id, pointing at the authored node.
var _avatars := {}
## Item id to [code]ground_item.gd[/code]. A separate space from
## [member _avatars]: see the class docs.
var _items := {}


func _ready() -> void:
	_net = net as NetClientScript
	if _net == null:
		push_error("Session.net must point at a node running net_client.gd")
		return
	_local = local_player as PlayerAvatarScript
	if _local == null:
		push_error("Session.local_player must point at a player_avatar.tscn instance")
		return
	if remote_players == null:
		push_error("Session.remote_players must point at a container node")
		return
	if ground_items == null:
		push_error("Session.ground_items must point at a container node")
		return

	_net.welcomed.connect(_on_welcomed)
	_net.welcome_items.connect(_on_welcome_items)
	_net.tick_received.connect(_on_tick_received)
	_net.spawned.connect(_on_spawned)
	_net.despawned.connect(_on_despawned)
	_net.path_assigned.connect(_on_path_assigned)
	_net.item_spawned.connect(_on_item_spawned)
	_net.item_despawned.connect(_on_item_despawned)
	_net.inventory_changed.connect(_on_inventory_changed)
	_net.equipment_changed.connect(_on_equipment_changed)
	_net.server_error.connect(_on_server_error)
	_net.disconnected.connect(_on_disconnected)

	_picker = ground_picker as GroundPickerScript
	if _picker == null:
		push_error("Session.ground_picker must point at a node running ground_picker.gd")
	else:
		_picker.ground_clicked.connect(_on_ground_clicked)
		_picker.item_clicked.connect(_on_item_clicked)

	_panel = inventory_panel as InventoryPanelScript
	if _panel == null:
		push_error("Session.inventory_panel must point at a node running inventory_panel.gd")
	else:
		_panel.slot_activated.connect(_on_slot_activated)
		_panel.equip_requested.connect(_on_equip_requested)

	_equipment = equipment_panel as EquipmentPanelScript
	if _equipment == null:
		push_error("Session.equipment_panel must point at a node running equipment_panel.gd")
	else:
		_equipment.worn_activated.connect(_on_worn_activated)
		_equipment.equip_from_bag.connect(_on_equip_from_bag)

	var url := _server_from_command_line()
	if not url.is_empty():
		connect_to_server(url)


## Opens the connection. After the socket dies this is called again with the
## last `welcome.session` on the URL (`PROTOCOL.md`, "When the connection dies").
func connect_to_server(url: String) -> Error:
	if _net == null:
		push_error("Session.connect_to_server: no net client")
		return ERR_UNCONFIGURED
	_base_url = NetClientScript.url_with_session(url, "")
	_logout_requested = false
	_connection_over = false
	_reconnect_at_msec = 0
	_backoff_steps = 0
	print("session: connecting to ", _base_url)
	var status := _net.connect_to_server(url)
	if status != OK:
		_schedule_reconnect()
	return status


## Stops reconnecting and sends a close frame. Logout, not a dropped socket.
func close() -> void:
	_logout_requested = true
	_reconnect_at_msec = 0
	if _net != null:
		_net.close()


## `welcome.session` last applied, or "".
func session_token() -> String:
	return _token


## The wait before reconnect attempt [param step], 0-based.
static func reconnect_backoff_msec(step: int) -> int:
	var n := maxi(step, 0)
	if n > 30:
		return RECONNECT_BACKOFF_CAP_MSEC
	return mini(RECONNECT_BACKOFF_START_MSEC * (1 << n), RECONNECT_BACKOFF_CAP_MSEC)


## This client's own player id, or 0 before `welcome`.
func own_id() -> int:
	return _you


## True once `welcome` has been applied.
func has_joined() -> bool:
	return _you != 0


## The clock every avatar in this session drives itself from.
func tick_clock() -> TickClock:
	return _clock


## The body for [param id], or null if this session has never heard of it.
func avatar_for(id: int) -> PlayerAvatarScript:
	var avatar: PlayerAvatarScript = _avatars.get(id)
	return avatar


## Every player id this session currently has a body for, ascending.
func known_ids() -> Array:
	var ids := _avatars.keys()
	ids.sort()
	return ids


## The ground item body for [param id], or null if this session has never heard
## of it.
##
## [param id] is an item id. Handing this a player id is a category error and
## finds nothing, which is the point of the two registries being separate.
func item_for(id: int) -> GroundItemScript:
	var item: GroundItemScript = _items.get(id)
	return item


## Every item id this session currently has a body for, ascending.
func known_item_ids() -> Array:
	var ids := _items.keys()
	ids.sort()
	return ids


## Sends a `move_to` for a ground-plane point, as a ground click would.
##
## Public so that a scripted client can drive the same path a click drives
## without synthesising an input event.
func request_move_to(x: float, z: float) -> void:
	move_to_requested.emit(x, z)
	if _net == null or not _net.is_open():
		push_warning("session: click at (%f, %f) dropped, the socket is not open" % [x, z])
		return
	_net.send_move_to(x, z)


## Sends `pickup` for a ground item, as a click on that item's body would. **M1.**
##
## [param item_id] must already be in this session's item registry. An id the
## server has not named is refused here, loudly, and nothing reaches the wire:
## the client has zero authority and inventing an id is the purest form of
## claiming some.
##
## [b]Nothing else happens.[/b] No path is drawn, no body is removed, and no
## inventory slot is filled. A pickup is a walk plus a pending action on the
## server (`PROTOCOL.md`, *Pickup*), so the walk arrives as an ordinary `path`
## and the item leaves the world when `item_despawn` says it did. A client that
## took the body away on click would be right most of the time and would show
## the loser of a contested pickup an item vanishing that they never got.
##
## Public so that a scripted client can drive the same path a click drives
## without synthesising an input event.
func request_pickup(item_id: int) -> void:
	if item_for(item_id) == null:
		push_warning("session: pickup for item %d, which this client does not know; ignoring"
			% item_id)
		return
	pickup_requested.emit(item_id)
	if _net == null or not _net.is_open():
		push_warning("session: pickup of item %d dropped, the socket is not open" % item_id)
		return
	_net.send_pickup(item_id)


## Sends `drop` for an inventory slot, as a click on that slot would. **M1.**
##
## [param slot] is an index into the inventory this client was last told it has,
## never an item id: the server looks up what is actually there, which is the
## intents-never-facts rule at its most load-bearing (`PROTOCOL.md`, `drop`).
##
## The panel is not changed here. It changes when the `inventory` the server
## sends back says it changed, and not before.
func request_drop(slot: int) -> void:
	if slot < 0:
		push_error("session: drop for slot %d; slot indices start at 0" % slot)
		return
	drop_requested.emit(slot)
	if _net == null or not _net.is_open():
		push_warning("session: drop of slot %d dropped, the socket is not open" % slot)
		return
	_net.send_drop(slot)


## Sends `equip` for a bag slot, as a right-click or drag would. **M3c.**
func request_equip(slot: int) -> void:
	if slot < 0:
		push_error("session: equip for slot %d; slot indices start at 0" % slot)
		return
	equip_requested.emit(slot)
	if _net == null or not _net.is_open():
		push_warning("session: equip of slot %d dropped, the socket is not open" % slot)
		return
	_net.send_equip(slot)


## Sends `unequip` for a worn slot, as activating it would. **M3c.**
func request_unequip(worn: String) -> void:
	if worn.is_empty():
		push_error("session: unequip needs a worn slot name")
		return
	unequip_requested.emit(worn)
	if _net == null or not _net.is_open():
		push_warning('session: unequip of "%s" dropped, the socket is not open' % worn)
		return
	_net.send_unequip(worn)


## `welcome`. The whole world, restated.
##
## Applied by rebuilding rather than by patching: `welcome` is the complete
## description of the world as of its tick, so anything this session believed
## beforehand is stale by definition. Rebuilding is also what makes a second
## `welcome` — which M0 never sends, and which M2's reconnect will — land
## correctly instead of leaving a ghost behind.
##
## [b]No path is waited for.[/b] Every listed player gets a body at the position
## `welcome` states, and a walker that has no path yet. A player standing still
## is never mentioned again, and a client that expected one `path` per listed
## player would wait forever for one that is never coming (PROTOCOL.md, `path`).
func _on_welcomed(
	you: int,
	tick_ms: int,
	tick: int,
	heartbeat_ticks: int,
	player_ids: PackedInt64Array,
	player_positions: PackedVector2Array,
) -> void:
	if player_ids.size() != player_positions.size():
		push_error("session: welcome ids and positions disagree in length; ignoring the frame")
		return

	var previous_you := _you
	var token := ""
	if _net != null:
		token = _net.session_token()

	_forget_everyone()
	# The inventory is not part of `welcome` — it is private to one player and
	# arrives as its own message inside the same atomic step (PROTOCOL.md,
	# `welcome`) — so the panel is emptied here and refilled a frame later by
	# the `inventory` that follows. Leaving the old one up would show a previous
	# session's contents as if the server had just restated them.
	if _panel != null:
		_panel.clear()
	_you = you
	_token = token
	_tick_ms = tick_ms
	_clock.anchor(tick, tick_ms)
	# `welcome` is a tick-bearing frame, so it opens the liveness window rather
	# than only configuring it (PROTOCOL.md, "Clock").
	_heartbeat_ticks = heartbeat_ticks
	_connection_over = false
	_reconnect_at_msec = 0
	_backoff_steps = 0
	_rearm_liveness()

	for index in player_ids.size():
		var id := int(player_ids[index])
		var avatar := _ensure_avatar(id)
		if avatar == null:
			continue
		var ground := player_positions[index]
		avatar.teleport_to(ground.x, ground.y)

	if not _avatars.has(_you):
		# The server always lists the client itself (PROTOCOL.md, `welcome`).
		# If it ever stops, the local body still has to be usable.
		push_error("session: welcome.players did not include our own id %d" % _you)
		var self_avatar := _ensure_avatar(_you)
		if self_avatar != null:
			self_avatar.teleport_to(_local.position.x, _local.position.z)

	if previous_you != 0 and previous_you == _you:
		print("session: resumed as %d at tick %d, %d player(s)" % [_you, tick, _avatars.size()])
		resumed.emit(_you)
	elif previous_you != 0:
		print("session: identity lost; was %d, now %d" % [previous_you, _you])
		identity_lost.emit(previous_you, _you)
	if previous_you != _you:
		print("session: joined as %d at tick %d, %d player(s)" % [_you, tick, _avatars.size()])
	joined.emit(_you)


## The ground items `welcome` listed. **M1.**
##
## Arrives immediately after [method _on_welcomed], which has already freed
## every body this session held. So this only builds; there is nothing left to
## clear and nothing here to make idempotent.
func _on_welcome_items(
	item_ids: PackedInt64Array,
	item_kinds: PackedStringArray,
	item_positions: PackedVector2Array,
) -> void:
	if item_ids.size() != item_kinds.size() or item_ids.size() != item_positions.size():
		push_error("session: welcome.items ids, kinds and positions disagree in length; ignoring")
		return

	for index in item_ids.size():
		var body := _ensure_item(int(item_ids[index]), item_kinds[index])
		if body == null:
			continue
		var ground := item_positions[index]
		body.place_at(ground.x, ground.y)

	if not _items.is_empty():
		print("session: %d ground item(s) in the world" % _items.size())


## `tick`, the server's heartbeat (`PROTOCOL.md`, "Clock").
func _on_tick_received(t: int) -> void:
	if not _clock.is_anchored():
		push_error("session: tick %d before welcome; ignoring" % t)
		return
	if t < 0:
		push_error("session: tick %d is negative; dropping the heartbeat" % t)
		return

	var estimate_at_receipt := _clock.estimated_tick()
	_rearm_liveness()
	if t == estimate_at_receipt:
		return

	var delta := t - estimate_at_receipt
	_clock.anchor(t, _tick_ms)
	print(correction_line(delta, t))
	clock_corrected.emit(delta, t)


## The correction line, whose format is `PROTOCOL.md`'s, "Clock", verbatim.
static func correction_line(delta: int, at_tick: int) -> String:
	return "session: clock corrected by %+d tick(s) at heartbeat %d" % [delta, at_tick]


func is_liveness_armed() -> bool:
	return _liveness_deadline_msec != 0


## Reopens the liveness window from now, or leaves it shut (`PROTOCOL.md`,
## "Clock").
func _rearm_liveness() -> void:
	if _connection_over or _heartbeat_ticks <= 0 or _tick_ms <= 0:
		_liveness_deadline_msec = 0
		return
	_liveness_deadline_msec = Time.get_ticks_msec() + _liveness_window_msec()


func _liveness_window_msec() -> int:
	return LIVENESS_HEARTBEATS * _heartbeat_ticks * _tick_ms


## The window that has just run out, or 0 while one is still open. Disarms as it
## returns, so an expiry is claimed exactly once and cannot be fired on twice.
func _claim_expired_window() -> int:
	if _liveness_deadline_msec == 0 or Time.get_ticks_msec() < _liveness_deadline_msec:
		return 0
	_liveness_deadline_msec = 0
	return _liveness_window_msec()


func _process(_delta: float) -> void:
	_maybe_reconnect()
	var window := _claim_expired_window()
	if window == 0:
		return
	push_error(
		(
			"session: no tick for %d ms (%d heartbeat(s) of %d tick(s) at %d ms);"
			+ " abandoning the socket"
		) % [window, LIVENESS_HEARTBEATS, _heartbeat_ticks, _tick_ms]
	)
	server_unresponsive.emit(window)
	_net.abandon()


## `item_spawn`. **M1.** Idempotent: an item id already known is replaced, never
## doubled (PROTOCOL.md, "Ordering and the join race").
##
## Replacing rather than repositioning is deliberate. A repeat may carry a
## different `kind`, and a body that kept its old material would draw an acorn
## where the server said something else lies.
func _on_item_spawned(id: int, kind: String, spawn_position: Vector2) -> void:
	# Nothing reaches a connection before its `welcome` (PROTOCOL.md, "Ordering
	# and the join race"), so this is defence against a broken peer rather than
	# a flow. Building the body anyway would put something in the world that no
	# `welcome` has yet described, and the next one would silently free it.
	if not _clock.is_anchored():
		push_error("session: item_spawn for %d before welcome; ignoring" % id)
		return
	if _items.has(id):
		push_warning("session: item_spawn for known item %d replaces the existing body" % id)
		_forget_item(id)
	var body := _ensure_item(id, kind)
	if body == null:
		return
	body.place_at(spawn_position.x, spawn_position.y)


## `item_despawn`. **M1.** An unknown item id is logged and ignored, never an
## error: a client that took an item and a client that watched it be taken can
## both be told, and only one of them is surprised.
func _on_item_despawned(id: int) -> void:
	if not _items.has(id):
		push_warning("session: item_despawn for unknown item %d; ignoring" % id)
		return
	_forget_item(id)


## `spawn`. Idempotent: an id already known is replaced, never doubled
## (PROTOCOL.md, "Ordering and the join race").
func _on_spawned(id: int, spawn_position: Vector2) -> void:
	if not _clock.is_anchored():
		push_error("session: spawn for %d before welcome; ignoring" % id)
		return
	if id == _you:
		# Never sent: a joining client learns its own existence from welcome.
		push_error("session: spawn carried our own id %d; repositioning instead" % id)
		_local.teleport_to(spawn_position.x, spawn_position.y)
		return
	if _avatars.has(id):
		push_warning("session: spawn for known player %d replaces the existing body" % id)
		_forget(id)
	var avatar := _ensure_avatar(id)
	if avatar == null:
		return
	avatar.teleport_to(spawn_position.x, spawn_position.y)


## `despawn`. An unknown id is logged and ignored, never an error.
func _on_despawned(id: int) -> void:
	if id == _you:
		push_error("session: despawn carried our own id %d; ignoring" % id)
		return
	if not _avatars.has(id):
		push_warning("session: despawn for unknown player %d; ignoring" % id)
		return
	_forget(id)


## `path`. An unknown id is logged and ignored, never an error.
##
## A one-element `points` array is legal and means halt; the walker holds at the
## final point of a polyline, so nothing here needs to special-case it.
func _on_path_assigned(
	id: int, start_tick: int, points: PackedVector2Array, speed: float
) -> void:
	var avatar: PlayerAvatarScript = _avatars.get(id)
	if avatar == null:
		push_warning("session: path for unknown player %d; ignoring" % id)
		return
	avatar.follow_path(points, start_tick, speed)


## The server refused something this client sent. For a log, not for branching.
func _on_server_error(re: String, message: String) -> void:
	push_warning('session: server refused "%s": %s' % [re, message])


func _on_disconnected(code: int, reason: String) -> void:
	_connection_over = true
	_liveness_deadline_msec = 0
	var resume := not _logout_requested and not _base_url.is_empty()
	if resume:
		push_warning(
			'session: disconnected, code %d "%s"; freezing, will reconnect' % [code, reason]
		)
		_schedule_reconnect()
		return
	push_warning('session: disconnected, code %d "%s"; freezing' % [code, reason])


func _schedule_reconnect() -> void:
	var delay := reconnect_backoff_msec(_backoff_steps)
	_backoff_steps += 1
	_reconnect_at_msec = Time.get_ticks_msec() + delay
	print("session: reconnecting in %.1fs" % (delay / 1000.0))
	reconnect_scheduled.emit(delay)


func _maybe_reconnect() -> void:
	if _reconnect_at_msec == 0 or Time.get_ticks_msec() < _reconnect_at_msec:
		return
	_reconnect_at_msec = 0
	var url := NetClientScript.url_with_session(_base_url, _token)
	print("session: connecting to ", _base_url)
	var status := _net.connect_to_server(url)
	if status != OK:
		_schedule_reconnect()


func _on_ground_clicked(x: float, z: float) -> void:
	request_move_to(x, z)


## A left click that met a ground item before it met the ground. **M1.**
##
## [b]The id comes from the registry, not from the node.[/b] The picker hands
## over the body it hit and this looks that body up in [member _items], so the
## id that reaches the wire is a key the server itself named in a `welcome`,
## `item_spawn`, or `welcome.items`. Reading an `item_id` property off the node
## instead would put whatever that node claimed on the wire, and a body this
## session never registered — one left behind by a bug, or built by a test —
## would become a `pickup` for an item that may belong to somebody else's id
## space entirely.
func _on_item_clicked(body: Node3D) -> void:
	var item := body as GroundItemScript
	if item == null:
		push_error("session: the picker reported a click on %s, which is not a ground item" % body)
		return
	var id := _id_of_item_body(item)
	if id == 0:
		push_warning(
			"session: clicked an item body this session has no registry entry for (%s); ignoring"
			% item.name
		)
		return
	request_pickup(id)


## A click on an occupied inventory slot. **M1.**
func _on_slot_activated(slot: int) -> void:
	request_drop(slot)


func _on_equip_requested(slot: int) -> void:
	request_equip(slot)


func _on_equip_from_bag(slot: int) -> void:
	request_equip(slot)


func _on_worn_activated(worn: String) -> void:
	request_unequip(worn)


## `inventory`. **M1.** This client's own inventory, restated in full.
##
## Handed straight to the panel. Nothing is cached here: a second copy of the
## inventory in this script would be a cache of a cache, and the panel is
## already only a view of what the server last said.
func _on_inventory_changed(
	size: int, slot_indices: PackedInt32Array, slot_kinds: PackedStringArray
) -> void:
	if _panel == null:
		push_error("session: inventory arrived with no panel to draw it")
		return
	_panel.apply(size, slot_indices, slot_kinds)


## `equipment`. **M3c.** This client's own worn equipment, restated in full.
func _on_equipment_changed(
	worn_names: PackedStringArray, slot_names: PackedStringArray, slot_kinds: PackedStringArray
) -> void:
	if _equipment == null:
		push_error("session: equipment arrived with no panel to draw it")
		return
	_equipment.apply(worn_names, slot_names, slot_kinds)


## The body for [param id], creating it if this session has not seen it before.
##
## The local body is the authored node; every other body is an instance of
## [code]player_avatar.tscn[/code] parented under [member remote_players].
## Both get the same clock, so both advance themselves from the same anchored
## estimate every frame and this script never touches a transform.
func _ensure_avatar(id: int) -> PlayerAvatarScript:
	var existing: PlayerAvatarScript = _avatars.get(id)
	if existing != null:
		return existing
	if id <= 0:
		push_error("session: player ids start at 1, got %d" % id)
		return null
	if _tick_ms <= 0:
		push_error("session: cannot build a body for %d before welcome states tick_ms" % id)
		return null

	var avatar: PlayerAvatarScript = _local
	if id != _you:
		avatar = PlayerAvatarScene.instantiate() as PlayerAvatarScript
		if avatar == null:
			push_error("session: player_avatar.tscn did not instantiate as a PlayerAvatar")
			return null
		avatar.name = "Player%d" % id
	avatar.configure(id, _tick_ms)
	avatar.clock = _clock
	if id != _you:
		remote_players.add_child(avatar)
	_avatars[id] = avatar
	return avatar


## Drops one body. The local one is never freed — it is authored content and the
## camera follows it — so it is only unbound.
func _forget(id: int) -> void:
	var avatar: PlayerAvatarScript = _avatars.get(id)
	if avatar == null:
		return
	_avatars.erase(id)
	if avatar == _local:
		_local.clock = null
		return
	# Removed from the tree before it is queued, so a caller that counts
	# RemotePlayers' children in the same frame sees the truth.
	var parent := avatar.get_parent()
	if parent != null:
		parent.remove_child(avatar)
	avatar.queue_free()


## The body for item [param id], creating it if this session has not seen it
## before.
##
## Every item body is an instance of [code]ground_item.tscn[/code] parented
## under [member ground_items]; there is no authored one, because unlike the
## local player there is never guaranteed to be an item and nothing follows one.
##
## An unknown [param kind] is not refused. It is handed to the body, which draws
## it magenta and keeps going (PROTOCOL.md, `item_spawn`), because unknown kinds
## are how content is added without a client release and a client that dropped
## them would render an incomplete world silently.
func _ensure_item(id: int, kind: String) -> GroundItemScript:
	var existing: GroundItemScript = _items.get(id)
	if existing != null:
		return existing
	if id <= 0:
		push_error("session: item ids start at 1, got %d" % id)
		return null

	var body := GroundItemScene.instantiate() as GroundItemScript
	if body == null:
		push_error("session: ground_item.tscn did not instantiate as a GroundItem")
		return null
	body.name = "Item%d" % id
	# Configured before it enters the tree, so it is never drawn for a frame in
	# the wrong colour.
	body.configure(id, kind)
	ground_items.add_child(body)
	_items[id] = body
	return body


## The item id [param body] is registered under, or 0 when it is registered
## under none. Item ids start at 1 (PROTOCOL.md, "Identity"), so 0 is not one.
##
## A linear scan over at most a world's worth of ground items, run once per
## click on one. Keying a second dictionary by body would be a second thing to
## keep in step with the first, for a saving nobody can measure.
func _id_of_item_body(body: GroundItemScript) -> int:
	for id: int in _items:
		if _items[id] == body:
			return id
	return 0


## Drops one item body. Unlike a player body there is no authored case: every
## one of these was instanced here, so every one is freed here.
func _forget_item(id: int) -> void:
	var body: GroundItemScript = _items.get(id)
	if body == null:
		return
	_items.erase(id)
	# Removed from the tree before it is queued, so a caller that counts
	# GroundItems' children in the same frame sees the truth.
	var parent := body.get_parent()
	if parent != null:
		parent.remove_child(body)
	body.queue_free()


## Everything this session believes about the world, dropped.
##
## Called only from [method _on_welcomed]. A `welcome` is the whole world
## restated, so it frees every item body as well as every player body: anything
## believed beforehand is stale by definition (PROTOCOL.md, `welcome`). M0 never
## sends a second `welcome` and M2's reconnect will, which is why this is written
## and tested now rather than discovered then.
func _forget_everyone() -> void:
	for id: int in _avatars.keys():
		_forget(id)
	for id: int in _items.keys():
		_forget_item(id)


## The websocket URL from `--server <url>`, or "" when it was not given.
##
## [method OS.get_cmdline_user_args] is everything after the engine's own `--`,
## so nothing here can collide with a Godot option.
static func _server_from_command_line() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(SERVER_ARG)
	if index == -1:
		return ""
	if index + 1 >= args.size():
		push_error("session: %s needs a websocket url after it" % SERVER_ARG)
		return ""
	return args[index + 1]

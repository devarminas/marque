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
## Typed by [code]preload[/code] rather than by global [code]class_name[/code]
## throughout, per NOTES.md, "Godot authoring traps".

const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const TickClock := preload("res://scripts/tick_clock.gd")

## Command-line flag naming the websocket URL, as `--server <url>` after the
## engine's own `--` separator.
const SERVER_ARG := "--server"

## Emitted once `welcome` has been applied: the clock is anchored, this client
## knows its own id, and every player the server listed has a body.
signal joined(you: int)

## Emitted whenever a ground click is forwarded as a `move_to`, whether or not
## the socket was open to carry it.
##
## The intent is observable so that the click path can be asserted without a
## server. Proving the click actually moves the player needs a server and is a
## different test.
signal move_to_requested(x: float, z: float)

## The [code]net_client.gd[/code] node. Authored as this node's child in
## [code]main.tscn[/code]; it needs to be in the tree because it polls its
## socket from [method Node._process].
@export var net: Node
## The authored local body, an instance of [code]player_avatar.tscn[/code].
## [code]CameraRig.target[/code] points at the same node.
@export var local_player: Node3D
## Container the remote bodies are instanced into.
@export var remote_players: Node3D
## The [code]ground_picker.gd[/code] node whose clicks become intents.
@export var ground_picker: Node

var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _local: PlayerAvatarScript = null
var _clock := TickClock.new()
## This client's own player id, or 0 before `welcome`.
var _you := 0
## `welcome.tick_ms`, or 0 before `welcome`. Every walker is built from it.
var _tick_ms := 0
## Player id to [code]player_avatar.gd[/code]. The local player is in here too,
## under its own id, pointing at the authored node.
var _avatars := {}


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

	_net.welcomed.connect(_on_welcomed)
	_net.spawned.connect(_on_spawned)
	_net.despawned.connect(_on_despawned)
	_net.path_assigned.connect(_on_path_assigned)
	_net.server_error.connect(_on_server_error)
	_net.disconnected.connect(_on_disconnected)

	_picker = ground_picker as GroundPickerScript
	if _picker == null:
		push_error("Session.ground_picker must point at a node running ground_picker.gd")
	else:
		_picker.ground_clicked.connect(_on_ground_clicked)

	var url := _server_from_command_line()
	if not url.is_empty():
		connect_to_server(url)


## Opens the connection. One connection per session, because reconnect is M2.
func connect_to_server(url: String) -> Error:
	if _net == null:
		push_error("Session.connect_to_server: no net client")
		return ERR_UNCONFIGURED
	print("session: connecting to ", url)
	return _net.connect_to_server(url)


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
	player_ids: PackedInt64Array,
	player_positions: PackedVector2Array,
) -> void:
	if player_ids.size() != player_positions.size():
		push_error("session: welcome ids and positions disagree in length; ignoring the frame")
		return

	_forget_everyone()
	_you = you
	_tick_ms = tick_ms
	# PROTOCOL.md, "Clock": anchored from welcome against a monotonic source,
	# never accumulated from frame deltas.
	_clock.anchor(tick, tick_ms)

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

	print("session: joined as %d at tick %d, %d player(s)" % [_you, tick, _avatars.size()])
	joined.emit(_you)


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


## M0 has no reconnect (PROTOCOL.md, "Deliberately absent"), so there is nothing
## to do but say so loudly.
##
## The world is deliberately left standing rather than cleared. A frozen last
## known state is a worse lie than an empty one only if nobody is told, and this
## is the telling; an empty field would look like everyone logged out. There is
## no UI in M0 to say it better. Revisitable when M2 adds reconnect.
func _on_disconnected(code: int, reason: String) -> void:
	push_warning('session: disconnected, code %d "%s"; M0 does not reconnect' % [code, reason])


func _on_ground_clicked(x: float, z: float) -> void:
	request_move_to(x, z)


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


func _forget_everyone() -> void:
	for id: int in _avatars.keys():
		_forget(id)


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

extends Node3D

## The second registry: ground item bodies, driven by scripted frames.
##
## [b]No server.[/b] Every frame here is handed to [code]main.tscn[/code]'s own
## decoder through [code]net_client.gd[/code]'s public
## [code]ingest_text_frame[/code], so this suite is green before M1's Go half
## exists and stays green independently of it. That is what makes the client
## half of M1 verifiable on its own.
##
## The thing under test is [code]main.tscn[/code] itself, so every assertion is
## about the scene the game ships rather than a rig assembled for the occasion.
##
## The wire layer is the other half and lives in
## [code]test_item_protocol.gd[/code], which needs no tree at all.

const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const Assertions := preload("res://tests/assertions.gd")

## Tolerance for a position that should be exact. Absorbs the float32 round trip
## through a transform and nothing else.
const EXACT_EPSILON := 0.002

## Green is Pickup, magenta is missing-asset (NOTES.md, "Color as semantics").
## Compared channel by channel within this, which is wide enough to survive a
## tweak to the exact shade and narrow enough that green can never pass for
## magenta.
const CHANNEL_EPSILON := 0.25

## A player capsule is 1.8 units tall. An item that is not obviously not a
## player has to be well under that, and this is the number the screenshot
## criterion is really asserting.
const MAX_ITEM_HEIGHT := 1.0
## The axe model stands ~1.24 units tall on its rest lift. Still far under a
## player, but taller than the box, so it gets its own bound.
const MAX_MODEL_HEIGHT := 1.3

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _container: Node3D = null


## Suite contract, polled by `run_tests.gd`. Reports; never quits.
func is_finished() -> bool:
	return _finished


func get_failures() -> PackedStringArray:
	return _assertions.failures


func get_assertion_count() -> int:
	return _assertions.assertion_count


func _ready() -> void:
	_root = MainScene.instantiate() as Node3D
	_root.name = "ItemsClient"
	_world.add_child(_root)
	_session = _root.get_node("Session") as SessionScript
	_net = _root.get_node("Session/Net") as NetClientScript
	_container = _root.get_node("GroundItems") as Node3D

	# main.tscn's Session resolves its exported node paths in _ready, and a
	# suite that asserts before that reads nulls that look like scene bugs.
	await get_tree().process_frame
	await get_tree().process_frame

	print("== items: the second registry, no server ==")
	_test_the_container_is_authored()
	_test_welcome_builds_item_bodies()
	_test_item_ids_are_a_separate_space_from_player_ids()
	_test_item_spawn_is_idempotent()
	_test_item_despawn()
	await _test_an_unknown_kind_is_magenta()
	_test_an_axe_draws_its_model()
	_test_a_malformed_item_frame_changes_nothing()
	_test_a_second_welcome_frees_items_as_well_as_players()
	_test_welcome_without_items()

	print(
		"ITEMS RAN: %d assertions, %d failed"
		% [_assertions.assertion_count, _assertions.failures.size()]
	)
	_finished = true


## CLAUDE.md, "Scene authoring": the container is static content and is authored
## in `main.tscn` beside `RemotePlayers`. A script that created it in `_ready`
## would be a scene edit written in the wrong language.
func _test_the_container_is_authored() -> void:
	_check(_container != null, "main.tscn authors a GroundItems container")
	_check(
		_container != null and _container.get_child_count() == 0,
		"which starts empty, because how many items exist is runtime information",
	)
	_check(
		_session != null and _session.known_item_ids().is_empty(),
		"and the session believes in no items before welcome",
	)
	_check(
		_session != null and _session.item_for(1) == null,
		"and item_for finds nothing for any id",
	)


## `welcome.items` is the world's ground items and builds a body for every one.
func _test_welcome_builds_item_bodies() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":142,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0},{"id":2,"x":5.0,"z":-3.0}],'
		+ '"items":[{"id":7,"kind":"acorn","x":3.0,"z":-2.0},'
		+ '{"id":9,"kind":"acorn","x":-1.5,"z":4.25}]}}'
	)

	_check(
		_session.known_item_ids() == [7, 9],
		"both listed items get a body, got %s" % [_session.known_item_ids()],
	)
	_check(
		_container.get_child_count() == 2,
		"two bodies were instanced, got %d" % _container.get_child_count(),
	)
	var body: GroundItemScript = _session.item_for(7)
	if _check(body != null, "the body for item 7 exists"):
		_check(
			body.get_parent() == _container,
			"and hangs off the GroundItems container, not RemotePlayers",
		)
		_check(body.item_id == 7, "carrying its item id, got %d" % body.item_id)
		_check(body.kind == "acorn", 'carrying its kind, got "%s"' % body.kind)
	_check_ground(7, Vector2(3.0, -2.0), "the body sits where welcome states")
	_check_ground(9, Vector2(-1.5, 4.25), "and so does the second one")

	# PROTOCOL.md, "Coordinates": y never appears on the wire, so it comes from
	# the same place the player avatar's does.
	var mine: PlayerAvatarScript = _session.avatar_for(1)
	if _check(mine != null and body != null, "both a player and an item exist to compare"):
		_check(
			is_equal_approx(body.position.y, mine.ground_y),
			"an item's y is the ground the avatar stands on, got %f" % body.position.y,
		)

	# The screenshot criterion, as a regression guard: an item is not a capsule.
	if body != null:
		var bounds := body.local_bounds()
		_check(
			bounds.size.y < MAX_ITEM_HEIGHT,
			"an item body is far shorter than a 1.8-unit player capsule, got %f" % bounds.size.y,
		)
		_check(
			bounds.position.y >= -EXACT_EPSILON,
			"and rests on the ground rather than sinking into it, got %f" % bounds.position.y,
		)


## PROTOCOL.md, "Identity": item ids are a separate sequence in a separate
## space. Player 1 and item 1 are unrelated, and nothing may key them together.
func _test_item_ids_are_a_separate_space_from_player_ids() -> void:
	_feed('{"item_spawn":{"id":1,"kind":"acorn","x":8.0,"z":8.0}}')

	var item: GroundItemScript = _session.item_for(1)
	var player: PlayerAvatarScript = _session.avatar_for(1)
	_check(item != null, "item 1 has a body")
	_check(player != null, "player 1 has a body")
	_check(
		item != null and player != null and item != player,
		"and they are different bodies: the two id spaces never meet",
	)
	_check(
		_session.known_ids() == [1, 2],
		"an item_spawn does not touch the player registry, got %s" % [_session.known_ids()],
	)
	_check(
		_session.known_item_ids() == [1, 7, 9],
		"and the item registry gains exactly one, got %s" % [_session.known_item_ids()],
	)
	_check_ground(1, Vector2(8.0, 8.0), "item 1 is where item_spawn put it")
	var here := Vector2(player.position.x, player.position.z)
	_check(
		here == Vector2(0.0, 0.0),
		"and player 1 did not move to meet it, got %v" % here,
	)

	_feed('{"item_despawn":{"id":1}}')
	_check(_session.item_for(1) == null, "despawning item 1 forgets the item")
	_check(_session.avatar_for(1) != null, "and leaves player 1 standing")


## PROTOCOL.md, "Ordering and the join race": an `item_spawn` for an id already
## known replaces rather than adding a second body.
func _test_item_spawn_is_idempotent() -> void:
	_feed('{"item_spawn":{"id":11,"kind":"acorn","x":1.0,"z":2.0}}')
	_check(_session.known_item_ids() == [7, 9, 11], "an item_spawn adds a body")
	_check(
		_container.get_child_count() == 3,
		"three bodies now, got %d" % _container.get_child_count(),
	)

	_feed('{"item_spawn":{"id":11,"kind":"acorn","x":-4.0,"z":6.0}}')
	_check(
		_container.get_child_count() == 3,
		"a repeated item_spawn replaces rather than doubling, got %d children"
		% _container.get_child_count(),
	)
	_check(_session.known_item_ids() == [7, 9, 11], "and leaves the id set alone")
	_check_ground(11, Vector2(-4.0, 6.0), "the replacement is at the new position")


## An unknown item id is logged and ignored, never an error and never a reason
## to stop.
func _test_item_despawn() -> void:
	var before := _session.known_item_ids()
	_feed('{"item_despawn":{"id":404}}')
	_check(
		_session.known_item_ids() == before,
		"an item_despawn for an unknown id changes nothing, got %s"
		% [_session.known_item_ids()],
	)
	_check(
		_container.get_child_count() == 3,
		"and invents no body, got %d" % _container.get_child_count(),
	)

	_feed('{"item_despawn":{"id":11}}')
	_check(_session.known_item_ids() == [7, 9], "an item_despawn for a known id drops the body")
	_check(
		_container.get_child_count() == 2,
		"the node leaves the tree in the same frame, got %d children"
		% _container.get_child_count(),
	)
	_check(_session.item_for(11) == null, "and the session forgets it")


## NOTES.md, "Color as semantics": green is Pickup, magenta is missing-asset.
##
## This is the path that has to work when the server learns a second kind before
## this client does, which is how content is added without a client release. A
## stale client meeting one must render it magenta and keep going, not render
## nothing and not stop.
func _test_an_unknown_kind_is_magenta() -> void:
	_feed('{"item_spawn":{"id":21,"kind":"sextant","x":0.0,"z":6.0}}')
	var stranger: GroundItemScript = _session.item_for(21)
	if not _check(stranger != null, "an unknown kind still gets a body"):
		return
	_check(stranger.kind == "sextant", "which remembers the server's name for it")
	_check(not stranger.is_kind_known(), "and knows it is a kind this client has no art for")

	var color := stranger.display_color()
	_check(
		color.r > 0.6 and color.g < 0.35 and color.b > 0.6,
		"an unknown kind draws magenta, got %s" % color,
	)

	var acorn: GroundItemScript = _session.item_for(7)
	if _check(acorn != null, "a known kind is there to compare against"):
		_check(acorn.is_kind_known(), "and is recognised")
		var known := acorn.display_color()
		_check(
			known.g > 0.5 and known.r < 0.4 and known.b < 0.4,
			"a known kind draws green, got %s" % known,
		)
		_check(
			not known.is_equal_approx(color),
			"the two are visibly different colours, not the same material twice",
		)

	# Several real frames. A body whose material was mutated rather than
	# swapped would have repainted every other item by now, because the two
	# materials are shared across every instance of the scene.
	for _frame in 5:
		await get_tree().process_frame
	var acorn_now: GroundItemScript = _session.item_for(7)
	if acorn_now != null:
		_check(
			acorn_now.display_color().g > 0.5 and acorn_now.display_color().r < 0.4,
			"and the known item is still green, so nothing mutated a shared material",
		)

	_feed('{"item_despawn":{"id":21}}')


## The one kind with real art: the box is hidden and the GLTF model stands in
## its place, resting on the ground. The click target is not touched, so the
## picker still resolves a click to the 0.5-unit box the scene authors.
func _test_an_axe_draws_its_model() -> void:
	_feed('{"item_spawn":{"id":61,"kind":"axe","x":-3.0,"z":1.0}}')
	var axe: GroundItemScript = _session.item_for(61)
	if not _check(axe != null, "an axe kind gets a body"):
		return
	_check(axe.has_model(), "which draws the axe model, not the box")
	_check(
		axe.get_node_or_null("Model") != null,
		"as a Model child, instanced from an authored scene",
	)
	var box := axe.get_node_or_null("Mesh") as MeshInstance3D
	_check(box != null and not box.visible, "and hides the box while the model stands in")
	_check(
		axe.get_node_or_null("CollisionShape3D") != null,
		"while the collision shape is untouched",
	)

	var bounds := axe.local_bounds()
	_check(
		bounds.size.y < MAX_MODEL_HEIGHT,
		"the axe is far shorter than a 1.8-unit player, got %f" % bounds.size.y,
	)
	_check(
		bounds.position.y >= -EXACT_EPSILON,
		"and rests on the ground rather than sinking into it, got %f" % bounds.position.y,
	)

	# The axe is a KNOWN kind, so its box path would have drawn green. With the
	# model standing in, display_color reads the hidden box and means nothing;
	# the colour story stays honest only if callers are told to ask has_model().
	_check(
		axe.is_kind_known(),
		"the axe is a known kind, so its colour question must be asked through has_model()",
	)

	_feed('{"item_despawn":{"id":61}}')


## PROTOCOL.md, "Compatibility": the client drops the single offending frame and
## keeps going. Here the proof is that the registry is untouched and that the
## very next good frame still lands.
func _test_a_malformed_item_frame_changes_nothing() -> void:
	var before := _session.known_item_ids()
	var children := _container.get_child_count()
	for frame: String in [
		'{"item_spawn":{"id":31,"x":1.0,"z":1.0}}',
		'{"item_spawn":{"id":31,"kind":"acorn","x":"here","z":1.0}}',
		'{"item_spawn":{"id":31,"kind":null,"x":1.0,"z":1.0}}',
		'{"item_spawn":"acorn"}',
		'not json at all',
	]:
		_feed(frame)
	_check(
		_session.known_item_ids() == before,
		"malformed item frames build nothing, got %s" % [_session.known_item_ids()],
	)
	_check(
		_container.get_child_count() == children,
		"and add no children, got %d" % _container.get_child_count(),
	)

	_feed('{"item_spawn":{"id":31,"kind":"acorn","x":1.0,"z":1.0}}')
	_check(
		_session.item_for(31) != null,
		"and the next good frame is still applied, so the session kept running",
	)
	_feed('{"item_despawn":{"id":31}}')


## PROTOCOL.md, `welcome`: a repeated `welcome` is the whole world restated, so
## it frees every item body as well as every player body. M0 never sends a second
## one and M2's reconnect will; this is written now so it is not discovered then.
func _test_a_second_welcome_frees_items_as_well_as_players() -> void:
	_check(
		_session.known_item_ids() == [7, 9] and _session.known_ids() == [1, 2],
		"there is a world to make stale, got items %s and players %s"
		% [_session.known_item_ids(), _session.known_ids()],
	)

	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":900,'
		+ '"players":[{"id":1,"x":2.0,"z":2.0}],'
		+ '"items":[{"id":50,"kind":"acorn","x":-6.0,"z":0.5}]}}'
	)

	_check(
		_session.known_item_ids() == [50],
		"the item world is exactly what the new welcome states, got %s"
		% [_session.known_item_ids()],
	)
	_check(
		_session.item_for(7) == null and _session.item_for(9) == null,
		"every item from the previous welcome is forgotten",
	)
	_check(
		_container.get_child_count() == 1,
		"and its body left the tree in the same frame, got %d children"
		% _container.get_child_count(),
	)
	_check(
		_session.known_ids() == [1],
		"the players are restated too, got %s" % [_session.known_ids()],
	)
	_check_ground(50, Vector2(-6.0, 0.5), "and the new item is where the new welcome says")


## A pre-M1 server sends a `welcome` with no `items` key at all. It must not
## crash a post-M1 client, and it must still clear the items that client held:
## no items on the wire and no items in the world are the same statement.
func _test_welcome_without_items() -> void:
	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1000,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}]}}'
	)
	_check(
		_session.known_item_ids().is_empty(),
		"a welcome with no items key leaves no items, got %s" % [_session.known_item_ids()],
	)
	_check(
		_container.get_child_count() == 0,
		"and no bodies, got %d" % _container.get_child_count(),
	)
	_check(_session.has_joined(), "while the client is still joined")
	_check(_session.known_ids() == [1], "with its players intact")

	_feed(
		'{"welcome":{"you":1,"tick_ms":150,"tick":1001,'
		+ '"players":[{"id":1,"x":0.0,"z":0.0}],"items":[]}}'
	)
	_check(
		_session.known_item_ids().is_empty(),
		"and an empty items array says the same thing, got %s" % [_session.known_item_ids()],
	)


## Hands one frame to the client's decoder as if it had arrived on the socket.
func _feed(text: String) -> void:
	_net.ingest_text_frame(text)


func _check_ground(id: int, expected: Vector2, message: String) -> void:
	var body: GroundItemScript = _session.item_for(id)
	if body == null:
		_check(false, "%s (no body for item %d)" % [message, id])
		return
	var actual := Vector2(body.position.x, body.position.z)
	_check(
		actual.distance_to(expected) < EXACT_EPSILON,
		"%s (expected %v, got %v)" % [message, expected, actual],
	)


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition

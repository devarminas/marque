extends Node3D


const MainScene := preload("res://scenes/main.tscn")
const SessionScript := preload("res://scripts/session.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const Assertions := preload("res://tests/assertions.gd")

const EXACT_EPSILON := 0.002

const CHANNEL_EPSILON := 0.25

const MAX_ITEM_HEIGHT := 1.0
const MAX_MODEL_HEIGHT := 1.3

@onready var _world: Node3D = $World

var _assertions := Assertions.new()
var _finished := false
var _root: Node3D = null
var _session: SessionScript = null
var _net: NetClientScript = null
var _container: Node3D = null


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

	var mine: PlayerAvatarScript = _session.avatar_for(1)
	if _check(mine != null and body != null, "both a player and an item exist to compare"):
		_check(
			is_equal_approx(body.position.y, mine.ground_y),
			"an item's y is the ground the avatar stands on, got %f" % body.position.y,
		)

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

	for _frame in 5:
		await get_tree().process_frame
	var acorn_now: GroundItemScript = _session.item_for(7)
	if acorn_now != null:
		_check(
			acorn_now.display_color().g > 0.5 and acorn_now.display_color().r < 0.4,
			"and the known item is still green, so nothing mutated a shared material",
		)

	_feed('{"item_despawn":{"id":21}}')


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

	_check(
		axe.is_kind_known(),
		"the axe is a known kind, so its colour question must be asked through has_model()",
	)

	_feed('{"item_despawn":{"id":61}}')


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

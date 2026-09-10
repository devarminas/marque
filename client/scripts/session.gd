extends Node


const NetClientScript := preload("res://scripts/net_client.gd")
const GroundPickerScript := preload("res://scripts/ground_picker.gd")
const PlayerAvatarScript := preload("res://scripts/player_avatar.gd")
const PlayerAvatarScene := preload("res://scenes/player_avatar.tscn")
const GroundItemScript := preload("res://scripts/ground_item.gd")
const GroundItemScene := preload("res://scenes/ground_item.tscn")
const ResourceNodeScript := preload("res://scripts/resource_node.gd")
const ResourceNodeScene := preload("res://scenes/resource_node.tscn")
const NpcDummyScript := preload("res://scripts/npc_dummy.gd")
const NpcDummyScene := preload("res://scenes/npc_dummy.tscn")
const NpcQuestGiverScene := preload("res://scenes/npc_quest_giver.tscn")
const NpcImpScene := preload("res://scenes/npc_imp.tscn")
const InventoryPanelScript := preload("res://scripts/inventory_panel.gd")
const DialogPanelScript := preload("res://scripts/dialog_panel.gd")
const GivePanelScript := preload("res://scripts/give_panel.gd")
const QuestLogPanelScript := preload("res://scripts/quest_log_panel.gd")
const PartyPanelScript := preload("res://scripts/party_panel.gd")
const EquipmentPanelScript := preload("res://scripts/equipment_panel.gd")
const HpHudScript := preload("res://scripts/hp_hud.gd")
const ClassHudScript := preload("res://scripts/class_hud.gd")
const ClassDebugScript := preload("res://scripts/class_debug.gd")
const ErrorHudScript := preload("res://scripts/error_hud.gd")
const ClassDefs := preload("res://scripts/class_defs.gd")
const DeathOverlayScript := preload("res://scripts/death_overlay.gd")
const EscMenuScript := preload("res://scripts/esc_menu.gd")
const HotbarScript := preload("res://scripts/hotbar.gd")
const AbilityDefs := preload("res://scripts/ability_defs.gd")
const CastHitFx := preload("res://scripts/cast_hit_fx.gd")
const TickClock := preload("res://scripts/tick_clock.gd")

const SERVER_ARG := "--server"

const LIVENESS_HEARTBEATS := 3

const RECONNECT_BACKOFF_START_MSEC := 500
const RECONNECT_BACKOFF_CAP_MSEC := 5000

const MOVE_INTENT_PERIOD_MSEC := 100

const REFUSAL_TEXT := {
	"gather": {
		"gather requires an active class whose skill matches this node": "usable tool not equipped",
	},
}

signal joined(you: int)

signal clock_corrected(delta: int, at_tick: int)

signal server_unresponsive(silent_msec: int)

signal reconnect_scheduled(delay_msec: int)

signal resumed(you: int)

signal identity_lost(was: int, now: int)

signal move_to_requested(x: float, z: float)

signal move_requested(dx: float, dz: float)

signal pickup_requested(item_id: int)

signal gather_requested(node_id: int)

signal attack_requested(player_id: int)

signal attack_refused(player_id: int, reason: String)

signal cast_requested(ability_id: String, target_id: int)

signal cast_effect_played(target_id: int, ability_id: String)

signal selection_changed(player_id: int)

signal drop_requested(slot: int)

signal use_requested(slot: int, on: int)

signal equip_requested(slot: int)

signal unequip_requested(worn: String)

signal talk_requested(npc_id: int)

signal dialog_option_requested(npc_id: int, option_id: String)

signal give_requested(npc_id: int, slot: int)

signal party_invite_requested(player_id: int)

signal party_accept_requested()

signal party_decline_requested()

signal party_leave_requested()

signal respawn_requested()

@export var net: Node
@export var local_player: Node3D
@export var remote_players: Node3D
@export var ground_items: Node3D
@export var resource_nodes: Node3D
@export var npcs: Node3D
@export var ground_picker: Node
@export var inventory_panel: Node
@export var dialog_panel: Node
@export var give_panel: Node
@export var quest_log_panel: Node
@export var party_panel: Node
@export var equipment_panel: Node
@export var hp_hud: Node
@export var class_hud: Node
@export var class_debug: Node
@export var error_hud: Node
@export var death_overlay: Node
@export var esc_menu: Node
@export var hotbar: Node
@export var camera_rig: Node

var _net: NetClientScript = null
var _picker: GroundPickerScript = null
var _panel: InventoryPanelScript = null
var _dialog: DialogPanelScript = null
var _give: GivePanelScript = null
var _quest_log: QuestLogPanelScript = null
var _party: PartyPanelScript = null
var _equipment: EquipmentPanelScript = null
var _hp_hud: HpHudScript = null
var _class_hud: ClassHudScript = null
var _class_debug: ClassDebugScript = null
var _error_hud: ErrorHudScript = null
var _classes: Dictionary = {}
var _skill_levels := {}
var _active_class_id := ""
var _death_overlay: DeathOverlayScript = null
var _esc_menu: EscMenuScript = null
var _hotbar: HotbarScript = null
var _hp := {}
var _mana := {}
var _local: PlayerAvatarScript = null
var _clock := TickClock.new()
var _you := 0
var _tick_ms := 0
var _heartbeat_ticks := 0
var _liveness_deadline_msec := 0
var _connection_over := false
var _base_url := ""
var _token := ""
var _backoff_steps := 0
var _reconnect_at_msec := 0
var _logout_requested := false
var _avatars := {}
var _items := {}
var _nodes := {}
var _npcs := {}
var _use_from := -1
var _bag_size := 0
var _bag_indices := PackedInt32Array()
var _bag_kinds := PackedStringArray()
var _quest_ids := PackedStringArray()
var _quest_titles := PackedStringArray()
var _quest_objectives := PackedStringArray()
var _quest_statuses := PackedStringArray()
var _give_dismissed := false
var _selected_player_id := 0
var _casts_awaiting_mana: Array = []
var _last_move_dx := 0.0
var _last_move_dz := 0.0
var _last_move_sent_msec := 0
var _move_held := false


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
	if resource_nodes == null:
		push_error("Session.resource_nodes must point at a container node")
		return
	if npcs == null:
		push_error("Session.npcs must point at a container node")
		return

	_net.welcomed.connect(_on_welcomed)
	_net.welcome_items.connect(_on_welcome_items)
	_net.welcome_nodes.connect(_on_welcome_nodes)
	_net.welcome_npcs.connect(_on_welcome_npcs)
	_net.tick_received.connect(_on_tick_received)
	_net.spawned.connect(_on_spawned)
	_net.despawned.connect(_on_despawned)
	_net.path_assigned.connect(_on_path_assigned)
	_net.item_spawned.connect(_on_item_spawned)
	_net.item_despawned.connect(_on_item_despawned)
	_net.node_spawned.connect(_on_node_spawned)
	_net.node_despawned.connect(_on_node_despawned)
	_net.node_state_changed.connect(_on_node_state_changed)
	_net.npc_spawned.connect(_on_npc_spawned)
	_net.inventory_changed.connect(_on_inventory_changed)
	_net.dialog_changed.connect(_on_dialog_changed)
	_net.quest_log_changed.connect(_on_quest_log_changed)
	_net.party_changed.connect(_on_party_changed)
	_net.party_invite_notice_changed.connect(_on_party_invite_notice_changed)
	_net.equipment_changed.connect(_on_equipment_changed)
	_net.class_changed.connect(_on_class_changed)
	_net.skills_changed.connect(_on_skills_changed)
	_net.hp_changed.connect(_on_hp_changed)
	_net.mana_changed.connect(_on_mana_changed)
	_net.server_error.connect(_on_server_error)
	_net.disconnected.connect(_on_disconnected)

	_picker = ground_picker as GroundPickerScript
	if _picker == null:
		push_error("Session.ground_picker must point at a node running ground_picker.gd")
	else:
		_picker.item_clicked.connect(_on_item_clicked)
		_picker.node_gather_clicked.connect(_on_node_gather_clicked)
		_picker.player_clicked.connect(_on_player_clicked)
		_picker.player_attack_clicked.connect(_on_player_attack_clicked)

	_panel = inventory_panel as InventoryPanelScript
	if _panel == null:
		push_error("Session.inventory_panel must point at a node running inventory_panel.gd")
	else:
		_panel.slot_activated.connect(_on_slot_activated)
		_panel.equip_requested.connect(_on_equip_requested)
		_panel.drop_requested.connect(request_drop)

	_dialog = dialog_panel as DialogPanelScript
	if _dialog == null:
		push_error("Session.dialog_panel must point at a node running dialog_panel.gd")
	else:
		_dialog.option_chosen.connect(_on_dialog_option_chosen)

	_give = give_panel as GivePanelScript
	if _give == null:
		push_error("Session.give_panel must point at a node running give_panel.gd")
	else:
		_give.offer_chosen.connect(_on_offer_chosen)
		_give.cancelled.connect(_on_give_cancelled)

	_quest_log = quest_log_panel as QuestLogPanelScript
	if _quest_log == null:
		push_error("Session.quest_log_panel must point at a node running quest_log_panel.gd")

	_party = party_panel as PartyPanelScript
	if _party == null:
		push_error("Session.party_panel must point at a node running party_panel.gd")
	else:
		_party.invite_pressed.connect(_on_party_invite_pressed)
		_party.accept_pressed.connect(_on_party_accept_pressed)
		_party.decline_pressed.connect(_on_party_decline_pressed)
		_party.leave_pressed.connect(_on_party_leave_pressed)

	_equipment = equipment_panel as EquipmentPanelScript
	if _equipment == null:
		push_error("Session.equipment_panel must point at a node running equipment_panel.gd")
	else:
		_equipment.worn_activated.connect(_on_worn_activated)
		_equipment.equip_from_bag.connect(_on_equip_from_bag)

	_hp_hud = hp_hud as HpHudScript
	if _hp_hud == null:
		push_error("Session.hp_hud must point at a node running hp_hud.gd")

	_classes = ClassDefs.load_classes()
	_class_hud = class_hud as ClassHudScript
	if _class_hud == null:
		push_error("Session.class_hud must point at a node running class_hud.gd")

	_class_debug = class_debug as ClassDebugScript
	if _class_debug == null:
		push_error("Session.class_debug must point at a node running class_debug.gd")

	_error_hud = error_hud as ErrorHudScript
	if _error_hud == null:
		push_error("Session.error_hud must point at a node running error_hud.gd")

	_death_overlay = death_overlay as DeathOverlayScript
	if _death_overlay == null:
		push_error("Session.death_overlay must point at a node running death_overlay.gd")
	else:
		_death_overlay.respawn_requested.connect(_on_respawn_requested)
	_esc_menu = esc_menu as EscMenuScript
	if _esc_menu == null:
		push_error("Session.esc_menu must point at a node running esc_menu.gd")
	else:
		_esc_menu.resume_requested.connect(_on_esc_resume_requested)
		_esc_menu.exit_requested.connect(_on_esc_exit_requested)
	_hotbar = hotbar as HotbarScript
	if _hotbar == null:
		push_error("Session.hotbar must point at a node running hotbar.gd")
	else:
		_hotbar.ability_activated.connect(_on_hotbar_ability)

	var url := _server_from_command_line()
	if not url.is_empty():
		connect_to_server(url)


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


func close() -> void:
	_logout_requested = true
	_reconnect_at_msec = 0
	if _net != null:
		_net.close()


func session_token() -> String:
	return _token


static func reconnect_backoff_msec(step: int) -> int:
	var n := maxi(step, 0)
	if n > 30:
		return RECONNECT_BACKOFF_CAP_MSEC
	return mini(RECONNECT_BACKOFF_START_MSEC * (1 << n), RECONNECT_BACKOFF_CAP_MSEC)


func own_id() -> int:
	return _you


func has_joined() -> bool:
	return _you != 0


func tick_clock() -> TickClock:
	return _clock


func avatar_for(id: int) -> PlayerAvatarScript:
	var avatar: PlayerAvatarScript = _avatars.get(id)
	return avatar


func known_ids() -> Array:
	var ids := _avatars.keys()
	ids.sort()
	return ids


func item_for(id: int) -> GroundItemScript:
	var item: GroundItemScript = _items.get(id)
	return item


func known_item_ids() -> Array:
	var ids := _items.keys()
	ids.sort()
	return ids


func node_for(id: int) -> ResourceNodeScript:
	var body: ResourceNodeScript = _nodes.get(id)
	return body


func known_node_ids() -> Array:
	var ids := _nodes.keys()
	ids.sort()
	return ids


func request_move_to(x: float, z: float) -> void:
	move_to_requested.emit(x, z)
	if _net == null or not _net.is_open():
		push_warning("session: move_to (%f, %f) dropped, the socket is not open" % [x, z])
		return
	_net.send_move_to(x, z)


func request_move(dx: float, dz: float) -> void:
	move_requested.emit(dx, dz)
	if _net == null or not _net.is_open():
		push_warning("session: move (%f, %f) dropped, the socket is not open" % [dx, dz])
		return
	_net.send_move(dx, dz)


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


func request_gather(node_id: int) -> void:
	if node_for(node_id) == null:
		push_warning(
			"session: gather for node %d, which this client does not know; ignoring" % node_id
		)
		return
	gather_requested.emit(node_id)
	if _net == null or not _net.is_open():
		push_warning("session: gather of node %d dropped, the socket is not open" % node_id)
		return
	_net.send_gather(node_id)


func request_attack(player_id: int) -> void:
	if player_id == _you:
		return
	if not _avatars.has(player_id) and not _npcs.has(player_id):
		push_warning(
			"session: attack for actor %d, which this client does not know; ignoring" % player_id
		)
		return
	var dummy: NpcDummyScript = _npcs.get(player_id)
	if dummy != null and dummy.faction != NpcDummyScript.FactionHostile:
		attack_refused.emit(player_id, "wrong_target")
		push_warning("session: attack refused for non-hostile npc %d" % player_id)
		return
	attack_requested.emit(player_id)
	if _net == null or not _net.is_open():
		push_warning("session: attack of actor %d dropped, the socket is not open" % player_id)
		return
	_net.send_attack(player_id)


func request_talk(npc_id: int) -> void:
	var dummy: NpcDummyScript = _npcs.get(npc_id)
	if dummy == null:
		push_warning(
			"session: talk for npc %d, which this client does not know; ignoring" % npc_id
		)
		return
	if (
		dummy.kind != NpcDummyScript.KindQuestGiver
		and dummy.kind != NpcDummyScript.KindImpQuestGiver
	):
		push_warning("session: talk refused for non-quest-giver npc %d" % npc_id)
		return
	talk_requested.emit(npc_id)
	if _net == null or not _net.is_open():
		push_warning("session: talk of npc %d dropped, the socket is not open" % npc_id)
		return
	_net.send_talk(npc_id)


func request_dialog_option(npc_id: int, option_id: String) -> void:
	if option_id.is_empty():
		push_error("session: dialog_option with an empty option id")
		return
	if _dialog == null or _dialog.npc_id() != npc_id:
		push_warning(
			"session: dialog_option for npc %d with no matching open dialog; ignoring" % npc_id
		)
		return
	dialog_option_requested.emit(npc_id, option_id)
	if _net == null or not _net.is_open():
		push_warning(
			"session: dialog_option %s for npc %d dropped, the socket is not open"
			% [option_id, npc_id]
		)
		return
	_net.send_dialog_option(npc_id, option_id)


func request_give(npc_id: int, slot: int) -> void:
	if slot < 0:
		push_error("session: give for slot %d; slot indices start at 0" % slot)
		return
	if _dialog == null or _dialog.npc_id() != npc_id:
		push_warning(
			"session: give for npc %d with no matching open dialog; ignoring" % npc_id
		)
		return
	if _give == null or _give.npc_id() != npc_id:
		push_warning(
			"session: give for npc %d with no matching open give panel; ignoring" % npc_id
		)
		return
	give_requested.emit(npc_id, slot)
	if _net == null or not _net.is_open():
		push_warning(
			"session: give of slot %d for npc %d dropped, the socket is not open"
			% [slot, npc_id]
		)
		return
	_net.send_give(npc_id, slot)


func request_party_invite(player_id: int) -> void:
	if player_id < 1:
		push_warning("session: party_invite needs a selected player id")
		return
	if player_id == _you:
		push_warning("session: party_invite of self ignored")
		return
	party_invite_requested.emit(player_id)
	if _net == null or not _net.is_open():
		push_warning("session: party_invite of player %d dropped, the socket is not open" % player_id)
		return
	_net.send_party_invite(player_id)


func request_party_accept() -> void:
	party_accept_requested.emit()
	if _net == null or not _net.is_open():
		push_warning("session: party_accept dropped, the socket is not open")
		return
	_net.send_party_accept()


func request_party_decline() -> void:
	party_decline_requested.emit()
	if _net == null or not _net.is_open():
		push_warning("session: party_decline dropped, the socket is not open")
		return
	_net.send_party_decline()


func request_party_leave() -> void:
	party_leave_requested.emit()
	if _net == null or not _net.is_open():
		push_warning("session: party_leave dropped, the socket is not open")
		return
	_net.send_party_leave()


func request_cast(ability_id: String) -> void:
	if ability_id.is_empty():
		return
	var target_id := _cast_target_for(ability_id)
	cast_requested.emit(ability_id, target_id)
	if _net == null or not _net.is_open():
		push_warning("session: cast %s dropped, the socket is not open" % ability_id)
		return
	if target_id < 1:
		if _net.send_cast(ability_id, 0) == OK:
			await_mana_for_cast(ability_id, 0)
		return
	if _net.send_cast(ability_id, target_id) == OK:
		await_mana_for_cast(ability_id, target_id)


func await_mana_for_cast(ability_id: String, target_id: int) -> void:
	_casts_awaiting_mana.append({"ability": ability_id, "target": target_id})


func casts_awaiting_mana_count() -> int:
	return _casts_awaiting_mana.size()


func _on_hotbar_ability(ability_id: String) -> void:
	request_cast(ability_id)


func _cast_target_for(ability_id: String) -> int:
	var catalog: Dictionary = AbilityDefs._empty_catalog()
	if _hotbar != null:
		catalog = _hotbar.catalog()
	var ability: Variant = AbilityDefs.get_ability(catalog, ability_id)
	if typeof(ability) != TYPE_DICTIONARY:
		return _selected_player_id
	var target_rule := String(ability.get("target", ""))
	if target_rule == AbilityDefs.TARGET_SELF:
		return _you
	if target_rule == AbilityDefs.TARGET_FRIENDLY:
		if _selected_player_id > 0 and _npc_faction(_selected_player_id) == NpcDummyScript.FactionFriendly:
			return _selected_player_id
		return _you
	return _selected_player_id


func _npc_faction(actor_id: int) -> String:
	var dummy: NpcDummyScript = _npcs.get(actor_id)
	if dummy == null:
		return ""
	return dummy.faction


func request_drop(slot: int) -> void:
	if slot < 0:
		push_error("session: drop for slot %d; slot indices start at 0" % slot)
		return
	drop_requested.emit(slot)
	if _net == null or not _net.is_open():
		push_warning("session: drop of slot %d dropped, the socket is not open" % slot)
		return
	_net.send_drop(slot)


func request_equip(slot: int) -> void:
	if slot < 0:
		push_error("session: equip for slot %d; slot indices start at 0" % slot)
		return
	equip_requested.emit(slot)
	if _net == null or not _net.is_open():
		push_warning("session: equip of slot %d dropped, the socket is not open" % slot)
		return
	_net.send_equip(slot)


func request_unequip(worn: String) -> void:
	if worn.is_empty():
		push_error("session: unequip needs a worn slot name")
		return
	unequip_requested.emit(worn)
	if _net == null or not _net.is_open():
		push_warning('session: unequip of "%s" dropped, the socket is not open' % worn)
		return
	_net.send_unequip(worn)


func request_use(slot: int, on: int) -> void:
	if slot < 0 or on < 0:
		push_error("session: use for slot %d on %d; slot indices start at 0" % [slot, on])
		return
	clear_use_selection()
	use_requested.emit(slot, on)
	if _net == null or not _net.is_open():
		push_warning("session: use of slot %d on %d dropped, the socket is not open" % [slot, on])
		return
	_net.send_use(slot, on)


func request_respawn() -> void:
	respawn_requested.emit()
	if _net == null or not _net.is_open():
		push_warning("session: respawn dropped, the socket is not open")
		return
	_net.send_respawn()


func clear_use_selection() -> bool:
	if _use_from < 0:
		return false
	_use_from = -1
	return true


func has_pending_use() -> bool:
	return _use_from >= 0


func selected_player_id() -> int:
	return _selected_player_id


func select_player(player_id: int) -> bool:
	if player_id == _you or player_id <= 0:
		return false
	if not _avatars.has(player_id) and not _npcs.has(player_id):
		return false
	var pair := hit_points_for(player_id)
	if pair.x == 0:
		return false
	if _selected_player_id == player_id:
		_sync_selection_chrome()
		return true
	_selected_player_id = player_id
	_sync_selection_chrome()
	selection_changed.emit(_selected_player_id)
	return true


func clear_selection() -> bool:
	if _selected_player_id == 0:
		return false
	_selected_player_id = 0
	_sync_selection_chrome()
	selection_changed.emit(0)
	return true


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if _esc_menu != null and _esc_menu.is_options_open():
		_esc_menu.close_options()
		get_viewport().set_input_as_handled()
		return
	if _esc_menu != null and _esc_menu.is_open():
		_close_esc_menu()
		get_viewport().set_input_as_handled()
		return
	if clear_use_selection():
		get_viewport().set_input_as_handled()
		return
	if clear_selection():
		get_viewport().set_input_as_handled()
		return
	_open_esc_menu()
	get_viewport().set_input_as_handled()


func is_esc_menu_open() -> bool:
	return _esc_menu != null and _esc_menu.is_open()


func _open_esc_menu() -> void:
	if _esc_menu == null:
		return
	if _move_held:
		_send_move_chord(0.0, 0.0)
	_esc_menu.open_menu()


func _close_esc_menu() -> void:
	if _esc_menu == null:
		return
	_esc_menu.close_menu()


func _on_esc_resume_requested() -> void:
	_close_esc_menu()


func _on_esc_exit_requested() -> void:
	get_tree().quit()


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
	_clear_hit_points()
	_clear_class_state()
	_clear_grip()
	_casts_awaiting_mana.clear()
	if _panel != null:
		_panel.clear()
	_you = you
	_token = token
	_tick_ms = tick_ms
	_clock.anchor(tick, tick_ms)
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


func _on_welcome_nodes(
	node_ids: PackedInt64Array,
	node_kinds: PackedStringArray,
	node_positions: PackedVector2Array,
	node_states: PackedStringArray,
) -> void:
	if (
		node_ids.size() != node_kinds.size()
		or node_ids.size() != node_positions.size()
		or node_ids.size() != node_states.size()
	):
		push_error(
			"session: welcome.nodes ids, kinds, positions and states disagree in length; ignoring"
		)
		return

	for index in node_ids.size():
		var body := _ensure_node(int(node_ids[index]), node_kinds[index], node_states[index])
		if body == null:
			continue
		var ground := node_positions[index]
		body.place_at(ground.x, ground.y)

	if not _nodes.is_empty():
		print("session: %d resource node(s) in the world" % _nodes.size())


func _on_welcome_npcs(
	npc_ids: PackedInt64Array,
	npc_kinds: PackedStringArray,
	npc_factions: PackedStringArray,
	npc_positions: PackedVector2Array,
	npc_hps: PackedInt32Array,
	npc_max_hps: PackedInt32Array,
) -> void:
	if (
		npc_ids.size() != npc_kinds.size()
		or npc_ids.size() != npc_factions.size()
		or npc_ids.size() != npc_positions.size()
		or npc_ids.size() != npc_hps.size()
		or npc_ids.size() != npc_max_hps.size()
	):
		push_error("session: welcome.npcs fields disagree in length; ignoring")
		return

	for index in npc_ids.size():
		var id := int(npc_ids[index])
		var body := _ensure_npc(id, npc_kinds[index], npc_factions[index])
		if body == null:
			continue
		var ground := npc_positions[index]
		body.place_at(ground.x, ground.y)
		_apply_hit_points(id, npc_hps[index], npc_max_hps[index])

	if not _npcs.is_empty():
		print("session: %d practice npc(s) in the world" % _npcs.size())


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


static func correction_line(delta: int, at_tick: int) -> String:
	return "session: clock corrected by %+d tick(s) at heartbeat %d" % [delta, at_tick]


func is_liveness_armed() -> bool:
	return _liveness_deadline_msec != 0


func _rearm_liveness() -> void:
	if _connection_over or _heartbeat_ticks <= 0 or _tick_ms <= 0:
		_liveness_deadline_msec = 0
		return
	_liveness_deadline_msec = Time.get_ticks_msec() + _liveness_window_msec()


func _liveness_window_msec() -> int:
	return LIVENESS_HEARTBEATS * _heartbeat_ticks * _tick_ms


func _claim_expired_window() -> int:
	if _liveness_deadline_msec == 0 or Time.get_ticks_msec() < _liveness_deadline_msec:
		return 0
	_liveness_deadline_msec = 0
	return _liveness_window_msec()


func _process(_delta: float) -> void:
	_maybe_reconnect()
	_poll_move_intent()
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


func _poll_move_intent() -> void:
	if _net == null or not _net.is_open() or not _clock.is_anchored():
		return
	if is_esc_menu_open():
		return

	var local_x := 0.0
	var local_z := 0.0
	if Input.is_action_pressed("move_left"):
		local_x -= 1.0
	if Input.is_action_pressed("move_right"):
		local_x += 1.0
	if Input.is_action_pressed("move_forward"):
		local_z += 1.0
	if Input.is_action_pressed("move_back"):
		local_z -= 1.0

	var dx := 0.0
	var dz := 0.0
	if local_x != 0.0 or local_z != 0.0:
		var yaw_rad := 0.0
		if camera_rig != null and camera_rig.has_method("get_yaw_degrees"):
			yaw_rad = deg_to_rad(float(camera_rig.call("get_yaw_degrees")))
		var forward := Vector2(-sin(yaw_rad), -cos(yaw_rad))
		var right := Vector2(cos(yaw_rad), -sin(yaw_rad))
		var world := right * local_x + forward * local_z
		dx = world.x
		dz = world.y

	var holding := dx != 0.0 or dz != 0.0
	if not holding and not _move_held:
		return
	var changed := (
		not is_equal_approx(dx, _last_move_dx) or not is_equal_approx(dz, _last_move_dz)
	)
	var now := Time.get_ticks_msec()
	var due := now - _last_move_sent_msec >= MOVE_INTENT_PERIOD_MSEC
	if changed or due or (not holding and _move_held):
		_send_move_chord(dx, dz)


func _send_move_chord(dx: float, dz: float) -> void:
	request_move(dx, dz)
	_last_move_dx = dx
	_last_move_dz = dz
	_last_move_sent_msec = Time.get_ticks_msec()
	_move_held = dx != 0.0 or dz != 0.0


func _on_item_spawned(id: int, kind: String, spawn_position: Vector2) -> void:
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


func _on_item_despawned(id: int) -> void:
	if not _items.has(id):
		push_warning("session: item_despawn for unknown item %d; ignoring" % id)
		return
	_forget_item(id)


func _on_node_spawned(id: int, kind: String, spawn_position: Vector2, state: String) -> void:
	if not _clock.is_anchored():
		push_error("session: node_spawn for %d before welcome; ignoring" % id)
		return
	if _nodes.has(id):
		push_warning("session: node_spawn for known node %d replaces the existing body" % id)
		_forget_node(id)
	var body := _ensure_node(id, kind, state)
	if body == null:
		return
	body.place_at(spawn_position.x, spawn_position.y)


func _on_node_despawned(id: int) -> void:
	if not _nodes.has(id):
		push_warning("session: node_despawn for unknown node %d; ignoring" % id)
		return
	_forget_node(id)


func _on_node_state_changed(
	id: int, kind: String, spawn_position: Vector2, state: String
) -> void:
	if not _clock.is_anchored():
		push_error("session: node_state for %d before welcome; ignoring" % id)
		return
	var body: ResourceNodeScript = _nodes.get(id)
	if body == null:
		body = _ensure_node(id, kind, state)
		if body == null:
			return
		body.place_at(spawn_position.x, spawn_position.y)
		return
	if body.kind != kind:
		_forget_node(id)
		body = _ensure_node(id, kind, state)
		if body == null:
			return
		body.place_at(spawn_position.x, spawn_position.y)
		return
	body.apply_state(state)
	body.place_at(spawn_position.x, spawn_position.y)


func _on_npc_spawned(
	id: int,
	kind: String,
	faction: String,
	spawn_position: Vector2,
	hp: int,
	max_hp: int,
) -> void:
	if not _clock.is_anchored():
		push_error("session: npc_spawn for %d before welcome; ignoring" % id)
		return
	if _npcs.has(id):
		push_warning("session: npc_spawn for known npc %d replaces the existing body" % id)
		_forget_npc(id)
	var body := _ensure_npc(id, kind, faction)
	if body == null:
		return
	body.place_at(spawn_position.x, spawn_position.y)
	_apply_hit_points(id, hp, max_hp)


func _on_spawned(id: int, spawn_position: Vector2) -> void:
	if not _clock.is_anchored():
		push_error("session: spawn for %d before welcome; ignoring" % id)
		return
	if id == _you:
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


func _on_despawned(id: int) -> void:
	if id == _you:
		push_error("session: despawn carried our own id %d; ignoring" % id)
		return
	if _avatars.has(id):
		_forget(id)
		return
	if _npcs.has(id):
		_forget_npc(id)
		return
	push_warning("session: despawn for unknown actor %d; ignoring" % id)


func _on_path_assigned(
	id: int, start_tick: int, points: PackedVector2Array, speed: float
) -> void:
	var avatar: PlayerAvatarScript = _avatars.get(id)
	if avatar != null:
		avatar.follow_path(points, start_tick, speed)
		return
	var dummy: NpcDummyScript = _npcs.get(id)
	if dummy != null:
		dummy.follow_path(points, start_tick, speed)
		return
	push_warning("session: path for unknown id %d; ignoring" % id)


func _on_server_error(re: String, message: String) -> void:
	if re == "cast" and not _casts_awaiting_mana.is_empty():
		_casts_awaiting_mana.pop_front()
	push_warning('session: server refused "%s": %s' % [re, message])
	if _error_hud != null:
		_error_hud.show_refusal(player_refusal_text(re, message))


static func player_refusal_text(re: String, message: String) -> String:
	return REFUSAL_TEXT.get(re, {}).get(message, message)


func _on_disconnected(code: int, reason: String) -> void:
	_connection_over = true
	_liveness_deadline_msec = 0
	_casts_awaiting_mana.clear()
	if _dialog != null:
		_dialog.clear()
	if _give != null:
		_give.clear()
	_quest_ids = PackedStringArray()
	_quest_titles = PackedStringArray()
	_quest_objectives = PackedStringArray()
	_quest_statuses = PackedStringArray()
	_give_dismissed = false
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


func _on_node_gather_clicked(body: Node3D) -> void:
	var resource_node := body as ResourceNodeScript
	if resource_node == null:
		push_error(
			"session: the picker reported a click on %s, which is not a resource node" % body
		)
		return
	var id := _id_of_node_body(resource_node)
	if id == 0:
		push_warning(
			"session: clicked a node body this session has no registry entry for (%s); ignoring"
			% resource_node.name
		)
		return
	request_gather(id)


func _on_player_clicked(body: Node3D) -> void:
	var avatar := body as PlayerAvatarScript
	if avatar != null:
		var id := _id_of_avatar_body(avatar)
		if id == 0:
			push_warning(
				"session: clicked a player body this session has no registry entry for (%s); ignoring"
				% avatar.name
			)
			return
		select_player(id)
		return
	var dummy := body as NpcDummyScript
	if dummy == null:
		push_error("session: the picker reported a click on %s, which is not selectable" % body)
		return
	var npc_id := _id_of_npc_body(dummy)
	if npc_id == 0:
		push_warning(
			"session: clicked an npc body this session has no registry entry for (%s); ignoring"
			% dummy.name
		)
		return
	select_player(npc_id)
	if (
		dummy.kind == NpcDummyScript.KindQuestGiver
		or dummy.kind == NpcDummyScript.KindImpQuestGiver
	):
		request_talk(npc_id)


func _on_player_attack_clicked(body: Node3D) -> void:
	var avatar := body as PlayerAvatarScript
	if avatar != null:
		var id := _id_of_avatar_body(avatar)
		if id == 0:
			push_warning(
				"session: clicked a player body this session has no registry entry for (%s); ignoring"
				% avatar.name
			)
			return
		select_player(id)
		request_attack(id)
		return
	var dummy := body as NpcDummyScript
	if dummy == null:
		push_error("session: the picker reported a click on %s, which is not selectable" % body)
		return
	var npc_id := _id_of_npc_body(dummy)
	if npc_id == 0:
		push_warning(
			"session: clicked an npc body this session has no registry entry for (%s); ignoring"
			% dummy.name
		)
		return
	select_player(npc_id)
	request_attack(npc_id)


func _on_slot_activated(slot: int) -> void:
	if slot < 0:
		push_error("session: use for slot %d; slot indices start at 0" % slot)
		return
	if _use_from < 0:
		_use_from = slot
		return
	var from := _use_from
	request_use(from, slot)


func _on_equip_requested(slot: int) -> void:
	request_equip(slot)


func _on_equip_from_bag(slot: int) -> void:
	request_equip(slot)


func _on_worn_activated(worn: String) -> void:
	request_unequip(worn)


func _on_inventory_changed(
	size: int, slot_indices: PackedInt32Array, slot_kinds: PackedStringArray
) -> void:
	_bag_size = size
	_bag_indices = slot_indices
	_bag_kinds = slot_kinds
	if _panel == null:
		push_error("session: inventory arrived with no panel to draw it")
		return
	clear_use_selection()
	_panel.apply(size, slot_indices, slot_kinds)
	_reconcile_give_panel()


func _on_dialog_changed(npc_id: int, lines: PackedStringArray, option_ids: PackedStringArray) -> void:
	if _dialog == null:
		push_error("session: dialog arrived with no panel to draw it")
		return
	var had_dialog := _dialog.visible
	_dialog.apply(npc_id, lines, option_ids)
	if not had_dialog or not _dialog.visible:
		_give_dismissed = false
	_reconcile_give_panel()


func _on_quest_log_changed(
	ids: PackedStringArray,
	titles: PackedStringArray,
	objectives: PackedStringArray,
	statuses: PackedStringArray,
) -> void:
	_quest_ids = ids
	_quest_titles = titles
	_quest_objectives = objectives
	_quest_statuses = statuses
	if _quest_log == null:
		push_error("session: quest_log arrived with no panel to draw it")
		return
	_quest_log.apply(ids, titles, objectives, statuses)
	_reconcile_give_panel()


func _on_party_changed(party_id: int, leader_id: int, members: PackedInt32Array) -> void:
	if _party == null:
		push_error("session: party arrived with no panel to draw it")
		return
	_party.apply_party(party_id, leader_id, members)


func _on_party_invite_notice_changed(from_player: int) -> void:
	if _party == null:
		push_error("session: party_invite_notice arrived with no panel to draw it")
		return
	_party.apply_invite(from_player)


func _on_party_invite_pressed() -> void:
	request_party_invite(_selected_player_id)


func _on_party_accept_pressed() -> void:
	request_party_accept()


func _on_party_decline_pressed() -> void:
	request_party_decline()


func _on_party_leave_pressed() -> void:
	request_party_leave()


func _on_dialog_option_chosen(npc_id: int, option_id: String) -> void:
	request_dialog_option(npc_id, option_id)


func _on_offer_chosen(npc_id: int, slot: int) -> void:
	request_give(npc_id, slot)


func _on_give_cancelled() -> void:
	_give_dismissed = true
	if _give != null:
		_give.clear()


func _reconcile_give_panel() -> void:
	if _give == null:
		return
	if not _give_should_open():
		_give.clear()
		return
	clear_use_selection()
	_give.apply(_dialog.npc_id(), _bag_size, _bag_indices, _bag_kinds)


func _give_should_open() -> bool:
	if _give_dismissed:
		return false
	if _dialog == null or not _dialog.visible or _dialog.npc_id() <= 0:
		return false
	var dummy: NpcDummyScript = _npcs.get(_dialog.npc_id())
	if dummy == null or dummy.kind != NpcDummyScript.KindQuestGiver:
		return false
	for status: String in _quest_statuses:
		if status == "active":
			return true
	return false


func _on_equipment_changed(
	worn_names: PackedStringArray, slot_names: PackedStringArray, slot_kinds: PackedStringArray
) -> void:
	if _local != null:
		_local.apply_equipment(worn_names, slot_names, slot_kinds)
	if _equipment == null:
		push_error("session: equipment arrived with no panel to draw it")
		return
	_equipment.apply(worn_names, slot_names, slot_kinds)


func _on_class_changed(
	player: int,
	class_id: String,
	missing_slot_names: PackedStringArray,
	missing_slot_kinds: PackedStringArray,
	missing_tools: PackedStringArray,
) -> void:
	if player != _you:
		return
	_apply_class(class_id, missing_slot_names, missing_slot_kinds, missing_tools)


func _on_skills_changed(
	player: int, skill_ids: PackedStringArray, levels: PackedInt32Array
) -> void:
	if player != _you:
		return
	_skill_levels.clear()
	for index in skill_ids.size():
		if index >= levels.size():
			break
		_skill_levels[skill_ids[index]] = levels[index]
	_refresh_class_debug()


func _on_hp_changed(id: int, hp: int, max_hp: int) -> void:
	_apply_hit_points(id, hp, max_hp)


func _on_mana_changed(id: int, mana: int, max_mana: int) -> void:
	var prior := -1
	if id == _you:
		prior = mana_for(_you).x
	_apply_mana(id, mana, max_mana)
	if id == _you and prior >= 0 and mana < prior and not _casts_awaiting_mana.is_empty():
		_resolve_cast_on_mana_spend()


func _resolve_cast_on_mana_spend() -> void:
	var pending: Dictionary = _casts_awaiting_mana.pop_front()
	var ability_id := String(pending.get("ability", ""))
	var target_id := int(pending.get("target", 0))
	_play_cast_effect_on_target(target_id, ability_id)


func _play_cast_effect_on_target(target_id: int, ability_id: String) -> void:
	var host: Node3D = _avatars.get(target_id)
	if host == null:
		host = _npcs.get(target_id)
	var color := CastHitFx.color_for_ui(_ability_ui_color(ability_id))
	if host == null:
		return
	if CastHitFx.play(host, color) == null:
		return
	var dummy := host as NpcDummyScript
	if dummy != null and dummy.kind == NpcDummyScript.KindDummy:
		dummy.observe_cast(ability_id)
	cast_effect_played.emit(target_id, ability_id)


func _ability_ui_color(ability_id: String) -> String:
	var catalog: Dictionary = AbilityDefs._empty_catalog()
	if _hotbar != null:
		catalog = _hotbar.catalog()
	var ability: Variant = AbilityDefs.get_ability(catalog, ability_id)
	if typeof(ability) != TYPE_DICTIONARY:
		return ""
	var ui: Dictionary = ability.get("ui", {})
	return String(ui.get("color", ""))


func _on_respawn_requested() -> void:
	request_respawn()


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


func _forget(id: int) -> void:
	if id == _selected_player_id:
		clear_selection()
	var avatar: PlayerAvatarScript = _avatars.get(id)
	if avatar == null:
		return
	_avatars.erase(id)
	if avatar == _local:
		_local.clock = null
		return
	var parent := avatar.get_parent()
	if parent != null:
		parent.remove_child(avatar)
	avatar.queue_free()


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
	body.configure(id, kind)
	ground_items.add_child(body)
	_items[id] = body
	return body


func _ensure_node(id: int, kind: String, state: String) -> ResourceNodeScript:
	var existing: ResourceNodeScript = _nodes.get(id)
	if existing != null:
		return existing
	if id <= 0:
		push_error("session: node ids start at 1, got %d" % id)
		return null

	var body := ResourceNodeScene.instantiate() as ResourceNodeScript
	if body == null:
		push_error("session: resource_node.tscn did not instantiate as a ResourceNode")
		return null
	body.name = "Node%d" % id
	body.configure(id, kind, state)
	resource_nodes.add_child(body)
	_nodes[id] = body
	return body


func _ensure_npc(id: int, kind: String, faction: String) -> NpcDummyScript:
	var existing: NpcDummyScript = _npcs.get(id)
	if existing != null:
		return existing
	if id <= 0:
		push_error("session: npc ids start at 1, got %d" % id)
		return null

	var scene := NpcDummyScene
	if kind == NpcDummyScript.KindQuestGiver:
		scene = NpcQuestGiverScene
	elif kind == NpcDummyScript.KindImp:
		scene = NpcImpScene
	var body := scene.instantiate() as NpcDummyScript
	if body == null:
		push_error("session: npc scene did not instantiate as an NpcDummy")
		return null
	body.configure(id, kind, faction)
	if _tick_ms > 0:
		body.configure_motion(_tick_ms)
		body.clock = _clock
	npcs.add_child(body)
	_npcs[id] = body
	return body


func _id_of_item_body(body: GroundItemScript) -> int:
	for id: int in _items:
		if _items[id] == body:
			return id
	return 0


func _id_of_node_body(body: ResourceNodeScript) -> int:
	for id: int in _nodes:
		if _nodes[id] == body:
			return id
	return 0


func _id_of_avatar_body(body: PlayerAvatarScript) -> int:
	for id: int in _avatars:
		if _avatars[id] == body:
			return id
	return 0


func _id_of_npc_body(body: NpcDummyScript) -> int:
	for id: int in _npcs:
		if _npcs[id] == body:
			return id
	return 0


func _forget_item(id: int) -> void:
	var body: GroundItemScript = _items.get(id)
	if body == null:
		return
	_items.erase(id)
	var parent := body.get_parent()
	if parent != null:
		parent.remove_child(body)
	body.queue_free()


func _forget_node(id: int) -> void:
	var body: ResourceNodeScript = _nodes.get(id)
	if body == null:
		return
	_nodes.erase(id)
	var parent := body.get_parent()
	if parent != null:
		parent.remove_child(body)
	body.queue_free()


func _forget_npc(id: int) -> void:
	if id == _selected_player_id:
		clear_selection()
	var body: NpcDummyScript = _npcs.get(id)
	if body == null:
		return
	_npcs.erase(id)
	var parent := body.get_parent()
	if parent != null:
		parent.remove_child(body)
	body.queue_free()


func _forget_everyone() -> void:
	for id: int in _avatars.keys():
		_forget(id)
	for id: int in _items.keys():
		_forget_item(id)
	for id: int in _nodes.keys():
		_forget_node(id)
	for id: int in _npcs.keys():
		_forget_npc(id)


func _apply_hit_points(id: int, hp: int, max_hp: int) -> void:
	_hp[id] = Vector2i(hp, max_hp)
	var avatar: PlayerAvatarScript = _avatars.get(id)
	if avatar != null:
		avatar.set_hit_points(hp, max_hp)
	var dummy: NpcDummyScript = _npcs.get(id)
	if dummy != null:
		dummy.set_hit_points(hp, max_hp)
	if id == _selected_player_id and hp == 0:
		clear_selection()
	if id != _you:
		return
	if _hp_hud != null:
		_hp_hud.apply(hp, max_hp)
	if _death_overlay != null:
		_death_overlay.visible = hp == 0


func _sync_selection_chrome() -> void:
	for id: int in _avatars:
		var avatar: PlayerAvatarScript = _avatars[id]
		if avatar == null:
			continue
		avatar.set_selected(id == _selected_player_id)
	for id: int in _npcs:
		var dummy: NpcDummyScript = _npcs[id]
		if dummy == null:
			continue
		dummy.set_selected(id == _selected_player_id)


func _apply_mana(id: int, mana: int, max_mana: int) -> void:
	_mana[id] = Vector2i(mana, max_mana)
	if id != _you:
		return
	if _hp_hud != null:
		_hp_hud.apply_mana(mana, max_mana)


func _clear_hit_points() -> void:
	_hp.clear()
	_mana.clear()
	if _local != null:
		_local.clear_hit_points()
	if _hp_hud != null:
		_hp_hud.clear()
	if _death_overlay != null:
		_death_overlay.visible = false


func _clear_grip() -> void:
	if _local != null:
		_local.clear_grip()


func _clear_class_state() -> void:
	_active_class_id = ""
	_skill_levels.clear()
	if _local != null:
		_local.apply_class("")
	if _class_hud != null:
		_class_hud.clear()
	_refresh_class_debug()


func _apply_class(
	class_id: String,
	missing_slot_names: PackedStringArray,
	missing_slot_kinds: PackedStringArray,
	missing_tools: PackedStringArray,
) -> void:
	_active_class_id = class_id
	if _local != null:
		_local.apply_class(class_id)
	if _class_hud == null:
		push_error("session: class arrived with no hud to draw it")
		return
	var display := ""
	if not class_id.is_empty():
		display = ClassDefs.class_display_name(_classes, class_id)
	var hint := _format_class_missing_hint(missing_slot_names, missing_slot_kinds, missing_tools)
	_class_hud.apply(display, hint)
	_refresh_class_debug()


func _refresh_class_debug() -> void:
	if _class_debug == null:
		return
	var formatted := ClassDebugScript.format(_active_class_id, _classes, _skill_levels)
	_class_debug.apply(formatted)


static func _format_class_missing_hint(
	slot_names: PackedStringArray, slot_kinds: PackedStringArray, tools: PackedStringArray
) -> String:
	var parts: PackedStringArray = []
	for index in slot_names.size():
		if index >= slot_kinds.size():
			break
		parts.append("%s (%s)" % [slot_names[index], slot_kinds[index]])
	for tool in tools:
		parts.append(String(tool))
	return ", ".join(parts)


func active_class_id() -> String:
	return _active_class_id


func active_class_debug_text() -> String:
	return "" if _class_debug == null else _class_debug.text


func hit_points_for(id: int) -> Vector2i:
	var pair: Variant = _hp.get(id)
	if pair == null:
		return Vector2i(-1, -1)
	return pair


func mana_for(id: int) -> Vector2i:
	var pair: Variant = _mana.get(id)
	if pair == null:
		return Vector2i(-1, -1)
	return pair


static func _server_from_command_line() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(SERVER_ARG)
	if index == -1:
		return ""
	if index + 1 >= args.size():
		push_error("session: %s needs a websocket url after it" % SERVER_ARG)
		return ""
	return args[index + 1]


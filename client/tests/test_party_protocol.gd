extends RefCounted


const NetClientScript := preload("res://scripts/net_client.gd")


class Recorder:
	extends RefCounted

	const NetClientScript := preload("res://scripts/net_client.gd")

	var net: NetClientScript
	var events: Array[Dictionary] = []

	func _init() -> void:
		net = NetClientScript.new()
		net.party_changed.connect(_on_party_changed)
		net.party_invite_notice_changed.connect(_on_party_invite_notice_changed)
		net.unknown_message.connect(_on_unknown)

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

	func _on_party_changed(party_id: int, leader_id: int, members: PackedInt32Array) -> void:
		events.append({
			"signal": "party_changed",
			"id": party_id,
			"leader": leader_id,
			"members": members,
		})

	func _on_party_invite_notice_changed(from_player: int) -> void:
		events.append({
			"signal": "party_invite_notice_changed",
			"from": from_player,
		})

	func _on_unknown(key: String) -> void:
		events.append({"signal": "unknown_message", "key": key})


var _assertions: RefCounted = null


func run(assertions: RefCounted) -> void:
	_assertions = assertions
	print("== party protocol: restatement and invite notice ==")
	_test_party_restatement()
	_test_empty_party_clear()
	_test_invite_notice_and_clear()
	_test_rejects_leader_missing_from_members()
	_test_intent_frames()
	assertions.finish()


func _check(condition: bool, message: String) -> bool:
	_assertions.check(condition, message)
	return condition


func _test_party_restatement() -> void:
	var rec := Recorder.new()
	rec.feed('{"party":{"id":1,"leader":2,"members":[2,3,4]}}')
	_check(rec.names() == ["party_changed"], "party emits party_changed, got %s" % [rec.names()])
	var events := rec.of("party_changed")
	if events.is_empty():
		rec.release()
		return
	var event: Dictionary = events[0]
	_check(event["id"] == 1, "party id is server id, got %s" % event["id"])
	_check(event["leader"] == 2, "leader is server id, got %s" % event["leader"])
	_check(
		event["members"] == PackedInt32Array([2, 3, 4]),
		"members are join-order ids, got %s" % [event["members"]],
	)
	rec.release()


func _test_empty_party_clear() -> void:
	var rec := Recorder.new()
	rec.feed('{"party":{"id":0,"leader":0,"members":[]}}')
	_check(rec.names() == ["party_changed"], "empty party emits party_changed")
	var events := rec.of("party_changed")
	if not events.is_empty():
		_check(events[0]["id"] == 0, "clear restates id 0")
		_check(
			(events[0]["members"] as PackedInt32Array).is_empty(),
			"clear restates zero members",
		)
	rec.release()


func _test_invite_notice_and_clear() -> void:
	var rec := Recorder.new()
	rec.feed('{"party_invite_notice":{"from":2}}')
	_check(
		rec.names() == ["party_invite_notice_changed"],
		"invite notice emits party_invite_notice_changed",
	)
	var events := rec.of("party_invite_notice_changed")
	if not events.is_empty():
		_check(events[0]["from"] == 2, "from is the inviter id")
	rec.clear()
	rec.feed('{"party_invite_notice":{"from":0}}')
	events = rec.of("party_invite_notice_changed")
	_check(not events.is_empty() and events[0]["from"] == 0, "from 0 clears the pending invite")
	rec.release()


func _test_rejects_leader_missing_from_members() -> void:
	var rec := Recorder.new()
	rec.feed('{"party":{"id":1,"leader":9,"members":[2,3]}}')
	_check(rec.names().is_empty(), "leader absent from members emits nothing, got %s" % [rec.names()])
	rec.release()


func _test_intent_frames() -> void:
	var invite := NetClientScript.party_invite_frame(2, 7)
	_check(
		invite == {"party_invite": {"player": 2, "seq": 7}},
		"party_invite frame names the target player, got %s" % [invite],
	)
	_check(
		NetClientScript.party_accept_frame(8) == {"party_accept": {"seq": 8}},
		"party_accept carries seq only",
	)
	_check(
		NetClientScript.party_decline_frame(9) == {"party_decline": {"seq": 9}},
		"party_decline carries seq only",
	)
	_check(
		NetClientScript.party_leave_frame(10) == {"party_leave": {"seq": 10}},
		"party_leave carries seq only",
	)

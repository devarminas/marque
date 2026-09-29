extends SceneTree

var _failures := 0


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _hp_frame(id: int, hp: int, max_hp: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(17)
	out.encode_u8(0, 1)
	out.encode_s64(1, id)
	out.encode_s32(9, hp)
	out.encode_s32(13, max_hp)
	return out


func _init() -> void:
	var world := WorldClient.new()
	_check(world.feed_frame(_hp_frame(7, 40, 50)) == "", "valid hp frame applies")
	_check(world.player_hp(7) == 40 and world.player_max_hp(7) == 50, "GDScript reads hp 40/50 from C++")
	_check(
		world.feed_frame(_hp_frame(7, 60, 50)) == "hp must satisfy 0 <= hp <= max_hp and max_hp >= 1",
		"hp above max is refused with the C++ fault text",
	)
	_check(world.player_hp(7) == 40, "refused frame leaves hp at 40")
	_check(not world.has_method("set_hp") and not world.has_method("apply"), "no write method is exposed to GDScript")
	_check(not ("vitals_" in world) and not ("world_" in world), "C++ state is not reachable as a property")
	print("%d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

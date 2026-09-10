extends RefCounted

const Assertions := preload("res://tests/assertions.gd")
const NetClientScript := preload("res://scripts/net_client.gd")
const CastBarScript := preload("res://scripts/cast_bar.gd")
const CastBarScene := preload("res://scenes/cast_bar.tscn")


func run(assertions: Assertions) -> void:
	_test_casting_frame(assertions)
	_test_cast_bar_clear(assertions)
	assertions.finish()


func _test_casting_frame(assertions: Assertions) -> void:
	var net := NetClientScript.new()
	var seen: Array = []
	net.casting_changed.connect(func(ability: String, progress: int, total: int) -> void:
		seen.append({"ability": ability, "progress": progress, "total": total})
	)
	net.ingest_text_frame('{"casting":{"ability":"fireball","progress":3,"total":8}}')
	net.ingest_text_frame('{"casting":{"ability":"","progress":0,"total":0}}')
	assertions.check(seen.size() == 2, "casting frames emit twice")
	if seen.size() >= 1:
		assertions.check(seen[0]["ability"] == "fireball", "ability restated")
		assertions.check(seen[0]["progress"] == 3 and seen[0]["total"] == 8, "progress restated")
	if seen.size() >= 2:
		assertions.check(seen[1]["ability"] == "" and seen[1]["total"] == 0, "idle casting clears")


func _test_cast_bar_clear(assertions: Assertions) -> void:
	var bar := CastBarScene.instantiate() as CastBarScript
	assertions.check(bar != null, "cast_bar scene loads")
	if bar == null:
		return
	bar.apply("fireball", 4, 8)
	assertions.check(bar.visible, "cast bar shows while casting")
	bar.apply("", 0, 0)
	assertions.check(not bar.visible, "cast bar clears on idle")
	bar.free()

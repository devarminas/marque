extends RefCounted

const Assertions := preload("res://tests/assertions.gd")
const DummyMeterScript := preload("res://scripts/dummy_meter.gd")


func run(assertions: Assertions) -> void:
	print("== dummy meter: rolling dps/hps from hp and casts ==")
	_test_hp_delta(assertions)
	_test_cast_fallback(assertions)
	_test_window_prunes(assertions)
	assertions.finish()


func _test_hp_delta(assertions: Assertions) -> void:
	var meter := DummyMeterScript.new()
	meter.observe_hp(100000, 100000)
	meter.observe_hp(99990, 100000)
	assertions.check(
		is_equal_approx(meter.rate_per_sec(), 2.0),
		"10 damage in 5s window reads as 2 DPS, got %s" % meter.rate_per_sec(),
	)


func _test_cast_fallback(assertions: Assertions) -> void:
	var meter := DummyMeterScript.new()
	meter.observe_cast("fireball")
	assertions.check(
		is_equal_approx(meter.rate_per_sec(), 8.0),
		"fireball cast fallback reads as 8 DPS, got %s" % meter.rate_per_sec(),
	)
	meter.reset()
	meter.observe_cast("heal")
	assertions.check(
		is_equal_approx(meter.rate_per_sec(), 5.0),
		"heal cast fallback reads as 5 HPS, got %s" % meter.rate_per_sec(),
	)


func _test_window_prunes(assertions: Assertions) -> void:
	var meter := DummyMeterScript.new()
	var now := Time.get_ticks_msec() / 1000.0
	meter._samples.append({"t": now - 6.0, "delta": 100.0, "kind": "fireball"})
	meter._samples.append({"t": now - 1.0, "delta": 10.0, "kind": "fireball"})
	assertions.check(
		is_equal_approx(meter.rate_per_sec(), 2.0),
		"old samples fall out of the 5s window, got %s" % meter.rate_per_sec(),
	)
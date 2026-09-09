class_name DummyMeter
extends RefCounted

const AbilityDefs := preload("res://scripts/ability_defs.gd")

const WINDOW_SEC := 5.0

var _samples: Array[Dictionary] = []


func reset() -> void:
	_samples.clear()


func observe_hp(hp: int, max_hp: int) -> void:
	if max_hp <= 0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _samples.is_empty():
		_samples.append({"t": now, "hp": hp, "max_hp": max_hp})
		return
	var last: Dictionary = _samples[_samples.size() - 1]
	var last_hp := int(last.get("hp", hp))
	if last_hp == hp and int(last.get("max_hp", max_hp)) == max_hp:
		return
	var delta := absi(last_hp - hp)
	_samples.append({"t": now, "delta": float(delta), "hp": hp, "max_hp": max_hp})
	_prune(now)


func observe_cast(ability_id: String) -> void:
	var amount := _ability_amount(ability_id)
	if amount <= 0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	_samples.append({"t": now, "delta": amount, "kind": ability_id})
	_prune(now)


func rate_per_sec() -> float:
	var now := Time.get_ticks_msec() / 1000.0
	_prune(now)
	var total := 0.0
	for row: Dictionary in _samples:
		if not row.has("delta"):
			continue
		total += float(row["delta"])
	if total <= 0.0:
		return 0.0
	return total / WINDOW_SEC


func _prune(now: float) -> void:
	var cutoff := now - WINDOW_SEC
	while _samples.size() > 1 and float(_samples[0]["t"]) < cutoff:
		_samples.remove_at(0)


static func _ability_amount(ability_id: String) -> float:
	var catalog: Dictionary = AbilityDefs.load_default()
	var ability: Variant = AbilityDefs.get_ability(catalog, ability_id)
	if typeof(ability) != TYPE_DICTIONARY:
		return 0.0
	var effect: Dictionary = ability.get("effect", {})
	return float(effect.get("amount", 0.0))
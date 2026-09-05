extends Label


func apply(hp: int, max_hp: int) -> void:
	text = "HP %d / %d" % [hp, max_hp]
	visible = true


func clear() -> void:
	text = "HP —"
	visible = false

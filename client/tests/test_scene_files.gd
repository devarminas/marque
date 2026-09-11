extends RefCounted

const Assertions := preload("res://tests/assertions.gd")

const SCENE_DIRS := [
	"res://scenes",
	"res://scenes/fixtures",
	"res://scenes/props",
	"res://tests",
]


func run(assertions: Assertions) -> void:
	_test_no_ext_resource_carries_a_uid(assertions)
	assertions.finish()


func _test_no_ext_resource_carries_a_uid(assertions: Assertions) -> void:
	var scanned := 0
	var unreadable := PackedStringArray()
	var offenders := PackedStringArray()
	for dir: String in SCENE_DIRS:
		for name: String in DirAccess.get_files_at(dir):
			if not name.ends_with(".tscn"):
				continue
			var path := "%s/%s" % [dir, name]
			scanned += 1
			var body := FileAccess.get_file_as_string(path)
			if body.is_empty():
				unreadable.append(path)
				continue
			var line_number := 0
			for line: String in body.split("\n"):
				line_number += 1
				if line.begins_with("[ext_resource") and line.contains("uid=\"uid://"):
					offenders.append("%s:%d" % [path, line_number])
	assertions.check(
		scanned > 0 and unreadable.is_empty(),
		"read every scene file under %s, got %d and could not read %s"
		% [", ".join(SCENE_DIRS), scanned, ", ".join(unreadable)],
	)
	assertions.check(
		offenders.is_empty(),
		"no ext_resource names a uid that a fresh clone cannot resolve, offenders %s"
		% ", ".join(offenders),
	)

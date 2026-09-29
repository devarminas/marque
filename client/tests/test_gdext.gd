extends RefCounted


const Assertions := preload("res://tests/assertions.gd")


func run(assertions: Assertions) -> void:
	assertions.check(
		ClassDB.class_exists("MarqueCore"),
		"the marque GDExtension registers MarqueCore (build it with scripts/native_test.sh)",
	)
	if ClassDB.can_instantiate("MarqueCore"):
		var core: RefCounted = ClassDB.instantiate("MarqueCore")
		assertions.check(core.scaffold_answer() == 42, "MarqueCore.scaffold_answer() returns 42 from marque_core")
	assertions.finish()

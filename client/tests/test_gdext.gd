extends RefCounted


const Assertions := preload("res://tests/assertions.gd")


func run(assertions: Assertions) -> void:
	assertions.check(
		ClassDB.class_exists("MarqueCore"),
		"the marque GDExtension registers MarqueCore (build it with scripts/native_test.sh)",
	)
	assertions.check(
		ClassDB.can_instantiate("MarqueCore"),
		"MarqueCore is instantiable",
	)
	assertions.finish()

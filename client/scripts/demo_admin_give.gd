extends RefCounted
## Grant known item kinds via admin /give for verify demos.
## Requires marqued started with -admin (every connected player is allowed).


const SessionScript := preload("res://scripts/session.gd")

const DEFAULT_TIMEOUT_MSEC := 15000
const SPIN_USEC := 20000


## Give each kind once. Skips kinds already in the bag. Returns "" on success,
## or a failure reason string.
func grant(
	session: SessionScript,
	tree: SceneTree,
	kinds: Array,
	timeout_msec: int = DEFAULT_TIMEOUT_MSEC,
) -> String:
	if session == null or tree == null:
		return "demo_admin_give: session or tree missing"
	for entry: Variant in kinds:
		var kind := String(entry).strip_edges()
		if kind.is_empty():
			return "demo_admin_give: empty kind"
		if _bag_has(session, kind):
			continue
		session.request_admin("/give %s" % kind)
		print("DEMO admin /give %s" % kind)
		var deadline := Time.get_ticks_msec() + timeout_msec
		while Time.get_ticks_msec() < deadline:
			if _bag_has(session, kind):
				break
			await tree.create_timer(SPIN_USEC / 1_000_000.0).timeout
		if not _bag_has(session, kind):
			return "admin /give %s never appeared in the bag after %dms" % [kind, timeout_msec]
	return ""


func _bag_has(session: SessionScript, kind: String) -> bool:
	var bag_kinds: Variant = session.get("_bag_kinds")
	if bag_kinds == null:
		return false
	for entry: Variant in bag_kinds:
		if String(entry) == kind:
			return true
	return false

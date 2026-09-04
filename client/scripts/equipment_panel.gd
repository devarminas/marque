extends PanelContainer

## What the player is wearing. Authored in `main.tscn`, opened and closed by the
## player. **M3b.**
##
## [b]Open or closed is [member CanvasItem.visible] and nothing else.[/b] A
## second boolean tracking the same fact would drift the first time anything
## assigned `visible` directly, which is not hypothetical: `inventory_panel.gd`
## does exactly that from its rebuild. So this script models no state. It owns
## one transition and the scene owns the starting value, which is closed.
##
## [b]Opaque while open.[/b] [constant Control.MOUSE_FILTER_STOP] is authored on
## this node in `main.tscn` and nothing here assigns it, which is M1k's lesson
## kept rather than relearnt: a filter re-armed from a script is a filter that
## is wrong for every frame before `_ready` and invisible to anyone reading the
## scene. A hidden [Control] is not hit-tested at all, so a closed panel costs
## the world behind it nothing.
##
## [b]The worn slot is drawn and never filled.[/b] What is actually equipped
## arrives on the wire in a later unit; a client that guessed would be a client
## with authority (CLAUDE.md). So the slot is authored chrome, not a control,
## and this script has no idea what a weapon is.

## The action that opens and closes it. Authored in `project.godot` so the bind
## is remappable configuration rather than a keycode buried in this file.
const TOGGLE_ACTION := "toggle_equipment"


func toggle() -> void:
	visible = not visible


## A hidden node still receives this, verified against 4.7.2, which is what lets
## a panel that starts closed open itself.
func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed(TOGGLE_ACTION):
		return
	toggle()
	# Consumed, so one keypress cannot also mean something to anything else.
	get_viewport().set_input_as_handled()

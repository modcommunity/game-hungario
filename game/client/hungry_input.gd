@tool
class_name HungryInput
extends Dot2DSampler

## Turns a mouse, a keyboard, a gamepad or a finger into a [Dot2DCommand].
##
## [Dot2DSampler] already does almost all of it, including the part that matters: it
## resolves the pointer to a [b]direction and a distance in world units[/b] rather than
## sending a screen position, because a screen position depends on a window size and a
## camera zoom the server does not have.
##
## What this adds is the one thing that is specific to a monster being a set: the pointer
## is measured from the [b]centroid[/b], not from a node. There is no single node to
## measure from — a burst monster is up to sixteen of them — and the server reconstructs
## the pointer by adding the same offset to the same centroid, so the two have to agree
## about what it was measured from. See [method HungryWorld.pointer_of].
##
## [b]Speed comes from how far the cursor is.[/b] Close is slow, far is full speed, and
## the dead zone is what makes it possible to stop. That relationship is
## [member Dot2DTunables.full_speed_reach] and it is the whole feel of the genre.


## `func() -> HungryMonster`. Whose centroid the pointer is measured from.
var monster_source: Callable = Callable()

## The camera, for turning a screen position into a world one.
##
## Taken explicitly rather than through a node's canvas transform, because the thing being
## measured from is a centroid and a centroid has no canvas transform.
var camera: Camera2D = null

## Replaces the sampled command with a supplied one.
##
## [code]func() -> Dot2DCommand[/code]. This is the same seam [Dot2DSampler] exists to be:
## the motor never reads a device, so a bot sitting in a client's seat, a recorded demo
## and a headless run with no pointer all drive the game through exactly the code a player
## does. Unset — which is every real session — the devices are read.
var command_source: Callable = Callable()

## The on-screen buttons, on a device that has no keyboard.
##
## Read rather than routed through [InputMap], because a touch button is a state a
## [Control] holds and an action is a state the input system holds — mapping one onto the
## other means synthesising events, and a synthesised press that is missed leaves an
## action stuck down.
var touch: HungryTouch = null

var _touch_at: Vector2 = Vector2.ZERO
var _touching_screen: bool = false


static func measuring(source: Callable, p_camera: Camera2D) -> HungryInput:
	var sampler := HungryInput.new()
	sampler.name = "Input"
	sampler.monster_source = source
	sampler.camera = p_camera
	sampler.use_pointer = true
	sampler.max_reach = HungryNetCommand.MAX_REACH
	sampler.register_default_actions = true
	sampler.split_button = &"hungry_split"
	sampler.action_button = &"hungry_throw"
	sampler.boost_button = &"hungry_boost"
	sampler.eject_button = &"hungry_eject"
	return sampler


func _ready() -> void:
	super._ready()

	if Engine.is_editor_hint():
		return

	_register_actions()


## The three this game needs, added only if the project does not already have them.
##
## Convenient for a prototype and wrong for a shipped game, where the actions are the
## project's and a player has rebound them. It only ever adds; it never rebinds one that
## exists, which is what [DotBindingsPanel] is for.
func _register_actions() -> void:
	_ensure_action(&"hungry_split", KEY_SPACE, MOUSE_BUTTON_LEFT)
	_ensure_action(&"hungry_throw", KEY_Q, MOUSE_BUTTON_RIGHT)
	_ensure_action(&"hungry_boost", KEY_SHIFT, 0)
	# W, which is free here because movement is the mouse. It is also where agar.io puts
	# it, and muscle memory from the genre is worth more than a tidier layout.
	_ensure_action(&"hungry_eject", KEY_W, 0)


func _ensure_action(action: StringName, key: Key, button: int) -> void:
	if InputMap.has_action(action):
		return

	InputMap.add_action(action)

	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)

	if button != 0:
		var click := InputEventMouseButton.new()
		click.button_index = button as MouseButton
		InputMap.action_add_event(action, click)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		_touching_screen = touch.pressed
		_touch_at = touch.position
	elif event is InputEventScreenDrag:
		_touch_at = (event as InputEventScreenDrag).position


## Produces the command for this tick.
##
## Overrides the base entirely rather than extending it, because the base measures from a
## node and the whole difference here is what it measures from.
func sample(_delta: float = 0.0) -> Dot2DCommand:
	var command := Dot2DCommand.new()

	if suspended or not is_inside_tree():
		return command

	if command_source.is_valid():
		var supplied: Variant = command_source.call()

		if supplied is Dot2DCommand:
			var typed := supplied as Dot2DCommand
			typed.sanitise(max_reach)
			return typed

		return command

	var touching_split := touch != null and touch.split_held
	var touching_throw := touch != null and touch.throw_held

	command.set_button(
		Dot2DCommand.BUTTON_SPLIT, _held(split_button) or touching_split
	)
	command.set_button(
		Dot2DCommand.BUTTON_ACTION, _held(action_button) or touching_throw
	)
	command.set_button(Dot2DCommand.BUTTON_BOOST, _held(boost_button))
	command.set_button(Dot2DCommand.BUTTON_EJECT, _held(eject_button))

	var monster := _monster()

	if monster == null or not monster.alive:
		return command

	var origin := monster.centre()
	var pointer := _pointer(origin)
	var offset := pointer - origin

	command.aim = offset.normalized() if offset.length_squared() > 0.000001 \
		else Vector2.ZERO
	command.reach = minf(offset.length(), max_reach)

	# On the server too, on everything that arrives. Doing it here as well costs nothing
	# and keeps a local prediction from being computed on a value the server will clamp.
	command.sanitise(max_reach)
	return command


func _held(action: StringName) -> bool:
	return action != &"" and InputMap.has_action(action) \
		and Input.is_action_pressed(action)


func _monster() -> HungryMonster:
	if not monster_source.is_valid():
		return null

	var value: Variant = monster_source.call()
	return value as HungryMonster if value is HungryMonster else null


## Where the player is pointing, in world coordinates.
##
## A finger beats the mouse when one is down, because a phone reports both and the mouse
## is wherever it was left. With no pointer at all — a gamepad, a headless run — the
## movement stick stands in, scaled to full speed, so the same command shape drives every
## device.
func _pointer(origin: Vector2) -> Vector2:
	if _touching_screen and camera != null:
		return camera.get_canvas_transform().affine_inverse() * _touch_at

	var stick := Input.get_vector(move_left, move_right, move_up, move_down)

	if stick.length_squared() > 0.04:
		return origin + stick.limit_length(1.0) * max_reach

	if DisplayServer.get_name() == "headless" or camera == null \
			or not camera.is_inside_tree():
		return origin

	return camera.get_global_mouse_position()


func describe() -> Dictionary:
	return {
		"suspended": suspended,
		"touching": _touching_screen,
		"camera": camera.name if camera != null else "<none>",
	}

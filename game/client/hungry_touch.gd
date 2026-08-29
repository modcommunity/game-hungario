@tool
class_name HungryTouch
extends Control

## The two buttons a phone needs, and nothing else.
##
## [b]This game is nearly playable on a phone by accident.[/b] There is nothing to aim and
## nothing to select: a drag is the pointer, near is slow, far is fast, and
## [HungryInput] already treats a finger as one. What a touchscreen has no way to express
## is the two edge-triggered actions — splitting and throwing — and that is all this is.
##
## [b]Buttons, not a gesture.[/b] A double-tap to split would fight the drag that steers,
## and a two-finger tap is undiscoverable. Two large targets in the corners cost a little
## screen and are the only control here anybody has to be told about once.
##
## They are [Control]s rather than [TouchScreenButton]s on purpose. A `Control` consumes
## the touch before [method Node._unhandled_input] sees it, so pressing one does not also
## drag the monster across the screen — which is exactly what a `TouchScreenButton`, being
## a `Node2D`, would let through.

const CHANNEL := "hungry.touch"

## Diameter of each button, in pixels, before the safe-area inset.
##
## Nine millimetres is the usual floor for a touch target and this is comfortably above
## it: these are pressed under pressure, with a thumb, while the other hand is steering.
const BUTTON_SIZE := 108.0

const EDGE_MARGIN := 26.0

signal split_pressed()
signal throw_pressed()

## Whether the buttons are held right now. Read by [HungryInput] each tick.
var split_held: bool = false
var throw_held: bool = false

var split_button: Button = null
var throw_button: Button = null

## What the throw button says it will throw. Set from the carry list.
var _carried: StringName = &""


## Whether this device wants them.
##
## Forced on by `--touch` so the layout can be looked at on a desktop, and so a headless
## run can build and drive it — a control nothing exercises is a control that breaks
## quietly.
static func wanted() -> bool:
	return DisplayServer.is_touchscreen_available() \
		or "--touch" in OS.get_cmdline_user_args()


static func make() -> HungryTouch:
	var touch := HungryTouch.new()
	touch.name = "Touch"
	touch.build()
	return touch


func build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# The container must not eat touches that are not on a button, or steering stops
	# working the moment this is added.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	split_button = _make_button("Split", Color(0.55, 0.80, 1.0))
	split_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	split_button.offset_left = EDGE_MARGIN
	split_button.offset_top = -(BUTTON_SIZE + EDGE_MARGIN)
	split_button.offset_right = EDGE_MARGIN + BUTTON_SIZE
	split_button.offset_bottom = -EDGE_MARGIN
	add_child(split_button)

	throw_button = _make_button("Throw", Color(0.95, 0.55, 0.35))
	throw_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	throw_button.offset_left = -(BUTTON_SIZE + EDGE_MARGIN)
	throw_button.offset_top = -(BUTTON_SIZE + EDGE_MARGIN)
	throw_button.offset_right = -EDGE_MARGIN
	throw_button.offset_bottom = -EDGE_MARGIN
	add_child(throw_button)

	# Nothing to throw until something is picked up. Disabled rather than hidden: a
	# control that appears and disappears under a thumb is worse than one that is there
	# and greyed.
	throw_button.disabled = true


func _make_button(text: String, tint: Color) -> Button:
	var button := Button.new()
	button.name = text
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_color_override(&"font_color", tint)

	button.button_down.connect(func() -> void: _on_down(text))
	button.button_up.connect(func() -> void: _on_up(text))

	return button


func _on_down(which: String) -> void:
	if which == "Split":
		split_held = true
		split_pressed.emit()
	else:
		throw_held = true
		throw_pressed.emit()


func _on_up(which: String) -> void:
	if which == "Split":
		split_held = false
	else:
		throw_held = false


## Keeps the throw button in step with what is being carried.
##
## The label names the item because there are three of them and they do very different
## things — throwing a lure at somebody chasing you is a wasted charge, and a button
## labelled "Throw" gives a player no way to know that.
func show_carried(items: PackedStringArray) -> void:
	var next := StringName(items[0]) if not items.is_empty() else &""

	if next == _carried:
		return

	_carried = next

	if throw_button == null:
		return

	throw_button.disabled = _carried == &""
	throw_button.text = "Throw" if _carried == &"" else String(_carried).capitalize()

	if _carried != &"":
		throw_button.add_theme_color_override(
			&"font_color", HungryContent.item_colour(_carried)
		)


## Safe-area insets, so a button is not under a notch or a home indicator.
##
## [DotHud] does this for its own children and this is a child of it, but the buttons are
## anchored to the corners rather than laid out — which is exactly the case an inset on
## the parent does not reach.
func apply_safe_area() -> void:
	var safe := DisplayServer.get_display_safe_area()
	var full := DisplayServer.window_get_size()

	if safe.size == Vector2i.ZERO or safe.size == full:
		return

	var bottom := float(full.y - safe.end.y)
	var left := float(safe.position.x)
	var right := float(full.x - safe.end.x)

	split_button.offset_left = EDGE_MARGIN + left
	split_button.offset_right = split_button.offset_left + BUTTON_SIZE
	split_button.offset_top = -(BUTTON_SIZE + EDGE_MARGIN + bottom)
	split_button.offset_bottom = -(EDGE_MARGIN + bottom)

	throw_button.offset_right = -(EDGE_MARGIN + right)
	throw_button.offset_left = throw_button.offset_right - BUTTON_SIZE
	throw_button.offset_top = -(BUTTON_SIZE + EDGE_MARGIN + bottom)
	throw_button.offset_bottom = -(EDGE_MARGIN + bottom)


func describe() -> Dictionary:
	return {
		"split": split_held,
		"throw": throw_held,
		"carried": String(_carried),
	}

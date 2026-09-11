class_name HungrySoundSink
extends DotAudioSink

## dot-audio's sink, backed by the sound this game already generates for itself.
##
## [b]This is the whole shape of hungario's audio integration, and it is deliberately not
## "replace `HungrySound` with dot-audio".[/b] This game bakes its entire bank
## arithmetically at boot — ten cues, 22 kHz, no files — and that is the best thing about
## its audio: it ships nothing, it works on every platform, and it is the only game in the
## family that makes a noise today. Throwing it away for an addon that names files would
## be a strict downgrade.
##
## What `HungrySound` does not have is the half dot-audio is: a catalogue a server can
## check, per-id concurrency caps, cooldowns, a distance cull, priorities, a mixer with a
## `linear_to_db` curve, and a manager that says **why** a sound was refused. So the two
## meet at the seam the addon was built around — [DotAudioSink] — and everything above it
## is dot-audio's while the last four lines stay this game's.
##
## The seam exists because **`AudioServer` reports a working sound card when there is
## none**: in a headless run the mix rate, the device list and the latency are all
## plausible and only `get_driver_name()` says "Dummy". dot-voice found that; this is the
## third addon to be built around it.

const CHANNEL := "hungry.sound"

## The cue each catalogue id maps to.
##
## [b]One map, here, and nowhere else.[/b] The alternative is a `match` in the manager and
## another in the renderer, which is two copies of one list — and the copy that goes stale
## is the one that plays the eating sound for a death.
const CUES := {
	"eat": HungrySound.Cue.EAT,
	"fruit": HungrySound.Cue.FRUIT,
	"pickup": HungrySound.Cue.PICKUP,
	"split": HungrySound.Cue.SPLIT,
	"eject": HungrySound.Cue.EJECT,
	"throw": HungrySound.Cue.THROW,
	"burst": HungrySound.Cue.BURST,
	"devour": HungrySound.Cue.DEVOUR,
	"die": HungrySound.Cue.DIE,
	"click": HungrySound.Cue.CLICK,
}

var sound: HungrySound = null

var _handles: Dictionary = {}
var _next := 1
var _log: Array[Dictionary] = []


func _init(p_sound: HungrySound = null) -> void:
	sound = p_sound


func play(request: Dictionary) -> int:
	var id := str(request.get("id", ""))
	if not CUES.has(id):
		# An id with no cue behind it is silence, not an error. dot-audio has already
		# decided this sound should be heard; whether this game has a noise for it is a
		# separate question, and a red line per bite on a client whose bank has not
		# finished baking is how a real error stops being read.
		DotLog.debug(CHANNEL, "no cue for that sound", {"id": id})
		return 0

	var handle := _next
	_next += 1
	# Recorded whether or not there is a device, which is what makes a headless suite a
	# test of this game's audio decisions rather than of a stand-in.
	_handles[handle] = request.duplicate()
	_log.append(request.duplicate())

	if sound != null and is_instance_valid(sound):
		# The pitch dot-audio rolled, not one this file picks. A pitch chosen down here
		# could not be reproduced from a seed, and an audio bug that cannot be reproduced
		# is an audio bug nobody fixes.
		sound.play(CUES[id], float(request.get("pitch", 1.0)))

	return handle


func stop(handle: int) -> void:
	# `HungrySound` has no handle for a voice: it round-robins a fixed pool and the blips
	# are a few tens of milliseconds long. Stopping one would mean giving it a handle
	# system for sounds that are over before anybody could ask -- so the book-keeping ends
	# and the noise finishes on its own, which is the honest answer rather than a
	# pretended one.
	_handles.erase(handle)


func stop_all() -> void:
	_handles.clear()


func is_playing(handle: int) -> bool:
	# Answered as "not any more" as soon as the manager asks a second time, because these
	# are blips and a manager whose concurrency counts never fall goes quiet after a
	# minute. The alternative is a timer per voice for sounds shorter than a frame.
	if not _handles.has(handle):
		return false
	_handles.erase(handle)
	return false


func move(_handle: int, _position: Vector3) -> void:
	# Every voice is flat. `HungrySound` bakes mono blips into an `AudioStreamPlayer`, and
	# the distance that matters in this game is already applied by dot-audio's cull --
	# which is the cheap half and the half that saves anything.
	pass


func usage() -> Dictionary:
	return {"playing": _handles.size(), "capacity": HungrySound.VOICES}


func sink_name() -> String:
	return "hungry"


## Everything this sink was asked to play, for a suite.
func played_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for r in _log:
		out.append(str(r.get("id", "")))
	return out


func count_of(id: StringName) -> int:
	var n := 0
	for r in _log:
		if str(r.get("id", "")) == String(id):
			n += 1
	return n


func last_pitch(id: StringName) -> float:
	for i in range(_log.size() - 1, -1, -1):
		if str(_log[i].get("id", "")) == String(id):
			return float(_log[i].get("pitch", 1.0))
	return 0.0


func forget() -> void:
	_log.clear()

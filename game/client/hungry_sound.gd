@tool
class_name HungrySound
extends Node

## Every noise this game makes, generated at startup. It ships no audio files.
##
## [b]The same reasoning as everything else here.[/b] dot-ui ships no art, dot-2d draws
## nothing, and the avatar parts are polygons — so the sound is a few hundred milliseconds
## of arithmetic rather than a directory of WAVs somebody has to produce before the game
## makes any noise at all. A real deployment replaces [method bake] with a bank of loaded
## streams and changes nothing else: the rest of this file is a pool and a switch.
##
## [b]Generated once, not per frame.[/b] Each voice is an [AudioStreamWAV] built at
## startup and played from a small pool of players. An [AudioStreamGenerator] pushing
## buffers would mean filling them on the main thread inside a frame budget, which is a
## real cost for a blip that is the same blip every time.
##
## [b]Nothing here needs an audio device.[/b] Baking is a pure function of its arguments
## and produces bytes, which is what the self-test checks; a headless run makes the bank,
## plays into a driver that discards it, and behaves exactly as it would with speakers.

const CHANNEL := "hungry.sound"

## 22 kHz mono. Half the size of 44 kHz and indistinguishable for what these are: short
## blips with no content above a few kilohertz.
const RATE := 22050

## Voices playing at once. Eating is the common case and a monster in a dense field eats
## several times a second; past a handful of overlapping blips it is noise anyway, and a
## pool that grows without bound is a pool that eventually stutters the frame it grows in.
const VOICES := 12

enum Cue {
	## Eating a crumb. Pitched up for the small ones.
	EAT,
	## A fruit, which is worth stopping for.
	FRUIT,
	## Picking up a throwable.
	PICKUP,
	## Splitting.
	SPLIT,
	## Ejecting.
	EJECT,
	## Throwing something.
	THROW,
	## Being burst.
	BURST,
	## Eating somebody.
	DEVOUR,
	## Being eaten.
	DIE,
	## A menu.
	CLICK,
}

## Volume in decibels, applied to every voice. A game whose sound cannot be turned down is
## a game people play muted.
@export_range(-60.0, 6.0, 0.5) var volume_db: float = -8.0

@export var muted: bool = false

var _bank: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next: int = 0


static func make() -> HungrySound:
	var sound := HungrySound.new()
	sound.name = "Sound"
	return sound


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	build()


## Bakes the bank and makes the voice pool. Safe to call twice.
func build() -> void:
	if not _bank.is_empty():
		return

	_bank = {
		Cue.EAT: bake(520.0, 760.0, 0.07, 0.35, 0.0),
		Cue.FRUIT: bake(420.0, 980.0, 0.26, 0.30, 0.15),
		Cue.PICKUP: bake(660.0, 1180.0, 0.13, 0.28, 0.0),
		Cue.SPLIT: bake(300.0, 170.0, 0.16, 0.40, 0.30),
		Cue.EJECT: bake(240.0, 150.0, 0.11, 0.35, 0.45),
		Cue.THROW: bake(180.0, 420.0, 0.14, 0.32, 0.35),
		Cue.BURST: bake(150.0, 60.0, 0.42, 0.55, 0.85),
		Cue.DEVOUR: bake(220.0, 110.0, 0.30, 0.45, 0.25),
		Cue.DIE: bake(320.0, 70.0, 0.55, 0.45, 0.40),
		Cue.CLICK: bake(880.0, 880.0, 0.04, 0.22, 0.0),
	}

	for index in range(VOICES):
		var player := AudioStreamPlayer.new()
		player.name = "Voice%d" % index
		player.volume_db = volume_db
		add_child(player)
		_players.append(player)


## Builds one voice.
##
## A sine sweep from [param from_hz] to [param to_hz] over [param seconds], with
## [param noise] of the amplitude replaced by a deterministic hash, under an attack-decay
## envelope. That is the whole synthesiser, and it covers everything from a crumb to a
## death because those two differ only in where the sweep goes and how much of it is
## noise.
##
## [b]Deterministic, and that matters more than it sounds.[/b] The noise comes from
## [method Dot2DScatter._hash] rather than from [method @GlobalScope.randf], so the bank is
## byte-identical on every machine and every run — which is what makes it something a test
## can assert about rather than listen to.
static func bake(
	from_hz: float,
	to_hz: float,
	seconds: float,
	amplitude: float,
	noise: float
) -> AudioStreamWAV:
	var frames := maxi(1, int(seconds * float(RATE)))
	var data := PackedByteArray()
	data.resize(frames * 2)

	var phase := 0.0

	for index in range(frames):
		var t := float(index) / float(frames)

		# Exponential rather than linear, because pitch is heard logarithmically: a linear
		# sweep from 150 to 60 spends most of its time near the top and reads as a click.
		var hz := from_hz * pow(maxf(0.001, to_hz / from_hz), t)
		phase += TAU * hz / float(RATE)

		# Fast attack, exponential decay. Anything slower on the attack turns a blip into
		# a swell, and every one of these is meant to land on a frame.
		var attack := minf(1.0, t / 0.02)
		var envelope := attack * pow(1.0 - t, 1.8)

		var tone := sin(phase)
		var grit := Dot2DScatter._unit(Dot2DScatter._hash(index, 0x51D)) * 2.0 - 1.0
		var sample := lerpf(tone, grit, clampf(noise, 0.0, 1.0)) * envelope * amplitude

		var value := clampi(int(sample * 32767.0), -32768, 32767)
		# Little-endian 16-bit, which is what AudioStreamWAV.FORMAT_16_BITS expects.
		data[index * 2] = value & 0xFF
		data[index * 2 + 1] = (value >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	return stream


## Plays a cue.
##
## [param pitch] is a multiplier, so eating a haunch and eating a crumb are the same blip
## at different pitches rather than two voices that have to be kept in step.
func play(cue: Cue, pitch: float = 1.0) -> void:
	if muted or _players.is_empty():
		return

	var stream: AudioStreamWAV = _bank.get(cue)

	if stream == null:
		return

	# Round-robin, oldest first. Stealing the least recently started voice is what keeps a
	# burst of eating from silencing the death that happens during it.
	var player := _players[_next]
	_next = (_next + 1) % _players.size()

	player.stream = stream
	player.pitch_scale = clampf(pitch, 0.4, 2.4)
	player.volume_db = volume_db
	player.play()


## The pitch a piece of food of this size should sound at.
##
## Bigger is lower, which is the one mapping nobody has to be taught.
static func food_pitch(tier: int) -> float:
	return clampf(1.35 - 0.13 * float(tier), 0.6, 1.6)


func voices() -> int:
	return _players.size()


func baked() -> int:
	return _bank.size()


func describe() -> Dictionary:
	return {
		"voices": _players.size(),
		"baked": _bank.size(),
		"muted": muted,
		"volume_db": volume_db,
	}

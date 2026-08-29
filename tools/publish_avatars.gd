extends Node

## Packages this game's avatar parts into a signed dot-cloud pack.
##
## [codeblock]
## godot --headless --path . res://tools/publish_avatars.tscn
## godot --headless --path . res://tools/publish_avatars.tscn -- \
##     --out user://published --version 1.1.0 --key user://keys/content.key \
##     --mirror https://cdn.example/hungry/
## [/codeblock]
##
## [b]A build step, not a runtime path.[/b] It hashes every file synchronously, which is
## the right thing in a CLI and the wrong thing in a frame. What it produces is a static
## directory — `manifest.json` plus an `objects/` tree keyed by content hash — that drops
## behind any web server or CDN with no configuration, because the paths are immutable and
## can be cached for ever.
##
## Generating a key here is a convenience for getting started. **The private half lands on
## disk with whatever permissions the platform gives it**, and it is the key that
## authorises code execution on every player's machine — a pack can contain scripts, and
## this one does. Move it into a secrets store and delete the file.

const CHANNEL := "hungry.publish"

const DEFAULT_OUT := "user://hungry_published"
const DEFAULT_KEY := "user://hungry_keys/content.key"
const DEFAULT_PUB := "user://hungry_keys/content.pub"


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := _arg(args, "--out", DEFAULT_OUT)
	var version := _arg(args, "--version", "1.0.0")
	var key_path := _arg(args, "--key", DEFAULT_KEY)
	var public_path := _arg(args, "--public", DEFAULT_PUB)
	var mirror := _arg(args, "--mirror", "")

	print("dot-2d-hungry: publishing avatar content")
	print("")

	var key := await _key(key_path, public_path)

	if key == "":
		get_tree().quit(1)
		return

	var mirrors := PackedStringArray()

	if mirror != "":
		mirrors.append(mirror)

	var published := HungryContentSource.publish(
		out_dir.path_join(HungryContentSource.PACK_ID), key, version, mirrors
	)

	if not published.ok:
		print("  FAILED  %s" % str(published.error))
		get_tree().quit(1)
		return

	var result: Dictionary = published.value

	print("  content id       %s" % HungryContentSource.PACK_ID)
	print("  version          %s" % version)
	print("  files            %d" % int(result.get("files", 0)))
	print("  objects          %d (%d deduplicated)" % [
		int(result.get("objects", 0)), int(result.get("deduped", 0))
	])
	print("  signed           %s" % ("yes" if bool(result.get("signed", false)) else "NO"))
	print("  manifest         %s" % str(result.get("manifest_path", "")))
	print("")
	print("  mounts at        res://dot_cloud/%s/%s/" % [
		HungryContentSource.PACK_ID, version
	])
	print("")
	print("  A client needs the public key in DotCloudConfig.trusted_keys under the id")
	print("  'default', and this directory reachable over HTTP or on disk.")
	print("  The public key is at %s" % public_path)

	get_tree().quit(0)


## Loads the signing key, generating one the first time.
##
## Refuses to publish unsigned rather than falling back to it. A default-configured client
## refuses unsigned content, so an unsigned pack is one nobody can mount — quietly
## producing one would be a build that succeeds and content that never loads.
func _key(key_path: String, public_path: String) -> String:
	if FileAccess.file_exists(key_path):
		var existing := DotPaths.read_text(key_path)

		if existing.ok:
			print("  signing key      %s" % key_path)
			return str(existing.value)

		print("  FAILED  could not read %s: %s" % [key_path, str(existing.error)])
		return ""

	print("  signing key      generating a new one")
	var made := DotCloudPublisher.generate_keys(key_path, public_path)

	if not made.ok:
		print("  FAILED  %s" % str(made.error))
		return ""

	var pair: Dictionary = made.value
	return str(pair["private"])


static func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var index := args.find(name)

	if index >= 0 and index + 1 < args.size():
		return args[index + 1]

	return fallback

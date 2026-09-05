extends Node

## The launcher: a name, an address, and a button.
##
## [codeblock]
## godot --path .                                  # the menu
## godot --path . -- --connect 127.0.0.1:27081     # straight in
## godot --path . -- --offline                     # bots, no server
## godot --headless --path . -- --seconds 3        # exit on its own, for a sweep
## [/codeblock]
##
## [b]This is the application, and the client is a scene it loads.[/b] dot-server's signon
## refuses an absolute scene path a server names — a server that could name one could ask
## every client to load any scene in their build — so a game that ships inside its own
## build cannot be handed its client scene by the server. It loads its own, and this is
## the file that does it. A game delivered through dot-cloud puts a relative path in
## [member DotGameDescriptor.client_scene] instead and never writes this.
##
## In a browser the address comes from the query string, so one export serves every
## server. See `web/embed.html`.

const CHANNEL := "hungry.play"

const CLIENT_SCENE := "res://game/client/hungry_client.tscn"

## Where the client's half of the connection lives.
##
## [b]Named "Server", which looks wrong and is not.[/b] Godot routes an RPC by the
## receiver's node path relative to its [MultiplayerAPI] root, so a call from the server's
## node arrives addressed to whatever that node is called. [DotClientLink] therefore has
## to sit at the same relative path as [DotServer], and both of them are "Server".
const LINK_NAME := &"Server"

var link: DotClientLink = null
var client: HungryClient = null

var _root: Node = null
var _menu: CanvasLayer = null
var _address: LineEdit = null
var _player_name: LineEdit = null
var _status: Label = null
var _connect_button: Button = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)

	_arm_exit_timer()

	_root = Node.new()
	_root.name = "ClientSide"
	add_child(_root)

	_build_menu()

	var wanted := _wanted_address()

	if "--offline" in OS.get_cmdline_user_args():
		_play_offline()
	elif wanted != "":
		_address.text = wanted
		_connect()


## The address to join, from the command line or from the page.
##
## The query string is what makes one web export serve every server: a link carries
## `?server=…` and the page does not have to be rebuilt per host.
func _wanted_address() -> String:
	# The query string first, because in a browser it is the only one a link can set and
	# it is what makes one export serve every server.
	if DotPlatform.is_web():
		var from_page := DotWeb.query_param("server")

		if from_page != "":
			return from_page

	# Both argument lists. `--connect x` after a `--` lands in the user args, and the same
	# pair passed to the web export's Engine lands in the full ones — a page that got that
	# wrong would silently show the menu instead of joining.
	for entry in [OS.get_cmdline_user_args(), OS.get_cmdline_args()]:
		var args: PackedStringArray = entry
		var index := args.find("--connect")

		if index >= 0 and index + 1 < args.size():
			return args[index + 1]

	return ""


func _build_menu() -> void:
	_menu = CanvasLayer.new()
	_menu.name = "Menu"
	add_child(_menu)

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.055, 0.062, 0.078)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -220.0
	panel.offset_right = 220.0
	panel.offset_top = -170.0
	panel.offset_bottom = 170.0
	_menu.add_child(panel)

	var column := VBoxContainer.new()
	panel.add_child(column)

	var title := Label.new()
	title.text = "hungry"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var blurb := Label.new()
	blurb.text = "Eat everything. Do not be eaten."
	blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(blurb)

	_player_name = LineEdit.new()
	_player_name.placeholder_text = "Your name"
	_player_name.text = "Player"
	_player_name.max_length = 24
	column.add_child(_player_name)

	_address = LineEdit.new()
	_address.placeholder_text = "host:port"
	_address.text = "127.0.0.1:27081"
	column.add_child(_address)

	_connect_button = Button.new()
	_connect_button.text = "Join"
	_connect_button.pressed.connect(_connect)
	column.add_child(_connect_button)

	var offline := Button.new()
	offline.text = "Play offline"
	offline.pressed.connect(_play_offline)
	column.add_child(offline)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)

	# A browser tab cannot listen, so there is nothing to host from here — and saying so
	# once is better than a Host button that fails.
	if DotPlatform.is_web():
		_status.text = "Browser build: client only."


func _connect() -> void:
	if link != null:
		return

	_connect_button.disabled = true
	_status.text = "Connecting…"

	link = DotClientLink.new()
	link.name = String(LINK_NAME)
	link.player_name = _player_name.text.strip_edges()
	_root.add_child(link)

	link.phase_changed.connect(func(_phase: DotClientLink.Phase, text: String) -> void:
		if text != "":
			_status.text = text
	)
	link.download_progress.connect(func(_fraction: float, text: String) -> void:
		_status.text = text
	)
	link.spawned.connect(_on_spawned)
	link.disconnected.connect(_on_disconnected)

	var connecting: DotResult = await link.connect_to_server(_address.text.strip_edges())

	if not connecting.ok:
		_status.text = str(connecting.error)
		_connect_button.disabled = false
		_drop_link()


func _on_spawned() -> void:
	_status.text = ""
	_menu.hide()
	_spawn_client(false)


func _on_disconnected(reason: String) -> void:
	_status.text = reason if reason != "" else "Disconnected."
	_connect_button.disabled = false
	_menu.show()

	if client != null and is_instance_valid(client):
		client.queue_free()
		client = null

	_drop_link()


func _drop_link() -> void:
	if link != null and is_instance_valid(link):
		link.queue_free()

	link = null


func _play_offline() -> void:
	_menu.hide()
	_spawn_client(true)


func _spawn_client(offline: bool) -> void:
	if client != null and is_instance_valid(client):
		return

	var packed: Variant = load(CLIENT_SCENE)

	if not (packed is PackedScene):
		_status.text = "The client scene is missing."
		_menu.show()
		return

	client = (packed as PackedScene).instantiate() as HungryClient
	client.force_offline = offline
	_root.add_child(client)

	DotLog.info(CHANNEL, "playing", {"offline": offline})


## Runs for `--seconds N` and then exits 0. Zero, the default, means forever.
##
## This scene is interactive: it waits for a person, so a blanket "run every example"
## sweep stalls here and the scene is therefore opened by nothing. That is the state a
## load-time regression hides in — a renamed node or a moved resource breaks it and no
## suite in the repository notices. Bounding it is what makes it sweepable, the same
## way dot-auth's issuer example is.
##
## Not a self-test: reaching the timeout only proves the scene loaded and ran frames.
## It exits 0 for exactly that claim and no larger one.
func _arm_exit_timer() -> void:
	var argv := OS.get_cmdline_user_args()
	var at := argv.find("--seconds")
	if at < 0 or at + 1 >= argv.size():
		return

	var seconds := maxf(0.0, argv[at + 1].to_float())
	if seconds <= 0.0:
		return

	print("Exiting in %.1f seconds (--seconds)." % seconds)
	await get_tree().create_timer(seconds).timeout
	print("--seconds elapsed; exiting.")
	get_tree().quit(0)

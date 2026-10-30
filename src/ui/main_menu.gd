extends Control
## Menu principal : Solo / Héberger / Rejoindre (parties LAN détectées ou IP saisie).

@onready var name_edit: LineEdit = %NameEdit
@onready var game_name_edit: LineEdit = %GameNameEdit
@onready var ip_edit: LineEdit = %IpEdit
@onready var lan_list: ItemList = %LanList
@onready var status: Label = %Status

var _lan_ips: Array[String] = []


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	name_edit.text = Net.player_name
	game_name_edit.text = "Partie de " + Net.player_name
	Net.lan_games_changed.connect(_refresh_lan)
	Net.connection_failed.connect(func(reason: String): status.text = reason)
	Net.start_lan_discovery()
	%SoloButton.pressed.connect(_on_solo)
	%HostButton.pressed.connect(_on_host)
	%JoinButton.pressed.connect(_on_join_ip)
	%QuitButton.pressed.connect(func(): get_tree().quit())
	lan_list.item_activated.connect(_on_lan_activated)
	status.text = "Recherche de parties sur le réseau local…"
	_check_autostart()


func _exit_tree() -> void:
	Net.stop_lan_discovery()


func _apply_names() -> void:
	if not name_edit.text.strip_edges().is_empty():
		Net.player_name = name_edit.text.strip_edges()
	if not game_name_edit.text.strip_edges().is_empty():
		Net.game_name = game_name_edit.text.strip_edges()


func _on_solo() -> void:
	_apply_names()
	if Net.host(false) == OK:
		Net.set_my_choice(Net.players[1].class_id, Net.players[1].race_id, true)
		get_tree().change_scene_to_file(Net.LOBBY_SCENE)


func _on_host() -> void:
	_apply_names()
	if Net.host(true) == OK:
		get_tree().change_scene_to_file(Net.LOBBY_SCENE)


func _on_join_ip() -> void:
	_apply_names()
	var ip := ip_edit.text.strip_edges()
	if ip.is_empty():
		status.text = "Saisis une adresse IP ou choisis une partie dans la liste."
		return
	status.text = "Connexion à %s…" % ip
	Net.join(ip)


func _on_lan_activated(index: int) -> void:
	if index < _lan_ips.size():
		_apply_names()
		status.text = "Connexion à %s…" % _lan_ips[index]
		Net.join(_lan_ips[index], Net.lan_games[_lan_ips[index]].get("port", Net.DEFAULT_PORT))


func _refresh_lan(games: Dictionary) -> void:
	lan_list.clear()
	_lan_ips.clear()
	for ip in games:
		var g: Dictionary = games[ip]
		lan_list.add_item("%s — %s  (%d/%d)" % [g.get("name", "?"), ip, g.get("players", 0), g.get("max_players", 2)])
		_lan_ips.append(ip)
	if games.is_empty():
		status.text = "Aucune partie détectée pour l'instant (double-clic sur une partie pour la rejoindre)."
	else:
		status.text = "%d partie(s) trouvée(s) — double-clic pour rejoindre." % games.size()


## Arguments en ligne de commande pour les tests : `-- --host` ou `-- --join 127.0.0.1`.
func _check_autostart() -> void:
	var args := OS.get_cmdline_user_args()
	if "--solo" in args:
		_on_solo.call_deferred()
	elif "--host" in args:
		_on_host.call_deferred()
	elif "--join" in args:
		var i := args.find("--join")
		ip_edit.text = args[i + 1] if i + 1 < args.size() else "127.0.0.1"
		_on_join_ip.call_deferred()

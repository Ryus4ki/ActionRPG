extends Node
## Autoload « Net » : hébergement / connexion ENet, découverte LAN par broadcast UDP,
## liste des joueurs du lobby, lancement de partie.
##
## Modèle : l'hôte (peer 1) est l'autorité. Le mode Solo = héberger sans annoncer sur le LAN.

signal lan_games_changed(games: Dictionary)      # ip -> {name, players, max_players, port, last_seen}
signal players_changed(players: Dictionary)      # peer_id -> {name, class_id, race_id, ready}
signal connection_failed(reason: String)
signal connected_to_host
signal disconnected_from_host
signal game_starting

const DEFAULT_PORT := 7777
const DISCOVERY_PORT := 7778
const MAX_PLAYERS := 2
const BROADCAST_INTERVAL := 1.0
const GAME_TAG := "ActionRPG"
const GAME_SCENE := "res://scenes/game.tscn"
const LOBBY_SCENE := "res://scenes/lobby.tscn"
const MENU_SCENE := "res://scenes/main_menu.tscn"

var player_name := "Aventurier"
var game_name := "Partie"
var is_host := false
var is_solo := false
var in_game := false
var players: Dictionary = {}          # peer_id -> infos (vérité chez l'hôte, répliquée)
var lan_games: Dictionary = {}

var _broadcaster: PacketPeerUDP
var _listener: PacketPeerUDP
var _broadcast_timer := 0.0
var _advertise := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	player_name = "Aventurier %d" % (randi() % 900 + 100)


func _process(delta: float) -> void:
	if _advertise and _broadcaster:
		_broadcast_timer -= delta
		if _broadcast_timer <= 0.0:
			_broadcast_timer = BROADCAST_INTERVAL
			var msg := JSON.stringify({"tag": GAME_TAG, "name": game_name, "players": players.size(),
				"max_players": MAX_PLAYERS, "port": DEFAULT_PORT})
			_broadcaster.put_packet(msg.to_utf8_buffer())
	if _listener:
		while _listener.get_available_packet_count() > 0:
			var pkt := _listener.get_packet()
			var ip := _listener.get_packet_ip()
			var data = JSON.parse_string(pkt.get_string_from_utf8())
			if data is Dictionary and data.get("tag") == GAME_TAG:
				data["last_seen"] = Time.get_ticks_msec()
				lan_games[ip] = data
				lan_games_changed.emit(lan_games)
		# Oublie les parties silencieuses depuis 4 s.
		var now := Time.get_ticks_msec()
		var changed := false
		for ip in lan_games.keys():
			if now - lan_games[ip].get("last_seen", 0) > 4000:
				lan_games.erase(ip)
				changed = true
		if changed:
			lan_games_changed.emit(lan_games)


# ------------------------------------------------------------------ hôte

## Héberge une partie. `advertise` = annoncer sur le LAN (faux en solo).
func host(advertise: bool = true, port: int = DEFAULT_PORT) -> Error:
	stop()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		connection_failed.emit("Impossible d'ouvrir le port %d (%s)" % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_host = true
	is_solo = not advertise
	players = {1: _new_player_info(player_name)}
	players_changed.emit(players)
	if advertise:
		_broadcaster = PacketPeerUDP.new()
		_broadcaster.set_broadcast_enabled(true)
		_broadcaster.set_dest_address("255.255.255.255", DISCOVERY_PORT)
		_advertise = true
		_broadcast_timer = 0.0
	return OK


func start_game() -> void:
	if not is_host:
		return
	_advertise = false  # plus de nouveaux joueurs une fois la partie lancée
	_rpc_start_game.rpc()


@rpc("authority", "call_local", "reliable")
func _rpc_start_game() -> void:
	in_game = true
	game_starting.emit()
	get_tree().change_scene_to_file(GAME_SCENE)


# ------------------------------------------------------------------ client

func join(ip: String, port: int = DEFAULT_PORT) -> Error:
	stop()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		connection_failed.emit("Connexion impossible à %s:%d (%s)" % [ip, port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	is_host = false
	is_solo = false
	return OK


## Écoute les annonces LAN (menu principal).
func start_lan_discovery() -> void:
	if _listener:
		return
	_listener = PacketPeerUDP.new()
	var err := _listener.bind(DISCOVERY_PORT)
	if err != OK:
		push_warning("Découverte LAN indisponible (port %d) : %s" % [DISCOVERY_PORT, error_string(err)])
		_listener = null
	lan_games.clear()


func stop_lan_discovery() -> void:
	if _listener:
		_listener.close()
		_listener = null


# ------------------------------------------------------------------ lobby

func set_my_choice(class_id: String, race_id: String, ready: bool) -> void:
	_rpc_set_choice.rpc_id(1, class_id, race_id, ready)


@rpc("any_peer", "call_local", "reliable")
func _rpc_set_choice(class_id: String, race_id: String, ready: bool) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	if players.has(id):
		players[id].class_id = class_id
		players[id].race_id = race_id
		players[id].ready = ready
		_broadcast_players()


@rpc("any_peer", "reliable")
func _rpc_register(name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	players[id] = _new_player_info(name)
	_broadcast_players()


func _broadcast_players() -> void:
	_rpc_players.rpc(players)
	players_changed.emit(players)


@rpc("authority", "reliable")
func _rpc_players(p: Dictionary) -> void:
	players = p
	players_changed.emit(players)


func all_ready() -> bool:
	for id in players:
		if not players[id].ready:
			return false
	return true


func _new_player_info(name: String) -> Dictionary:
	return {"name": name, "class_id": "fighter", "race_id": "human", "ready": false}


# ------------------------------------------------------------------ commun

func stop() -> void:
	_advertise = false
	if _broadcaster:
		_broadcaster.close()
		_broadcaster = null
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	is_host = false
	is_solo = false
	in_game = false
	players.clear()


func leave_to_menu() -> void:
	stop()
	get_tree().change_scene_to_file(MENU_SCENE)


func local_peer_id() -> int:
	return multiplayer.get_unique_id()


## Adresses IPv4 locales utiles pour qu'un coéquipier rejoigne (hors 127.x et liens locaux 169.254.x).
## Les adresses de réseau privé (192.168.x, 10.x, 172.16-31.x) sont listées en premier.
static func local_ipv4_addresses() -> Array[String]:
	var priv: Array[String] = []
	var other: Array[String] = []
	for ip in IP.get_local_addresses():
		if ip.contains(":") or ip.begins_with("127.") or ip.begins_with("169.254."):
			continue
		var parts := ip.split(".")
		if parts.size() != 4:
			continue
		var a := int(parts[0])
		var b := int(parts[1])
		if a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31):
			priv.append(ip)
		else:
			other.append(ip)
	return priv + other


func _on_peer_connected(id: int) -> void:
	if is_host and in_game:
		# Pas de connexion en cours de partie dans cette version.
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _on_peer_disconnected(id: int) -> void:
	if is_host:
		players.erase(id)
		_broadcast_players()


func _on_connected_to_server() -> void:
	_rpc_register.rpc_id(1, player_name)
	connected_to_host.emit()
	get_tree().change_scene_to_file(LOBBY_SCENE)


func _on_connection_failed() -> void:
	stop()
	connection_failed.emit("L'hôte ne répond pas.")


func _on_server_disconnected() -> void:
	stop()
	disconnected_from_host.emit()
	get_tree().change_scene_to_file(MENU_SCENE)

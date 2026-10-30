extends Node
## Test réseau à deux instances headless.
##   Hôte   : godot --headless --path . res://tests/net_smoke.tscn -- --host
##   Client : godot --headless --path . res://tests/net_smoke.tscn -- --join 127.0.0.1
## Le nœud se détache de la scène courante pour survivre aux changements de scène.
## En solo (sans argument) : héberge sans annoncer et vérifie la boucle de combat.

const TIMEOUT := 40.0

var role := "solo"
var hits_seen := 0
var hits_on_enemies := 0
var hits_on_me := 0
var t0 := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--host" in args:
		role = "host"
	elif "--join" in args:
		role = "client"
	_detach.call_deferred()


func _detach() -> void:
	var tree := get_tree()
	get_parent().remove_child(self)
	tree.root.add_child(self)
	t0 = Time.get_ticks_msec() / 1000.0
	EventBus.hit_resolved.connect(func(target: Node3D, r: Dictionary):
		hits_seen += 1
		if r.get("hit", false):
			if target.is_in_group("players"):
				hits_on_me += 1
			else:
				hits_on_enemies += 1
	)
	_run()


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - t0


func _fail(msg: String) -> void:
	print("=== NET %s ÉCHEC : %s ===" % [role.to_upper(), msg])
	get_tree().quit(1)


func _run() -> void:
	match role:
		"host":
			await _run_host()
		"client":
			await _run_client()
		_:
			await _run_solo()


# ---------------------------------------------------------------- hôte

func _run_host() -> void:
	Net.player_name = "Hote"
	if Net.host(true) != OK:
		_fail("host() a échoué")
		return
	Net.set_my_choice("fighter", "human", true)
	print("[hôte] en attente d'un client…")
	while Net.players.size() < 2 or not Net.all_ready():
		if _elapsed() > TIMEOUT:
			_fail("aucun client prêt")
			return
		await get_tree().create_timer(0.1).timeout
	print("[hôte] client prêt : %s — lancement" % Net.players[Net.players.keys()[1]].name)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	# Attendre que le client ait fini (il se déconnecte) ou le timeout.
	while Net.players.size() > 1 and _elapsed() < TIMEOUT:
		await get_tree().create_timer(0.2).timeout
	var players := game.get_node("Players").get_children()
	var enemies_alive := 0
	for e in game.get_node("Enemies").get_children():
		if e.health.is_alive():
			enemies_alive += 1
	print("[hôte] résolutions=%d touches ennemis=%d ; ennemis vivants=%d ; joueurs=%d" % [hits_seen, hits_on_enemies, enemies_alive, players.size()])
	var ok := hits_on_enemies > 0
	print("=== NET HOST %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- client

func _run_client() -> void:
	Net.player_name = "Client"
	var args := OS.get_cmdline_user_args()
	var ip := args[args.find("--join") + 1]
	print("[client] connexion à %s…" % ip)
	if Net.join(ip) != OK:
		_fail("join() a échoué")
		return
	while not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if _elapsed() > 15.0:
			_fail("connexion impossible")
			return
		await get_tree().create_timer(0.1).timeout
	await get_tree().create_timer(0.3).timeout  # laisser le lobby s'installer
	Net.set_my_choice("wizard", "elf", true)
	print("[client] connecté, prêt (magicien elfe)")
	var game := await _wait_game()
	if game == null:
		return
	# Attendre le spawn de notre joueur et des monstres.
	var me: PlayerCharacter = null
	while _elapsed() < TIMEOUT:
		me = game.get_node("Players").get_node_or_null("Player_%d" % multiplayer.get_unique_id())
		if me and game.get_node("Enemies").get_child_count() >= 3 and me.health.max_hp > 0:
			break
		await get_tree().create_timer(0.1).timeout
	if me == null:
		_fail("joueur local non spawné")
		return
	var enemies := game.get_node("Enemies").get_children()
	print("[client] je suis %s PV %d/%d CA %d ; %d ennemis visibles ; hôte visible : %s" % [
		me.stats.display_name, me.health.hp, me.health.max_hp, me.stats.armor_class(), enemies.size(),
		game.get_node("Players").get_node_or_null("Player_1") != null])
	if enemies.size() != 3 or me.health.max_hp <= 0:
		_fail("réplication initiale incomplète")
		return
	# On pilote le joueur « à la main » : désactiver la lecture clavier locale.
	me.is_local = false
	# Un magicien niveau 1 ne survit pas à trois monstres : on teste la réplication, pas l'équilibrage.
	me.request_action("debug_god")
	var target: Enemy = enemies[0]
	var p0 := me.global_position
	var attacks := 0
	var start_hp: int = target.health.hp
	while _elapsed() < TIMEOUT:
		await get_tree().physics_frame
		if not is_instance_valid(target) or target.health.is_dead:
			break
		var to := target.global_position - me.global_position
		to.y = 0.0
		var yaw := atan2(-to.x, -to.z)
		if to.length() > 1.6:
			# Avancer : input "avant" relatif à la caméra orientée vers la cible.
			me._rpc_input.rpc_id(1, Vector2(0, -1), yaw, false)
		else:
			me._rpc_input.rpc_id(1, Vector2.ZERO, yaw, false)
			if Engine.get_physics_frames() % 10 == 0:
				me.request_action("attack")
				attacks += 1
		if hits_on_enemies >= 2:
			break
	if not is_instance_valid(me):
		_fail("joueur local détruit en cours de test (déconnexion ?)")
		return
	var moved := me.global_position.distance_to(p0)
	var end_hp: int = target.health.hp if is_instance_valid(target) else 0
	print("[client] déplacé de %.1f m ; attaques demandées=%d ; résolutions reçues=%d ; touches ennemis=%d ; PV cible %d→%d" % [
		moved, attacks, hits_seen, hits_on_enemies, start_hp, end_hp])
	var ok := moved > 2.0 and hits_on_enemies > 0 and end_hp < start_hp
	print("=== NET CLIENT %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- solo

func _run_solo() -> void:
	Net.player_name = "Solo"
	Net.host(false)
	Net.set_my_choice("fighter", "human", true)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	var me: PlayerCharacter = null
	while _elapsed() < TIMEOUT:
		me = game.get_node("Players").get_node_or_null("Player_1")
		if me and game.get_node("Enemies").get_child_count() >= 3:
			break
		await get_tree().create_timer(0.1).timeout
	if me == null:
		_fail("joueur non spawné")
		return
	me.is_local = false
	var enemies := game.get_node("Enemies").get_children()
	var target: Enemy = enemies[0]
	var tc := -Vector3(target.global_position.x, 0, target.global_position.z).normalized()
	me.global_position = target.global_position + tc * 5.0 + Vector3(0, 0.1, 0)
	var attacks := 0
	while _elapsed() < TIMEOUT:
		await get_tree().physics_frame
		var nearest: Enemy = null
		var nd := 999.0
		for e in game.get_node("Enemies").get_children():
			if e.health.is_alive():
				var d: float = e.global_position.distance_to(me.global_position)
				if d < nd:
					nd = d
					nearest = e
		if nearest and nd < 2.0:
			var to := nearest.global_position - me.global_position
			me._cam_yaw = atan2(-to.x, -to.z)
			if me.try_attack():
				attacks += 1
		if hits_on_enemies >= 3 and hits_on_me >= 1:
			break
	print("[solo] attaques=%d résolutions=%d touches ennemis=%d touches sur moi=%d PV %d/%d" % [
		attacks, hits_seen, hits_on_enemies, hits_on_me, me.health.hp, me.health.max_hp])
	var ok := attacks > 0 and hits_on_enemies > 0
	print("=== NET SOLO %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


func _wait_game() -> Node:
	while _elapsed() < TIMEOUT:
		var cur := get_tree().current_scene
		if cur and cur.name == "Game":
			return cur
		await get_tree().create_timer(0.1).timeout
	_fail("la scène de jeu n'a pas été chargée")
	return null

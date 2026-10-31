extends Node3D
## Scène de partie : charge le niveau, fait apparaître joueurs et monstres (hôte) via les
## MultiplayerSpawner, et relaie les événements de combat de l'hôte vers les clients.

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const ENEMY_SCENE := preload("res://scenes/enemy.tscn")
const PROJECTILE_SCENE := preload("res://scenes/projectile.tscn")
const LOOT_SCENE := preload("res://scenes/loot_drop.tscn")

## Niveau de secours si Net.level_path est vide ou introuvable.
@export var level_scene: PackedScene = preload("res://scenes/test_arena.tscn")

@onready var level_root: Node3D = $Level
@onready var players_root: Node3D = $Players
@onready var enemies_root: Node3D = $Enemies
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var enemy_spawner: MultiplayerSpawner = $EnemySpawner
@onready var projectile_spawner: MultiplayerSpawner = $ProjectileSpawner
@onready var projectiles_root: Node3D = $Projectiles
@onready var loot_spawner: MultiplayerSpawner = $LootSpawner

var level: Node3D
var _peers_ready: Dictionary = {}  # peer_id -> true quand le client a chargé la scène
var _spawned := false
var _cleared := false
## Statistiques de la partie (hôte) : peer_id -> {damage_dealt, damage_taken, kills, downs, potions, gold}.
var run_stats: Dictionary = {}
var _run_start_msec := 0


func _ready() -> void:
	add_to_group("game")
	player_spawner.spawn_function = _spawn_player
	enemy_spawner.spawn_function = _spawn_enemy
	projectile_spawner.spawn_function = _spawn_projectile
	loot_spawner.spawn_function = _spawn_loot
	FloatingText.install(self)
	Sound.start_ambient()
	tree_exiting.connect(Sound.stop_ambient)
	var chosen: PackedScene = load(Net.level_path) if Net.level_path != "" and ResourceLoader.exists(Net.level_path) else null
	level = (chosen if chosen else level_scene).instantiate()
	level_root.add_child(level)
	if multiplayer.is_server():
		EventBus.hit_resolved.connect(_on_hit_resolved_server)
		EventBus.creature_died.connect(_on_creature_died_server)
		EventBus.creature_downed.connect(_on_creature_downed_server)
		multiplayer.peer_disconnected.connect(_on_peer_left)
		_peers_ready[1] = true
		_try_spawn_all.call_deferred()
		# Filet de sécurité : si un client ne répond pas, on lance quand même après 5 s.
		get_tree().create_timer(5.0).timeout.connect(func(): _spawn_all_once(true))
	else:
		_notify_ready_until_spawned()


## Client : signale à l'hôte que la scène est chargée, en répétant tant que rien n'est apparu
## (l'hôte peut charger sa propre scène une image après nous).
func _notify_ready_until_spawned() -> void:
	await get_tree().create_timer(0.2).timeout  # l'hôte charge sa scène une image après nous
	for _i in 20:
		_rpc_level_ready.rpc_id(1)
		await get_tree().create_timer(0.5).timeout
		if players_root.get_child_count() > 0 or not is_inside_tree():
			return


@rpc("any_peer", "reliable")
func _rpc_level_ready() -> void:
	if not multiplayer.is_server():
		return
	_peers_ready[multiplayer.get_remote_sender_id()] = true
	_try_spawn_all()


func _try_spawn_all() -> void:
	for id in Net.players:
		if not _peers_ready.has(id):
			return
	_spawn_all_once(false)


func _spawn_all_once(forced: bool) -> void:
	if _spawned:
		return
	_spawned = true
	if forced:
		push_warning("Lancement forcé : certains clients n'ont pas confirmé le chargement.")
	# Deux images pour laisser le navmesh se synchroniser.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var i := 0
	var ids := Net.players.keys()
	if ids.is_empty():
		ids = [1]
	checkpoint = level.player_spawn_position(0)
	_run_start_msec = Time.get_ticks_msec()
	for id in ids:
		var info: Dictionary = Net.players.get(id, {})
		var spawn_pos: Vector3 = level.player_spawn_by_id(Net.spawn_id, i) if level.has_method("player_spawn_by_id") else level.player_spawn_position(i)
		var spawn_yaw: float = level.player_spawn_yaw(Net.spawn_id) if level.has_method("player_spawn_yaw") else 0.0
		# Reprise d'une partie : le personnage revient là où il s'était arrêté (s'il était dans cette zone).
		var st: Dictionary = Net.party_state.get(id, {})
		if Net.fresh_start and st.get("zone", "") == Net.level_path and st.get("pos") is Array and (st.pos as Array).size() == 3:
			var saved := Vector3(float(st.pos[0]), float(st.pos[1]) + 0.2, float(st.pos[2]))
			if saved.y > -5.0:
				spawn_pos = saved
				spawn_yaw = float(st.get("yaw", spawn_yaw))
		player_spawner.spawn({
			"peer_id": id,
			"class_id": info.get("class_id", "fighter"),
			"race_id": info.get("race_id", "human"),
			"name": info.get("name", "Aventurier"),
			"position": spawn_pos,
			"yaw": spawn_yaw,
		})
		# Personnage conservé d'une zone à l'autre.
		if Net.party_state.has(id):
			var p := players_root.get_node_or_null("Player_%d" % id)
			if p:
				p.load_state(Net.party_state[id])
		var pl := players_root.get_node_or_null("Player_%d" % id)
		if pl:
			pl.add_progress("zone:" + Net.level_path)
		i += 1
	checkpoint = level.player_spawn_by_id(Net.spawn_id, 0) if level.has_method("player_spawn_by_id") else level.player_spawn_position(0)
	_rpc_zone_entered.rpc(level.zone_name if "zone_name" in level else Net.LEVELS.get(Net.level_path, ""))
	for e in level.enemy_spawn_list():
		if GameData.monster(e.monster_id).is_empty():
			push_warning("Monstre inconnu pour le spawn : " + e.monster_id)
			continue
		enemy_spawner.spawn(e)


## Appelé sur TOUTES les machines par le MultiplayerSpawner avec les mêmes données.
func _spawn_player(data: Dictionary) -> Node:
	var p: PlayerCharacter = PLAYER_SCENE.instantiate()
	p.name = "Player_%d" % data.peer_id
	p.peer_id = data.peer_id
	p.class_id = data.class_id
	p.start_class = data.class_id  # classe de création (caractéristiques) ; le job suit ensuite l'arme
	p.race_id = data.race_id
	p.player_name = data.name
	p.position = data.position
	p.rotation.y = float(data.get("yaw", 0.0))  # face à la zone (et la caméra derrière, voir PlayerCharacter._ready)
	return p


## Hôte : fait apparaître un projectile de sort chez tout le monde.
func spawn_projectile(data: Dictionary) -> void:
	projectile_spawner.spawn(data)


func _spawn_projectile(data: Dictionary) -> Node:
	var p: Projectile = PROJECTILE_SCENE.instantiate()
	p.caster_path = data.get("caster", NodePath())
	p.spell_id = data.get("spell_id", "")
	p.slot_level = data.get("slot_level", 0)
	p.position = data.get("origin", Vector3.ZERO)
	p.direction = data.get("direction", Vector3.FORWARD)
	p.speed = data.get("speed", 25.0)
	p.max_range = data.get("max_range", 30.0)
	p.radius = data.get("radius", 0.15)
	p.color = data.get("color", Color(1, 0.5, 0.1))
	p.homing = data.get("homing", false)
	p.target_path = data.get("target", NodePath())
	p.explode_on_arrival = data.get("explode_on_arrival", false)
	p.target_point = data.get("target_point", Vector3.ZERO)
	p.hostile = data.get("hostile", false)
	p.attack = data.get("attack", {})
	return p


## Hôte : fait apparaître un monstre en cours de partie (renforts du boss…).
func spawn_enemy_at(monster_id: String, pos: Vector3) -> void:
	if not multiplayer.is_server() or GameData.monster(monster_id).is_empty():
		return
	enemy_spawner.spawn({"monster_id": monster_id, "position": pos})


## Hôte : vrai s'il ne reste aucun monstre vivant.
func all_enemies_dead() -> bool:
	for e in enemies_root.get_children():
		if e is Creature and e.health.is_alive():
			return false
	return true


func stat_add(peer_id: int, key: String, amount: int) -> void:
	if not run_stats.has(peer_id):
		run_stats[peer_id] = {"damage_dealt": 0, "damage_taken": 0, "kills": 0, "downs": 0, "potions": 0, "gold": 0}
	run_stats[peer_id][key] = int(run_stats[peer_id].get(key, 0)) + amount


## Résumé de fin de partie envoyé à tous (hôte).
func _build_summary() -> Dictionary:
	var players: Array = []
	for p in players_root.get_children():
		if p is PlayerCharacter:
			var st: Dictionary = run_stats.get(p.peer_id, {})
			players.append({
				"name": p.player_name, "class": GameData.player_class(p.class_id).get("name", p.class_id),
				"race": GameData.race(p.race_id).get("name", p.race_id), "level": p.stats.level, "xp": p.stats.xp,
				"gold": p.inventory.gold if p.inventory else 0,
				"damage_dealt": st.get("damage_dealt", 0), "damage_taken": st.get("damage_taken", 0),
				"kills": st.get("kills", 0), "downs": st.get("downs", 0), "potions": st.get("potions", 0),
			})
	return {
		"level_name": Net.LEVELS.get(Net.level_path, "Niveau"),
		"duration": float(Time.get_ticks_msec() - _run_start_msec) / 1000.0,
		"players": players,
	}


@rpc("authority", "call_local", "reliable")
func _rpc_run_finished(summary: Dictionary) -> void:
	EventBus.run_finished.emit(summary)


func _on_creature_died_server(c: Node3D) -> void:
	if not multiplayer.is_server() or not (c is Enemy) or _cleared:
		return
	if c.last_attacker is PlayerCharacter:
		stat_add(c.last_attacker.peer_id, "kills", 1)
	# Quêtes : tout le groupe progresse sur les objectifs de chasse.
	for p in players_root.get_children():
		if p is PlayerCharacter:
			p.on_party_kill(c.monster_id)
	# Réapparition (zones extérieures) : même monstre, même poste, après le délai.
	var info: Dictionary = c.spawn_info
	if float(info.get("respawn", 0.0)) > 0.0:
		var delay: float = float(info.respawn)
		get_tree().create_timer(delay).timeout.connect(func():
			if is_instance_valid(self) and multiplayer.is_server():
				enemy_spawner.spawn(info))
	# Dehors, pas de « zone nettoyée ».
	if "track_clear" in level and not level.track_clear:
		return
	# On laisse une image aux renforts éventuels d'apparaître avant de vérifier.
	await get_tree().physics_frame
	if _cleared or not all_enemies_dead():
		return
	_cleared = true
	_rpc_level_cleared.rpc()
	await get_tree().create_timer(2.5).timeout
	_rpc_run_finished.rpc(_build_summary())


@rpc("authority", "call_local", "reliable")
func _rpc_level_cleared() -> void:
	EventBus.level_cleared.emit()


## Hôte → tous : message système dans le journal.
func system_message(text: String) -> void:
	if multiplayer.is_server():
		_rpc_system_message.rpc(text)


@rpc("authority", "call_local", "reliable")
func _rpc_system_message(text: String) -> void:
	EventBus.system_message.emit(text)


## Point de réapparition du groupe (hôte). Par défaut : l'entrée du niveau.
var checkpoint := Vector3.ZERO
var _respawn_pending := false


func set_checkpoint(pos: Vector3) -> void:
	checkpoint = pos


## Hôte : si tous les joueurs sont à terre, le groupe réapparaît au dernier feu de camp.
func _on_creature_downed_server(c: Node3D) -> void:
	if not multiplayer.is_server() or not (c is PlayerCharacter):
		return
	stat_add(c.peer_id, "downs", 1)
	if _respawn_pending:
		return
	for p in players_root.get_children():
		if p is PlayerCharacter and p.health.is_alive():
			return
	_respawn_pending = true
	system_message("Tout le groupe est à terre… Réapparition au dernier point de repos dans 4 s.")
	await get_tree().create_timer(4.0).timeout
	_respawn_pending = false
	var i := 0
	for p in players_root.get_children():
		if p is PlayerCharacter and is_instance_valid(p):
			p.global_position = checkpoint + Vector3(1.2 * i, 0.0, 0.0)
			p.velocity = Vector3.ZERO
			if p.health.is_downed:
				p.health.revive(0.5)
			i += 1
	system_message("Le groupe se relève au point de repos.")


## Hôte → tous : un monstre prépare une compétence (avertissement HUD + texte flottant).
func announce_monster_skill(monster: Node3D, skill_name: String) -> void:
	if multiplayer.is_server():
		_rpc_monster_skill.rpc(str(monster.get_path()), skill_name)


@rpc("authority", "call_local", "reliable")
func _rpc_monster_skill(path: String, skill_name: String) -> void:
	var m := get_node_or_null(path) as Node3D
	if m:
		EventBus.monster_skill.emit(m, skill_name)


## Hôte → tous : un boss change de phase (message HUD).
func announce_boss_phase(boss: Node3D, phase: int) -> void:
	_rpc_boss_phase.rpc(str(boss.get_path()), phase)


@rpc("authority", "call_local", "reliable")
func _rpc_boss_phase(path: String, phase: int) -> void:
	var boss := get_node_or_null(path) as Node3D
	if boss:
		EventBus.boss_phase.emit(boss, phase)


## Hôte : fait apparaître un objet au sol chez tout le monde. data = {entry: {id, qty, rarity}, position}
func spawn_loot(data: Dictionary) -> void:
	loot_spawner.spawn(data)


func _spawn_loot(data: Dictionary) -> Node:
	var l: LootDrop = LOOT_SCENE.instantiate()
	var e: Dictionary = data.get("entry", {})
	l.item_id = e.get("id", "gold")
	l.qty = int(e.get("qty", 1))
	l.rarity = e.get("rarity", "common")
	l.position = data.get("position", Vector3.ZERO)
	return l


## Effet visuel simple (sphère qui s'étend et s'efface), sur toutes les machines.
func show_vfx(pos: Vector3, radius: float, color: Color) -> void:
	_rpc_vfx.rpc(pos, radius, color)


@rpc("authority", "call_local", "reliable")
func _rpc_vfx(pos: Vector3, radius: float, color: Color) -> void:
	Sound.play_at("explosion" if radius >= 2.5 else "flames", pos)
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.3
	m.height = 0.6
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color, 0.6)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	mi.material_override = mat
	add_child(mi)
	mi.global_position = pos
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * (radius / 0.3), 0.35).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(mi.queue_free)


func _spawn_enemy(data: Dictionary) -> Node:
	var e: Enemy = ENEMY_SCENE.instantiate()
	e.monster_id = data.monster_id
	e.position = data.position
	e.spawn_info = data
	return e


## Hôte → tous : nom de la zone à l'arrivée (bandeau HUD).
@rpc("authority", "call_local", "reliable")
func _rpc_zone_entered(zone_name: String) -> void:
	EventBus.zone_entered.emit(zone_name)


## Hôte : changement de zone demandé par une ligne de zone (tout le groupe suit).
var _zoning := false
func change_zone(level_path: String, spawn_id: String, by: Node) -> void:
	if not multiplayer.is_server() or _zoning or not ResourceLoader.exists(level_path):
		return
	_zoning = true
	var states := {}
	for p in players_root.get_children():
		if p is PlayerCharacter:
			states[p.peer_id] = p.save_state()
			_deliver_save(p.peer_id, states[p.peer_id], level_path, spawn_id)  # sauvegarde à chaque zone
	system_message("%s passe vers %s… le groupe suit." % [by.player_name if by is PlayerCharacter else "Le groupe", Net.LEVELS.get(level_path, "la zone suivante")])
	await get_tree().create_timer(0.6).timeout
	Net.change_zone(level_path, spawn_id, states)


# ------------------------------------------------------------------ sauvegarde des personnages

const AUTOSAVE_EVERY := 30.0
var _autosave_left := AUTOSAVE_EVERY


func _process(delta: float) -> void:
	if not multiplayer.is_server() or not _spawned or _zoning:
		return
	_autosave_left -= delta
	if _autosave_left <= 0.0:
		_autosave_left = AUTOSAVE_EVERY
		save_party()


## Hôte : envoie à chaque propriétaire l'état de son personnage (zone, position comprises).
func save_party(only_peer := -1) -> void:
	for p in players_root.get_children():
		if p is PlayerCharacter and (only_peer < 0 or p.peer_id == only_peer) and p.health.max_hp > 0:
			var st: Dictionary = p.save_state()
			st["zone"] = Net.level_path
			st["pos"] = [p.global_position.x, p.global_position.y, p.global_position.z]
			st["yaw"] = p.camera_pivot.rotation.y
			_deliver_save(p.peer_id, st, Net.level_path, Net.spawn_id)


func _deliver_save(peer: int, st: Dictionary, zone: String, spawn: String) -> void:
	if peer == multiplayer.get_unique_id():
		Characters.save_current(st, zone, spawn)
	else:
		_rpc_save_character.rpc_id(peer, st, zone, spawn)


@rpc("authority", "reliable")
func _rpc_save_character(st: Dictionary, zone: String, spawn: String) -> void:
	Characters.save_current(st, zone, spawn)


@rpc("any_peer", "reliable")
func _rpc_request_save() -> void:
	if multiplayer.is_server():
		save_party(multiplayer.get_remote_sender_id())


## Avant de quitter : l'hôte sauvegarde tout le monde ; un client demande sa sauvegarde et attend un peu.
func save_party_now() -> void:
	if not _spawned and multiplayer.is_server():
		return
	if multiplayer.is_server():
		save_party()
	else:
		_rpc_request_save.rpc_id(1)
		await get_tree().create_timer(0.4).timeout


## La progression de l'HÔTE décide de ce qui est ouvert dans le monde (un joueur plus avancé qui le rejoint
## est limité par elle).
func world_has_progress(flag: String) -> bool:
	var host := players_root.get_node_or_null("Player_1")
	if host is PlayerCharacter:
		return (host as PlayerCharacter).has_progress(flag)
	return true


## Hôte : un PNJ ouvre son dialogue sur la machine d'un joueur.
func open_npc_for(peer_id: int, npc_id: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		EventBus.npc_dialog.emit(npc_id)
	else:
		_rpc_open_npc.rpc_id(peer_id, npc_id)


@rpc("authority", "reliable")
func _rpc_open_npc(npc_id: String) -> void:
	EventBus.npc_dialog.emit(npc_id)


## Hôte → clients : résultat d'une attaque (pour chiffres flottants et journal).
func _on_hit_resolved_server(target: Node3D, result: Dictionary) -> void:
	# Statistiques.
	var attacker: Node = result.get("attacker")
	if result.has("heal"):
		if target is PlayerCharacter:
			stat_add(target.peer_id, "potions", 1)
	elif result.get("damage", 0) > 0:
		if attacker is PlayerCharacter:
			stat_add(attacker.peer_id, "damage_dealt", int(result.damage))
		if target is PlayerCharacter:
			stat_add(target.peer_id, "damage_taken", int(result.damage))
	if Net.players.size() <= 1:
		return
	var payload := result.duplicate()
	payload["attacker"] = str(result.attacker.get_path()) if result.get("attacker") else ""
	payload["target"] = str(target.get_path())
	_rpc_hit.rpc(payload)


@rpc("authority", "reliable")
func _rpc_hit(payload: Dictionary) -> void:
	var target := get_node_or_null(payload.get("target", "")) as Node3D
	if target == null:
		return
	var result := payload.duplicate()
	result["attacker"] = get_node_or_null(payload.get("attacker", ""))
	result["target"] = target
	EventBus.hit_resolved.emit(target, result)


func _on_peer_left(id: int) -> void:
	var p := players_root.get_node_or_null("Player_%d" % id)
	if p:
		p.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and Input.is_key_pressed(KEY_SHIFT):
		Net.leave_to_menu()

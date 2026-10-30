extends Node3D
## Scène de partie : charge le niveau, fait apparaître joueurs et monstres (hôte) via les
## MultiplayerSpawner, et relaie les événements de combat de l'hôte vers les clients.

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const ENEMY_SCENE := preload("res://scenes/enemy.tscn")
const PROJECTILE_SCENE := preload("res://scenes/projectile.tscn")
const LOOT_SCENE := preload("res://scenes/loot_drop.tscn")

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


func _ready() -> void:
	add_to_group("game")
	player_spawner.spawn_function = _spawn_player
	enemy_spawner.spawn_function = _spawn_enemy
	projectile_spawner.spawn_function = _spawn_projectile
	loot_spawner.spawn_function = _spawn_loot
	FloatingText.install(self)
	level = level_scene.instantiate()
	level_root.add_child(level)
	if multiplayer.is_server():
		EventBus.hit_resolved.connect(_on_hit_resolved_server)
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
	for id in ids:
		var info: Dictionary = Net.players.get(id, {})
		player_spawner.spawn({
			"peer_id": id,
			"class_id": info.get("class_id", "fighter"),
			"race_id": info.get("race_id", "human"),
			"name": info.get("name", "Aventurier"),
			"position": level.player_spawn_position(i),
		})
		i += 1
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
	p.race_id = data.race_id
	p.player_name = data.name
	p.position = data.position
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
	return p


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
	return e


## Hôte → clients : résultat d'une attaque (pour chiffres flottants et journal).
func _on_hit_resolved_server(target: Node3D, result: Dictionary) -> void:
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

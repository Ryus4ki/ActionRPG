class_name Enemy
extends Creature
## Monstre piloté par IA : patrouille sur place, poursuit le joueur le plus proche,
## attaque au contact. Logique exécutée uniquement côté hôte (M2).

enum State { IDLE, CHASE, ATTACK, DEAD }

const ATTACK_IMPACT_RATIO := 0.5   # l'impact tombe au milieu de l'animation d'attaque
const REPATH_INTERVAL := 0.25

@export var monster_id := "goblin"

@onready var nav: NavigationAgent3D = $NavigationAgent3D

var state := State.IDLE
var target: Creature = null
var data: Dictionary = {}
var attacks: Array = []
var aggro_range := 10.0
var reach := 1.5
var _attack_cooldown := 0.0
var _repath_timer := 0.0
var _impact_pending := false
var _xp_given := false


func _ready() -> void:
	faction = "enemies"
	data = GameData.monster(monster_id)
	model_path = "res://assets/models/%s.glb" % data.get("model", "sk_humanoid")
	model_scale = data.get("scale", 1.0)
	if data.has("tint"):
		tint = Color(data["tint"])
	super()
	stats.setup_from_monster(monster_id)
	if is_server():
		health.setup(stats.max_hp())
	attacks = data.get("attacks", [])
	aggro_range = data.get("behavior", {}).get("aggro_range", 10.0)
	if not attacks.is_empty():
		reach = attacks[0].get("reach", 1.5)
	nav.path_desired_distance = 1.0
	nav.target_desired_distance = maxf(reach - 0.3, 0.6)
	nav.radius = 0.35 * model_scale
	# Arme visuelle : gobelin → dague, squelette → épée, ogre → masse.
	var weapon_model: String = {"goblin": "sm_dagger", "goblin_boss": "sm_sword", "skeleton": "sm_sword", "ogre": "sm_mace"}.get(monster_id, "")
	if weapon_model != "":
		attach_to_bone("hand.R", "res://assets/models/%s.glb" % weapon_model, PlayerCharacter.WEAPON_GRIP)


func _physics_process(delta: float) -> void:
	if not is_server():
		return
	apply_gravity(delta)
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	if health.is_dead:
		state = State.DEAD
	match state:
		State.IDLE:
			_idle(delta)
		State.CHASE:
			_chase(delta)
		State.ATTACK:
			_attack(delta)
		State.DEAD:
			velocity.x = 0.0
			velocity.z = 0.0
	move_and_slide()


func _idle(_delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	play_anim("idle")
	var t := _nearest_player(aggro_range)
	if t:
		target = t
		state = State.CHASE


func _chase(delta: float) -> void:
	if not _target_valid():
		target = null
		state = State.IDLE
		return
	var dist := global_position.distance_to(target.global_position)
	if dist <= reach and not is_busy():
		state = State.ATTACK
		return
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = REPATH_INTERVAL
		nav.target_position = target.global_position
	if is_busy():
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		return
	var next := nav.get_next_path_position()
	var dir := (next - global_position)
	dir.y = 0.0
	if dir.length() > 0.05:
		dir = dir.normalized()
		var speed := stats.move_speed_mps(true) * 0.85
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		face_direction(dir, delta, 8.0)
		play_anim("run")
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		play_anim("idle")


func _attack(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	if not _target_valid():
		state = State.IDLE
		return
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	face_direction(to_target, delta, 10.0)
	if to_target.length() > reach + 0.4 and not is_busy():
		state = State.CHASE
		return
	if _attack_cooldown <= 0.0 and not is_busy() and not attacks.is_empty():
		var atk: Dictionary = attacks[0]
		_attack_cooldown = atk.get("cooldown", 1.5)
		play_anim("attack", 0.05, true)
		_impact_pending = true
		var length := anim.get_animation("attack").length if anim and anim.has_animation("attack") else 0.8
		var windup: float = atk.get("windup", 0.0)
		get_tree().create_timer(length * ATTACK_IMPACT_RATIO + windup).timeout.connect(_resolve_hit.bind(atk))
	else:
		if not is_busy():
			play_anim("idle")


func _resolve_hit(atk: Dictionary) -> void:
	_impact_pending = false
	if health.is_dead or not _target_valid():
		return
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	# Touche si toujours à portée et à peu près devant (cône de 120°).
	if to_target.length() <= reach + 0.5 and forward().dot(to_target.normalized()) > -0.5:
		CombatResolver.weapon_attack(self, target, atk)


func _target_valid() -> bool:
	return target != null and is_instance_valid(target) and target.health.is_alive()


func _nearest_player(max_dist: float) -> Creature:
	var best: Creature = null
	var best_d := max_dist
	for p in get_tree().get_nodes_in_group("players"):
		if p is Creature and p.health.is_alive():
			var d: float = global_position.distance_to(p.global_position)
			if d < best_d:
				best_d = d
				best = p
	return best


func _on_died() -> void:
	super()
	state = State.DEAD
	if not is_server():
		return
	# Le dernier attaquant joueur gagne l'XP (partagée en M2).
	if not _xp_given:
		_xp_given = true
		for p in get_tree().get_nodes_in_group("players"):
			if p is Creature:
				p.stats.add_xp(stats.xp_value)
	# Butin au sol.
	var game := get_tree().get_first_node_in_group("game")
	if game:
		Loot.drop_for_monster(game, monster_id, global_position)
	# Le corps disparaît après quelques secondes.
	get_tree().create_timer(8.0).timeout.connect(queue_free)

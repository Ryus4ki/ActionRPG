class_name Enemy
extends Creature
## Monstre piloté par IA : attend, poursuit le joueur le plus proche, attaque au contact
## ou à distance (archer, toile d'araignée), garde ses distances si demandé, enchaîne
## plusieurs coups (multiattack), et gère les phases de boss (renforts, accélération).
## Logique exécutée uniquement côté hôte.

enum State { IDLE, CHASE, ATTACK, DEAD }

const ATTACK_IMPACT_RATIO := 0.5   # l'impact tombe au milieu de l'animation d'attaque
const MULTIATTACK_GAP := 0.35      # délai entre deux coups d'une attaque multiple
const REPATH_INTERVAL := 0.25
const PROJECTILE_HEIGHT := 1.2

@export var monster_id := "goblin"

@onready var nav: NavigationAgent3D = $NavigationAgent3D

var state := State.IDLE
var target: Creature = null
## Répliqué : peer_id du joueur que ce monstre attaque (0 = personne) — liste des attaquants du HUD.
var target_peer := 0
var data: Dictionary = {}
var attacks: Array = []
var melee_attacks: Array = []
var ranged_attacks: Array = []
var aggro_range := 10.0
var keep_distance := 0.0        # > 0 : préfère tirer de loin (archer)
var retreat_duration := 1.2     # recul limité : durée d'un repli…
var retreat_cooldown := 8.0     # …puis pas de nouveau repli avant ce délai (sinon kiting infini)
var _retreat_until := 0.0
var _retreat_next := 0.0
var reach := 1.5
var is_boss := false
## Phase de boss courante (0 = aucune déclenchée). Répliquée : les clients affichent le message.
var phase := 0:
	set(v):
		phase = v
var last_attacker: Node = null   # dernier joueur à avoir blessé ce monstre (statistiques)
var spawn_info: Dictionary = {}  # données d'apparition (poste, délai de réapparition) — hôte
## TP du monstre (répliqué pour le cadre de cible) : à 100, il prépare une compétence (`skills` du bestiaire).
var tp := 0
## Nom de la compétence en préparation (répliqué : « prépare X » dans le HUD), vide sinon.
var preparing := ""
var skills: Array = []
var _skill_pending: Dictionary = {}
var _tp_per_hit := 20
var _tp_from_hit_taken := 10
var home_position := Vector3.ZERO  # poste : au-delà de LEASH_RANGE on abandonne et on rentre
var _taunt_until := 0.0
var _returning := false
const LEASH_RANGE := 30.0
var _cooldowns: Array[float] = []  # un compte à rebours par attaque
var _cooldown_mult := 1.0          # < 1 : attaque plus vite (phase de boss)
var _repath_timer := 0.0
var _xp_given := false


func _ready() -> void:
	faction = "enemies"
	data = GameData.monster(monster_id)
	var mdl: String = data.get("model", "sk_humanoid")
	model_path = mdl if mdl.begins_with("proc:") else "res://assets/models/%s.glb" % mdl
	model_scale = data.get("scale", 1.0)
	if data.has("tint"):
		tint = Color(data["tint"])
	super()
	stats.setup_from_monster(monster_id)
	if is_server():
		health.setup(stats.max_hp())
		health.damaged.connect(_on_damaged)
	attacks = data.get("attacks", [])
	for atk in attacks:
		_cooldowns.append(0.0)
		if atk.has("range"):
			ranged_attacks.append(atk)
		else:
			melee_attacks.append(atk)
	skills = data.get("skills", [])
	_tp_per_hit = int(GameData.bal("monster_tp_per_hit", 20))
	_tp_from_hit_taken = int(GameData.bal("monster_tp_from_hit_taken", 10))
	var behavior: Dictionary = data.get("behavior", {})
	aggro_range = behavior.get("aggro_range", 10.0)
	wander_radius = behavior.get("wander_radius", 0.0)
	pack = behavior.get("pack", false)
	keep_distance = behavior.get("keep_distance", 0.0)
	retreat_duration = behavior.get("retreat_duration", 1.2)
	retreat_cooldown = behavior.get("retreat_cooldown", 8.0)
	is_boss = data.get("is_boss", false)
	if is_boss:
		add_to_group("bosses")
	if not melee_attacks.is_empty():
		reach = melee_attacks[0].get("reach", 1.5)
	home_position = global_position
	nav.path_desired_distance = 1.0
	nav.target_desired_distance = maxf(reach - 0.3, 0.6)
	nav.radius = 0.35 * model_scale
	# Arme visuelle selon le monstre.
	var weapon_model: String = {
		"goblin": "sm_dagger", "goblin_archer": "sm_dagger", "goblin_boss": "sm_sword",
		"skeleton": "sm_sword", "ogre": "sm_mace",
	}.get(monster_id, "")
	if weapon_model != "":
		attach_to_bone("hand.R", "res://assets/models/%s.glb" % weapon_model, PlayerCharacter.WEAPON_GRIP)


func display_name() -> String:
	return data.get("name", monster_id)


func _physics_process(delta: float) -> void:
	if not is_server():
		return
	apply_gravity(delta)
	for i in _cooldowns.size():
		_cooldowns[i] = maxf(0.0, _cooldowns[i] - delta)
	if health.is_dead:
		state = State.DEAD
	var tp_peer := 0
	if state in [State.CHASE, State.ATTACK] and not _returning and is_instance_valid(target) and target is PlayerCharacter:
		tp_peer = (target as PlayerCharacter).peer_id
	if tp_peer != target_peer:
		target_peer = tp_peer
	tick_conditions(delta)
	if is_stunned() and state != State.DEAD:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		apply_knock(delta)
		move_and_slide()
		return
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
	apply_knock(delta)
	move_and_slide()


var wander_radius := 0.0     # > 0 : flâne autour de son poste quand il n'a rien à faire
var _wander_target := Vector3.ZERO
var _wander_timer := 0.0
var pack := false            # meute : alerte ses congénères proches quand il engage


func _idle(delta: float) -> void:
	var t := _nearest_player(aggro_range)
	if t:
		_engage(t)
		return
	# Flânerie : un point au hasard autour du poste, de temps en temps, au pas.
	if wander_radius > 0.0:
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = randf_range(4.0, 9.0)
			var ang := randf() * TAU
			_wander_target = home_position + Vector3(cos(ang), 0, sin(ang)) * randf_range(1.0, wander_radius)
			nav.target_position = _wander_target
		var to := _wander_target - global_position
		to.y = 0.0
		if _wander_target != Vector3.ZERO and to.length() > 0.6 and not is_busy():
			var next := nav.get_next_path_position()
			var dir := next - global_position
			dir.y = 0.0
			if dir.length() > 0.05:
				dir = dir.normalized()
				var speed := stats.move_speed_mps(false)
				velocity.x = dir.x * speed
				velocity.z = dir.z * speed
				face_direction(dir, delta, 6.0)
				play_anim("walk")
				return
	velocity.x = 0.0
	velocity.z = 0.0
	play_anim("idle")


## Passe à la poursuite d'une cible ; une meute alerte ses congénères à 12 m.
func _engage(t: Creature) -> void:
	target = t
	state = State.CHASE
	if pack:
		for e in get_tree().get_nodes_in_group("enemies"):
			if e is Enemy and e != self and e.monster_id == monster_id and e.state == State.IDLE and e.health.is_alive() \
					and e.global_position.distance_to(global_position) <= 12.0:
				e.target = t
				e.state = State.CHASE


## Provocation : ce monstre prend `by` pour cible pendant `duration` s.
func taunt(by: Creature, duration: float) -> void:
	if health.is_dead:
		return
	target = by
	_taunt_until = GameData.now() + duration
	_returning = false
	if state == State.IDLE:
		state = State.CHASE


func _chase(delta: float) -> void:
	# Laisse : trop loin du poste → on abandonne, on rentre et on récupère.
	if _returning:
		_return_home(delta)
		return
	if global_position.distance_to(home_position) > LEASH_RANGE:
		target = null
		_returning = true
		nav.target_position = home_position
		return
	if not _target_valid():
		target = null
		state = State.IDLE
		return
	# Hors provocation, on garde la cible la plus proche visible.
	if GameData.now() > _taunt_until:
		var nearest := _nearest_player(aggro_range * 1.5)
		if nearest and nearest != target and global_position.distance_to(nearest.global_position) < global_position.distance_to(target.global_position) * 0.6:
			target = nearest
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	var dist := to_target.length()
	# Au contact (mêlée disponible) : on frappe.
	if not melee_attacks.is_empty() and dist <= reach and not is_busy():
		state = State.ATTACK
		return
	# Compétence prête (100 TP) ou tir à distance en chemin si la cible est visible.
	if not is_busy() and _try_skill(dist):
		return
	if not is_busy() and _try_ranged(to_target, dist, delta):
		return
	if is_busy() or is_restrained():
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		return
	# Choix du déplacement : repli limité si trop près (archer), sinon approche.
	var now := GameData.now()
	var dir := Vector3.ZERO
	var retreating := false
	if keep_distance > 0.0 and dist < keep_distance * 0.6:
		if now < _retreat_until:
			retreating = true
		elif now >= _retreat_next and dist > reach + 0.3:
			_retreat_until = now + retreat_duration
			_retreat_next = now + retreat_cooldown
			retreating = true
	if retreating:
		dir = -to_target.normalized()
		face_direction(to_target, delta, 8.0)
	elif keep_distance > 0.0 and dist <= keep_distance and dist > 2.5 and _has_line_of_sight():
		# À bonne distance et à vue : on reste planté et on tire.
		velocity.x = 0.0
		velocity.z = 0.0
		face_direction(to_target, delta, 8.0)
		play_anim("idle")
		return
	else:
		_repath_timer -= delta
		if _repath_timer <= 0.0:
			_repath_timer = REPATH_INTERVAL
			nav.target_position = target.global_position
		var next := nav.get_next_path_position()
		dir = next - global_position
		dir.y = 0.0
	if dir.length() > 0.05:
		dir = dir.normalized()
		var speed := stats.move_speed_mps(true) * (0.5 if retreating else 0.85)
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		if not retreating:
			face_direction(dir, delta, 8.0)
		play_anim("walk" if retreating else "run")
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		play_anim("idle")


func _return_home(delta: float) -> void:
	var to := home_position - global_position
	to.y = 0.0
	if to.length() < 1.0:
		_returning = false
		velocity.x = 0.0
		velocity.z = 0.0
		health.heal(health.max_hp)
		state = State.IDLE
		return
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		_repath_timer = REPATH_INTERVAL
		nav.target_position = home_position
	var next := nav.get_next_path_position()
	var dir := next - global_position
	dir.y = 0.0
	if dir.length() > 0.05:
		dir = dir.normalized()
		var speed := stats.move_speed_mps(true)
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		face_direction(dir, delta, 8.0)
		play_anim("run")


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
	if is_busy():
		return
	if _try_skill(to_target.length()):
		return
	for i in attacks.size():
		var atk: Dictionary = attacks[i]
		if atk.has("range") or _cooldowns[i] > 0.0:
			continue
		_start_melee(i, atk)
		return
	play_anim("idle")


func _start_melee(index: int, atk: Dictionary) -> void:
	_cooldowns[index] = atk.get("cooldown", 1.5) * _cooldown_mult * GameData.bal("monster_attack_cooldown_mult")
	play_anim("attack", 0.05, true)
	var length := anim.get_animation("attack").length if anim and anim.has_animation("attack") else 0.8
	var windup: float = atk.get("windup", 0.0)
	var count: int = atk.get("multiattack", 1)
	for n in count:
		get_tree().create_timer(length * ATTACK_IMPACT_RATIO + windup + n * MULTIATTACK_GAP).timeout.connect(_resolve_hit.bind(atk))
	if count > 1:
		# L'animation reste prioritaire le temps des coups supplémentaires.
		_one_shot_until = maxf(_one_shot_until, GameData.now() + length * ATTACK_IMPACT_RATIO + windup + (count - 1) * MULTIATTACK_GAP + 0.2)


## Tire si une attaque à distance est prête, la cible dans la portée et visible.
func _try_ranged(to_target: Vector3, dist: float, _delta: float) -> bool:
	if ranged_attacks.is_empty():
		return false
	for i in attacks.size():
		var atk: Dictionary = attacks[i]
		if not atk.has("range") or _cooldowns[i] > 0.0:
			continue
		if dist > atk.range or dist < 2.0 or not _has_line_of_sight():
			continue
		_cooldowns[i] = atk.get("cooldown", 2.0) * _cooldown_mult * GameData.bal("monster_attack_cooldown_mult")
		face_direction(to_target, 1.0, 100.0)
		velocity.x = 0.0
		velocity.z = 0.0
		play_anim("cast" if monster_id == "giant_spider" else "attack", 0.05, true)
		var length := anim.get_animation("attack").length if anim and anim.has_animation("attack") else 0.8
		get_tree().create_timer(length * ATTACK_IMPACT_RATIO).timeout.connect(_fire_projectile.bind(atk))
		return true
	return false


func _fire_projectile(atk: Dictionary) -> void:
	if health.is_dead or not _target_valid():
		return
	var game := get_tree().get_first_node_in_group("game")
	if game == null:
		return
	var origin := global_position + Vector3(0, PROJECTILE_HEIGHT * model_scale, 0)
	var aim := target.global_position + Vector3(0, 1.0, 0)
	var dir := (aim - origin).normalized()
	var is_web: bool = atk.get("on_hit", {}).has("condition")
	game.spawn_projectile({
		"caster": get_path(), "origin": origin, "direction": dir,
		"speed": atk.get("projectile_speed", 25.0), "max_range": atk.get("range", 20.0) + 4.0,
		"radius": 0.25 if is_web else 0.1,
		"color": Color(0.9, 0.9, 0.8) if is_web else Color(0.75, 0.6, 0.35),
		"hostile": true, "attack": atk,
	})


func _resolve_hit(atk: Dictionary) -> void:
	if health.is_dead or not _target_valid():
		return
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	# Touche si toujours à portée et à peu près devant (cône de 120°).
	if to_target.length() <= reach + 0.5 and forward().dot(to_target.normalized()) > -0.5:
		var r := CombatResolver.weapon_attack(self, target, atk)
		if r.get("hit", false):
			gain_tp(_tp_per_hit)


# ---------------------------------------------------------------- compétences (TP)

func gain_tp(amount: int) -> void:
	tp = clampi(tp + amount, 0, 300)


## À 100 TP : choisit une compétence utilisable (portée) et la prépare (annonce + délai de réaction).
func _try_skill(dist: float) -> bool:
	if skills.is_empty() or tp < 100 or not _target_valid() or not _skill_pending.is_empty():
		return false
	var usable: Array = []
	for sk in skills:
		var r: float = sk.get("range", reach + 0.5)
		if sk.get("type", "") in ["self_heal", "buff_allies"] or dist <= r:
			if sk.get("type", "") == "self_heal" and health.hp > health.max_hp * 0.6:
				continue
			usable.append(sk)
	if usable.is_empty():
		return false
	var sk: Dictionary = usable[randi() % usable.size()]
	_skill_pending = sk
	tp = 0
	preparing = sk.get("name", sk.get("id", "?"))
	velocity.x = 0.0
	velocity.z = 0.0
	if _target_valid():
		face_direction(target.global_position - global_position, 1.0, 100.0)
	play_anim("cast", 0.05, true)
	var windup: float = sk.get("windup", GameData.bal("monster_skill_windup", 1.5))
	_one_shot_until = maxf(_one_shot_until, GameData.now() + windup + 0.3)
	var game := get_tree().get_first_node_in_group("game")
	if game:
		game.announce_monster_skill(self, preparing)
	get_tree().create_timer(windup).timeout.connect(_execute_skill)
	return true


func _execute_skill() -> void:
	var sk := _skill_pending
	_skill_pending = {}
	preparing = ""
	if sk.is_empty() or health.is_dead or is_stunned():
		return
	play_anim("attack", 0.05, true)
	var sname: String = sk.get("name", "?")
	match sk.get("type", ""):
		"aoe":
			var radius: float = sk.get("radius", 3.0)
			for p in get_tree().get_nodes_in_group("players"):
				if p is Creature and p.health.is_alive() and p.global_position.distance_to(global_position) <= radius:
					var r := CombatResolver.save_damage(self, p, sk.get("damage", "2d6"), sk.get("damage_type", "bludgeoning"),
						sk.get("save_ability", "dex"), int(sk.get("dc", 12)), sk.get("half_on_success", true), sname)
					if sk.has("knockback") and r.get("damage", 0) > 0:
						p.apply_knockback(p.global_position - global_position, float(sk.knockback) * 3.0)
			var game := get_tree().get_first_node_in_group("game")
			if game:
				game.show_vfx(global_position + Vector3(0, 0.8, 0), radius, Color(sk.get("color", "#ff8040")))
		"strike":
			if _target_valid() and global_position.distance_to(target.global_position) <= reach + 1.0:
				var atk: Dictionary = (attacks[0] if not attacks.is_empty() else {"bonus": 4, "damage": "1d6"}).duplicate()
				atk["name"] = sname
				atk["damage_multiplier"] = float(sk.get("multiplier", 1.5))
				if sk.has("on_hit"):
					atk["on_hit"] = sk.on_hit
				if sk.has("knockback"):
					atk["knockback"] = sk.knockback
				CombatResolver.weapon_attack(self, target, atk)
		"shot":
			if _target_valid():
				var atk: Dictionary = {"name": sname, "bonus": int(sk.get("bonus", attacks[0].get("bonus", 4) if not attacks.is_empty() else 4)),
					"damage": sk.get("damage", "1d6"), "damage_type": sk.get("damage_type", "piercing"),
					"range": sk.get("range", 20.0), "projectile_speed": sk.get("projectile_speed", 30.0)}
				if sk.has("on_hit"):
					atk["on_hit"] = sk.on_hit
				_fire_projectile(atk)
		"self_heal":
			var amount := int(Dice.roll_expr(str(sk.get("heal", "2d8")), CombatResolver.rng) * GameData.bal("healing_mult"))
			health.heal(amount)
			EventBus.hit_resolved.emit(self, {"attacker": self, "target": self, "attack_name": sname, "hit": true,
				"heal": amount, "damage": 0, "damage_type": 0})
		"buff_allies":
			var radius: float = sk.get("radius", 10.0)
			var n := 0
			for e in get_tree().get_nodes_in_group("enemies"):
				if e is Creature and e.health.is_alive() and e.global_position.distance_to(global_position) <= radius:
					e.apply_condition(sk.get("condition", "strengthened"), float(sk.get("duration", 15.0)))
					n += 1
			var game := get_tree().get_first_node_in_group("game")
			if game:
				game.system_message("%s : %s — %d monstre(s) renforcé(s)." % [stats.display_name, sname, n])
				game.show_vfx(global_position + Vector3(0, 1.0, 0), 2.0, Color(1.0, 0.3, 0.3))
		"debuff_aoe":
			var radius: float = sk.get("radius", 6.0)
			for p in get_tree().get_nodes_in_group("players"):
				if p is Creature and p.health.is_alive() and p.global_position.distance_to(global_position) <= radius:
					var dodging: bool = p is PlayerCharacter and p.is_dodging()
					var save := CombatRules.saving_throw(p.stats.save_bonus(sk.get("save_ability", "wis")), int(sk.get("dc", 12)), Dice.RollMode.NORMAL, CombatResolver.rng)
					var res := {"attacker": self, "target": p, "attack_name": sname, "hit": not (save.success or dodging), "crit": false, "fumble": false,
						"save_d20": save.d20, "save_total": save.total, "save_success": save.success or dodging, "dc": int(sk.get("dc", 12)),
						"damage": 0, "damage_type": 0, "evaded": dodging}
					if not (save.success or dodging):
						p.apply_condition(sk.get("condition", "weakened"), float(sk.get("duration", 10.0)))
						res["condition"] = sk.get("condition", "weakened")
					EventBus.hit_resolved.emit(p, res)
			var game := get_tree().get_first_node_in_group("game")
			if game:
				game.show_vfx(global_position + Vector3(0, 1.0, 0), radius, Color(sk.get("color", "#8060ff")))


func _has_line_of_sight() -> bool:
	if not _target_valid():
		return false
	var from := global_position + Vector3(0, PROJECTILE_HEIGHT * model_scale, 0)
	var to := target.global_position + Vector3(0, 1.0, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)  # couche monde uniquement
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _target_valid() -> bool:
	return target != null and is_instance_valid(target) and target.health.is_alive()


func _nearest_player(max_dist: float) -> Creature:
	var best: Creature = null
	var best_d := max_dist
	for p in get_tree().get_nodes_in_group("players"):
		if p is Creature and p.health.is_alive():
			var d: float = global_position.distance_to(p.global_position)
			if d < best_d and _can_see(p):
				best_d = d
				best = p
	return best


## Ligne de vue vers une créature (seul le décor, couche 1, bloque).
func _can_see(c: Node3D) -> bool:
	var from := global_position + Vector3(0, PROJECTILE_HEIGHT * model_scale, 0)
	var to := c.global_position + Vector3(0, 1.0, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


# ---------------------------------------------------------------- boss

func _on_damaged(_amount: int, _type: int, _crit: bool, source: Node) -> void:
	if source is PlayerCharacter:
		last_attacker = source
		gain_tp(_tp_from_hit_taken)
	# Se faire attaquer réveille le monstre (archer touché de loin, etc.).
	if state == State.IDLE and not _returning and source is Creature and source.is_in_group("players") and source.health.is_alive():
		_engage(source)
	if not is_boss or not health.is_alive() or health.hp <= 0:
		return
	var phases: Array = data.get("phases", [])
	var pct := float(health.hp) / float(maxi(health.max_hp, 1))
	while phase < phases.size() and pct <= float(phases[phase].get("hp_pct_below", 1.0)):
		_enter_phase(phase + 1, phases[phase])


func _enter_phase(number: int, ph: Dictionary) -> void:
	phase = number
	var game := get_tree().get_first_node_in_group("game")
	if ph.has("summon") and game:
		var summon: Dictionary = ph.summon
		var count: int = summon.get("count", 1)
		for i in count:
			var angle := TAU * float(i) / float(count) + 0.4
			var pos := global_position + Vector3(cos(angle), 0.0, sin(angle)) * 2.0
			game.spawn_enemy_at(summon.get("monster", "goblin"), pos)
	if ph.has("buff"):
		_cooldown_mult = 1.0 / float(ph.buff.get("attack_speed_multiplier", 1.0))
	if game:
		game.announce_boss_phase(self, number)


func _on_died() -> void:
	super()
	state = State.DEAD
	if not is_server():
		return
	# Les joueurs gagnent l'XP (partagée).
	if not _xp_given:
		_xp_given = true
		for p in get_tree().get_nodes_in_group("players"):
			if p is Creature:
				p.stats.add_xp(stats.xp_value)
				if p is PlayerCharacter:
					var pc := p as PlayerCharacter
					var nxt := Rules.xp_for_next_level(pc.stats.level)
					pc.notify_xp("%s vaincu : [b]+%d XP[/b] (%s %d — %s)" % [stats.display_name, stats.xp_value,
						GameData.player_class(pc.class_id).get("name", pc.class_id), pc.stats.level,
						("%d / %d" % [pc.stats.xp, nxt]) if nxt > 0 else "niveau max"])
	# Butin au sol.
	var game := get_tree().get_first_node_in_group("game")
	if game:
		Loot.drop_for_monster(game, monster_id, global_position)
	# Le corps disparaît après quelques secondes.
	get_tree().create_timer(8.0).timeout.connect(queue_free)

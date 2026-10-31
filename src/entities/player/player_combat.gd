class_name PlayerCombat
extends Node
## Combat « façon FFXI » du joueur : cible verrouillée, engagement, auto-attaque au délai de l'arme,
## TP et weapon skills, compétences de classe à recharge, incantation avec temps de lancement
## (interrompue par le déplacement), fuite. Toute la simulation tourne sur l'hôte ; l'état utile
## au HUD est répliqué (voir player.tscn).

const TP_MAX := 300
const TP_READY := 100
const ATTACK_IMPACT_DELAY := 0.4     # frame 12 / 30 fps de l'animation "attack"
const CAST_RELEASE_DELAY := 0.47     # frame 14 / 30 fps de l'animation "cast"
const MELEE_REACH := 2.2
const FACING_DOT := 0.3              # il faut être à peu près face à la cible pour frapper
const FLEE_DURATION := 5.0
const FLEE_COOLDOWN := 20.0
const FLEE_SPEED_MULT := 1.5
const TARGET_RANGE := 30.0
const CAST_MOVE_TOLERANCE := 0.15    # s de déplacement tolérées avant interruption

var player: PlayerCharacter

# --- état répliqué ---
var target_path := NodePath()
var engaged := false
var tp := 0
var casting_id := ""
var cast_left := 0.0
var cast_total := 0.0
var fleeing := false
## Recharges restantes (s) par capacité, rafraîchies 4×/s pour le HUD : {id: float}.
var cooldowns_left: Dictionary = {}
var instant_cast_ready := false

# --- hôte ---
var _swing_timer := 0.0
var _cooldown_until: Dictionary = {}  # id -> instant (s)
var _flee_until := 0.0
var _cast_spell := ""
var _cast_moving_time := 0.0
var _cooldown_refresh := 0.0
var _impact_pending := 0


func setup(p: PlayerCharacter) -> void:
	player = p
	if p.is_server():
		p.health.damaged.connect(_on_damaged)
		EventBus.hit_resolved.connect(_on_hit_resolved)


func _now() -> float:
	return GameData.now()


func target() -> Creature:
	if target_path.is_empty():
		return null
	var n := get_node_or_null(target_path)
	return n if n is Creature else null


func target_alive() -> bool:
	var t := target()
	return t != null and is_instance_valid(t) and t.health.is_alive()


func weapon_delay() -> float:
	return float(player.weapon.get("delay", 2.4)) * GameData.bal("player_weapon_delay_mult")


func weapon_skill() -> Dictionary:
	return GameData.weapon_skill(player.weapon.get("weapon_skill", ""))


func is_casting() -> bool:
	return casting_id != ""


## Nom de l'armure / du bouclier porté que le job actuel ne maîtrise pas ("" si aucun).
func armor_hindrance() -> String:
	var profs: Array = GameData.player_class(player.class_id).get("armor_proficiencies", [])
	var eq: Dictionary = player.inventory.equipped
	if eq.has("armor"):
		var a := Inventory.item_data(eq["armor"])
		if not str(a.get("armor_type", "light")) in profs:
			return Inventory.display_name(eq["armor"])
	if eq.has("shield") and not "shield" in profs:
		return Inventory.display_name(eq["shield"])
	return ""


## Capacités de classe actives (hors passives) disponibles au niveau courant : [{id, name, ...}].
func abilities() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cls: Dictionary = GameData.player_class(player.class_id)
	var by_level: Dictionary = cls.get("features_by_level", {})
	var feats: Dictionary = cls.get("features", {})
	for lvl_key in by_level:
		if int(lvl_key) > player.stats.level:
			continue
		for fid in by_level[lvl_key]:
			var f: Dictionary = feats.get(fid, {})
			if f.get("type", "passive") in ["passive", "asi"]:
				continue
			if f.get("type") == "guard_toggle" and not player.has_shield:
				continue
			var entry := f.duplicate()
			entry["id"] = fid
			out.append(entry)
	return out


func cooldown_left(id: String) -> float:
	return maxf(0.0, float(_cooldown_until.get(id, 0.0)) - _now())


# ------------------------------------------------------------------ actions (hôte)

## Cible : chemin de nœud (vide = désélection). Changer de cible en combat garde l'engagement.
func set_target(path: NodePath) -> void:
	var n := get_node_or_null(path) if not path.is_empty() else null
	if n is Creature and n.is_in_group("enemies") and n.health.is_alive():
		target_path = n.get_path()
	else:
		target_path = NodePath()
		engaged = false


func engage() -> bool:
	if not target_alive() or not player.health.is_alive():
		return false
	if player.is_blocking:
		player.set_blocking(false)
	if not engaged:
		engaged = true
		_swing_timer = minf(_swing_timer, 0.3)  # premier coup rapide
	return true


func disengage() -> void:
	engaged = false


func flee() -> bool:
	if _now() < _flee_until + FLEE_COOLDOWN - FLEE_DURATION or not player.health.is_alive():
		return false
	disengage()
	cancel_cast("Fuite")
	_flee_until = _now() + FLEE_DURATION
	fleeing = true
	_cooldown_until["flee"] = _flee_until + FLEE_COOLDOWN - FLEE_DURATION
	return true


func speed_multiplier() -> float:
	return FLEE_SPEED_MULT if fleeing else 1.0


## Weapon skill : 100 TP minimum, cible à portée de mêlée.
func use_weapon_skill() -> bool:
	var ws := weapon_skill()
	if ws.is_empty() or tp < TP_READY or not target_alive() or player.is_busy() or is_casting() or player.is_stunned():
		return false
	var t := target()
	if not _in_melee_range(t):
		_notify("Trop loin pour %s." % ws.get("name", "la compétence"))
		return false
	engage()
	var spent := tp
	tp = 0
	player.face_target_now(t)
	player.play_anim("attack", 0.05, true)
	var scale := 1.0 + float(ws.get("tp_scaling", 0.5)) * float(spent - TP_READY) / float(TP_MAX - TP_READY)
	var atk: Dictionary = player.weapon.duplicate()
	atk["name"] = ws.get("name", "Weapon skill")
	atk["damage_multiplier"] = float(ws.get("multiplier", 1.0)) * scale
	if ws.has("knockback"):
		atk["knockback"] = ws.knockback
	if ws.has("condition"):
		atk["on_hit"] = {"condition": ws.condition, "duration": ws.get("condition_duration", 3.0)}
	var hits: int = ws.get("hits", 1)
	var mode: Dice.RollMode = Dice.RollMode.ADVANTAGE if ws.get("advantage", false) else Dice.RollMode.NORMAL
	for i in hits:
		get_tree().create_timer(ATTACK_IMPACT_DELAY + i * 0.25).timeout.connect(func():
			if is_instance_valid(player) and player.health.is_alive() and is_instance_valid(t) and t.health.is_alive():
				CombatResolver.weapon_attack(player, t, atk, mode))
	_swing_timer = weapon_delay() * 0.5
	_notify("%s utilise %s !" % [player.player_name, ws.get("name", "")])
	return true


## Compétence de classe par identifiant (voir features des classes).
func use_ability(id: String) -> bool:
	var f: Dictionary = {}
	for a in abilities():
		if a.id == id:
			f = a
	if f.is_empty() or not player.health.is_alive() or player.is_stunned():
		return false
	if cooldown_left(id) > 0.0:
		_notify("%s : encore %d s." % [f.name, ceili(cooldown_left(id))])
		return false
	var used := false
	match f.get("type", ""):
		"self_heal":
			var amount := Dice.roll_expr(str(f.get("heal", "1d10")), CombatResolver.rng)
			if f.get("add_level", false):
				amount += player.stats.level
			amount = int(amount * GameData.bal("healing_mult"))
			player.health.heal(amount)
			EventBus.hit_resolved.emit(player, {"attacker": player, "target": player, "attack_name": f.name,
				"hit": true, "heal": amount, "damage": 0, "damage_type": 0})
			used = true
		"buff":
			if f.get("effect", "") == "reset_cooldowns":
				for k in _cooldown_until.keys():
					if k != id:
						_cooldown_until.erase(k)
				tp = maxi(tp, TP_READY)
				_swing_timer = 0.0
				used = true
		"taunt":
			# Cible unique, à distance : permet d'extraire un monstre d'un groupe.
			var t := target()
			if not target_alive():
				_notify("Provocation : choisis d'abord une cible (Tab / clic).")
				return false
			if player.global_position.distance_to(t.global_position) > float(f.get("range", 20.0)):
				_notify("Provocation : trop loin (portée %d m)." % int(f.get("range", 20.0)))
				return false
			if t is Enemy:
				t.taunt(player, float(f.get("duration", 8.0)))
				player.face_target_now(t)
			_notify("%s provoque %s !" % [player.player_name, t.stats.display_name])
			used = true
		"guard_toggle":
			if player.is_blocking:
				player.set_blocking(false)
			else:
				disengage()
				cancel_cast("Garde")
				player.set_blocking(true)
			return true  # pas de recharge
		"restore_slots":
			if player.spell_book:
				var total := ceili(player.stats.level / 2.0)
				var s: Dictionary = player.spell_book.slots.duplicate()
				var keys: Array = s.keys()
				keys.sort_custom(func(a, b): return int(a) > int(b))
				for k in keys:
					while total >= int(k) and int(s[k]) < int(player.spell_book.max_slots.get(k, 0)):
						s[k] = int(s[k]) + 1
						total -= int(k)
				player.spell_book.slots = s
				used = true
		"instant_cast":
			instant_cast_ready = true
			used = true
	if used:
		if f.has("cooldown"):
			_cooldown_until[id] = _now() + float(f.cooldown)
		if f.get("type") != "taunt":
			_notify("%s utilise %s." % [player.player_name, f.name])
		player.play_anim("cast", 0.1, true)
	return used


## Incantation : démarre le temps de lancement ; le sort part à la fin si on n'a pas bougé.
func start_cast(spell_id: String) -> bool:
	if not player.spell_book or not player.spell_book.is_caster() or not player.health.is_alive():
		return false
	if is_casting() or player.is_busy() or player.is_stunned():
		return false
	var spell := GameData.spell(spell_id)
	if spell.is_empty():
		return false
	if not player.spell_book.can_cast(spell_id):
		_notify("Plus d'emplacement pour %s." % spell.get("name", spell_id))
		return false
	# Règle D&D : on n'incante pas dans une armure (ou avec un bouclier) que le job ne maîtrise pas.
	var hindrance := armor_hindrance()
	if hindrance != "":
		_notify("Impossible d'incanter : %s gêne le %s (retirez-le dans l'inventaire)." % [hindrance,
			GameData.player_class(player.class_id).get("name", player.class_id)])
		return false
	var needs_target: bool = spell.get("targeting", "projectile") != "self_or_ally"
	if needs_target and not target_alive():
		_notify("Choisis d'abord une cible (Tab).")
		return false
	if player.is_blocking:
		player.set_blocking(false)
	_cast_spell = spell_id
	casting_id = spell_id
	cast_total = 0.0 if instant_cast_ready else float(spell.get("cast_time", 1.0))
	cast_left = cast_total
	_cast_moving_time = 0.0
	if needs_target:
		player.face_target_now(target())
	if cast_total <= 0.0:
		_release_cast()
	else:
		player.play_anim("cast", 0.1, true)
	return true


func cancel_cast(reason: String = "") -> void:
	if not is_casting():
		return
	_cast_spell = ""
	casting_id = ""
	cast_left = 0.0
	player.release_anim()
	if reason != "":
		_notify("Incantation interrompue (%s)." % reason)


func _release_cast() -> void:
	var spell_id := _cast_spell
	_cast_spell = ""
	casting_id = ""
	cast_left = 0.0
	if not player.health.is_alive():
		return
	var t := target()
	player.play_anim("cast", 0.05, true)
	instant_cast_ready = false
	get_tree().create_timer(CAST_RELEASE_DELAY).timeout.connect(func():
		if is_instance_valid(player) and player.health.is_alive():
			var eye: Vector3 = player.global_position + Vector3(0, PlayerCharacter.CAST_HEIGHT, 0)
			var dir: Vector3 = player.aim_direction()
			if t and is_instance_valid(t):
				dir = ((t.global_position + Vector3(0, 1.0, 0)) - eye).normalized()
			SpellCaster.cast(player, spell_id, eye, dir, t if (t and is_instance_valid(t)) else null))


# ------------------------------------------------------------------ simulation (hôte)

func tick(delta: float, moving: bool) -> void:
	# Recharges pour le HUD.
	_cooldown_refresh -= delta
	if _cooldown_refresh <= 0.0:
		_cooldown_refresh = 0.25
		var cl := {}
		for k in _cooldown_until:
			var left: float = float(_cooldown_until[k]) - _now()
			if left > 0.0:
				cl[k] = snappedf(left, 0.1)
		if cl != cooldowns_left:
			cooldowns_left = cl
	if fleeing and _now() >= _flee_until:
		fleeing = false
	# Cible morte ou disparue → désengagement.
	if not target_path.is_empty() and not target_alive():
		target_path = NodePath()
		engaged = false
		cancel_cast()
	# Incantation.
	if is_casting():
		if moving:
			_cast_moving_time += delta
			if _cast_moving_time > CAST_MOVE_TOLERANCE:
				cancel_cast("déplacement")
		else:
			_cast_moving_time = 0.0
		if is_casting():
			cast_left = maxf(0.0, cast_left - delta)
			if cast_left <= 0.0:
				_release_cast()
		return
	# Auto-attaque.
	_swing_timer = maxf(0.0, _swing_timer - delta)
	if engaged and not player.is_blocking and not player.is_busy() and _swing_timer <= 0.0:
		var t := target()
		if _in_melee_range(t) and _facing(t):
			_swing(t)


func _swing(t: Creature) -> void:
	_swing_timer = weapon_delay()
	player.play_anim("attack", 0.05, true)
	var per_swing: int = 1
	for a in abilities_passive():
		per_swing = maxi(per_swing, int(a.get("attacks_per_swing", 1)))
	for i in per_swing:
		get_tree().create_timer(ATTACK_IMPACT_DELAY + i * 0.3).timeout.connect(func():
			if is_instance_valid(player) and player.health.is_alive() and is_instance_valid(t) and t.health.is_alive() \
					and _in_melee_range(t, 0.6):
				CombatResolver.weapon_attack(player, t, player.weapon))


func abilities_passive() -> Array:
	var out: Array = []
	var cls: Dictionary = GameData.player_class(player.class_id)
	var by_level: Dictionary = cls.get("features_by_level", {})
	var feats: Dictionary = cls.get("features", {})
	for lvl_key in by_level:
		if int(lvl_key) > player.stats.level:
			continue
		for fid in by_level[lvl_key]:
			var f: Dictionary = feats.get(fid, {})
			if f.get("type", "") == "passive":
				out.append(f)
	return out


func _in_melee_range(t: Creature, extra := 0.0) -> bool:
	if t == null or not is_instance_valid(t):
		return false
	var reach: float = MELEE_REACH + extra + 0.5 * (t.model_scale - 1.0)
	return player.global_position.distance_to(t.global_position) <= reach


func _facing(t: Creature) -> bool:
	var to := t.global_position - player.global_position
	to.y = 0.0
	return to.length() < 0.01 or player.forward().dot(to.normalized()) >= FACING_DOT


## TP : coups portés par le joueur (plein) et coups reçus (moitié).
func _on_hit_resolved(target_node: Node3D, r: Dictionary) -> void:
	if r.has("heal") or not r.get("hit", false):
		return
	if r.get("attacker") == player and target_node != player and not r.has("damage_multiplier") \
			and r.get("attack_name", "") == player.weapon.get("name", ""):
		_gain_tp(_tp_per_hit())
	elif target_node == player and r.get("damage", 0) > 0:
		_gain_tp(_tp_per_hit() / 2)


func _on_damaged(_amount: int, _type: int, _crit: bool, _source: Node) -> void:
	pass


func _tp_per_hit() -> int:
	# Plus l'arme est lente, plus le gain par coup est élevé (≈ 1 WS toutes les 5-6 touches).
	return int(round((8.0 + float(player.weapon.get("delay", 2.4)) * 4.0) * GameData.bal("tp_per_hit_mult")))


func _gain_tp(amount: int) -> void:
	var before := tp
	tp = clampi(tp + amount, 0, TP_MAX)
	if before < TP_READY and tp >= TP_READY:
		_notify("%s : TP prêts — weapon skill disponible !" % player.player_name)


func _notify(text: String) -> void:
	var game := get_tree().get_first_node_in_group("game")
	if game:
		game.system_message(text)

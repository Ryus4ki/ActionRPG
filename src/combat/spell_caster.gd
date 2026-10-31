class_name SpellCaster
extends RefCounted
## Lancement et résolution des sorts (hôte uniquement). Données : data/spells/spells.json.
##
## resolution : "spell_attack" (jet d'attaque de sort vs CA), "auto_hit" (touche toujours),
##              "save" (jet de sauvegarde de la cible, moitié si réussi), "buff".
## targeting  : "projectile", "projectile_multi", "homing_multi", "cone", "ground_aoe", "self_or_ally".

const PROJECTILE_SCENE := preload("res://scenes/projectile.tscn")
const SPELL_COLORS := {
	"fire_bolt": Color(1.0, 0.45, 0.1), "magic_missile": Color(0.6, 0.6, 1.0),
	"scorching_ray": Color(1.0, 0.3, 0.1), "fireball": Color(1.0, 0.55, 0.15),
	"burning_hands": Color(1.0, 0.5, 0.1), "mage_armor": Color(0.5, 0.8, 1.0),
}


## Dés de dégâts du sort selon le niveau du lanceur (tours de magie) ou l'emplacement utilisé.
static func damage_dice(spell: Dictionary, caster_level: int, slot_level: int) -> String:
	var dice: String = spell.get("damage", "1d4")
	if spell.get("level", 0) == 0:
		# Tour de magie : paliers par niveau de personnage.
		var scaling: Dictionary = spell.get("scaling", {})
		var keys := scaling.keys()
		keys.sort_custom(func(a, b): return int(a) < int(b))
		for k in keys:
			if caster_level >= int(k):
				dice = scaling[k]
		return dice
	var extra := slot_level - int(spell.get("level", 1))
	var upcast: Dictionary = spell.get("upcast", {})
	if extra > 0 and upcast.has("extra_dice_per_slot_level"):
		var d := Dice.parse(dice)
		var e := Dice.parse(upcast["extra_dice_per_slot_level"])
		dice = "%dd%d%s" % [d.count + e.count * extra, d.sides, ("+%d" % d.bonus) if d.bonus > 0 else ("%d" % d.bonus if d.bonus < 0 else "")]
	return dice


static func projectile_count(spell: Dictionary, slot_level: int) -> int:
	var n: int = spell.get("projectiles", 1)
	var extra := slot_level - int(spell.get("level", 1))
	var upcast: Dictionary = spell.get("upcast", {})
	if extra > 0 and upcast.has("projectiles_per_slot_level"):
		n += int(upcast["projectiles_per_slot_level"]) * extra
	return n


## Lance le sort sélectionné. `aim_origin` / `aim_dir` : rayon de visée (yeux du joueur, direction caméra).
## Renvoie vrai si le sort est parti (emplacement consommé).
static func cast(caster: PlayerCharacter, spell_id: String, aim_origin: Vector3, aim_dir: Vector3, target: Node3D = null) -> bool:
	var book: SpellBook = caster.spell_book
	var spell := GameData.spell(spell_id)
	if spell.is_empty() or not book.can_cast(spell_id):
		return false
	var slot_level := book.consume(spell_id)
	var game := _game(caster)
	var color: Color = SPELL_COLORS.get(spell_id, Color(0.8, 0.8, 1.0))
	match spell.get("targeting", "projectile"):
		"projectile", "projectile_multi":
			var n := projectile_count(spell, slot_level)
			for i in n:
				# Léger éventail pour les rayons multiples.
				var spread := 0.0 if n == 1 else deg_to_rad(-6.0 + 12.0 * i / float(n - 1))
				var dir := aim_dir.rotated(Vector3.UP, spread)
				game.spawn_projectile({
					"caster": caster.get_path(), "spell_id": spell_id, "slot_level": slot_level,
					"origin": aim_origin + dir * 0.6, "direction": dir,
					"speed": spell.get("projectile_speed", 25.0), "max_range": spell.get("range", 30.0),
					"radius": 0.12, "color": color,
				})
		"homing_multi":
			var n := projectile_count(spell, slot_level)
			var targets: Array = [target] if (target and is_instance_valid(target)) else _enemies_in_front(caster, spell.get("range", 36.0), 0.3)
			if targets.is_empty():
				_refund(book, spell_id, slot_level)
				return false
			for i in n:
				var t: Node3D = targets[i % targets.size()]
				var dir := aim_dir.rotated(Vector3.UP, deg_to_rad(randf_range(-25, 25))).rotated(caster.global_transform.basis.x, deg_to_rad(randf_range(5, 25)))
				game.spawn_projectile({
					"caster": caster.get_path(), "spell_id": spell_id, "slot_level": slot_level,
					"origin": aim_origin + Vector3(0, 0.2, 0), "direction": dir, "homing": true, "target": t.get_path(),
					"speed": minf(spell.get("projectile_speed", 30.0), 18.0), "max_range": spell.get("range", 36.0) * 2.0,
					"radius": 0.1, "color": color,
				})
		"cone":
			var hit_any := false
			var cos_half := cos(deg_to_rad(float(spell.get("cone_angle", 90)) / 2.0))
			for e in _enemies_in_front(caster, spell.get("range", 4.5), cos_half):
				_apply_save_spell(caster, e, spell, spell_id, slot_level)
				hit_any = true
			game.show_vfx(caster.global_position + Vector3(0, 1.0, 0) + caster.forward() * 2.0, 2.2, color)
			if not hit_any:
				pass  # le sort est consommé même sans cible (comme en D&D)
		"ground_aoe":
			var target_point := _ground_target(caster, aim_origin, aim_dir, spell.get("range", 45.0))
			if target and is_instance_valid(target):
				target_point = target.global_position
			game.spawn_projectile({
				"caster": caster.get_path(), "spell_id": spell_id, "slot_level": slot_level,
				"origin": aim_origin + aim_dir * 0.6, "direction": (target_point - aim_origin).normalized(),
				"speed": spell.get("projectile_speed", 20.0), "max_range": spell.get("range", 45.0) + 5.0,
				"explode_on_arrival": true, "target_point": target_point, "radius": 0.25, "color": color,
			})
		"self_or_ally":
			_apply_buff(caster, spell)
			game.show_vfx(caster.global_position + Vector3(0, 1.0, 0), 1.6, color)
		_:
			push_warning("Ciblage de sort inconnu : " + str(spell.get("targeting")))
	return true


static func _refund(book: SpellBook, spell_id: String, slot_level: int) -> void:
	if slot_level > 0:
		var s := book.slots.duplicate()
		s[str(slot_level)] = int(s[str(slot_level)]) + 1
		book.slots = s
	book._cooldown_until.erase(spell_id)


## Impact d'un projectile sur une créature (appelé par Projectile).
static func projectile_hit(caster: Node, target: Creature, spell_id: String, slot_level: int) -> void:
	if not (caster is PlayerCharacter) or not is_instance_valid(target):
		return
	var spell := GameData.spell(spell_id)
	var dice := damage_dice(spell, caster.stats.level, slot_level)
	match spell.get("resolution", "spell_attack"):
		"spell_attack":
			CombatResolver.weapon_attack(caster, target, {
				"name": spell.get("name", spell_id), "damage": dice,
				"damage_type": spell.get("damage_type", "force"),
				"bonus": caster.stats.spell_attack_bonus(caster.spell_book.casting_ability),
				"damage_multiplier": GameData.bal("spell_damage_mult"),
			})
		"auto_hit":
			CombatResolver.direct_damage(caster, target, dice, spell.get("damage_type", "force"), spell.get("name", spell_id))
		"save":
			_apply_save_spell(caster, target, spell, spell_id, slot_level)


## Explosion d'une zone (boule de feu) : sauvegarde pour chaque ennemi dans le rayon.
static func explode_at(caster: Node, pos: Vector3, spell_id: String, slot_level: int) -> void:
	if not (caster is PlayerCharacter):
		return
	var spell := GameData.spell(spell_id)
	var radius: float = spell.get("radius", 6.0)
	var game := _game(caster)
	game.show_vfx(pos, radius, SPELL_COLORS.get(spell_id, Color(1, 0.5, 0.1)))
	for e in caster.get_tree().get_nodes_in_group("enemies"):
		if e is Creature and e.health.is_alive() and e.global_position.distance_to(pos) <= radius:
			_apply_save_spell(caster, e, spell, spell_id, slot_level)
	if spell.get("friendly_fire", false):
		for p in caster.get_tree().get_nodes_in_group("players"):
			if p is Creature and p.health.is_alive() and p.global_position.distance_to(pos) <= radius:
				_apply_save_spell(caster, p, spell, spell_id, slot_level)


static func _apply_save_spell(caster: PlayerCharacter, target: Node3D, spell: Dictionary, spell_id: String, slot_level: int) -> void:
	var dice := damage_dice(spell, caster.stats.level, slot_level)
	CombatResolver.save_damage(caster, target, dice, spell.get("damage_type", "fire"),
		spell.get("save_ability", "dex"), caster.stats.spell_save_dc(caster.spell_book.casting_ability),
		spell.get("half_on_success", true), spell.get("name", spell_id))


static func _apply_buff(caster: PlayerCharacter, spell: Dictionary) -> void:
	var effect: Dictionary = spell.get("effect", {})
	match effect.get("type", ""):
		"set_base_ac":
			caster.stats.mage_armor = true  # n'agit que sans armure (voir StatBlock.armor_class)


## Ennemis vivants à portée dont la direction est dans le cône (dot ≥ min_dot), triés par distance.
static func _enemies_in_front(caster: Creature, range_m: float, min_dot: float) -> Array:
	var out: Array = []
	var fwd := caster.forward()
	for e in caster.get_tree().get_nodes_in_group("enemies"):
		if not (e is Creature) or not e.health.is_alive():
			continue
		var to: Vector3 = e.global_position - caster.global_position
		to.y = 0.0
		var d := to.length()
		if d > range_m or d < 0.01:
			continue
		if fwd.dot(to / d) >= min_dot:
			out.append(e)
	out.sort_custom(func(a, b): return caster.global_position.distance_to(a.global_position) < caster.global_position.distance_to(b.global_position))
	return out


## Point au sol visé : intersection du rayon de visée avec le sol (y = 0), plafonné à la portée.
static func _ground_target(caster: Creature, origin: Vector3, dir: Vector3, range_m: float) -> Vector3:
	var point: Vector3
	if dir.y < -0.02:
		var t := -origin.y / dir.y
		point = origin + dir * t
	else:
		point = origin + dir * range_m
		point.y = 0.0
	var flat := point - caster.global_position
	flat.y = 0.0
	if flat.length() > range_m:
		point = caster.global_position + flat.normalized() * range_m
		point.y = 0.0
	return point


static func _game(node: Node) -> Node:
	return node.get_tree().get_first_node_in_group("game")

class_name CombatResolver
extends RefCounted
## Résolution d'une attaque entre deux créatures, en utilisant rules/.
## N'est appelé QUE côté hôte. Le Dictionary renvoyé est ce qui sera répliqué/affiché.
##
## Une « attaque » est un Dictionary (arme de items.json ou attaque de monsters.json) :
##   { damage: "1d8", damage_type: "slashing", ability: "str", magic_bonus: 0, bonus: 4 (monstre) }

static var rng := RandomNumberGenerator.new()


static func _stats(node: Node) -> StatBlock:
	return node.get_node_or_null("StatBlock") as StatBlock


static func _health(node: Node) -> Health:
	return node.get_node_or_null("Health") as Health


## Attaque d'arme (mêlée ou projectile) : jet d'attaque vs CA, puis dégâts.
static func weapon_attack(attacker: Node3D, target: Node3D, attack: Dictionary,
		mode: Dice.RollMode = Dice.RollMode.NORMAL) -> Dictionary:
	var a_stats := _stats(attacker)
	var t_stats := _stats(target)
	var t_health := _health(target)
	if a_stats == null or t_stats == null or t_health == null or not t_health.is_alive():
		return {}

	var ability: String = attack.get("ability", "str")
	var magic: int = attack.get("magic_bonus", 0)
	var atk_bonus: int
	if attack.has("bonus"):          # monstre : bonus fixe du bestiaire (+ précision globale, balance.json)
		atk_bonus = int(attack["bonus"])
		if attacker is Enemy:
			atk_bonus += int(GameData.bal("monster_hit_bonus", 0.0))
	else:
		atk_bonus = a_stats.attack_bonus(ability, magic)

	# Garde active (bouclier) : désavantage sur l'attaque et dégâts divisés par deux.
	var blocked := target is Creature and (target as Creature).blocks_attack_from(attacker.global_position)
	if blocked:
		mode = Dice.RollMode.DISADVANTAGE if mode != Dice.RollMode.ADVANTAGE else Dice.RollMode.NORMAL
	# Conditions de l'attaquant : aveuglé → désavantage ; affaibli −2 / renforcé +2.
	if attacker is Creature:
		var a := attacker as Creature
		if a.has_condition("blinded"):
			mode = Dice.RollMode.DISADVANTAGE if mode != Dice.RollMode.ADVANTAGE else Dice.RollMode.NORMAL
		atk_bonus += a.condition_attack_bonus()

	var roll := CombatRules.attack_roll(atk_bonus, t_stats.armor_class(), mode, rng)
	var result := {
		"attacker": attacker, "target": target, "attack_name": attack.get("name", ""),
		"d20": roll.d20, "total": roll.total, "ac": t_stats.armor_class(),
		"hit": roll.hit, "crit": roll.crit, "fumble": roll.fumble, "blocked": blocked,
		"damage": 0, "damage_type": StatBlock.damage_type_from_string(attack.get("damage_type", "bludgeoning")),
	}
	if roll.hit and attack.has("damage"):
		var dmg_bonus: int = magic
		if not attack.has("bonus"):
			dmg_bonus += a_stats.ability_mod(ability)
		var raw := CombatRules.roll_damage(attack.get("damage", "1d4"), dmg_bonus, roll.crit, rng)
		var final := CombatRules.apply_defenses(raw, result.damage_type,
			t_stats.damage_resistances, t_stats.damage_vulnerabilities, t_stats.damage_immunities)
		if blocked:
			final = final / 2
		if attack.has("damage_multiplier"):
			final = int(round(final * float(attack.damage_multiplier)))
		result.damage = final
		t_health.take_damage(final, result.damage_type, roll.crit, attacker)
	var on_hit: Dictionary = attack.get("on_hit", {})
	if roll.hit and on_hit.has("condition") and target is Creature:
		(target as Creature).apply_condition(on_hit.condition, on_hit.get("duration", 3.0))
		result["condition"] = on_hit.condition
	if roll.hit and attack.has("knockback") and target is Creature and not blocked:
		(target as Creature).apply_knockback(target.global_position - attacker.global_position, attack.knockback * 3.0)
	EventBus.hit_resolved.emit(target, result)
	# Effet secondaire avec sauvegarde (poison de morsure…), résolu séparément.
	if roll.hit and on_hit.has("save_ability") and t_health.is_alive():
		save_damage(attacker, target, on_hit.get("extra_damage", "1d6"), on_hit.get("extra_damage_type", "poison"),
			on_hit.save_ability, on_hit.get("dc", 10), on_hit.get("half_on_success", true), on_hit.get("extra_damage_type", "poison").capitalize())
	return result


## Dégâts directs avec jet de sauvegarde (sorts de zone, poison…).
static func save_damage(attacker: Node3D, target: Node3D, dice_expr: String, damage_type: String,
		save_ability: String, dc: int, half_on_success: bool = true, attack_name: String = "") -> Dictionary:
	var t_stats := _stats(target)
	var t_health := _health(target)
	if t_stats == null or t_health == null or not t_health.is_alive():
		return {}
	var save := CombatRules.saving_throw(t_stats.save_bonus(save_ability), dc, Dice.RollMode.NORMAL, rng)
	var dtype := StatBlock.damage_type_from_string(damage_type)
	var full := CombatRules.roll_damage(dice_expr, 0, false, rng)
	if attacker is PlayerCharacter:
		full = roundi(full * GameData.bal("spell_damage_mult"))  # sorts des joueurs (balance.json)
	var dealt := CombatRules.save_spell_damage(full, save.success, half_on_success)
	# Esquive en cours : on passe au travers (succès automatique). Garde levée : dégâts divisés par deux.
	var evaded: bool = target is PlayerCharacter and (target as PlayerCharacter).is_dodging()
	if evaded:
		dealt = 0
	elif target is Creature and (target as Creature).is_blocking:
		dealt = dealt / 2
	dealt = CombatRules.apply_defenses(dealt, dtype,
		t_stats.damage_resistances, t_stats.damage_vulnerabilities, t_stats.damage_immunities)
	var result := {
		"attacker": attacker, "target": target, "attack_name": attack_name, "hit": dealt > 0, "crit": false, "fumble": false,
		"save_d20": save.d20, "save_total": save.total, "save_success": save.success or evaded, "dc": dc,
		"damage": dealt, "damage_type": dtype, "evaded": evaded,
	}
	if dealt > 0:
		t_health.take_damage(dealt, dtype, false, attacker)
	EventBus.hit_resolved.emit(target, result)
	return result


## Dégâts automatiques sans jet (projectile magique) : dés + résistances.
static func direct_damage(attacker: Node3D, target: Node3D, dice_expr: String, damage_type: String,
		attack_name: String = "") -> Dictionary:
	var t_stats := _stats(target)
	var t_health := _health(target)
	if t_stats == null or t_health == null or not t_health.is_alive():
		return {}
	var dtype := StatBlock.damage_type_from_string(damage_type)
	var raw := CombatRules.roll_damage(dice_expr, 0, false, rng)
	if attacker is PlayerCharacter:
		raw = roundi(raw * GameData.bal("spell_damage_mult"))
	var dealt := CombatRules.apply_defenses(raw, dtype,
		t_stats.damage_resistances, t_stats.damage_vulnerabilities, t_stats.damage_immunities)
	var result := {
		"attacker": attacker, "target": target, "attack_name": attack_name, "hit": true, "crit": false,
		"fumble": false, "auto_hit": true, "damage": dealt, "damage_type": dtype,
	}
	t_health.take_damage(dealt, dtype, false, attacker)
	EventBus.hit_resolved.emit(target, result)
	return result

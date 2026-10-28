class_name CombatRules
extends RefCounted
## Résolution des attaques, sauvegardes et dégâts (SRD 5.1 simplifié).
## Ces fonctions ne sont appelées que côté hôte ; le résultat (Dictionary) est répliqué.

enum DamageType {
	BLUDGEONING, PIERCING, SLASHING,
	FIRE, COLD, LIGHTNING, ACID, POISON, NECROTIC, RADIANT, FORCE, PSYCHIC, THUNDER
}


## Jet d'attaque : d20 + bonus vs CA. 20 naturel = critique (touche toujours),
## 1 naturel = échec automatique.
static func attack_roll(attack_bonus: int, target_ac: int,
		mode: Dice.RollMode = Dice.RollMode.NORMAL, rng: RandomNumberGenerator = null) -> Dictionary:
	var d20 := Dice.roll_d20(mode, rng)
	var crit := d20 == 20
	var fumble := d20 == 1
	var total := d20 + attack_bonus
	var hit := crit or (not fumble and total >= target_ac)
	return {"d20": d20, "total": total, "hit": hit, "crit": crit, "fumble": fumble}


## Jet de sauvegarde : d20 + bonus vs DD. Pas de critique sur les sauvegardes.
static func saving_throw(save_bonus: int, dc: int,
		mode: Dice.RollMode = Dice.RollMode.NORMAL, rng: RandomNumberGenerator = null) -> Dictionary:
	var d20 := Dice.roll_d20(mode, rng)
	var total := d20 + save_bonus
	return {"d20": d20, "total": total, "success": total >= dc}


## Dégâts : expression de dés + bonus fixe ; critique = dés doublés. Minimum 0.
static func roll_damage(dice_expr: String, bonus: int = 0, crit: bool = false,
		rng: RandomNumberGenerator = null) -> int:
	return maxi(Dice.roll_expr(dice_expr, rng, crit) + bonus, 0)


## Applique résistances (÷2, arrondi à l'inférieur), vulnérabilités (×2) et immunités (0).
static func apply_defenses(amount: int, type: DamageType,
		resistances: Array = [], vulnerabilities: Array = [], immunities: Array = []) -> int:
	if type in immunities:
		return 0
	var result := amount
	if type in resistances:
		result = result / 2
	if type in vulnerabilities:
		result *= 2
	return result


## Sort à sauvegarde (ex. Boule de feu) : dégâts pleins si raté, moitié si réussi
## (ou 0 si `half_on_success` est faux, ex. Mains brûlantes = moitié, Sommeil = rien).
static func save_spell_damage(full_damage: int, save_success: bool, half_on_success: bool = true) -> int:
	if not save_success:
		return full_damage
	return full_damage / 2 if half_on_success else 0


## Nom lisible d'un type de dégâts (pour l'UI / les logs).
static func damage_type_name(type: DamageType) -> String:
	return DamageType.keys()[type].to_lower()

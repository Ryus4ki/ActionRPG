class_name Dice
extends RefCounted
## Lancers de dés D&D.
## IMPORTANT : en réseau, les dés sont TOUJOURS lancés côté hôte (autorité),
## jamais côté client. Passer un RandomNumberGenerator pour des tests déterministes.

enum RollMode { NORMAL, ADVANTAGE, DISADVANTAGE }


static func _rand(sides: int, rng: RandomNumberGenerator) -> int:
	if rng != null:
		return rng.randi_range(1, sides)
	return randi_range(1, sides)


## Lance `count` dés à `sides` faces et renvoie la somme.
static func roll(count: int, sides: int, rng: RandomNumberGenerator = null) -> int:
	var total := 0
	for _i in count:
		total += _rand(sides, rng)
	return total


## Analyse une expression de dés : "2d6+3", "1d8", "d20", "3d4-1".
## Renvoie { count, sides, bonus }.
static func parse(expr: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("^\\s*(\\d*)d(\\d+)\\s*([+-]\\s*\\d+)?\\s*$")
	var m := re.search(expr.to_lower())
	if m == null:
		push_error("Expression de dés invalide : '%s'" % expr)
		return {"count": 0, "sides": 0, "bonus": 0}
	var count := 1 if m.get_string(1).is_empty() else int(m.get_string(1))
	var sides := int(m.get_string(2))
	var bonus := 0
	if not m.get_string(3).is_empty():
		bonus = int(m.get_string(3).replace(" ", ""))
	return {"count": count, "sides": sides, "bonus": bonus}


## Lance une expression ("2d6+3"). Si `crit` est vrai, le nombre de dés est doublé
## (règle SRD du coup critique : on double les dés, pas le bonus).
static func roll_expr(expr: String, rng: RandomNumberGenerator = null, crit: bool = false) -> int:
	var d := parse(expr)
	var count: int = d.count * (2 if crit else 1)
	return roll(count, d.sides, rng) + d.bonus


## Moyenne d'une expression (utile pour l'équilibrage et les PV fixes des monstres).
static func average(expr: String) -> float:
	var d := parse(expr)
	return d.count * (d.sides + 1) / 2.0 + d.bonus


## Jet de d20 avec avantage / désavantage.
static func roll_d20(mode: RollMode = RollMode.NORMAL, rng: RandomNumberGenerator = null) -> int:
	var a := _rand(20, rng)
	if mode == RollMode.NORMAL:
		return a
	var b := _rand(20, rng)
	return maxi(a, b) if mode == RollMode.ADVANTAGE else mini(a, b)

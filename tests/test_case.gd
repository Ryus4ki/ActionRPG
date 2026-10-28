extends RefCounted
## Classe de base des tests : assertions simples qui accumulent les échecs.

var failures: Array[String] = []


func reset() -> void:
	failures.clear()


func assert_eq(actual, expected, msg: String = "") -> void:
	if actual != expected:
		failures.append("%s attendu=%s obtenu=%s" % [msg, str(expected), str(actual)])


func assert_true(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("%s (attendu vrai)" % msg)


func assert_false(cond: bool, msg: String = "") -> void:
	if cond:
		failures.append("%s (attendu faux)" % msg)


func assert_between(value, lo, hi, msg: String = "") -> void:
	if value < lo or value > hi:
		failures.append("%s : %s hors de [%s, %s]" % [msg, str(value), str(lo), str(hi)])


## RNG déterministe pour les tests.
func seeded(seed_value: int = 42) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng

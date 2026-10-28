extends "res://tests/test_case.gd"

const Dice := preload("res://src/rules/dice.gd")
const Rules := preload("res://src/rules/rules.gd")
const CombatRules := preload("res://src/rules/combat_rules.gd")


# ---------- Dice ----------

func test_parse_expressions() -> void:
	assert_eq(Dice.parse("2d6+3"), {"count": 2, "sides": 6, "bonus": 3}, "2d6+3")
	assert_eq(Dice.parse("d20"), {"count": 1, "sides": 20, "bonus": 0}, "d20")
	assert_eq(Dice.parse("3d4-1"), {"count": 3, "sides": 4, "bonus": -1}, "3d4-1")
	assert_eq(Dice.parse("1D8 + 2"), {"count": 1, "sides": 8, "bonus": 2}, "espaces/majuscules")


func test_roll_ranges() -> void:
	var rng := seeded()
	for _i in 200:
		assert_between(Dice.roll(2, 6, rng), 2, 12, "2d6")
		assert_between(Dice.roll_expr("1d8+2", rng), 3, 10, "1d8+2")
		assert_between(Dice.roll_d20(Dice.RollMode.NORMAL, rng), 1, 20, "d20")


func test_crit_doubles_dice_not_bonus() -> void:
	var rng := seeded()
	for _i in 200:
		assert_between(Dice.roll_expr("1d8+3", rng, true), 5, 19, "crit 2d8+3")


func test_average() -> void:
	assert_eq(Dice.average("2d6+3"), 10.0, "moyenne 2d6+3")
	assert_eq(Dice.average("1d8"), 4.5, "moyenne 1d8")


func test_advantage_is_better_on_average() -> void:
	var rng := seeded(7)
	var adv := 0
	var dis := 0
	for _i in 2000:
		adv += Dice.roll_d20(Dice.RollMode.ADVANTAGE, rng)
		dis += Dice.roll_d20(Dice.RollMode.DISADVANTAGE, rng)
	assert_true(adv > dis, "avantage > désavantage")
	assert_between(adv / 2000.0, 12.5, 15.5, "moyenne avantage ≈ 13.8")
	assert_between(dis / 2000.0, 5.5, 8.5, "moyenne désavantage ≈ 7.2")


# ---------- Rules ----------

func test_ability_mod() -> void:
	assert_eq(Rules.ability_mod(10), 0, "10")
	assert_eq(Rules.ability_mod(11), 0, "11")
	assert_eq(Rules.ability_mod(12), 1, "12")
	assert_eq(Rules.ability_mod(8), -1, "8")
	assert_eq(Rules.ability_mod(9), -1, "9")
	assert_eq(Rules.ability_mod(20), 5, "20")
	assert_eq(Rules.ability_mod(1), -5, "1")


func test_proficiency_bonus() -> void:
	assert_eq(Rules.proficiency_bonus(1), 2, "niv 1")
	assert_eq(Rules.proficiency_bonus(4), 2, "niv 4")
	assert_eq(Rules.proficiency_bonus(5), 3, "niv 5")
	assert_eq(Rules.proficiency_bonus(8), 3, "niv 8")
	assert_eq(Rules.proficiency_bonus(9), 4, "niv 9")


func test_xp_levels() -> void:
	assert_eq(Rules.level_for_xp(0), 1, "0 xp")
	assert_eq(Rules.level_for_xp(299), 1, "299 xp")
	assert_eq(Rules.level_for_xp(300), 2, "300 xp")
	assert_eq(Rules.level_for_xp(6500), 5, "6500 xp")
	assert_eq(Rules.level_for_xp(999999), 10, "plafond")
	assert_eq(Rules.xp_for_next_level(1), 300, "suivant niv 1")
	assert_eq(Rules.xp_for_next_level(10), -1, "niv max")


func test_max_hp() -> void:
	# Guerrier d10, CON 14 (+2) : niv 1 = 12, puis +8/niveau
	assert_eq(Rules.max_hp(10, 1, 2), 12, "guerrier niv 1")
	assert_eq(Rules.max_hp(10, 5, 2), 44, "guerrier niv 5")
	# Magicien d6, CON 12 (+1) : niv 1 = 7, puis +5/niveau
	assert_eq(Rules.max_hp(6, 1, 1), 7, "magicien niv 1")
	assert_eq(Rules.max_hp(6, 3, 1), 17, "magicien niv 3")
	# CON très négative : minimum 1 par niveau
	assert_eq(Rules.max_hp(6, 2, -5), 2, "min 1 par niveau")


func test_spell_dc_and_attack_bonus() -> void:
	assert_eq(Rules.spell_save_dc(2, 3), 13, "DD niv 1 INT 16")
	assert_eq(Rules.attack_bonus(3, 2), 5, "FOR 16 maîtrisé")
	assert_eq(Rules.attack_bonus(3, 2, false), 3, "non maîtrisé")
	assert_eq(Rules.attack_bonus(3, 2, true, 1), 6, "arme +1")


func test_armor_class() -> void:
	assert_eq(Rules.armor_class(10, 3, "none"), 13, "sans armure DEX 16")
	assert_eq(Rules.armor_class(11, 3, "light"), 14, "cuir DEX 16")
	assert_eq(Rules.armor_class(14, 3, "medium"), 16, "écailles DEX plafonnée à 2")
	assert_eq(Rules.armor_class(16, 3, "heavy", 2), 18, "mailles + bouclier, DEX ignorée")


# ---------- CombatRules ----------

func test_attack_roll_outcomes() -> void:
	var rng := seeded(3)
	var seen_crit := false
	var seen_fumble := false
	for _i in 500:
		var r := CombatRules.attack_roll(5, 15, Dice.RollMode.NORMAL, rng)
		assert_eq(r.total, r.d20 + 5, "total")
		if r.d20 == 20:
			seen_crit = true
			assert_true(r.hit and r.crit, "20 naturel touche + critique")
		elif r.d20 == 1:
			seen_fumble = true
			assert_true(not r.hit and r.fumble, "1 naturel rate")
		else:
			assert_eq(r.hit, r.total >= 15, "comparaison CA")
	assert_true(seen_crit and seen_fumble, "les deux cas extrêmes sont apparus")


func test_saving_throw() -> void:
	var rng := seeded(9)
	for _i in 200:
		var r := CombatRules.saving_throw(2, 13, Dice.RollMode.NORMAL, rng)
		assert_eq(r.success, r.total >= 13, "réussite = total ≥ DD")


func test_damage_and_defenses() -> void:
	var T := CombatRules.DamageType
	assert_eq(CombatRules.apply_defenses(10, T.FIRE, [T.FIRE]), 5, "résistance")
	assert_eq(CombatRules.apply_defenses(11, T.FIRE, [T.FIRE]), 5, "résistance arrondi bas")
	assert_eq(CombatRules.apply_defenses(10, T.FIRE, [], [T.FIRE]), 20, "vulnérabilité")
	assert_eq(CombatRules.apply_defenses(10, T.POISON, [], [], [T.POISON]), 0, "immunité")
	assert_eq(CombatRules.apply_defenses(10, T.SLASHING, [T.FIRE]), 10, "non concerné")
	assert_eq(CombatRules.save_spell_damage(20, false), 20, "sauvegarde ratée")
	assert_eq(CombatRules.save_spell_damage(21, true), 10, "sauvegarde réussie = moitié")
	assert_eq(CombatRules.save_spell_damage(20, true, false), 0, "sauvegarde réussie = rien")
	assert_eq(CombatRules.damage_type_name(T.BLUDGEONING), "bludgeoning", "nom")
	var rng := seeded()
	for _i in 100:
		assert_between(CombatRules.roll_damage("1d6", -10, false, rng), 0, 0, "jamais négatif")

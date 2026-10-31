extends "res://tests/test_case.gd"

const GameDataScript := preload("res://src/core/game_data.gd")


func _data() -> Node:
	var gd: Node = GameDataScript.new()
	gd.load_all()
	return gd


func test_tables_loaded() -> void:
	var gd := _data()
	assert_eq(gd.classes.size(), 2, "2 classes")
	assert_eq(gd.races.size(), 3, "3 races")
	assert_eq(gd.spells.size(), 6, "6 sorts")
	assert_eq(gd.monsters.size(), 10, "10 monstres")
	assert_true(gd.items.size() >= 12, "≥ 12 objets")
	assert_eq(gd.rarities.size(), 3, "3 raretés")
	assert_false(gd.items.has("_rarity_table"), "table de rareté extraite")
	gd.free()


func test_cross_references() -> void:
	var gd := _data()
	var errors: Array[String] = gd.validate()
	for e in errors:
		failures.append(e)
	gd.free()


func test_class_values() -> void:
	var gd := _data()
	assert_eq(gd.player_class("fighter").hit_die, 10, "guerrier d10")
	assert_eq(gd.player_class("wizard").hit_die, 6, "magicien d6")
	assert_eq(gd.spell("fireball").level, 3, "boule de feu niv 3")
	assert_eq(gd.monster("ogre").hp_fixed, 59, "ogre 59 PV")
	assert_eq(floori(Dice.average(gd.monster("ogre").hp)), 59, "moyenne 7d10+21 = 59.5, le SRD arrondit en dessous")
	gd.free()

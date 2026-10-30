class_name Loot
extends RefCounted
## Tirage du butin (hôte) à partir de data/items/loot_tables.json et apparition au sol.

const RARITY_ORDER := ["common", "uncommon", "rare"]


static func table_for_monster(monster_id: String) -> String:
	var tables: Dictionary = GameData.loot_tables
	var by_monster: Dictionary = tables.get("by_monster", {})
	return by_monster.get(monster_id, "default")


## Tire une rareté selon les poids de items.json, avec un minimum optionnel.
static func roll_rarity(min_rarity: String = "common") -> String:
	var min_idx := RARITY_ORDER.find(min_rarity)
	var candidates: Array = []
	var total := 0.0
	for r in RARITY_ORDER:
		if RARITY_ORDER.find(r) >= min_idx and GameData.rarities.has(r):
			candidates.append(r)
			total += float(GameData.rarities[r].get("weight", 1))
	var x := CombatResolver.rng.randf() * total
	for r in candidates:
		x -= float(GameData.rarities[r].get("weight", 1))
		if x <= 0.0:
			return r
	return candidates[-1] if not candidates.is_empty() else "common"


static func items_of_type(type: String) -> Array[String]:
	var out: Array[String] = []
	for id in GameData.items:
		if GameData.items[id].get("type", "") == type:
			out.append(id)
	return out


## Renvoie une liste d'entrées {id, qty, rarity} pour une table donnée.
static func roll(table_name: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var table: Dictionary = GameData.loot_tables.get(table_name, GameData.loot_tables.get("default", {}))
	if table.is_empty():
		return out
	var gold := Dice.roll_expr(table.get("gold", "1d4"), CombatResolver.rng)
	if gold > 0:
		out.append({"id": "gold", "qty": gold, "rarity": "common"})
	for d in table.get("drops", []):
		if CombatResolver.rng.randf() > float(d.get("chance", 0.0)):
			continue
		var id := ""
		if d.has("item"):
			id = d["item"]
		elif d.has("pool"):
			var pool := items_of_type(d["pool"])
			if pool.is_empty():
				continue
			id = pool[CombatResolver.rng.randi_range(0, pool.size() - 1)]
		if id == "":
			continue
		var qty := 1
		if d.has("qty"):
			qty = Dice.roll_expr(str(d["qty"]), CombatResolver.rng)
		var data := GameData.item(id)
		var rarity := "common"
		if data.get("type", "") in ["weapon", "armor", "shield"]:
			rarity = roll_rarity(d.get("min_rarity", "common"))
		out.append({"id": id, "qty": qty, "rarity": rarity})
	return out


## Fait apparaître les objets au sol autour d'une position (hôte).
static func drop_at(game: Node, pos: Vector3, entries: Array[Dictionary]) -> void:
	var i := 0
	for e in entries:
		var angle := TAU * i / maxf(1.0, entries.size()) + CombatResolver.rng.randf() * 0.5
		var offset := Vector3(cos(angle), 0, sin(angle)) * (0.0 if entries.size() == 1 else 0.7)
		game.spawn_loot({"entry": e, "position": pos + offset + Vector3(0, 0.1, 0)})
		i += 1


static func drop_for_monster(game: Node, monster_id: String, pos: Vector3) -> void:
	drop_at(game, pos, roll(table_for_monster(monster_id)))

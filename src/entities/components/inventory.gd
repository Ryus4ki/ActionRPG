class_name Inventory
extends Node
## Inventaire et équipement d'un joueur. Vérité côté hôte ; répliqué (setters → `changed`).
##
## Un objet d'inventaire = {"id": "longsword", "rarity": "common", "qty": 1}
## Équipement = {"weapon": item, "armor": item, "shield": item}

signal changed

const MAX_SLOTS := 20

var gold := 0:
	set(v):
		gold = v
		changed.emit()
var items: Array = []:
	set(v):
		items = v
		changed.emit()
var equipped: Dictionary = {}:
	set(v):
		equipped = v
		changed.emit()


# ------------------------------------------------------------ requêtes

static func item_data(entry: Dictionary) -> Dictionary:
	return GameData.item(entry.get("id", ""))


static func magic_bonus(entry: Dictionary) -> int:
	return int(GameData.rarities.get(entry.get("rarity", "common"), {}).get("magic_bonus", 0))


static func display_name(entry: Dictionary) -> String:
	var data := item_data(entry)
	var name: String = data.get("name", entry.get("id", "?"))
	var bonus := magic_bonus(entry)
	if bonus > 0 and data.get("type", "") in ["weapon", "armor", "shield"]:
		name += " +%d" % bonus
	return name


static func rarity_color(entry: Dictionary) -> Color:
	return Color(GameData.rarities.get(entry.get("rarity", "common"), {}).get("color", "#ffffff"))


func count(item_id: String) -> int:
	var n := 0
	for e in items:
		if e.id == item_id:
			n += int(e.get("qty", 1))
	return n


func find_index(item_id: String) -> int:
	for i in items.size():
		if items[i].id == item_id:
			return i
	return -1


func is_full() -> bool:
	return items.size() >= MAX_SLOTS


# ------------------------------------------------------------ mutations (hôte)

## Ajoute un objet ; les consommables s'empilent. Renvoie faux si plein.
func add(entry: Dictionary) -> bool:
	var data := item_data(entry)
	if data.is_empty():
		return false
	if data.get("type", "") == "currency":
		gold += int(entry.get("qty", 1))
		return true
	var list := items.duplicate(true)
	if data.get("stackable", false):
		for e in list:
			if e.id == entry.id:
				e.qty = mini(int(e.get("qty", 1)) + int(entry.get("qty", 1)), int(data.get("max_stack", 99)))
				items = list
				return true
	if list.size() >= MAX_SLOTS:
		return false
	var copy := entry.duplicate()
	copy["qty"] = int(entry.get("qty", 1))
	copy["rarity"] = entry.get("rarity", "common")
	list.append(copy)
	items = list
	return true


func remove_at(index: int, qty: int = 1) -> Dictionary:
	if index < 0 or index >= items.size():
		return {}
	var list := items.duplicate(true)
	var e: Dictionary = list[index]
	var removed := e.duplicate()
	removed["qty"] = qty
	e.qty = int(e.get("qty", 1)) - qty
	if e.qty <= 0:
		list.remove_at(index)
	items = list
	return removed


## Équipe l'objet d'inventaire à l'index donné (l'ancien équipement revient dans le sac).
func equip(index: int) -> bool:
	if index < 0 or index >= items.size():
		return false
	var entry: Dictionary = items[index]
	var data := item_data(entry)
	var slot: String = data.get("type", "")
	if slot not in ["weapon", "armor", "shield"]:
		return false
	var list := items.duplicate(true)
	list.remove_at(index)
	var eq := equipped.duplicate(true)
	if eq.has(slot):
		list.append(eq[slot])
	# Une arme à deux mains retire le bouclier (et inversement).
	if slot == "weapon" and int(data.get("hands", 1)) == 2 and eq.has("shield"):
		list.append(eq["shield"])
		eq.erase("shield")
	if slot == "shield" and eq.has("weapon") and int(item_data(eq["weapon"]).get("hands", 1)) == 2:
		list.append(eq["weapon"])
		eq.erase("weapon")
	eq[slot] = entry.duplicate()
	eq[slot]["qty"] = 1
	equipped = eq
	items = list
	return true


func unequip(slot: String) -> bool:
	if not equipped.has(slot) or is_full():
		return false
	var eq := equipped.duplicate(true)
	var entry: Dictionary = eq[slot]
	eq.erase(slot)
	var list := items.duplicate(true)
	list.append(entry)
	equipped = eq
	items = list
	return true

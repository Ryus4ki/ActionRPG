class_name QuestLog
extends Node
## Journal de quêtes du joueur (répliqué) : id -> {state: "active"|"done", progress: int}.
## Données : data/quests/quests.json. L'hôte fait avancer les quêtes (kills, collecte) et remet les récompenses.

signal changed

var quests: Dictionary = {}:
	set(v):
		quests = v
		changed.emit()


static func quest_data(id: String) -> Dictionary:
	return GameData.quests.get(id, {})


func state_of(id: String) -> String:
	return str(quests.get(id, {}).get("state", ""))


func progress_of(id: String) -> int:
	return int(quests.get(id, {}).get("progress", 0))


func is_active(id: String) -> bool:
	return state_of(id) == "active"


func is_done(id: String) -> bool:
	return state_of(id) == "done"


## Peut-on accepter cette quête ? (pas déjà prise, prérequis remplis)
func can_accept(id: String) -> bool:
	var q := quest_data(id)
	if q.is_empty() or quests.has(id):
		return false
	for req in q.get("requires", []):
		if not is_done(str(req)):
			return false
	return true


func accept(id: String) -> bool:
	if not can_accept(id):
		return false
	var qs := quests.duplicate(true)
	qs[id] = {"state": "active", "progress": 0}
	quests = qs
	return true


## Objectif atteint ? (kill : compteur ; collect : objets dans le sac)
func is_complete(id: String, inventory: Inventory) -> bool:
	if not is_active(id):
		return false
	var obj: Dictionary = quest_data(id).get("objective", {})
	match obj.get("type", ""):
		"kill":
			return progress_of(id) >= int(obj.get("count", 1))
		"collect":
			return inventory != null and inventory.count(str(obj.get("item", ""))) >= int(obj.get("count", 1))
		"talk":
			return true
	return false


## Hôte : un monstre tué par ce joueur (ou son groupe).
func on_kill(monster_id: String) -> Array[String]:
	var advanced: Array[String] = []
	var qs := quests.duplicate(true)
	for id in qs:
		if qs[id].get("state", "") != "active":
			continue
		var obj: Dictionary = quest_data(id).get("objective", {})
		if obj.get("type", "") == "kill" and obj.get("monster", "") == monster_id and int(qs[id].progress) < int(obj.get("count", 1)):
			qs[id].progress = int(qs[id].progress) + 1
			advanced.append(id)
	if not advanced.is_empty():
		quests = qs
	return advanced


## Hôte : rend la quête (retire les objets collectés), marque « done ». Les récompenses sont données par le joueur.
func turn_in(id: String, inventory: Inventory) -> bool:
	if not is_complete(id, inventory):
		return false
	var obj: Dictionary = quest_data(id).get("objective", {})
	if obj.get("type", "") == "collect" and inventory:
		var idx := inventory.find_index(str(obj.get("item", "")))
		var left := int(obj.get("count", 1))
		while idx >= 0 and left > 0:
			var qty := int(inventory.items[idx].get("qty", 1))
			var take := mini(qty, left)
			inventory.remove_at(idx, take)
			left -= take
			idx = inventory.find_index(str(obj.get("item", "")))
	var qs := quests.duplicate(true)
	qs[id] = {"state": "done", "progress": progress_of(id)}
	quests = qs
	return true

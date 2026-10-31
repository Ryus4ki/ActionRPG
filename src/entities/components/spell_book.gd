class_name SpellBook
extends Node
## Sorts connus, emplacements de sorts et sélection courante d'un lanceur (SRD 5e simplifié).
## `slots` et `selected` sont répliqués ; les setters réémettent `changed` côté client pour le HUD.

signal changed

var casting_ability := "int"
## Sorts connus à ce niveau, dans l'ordre d'affichage (tours de magie d'abord).
var known: Array[String] = []:
	set(v):
		known = v
		changed.emit()
## Emplacements restants par niveau de sort : {"1": 2, "2": 0}
var slots: Dictionary = {}:
	set(v):
		slots = v
		changed.emit()
var max_slots: Dictionary = {}:
	set(v):
		max_slots = v
		changed.emit()
var selected := 0:
	set(v):
		selected = v
		changed.emit()

var _cooldown_until: Dictionary = {}  # spell_id -> temps (s)


func setup(class_data: Dictionary, level: int) -> void:
	casting_ability = class_data.get("spellcasting_ability", "int")
	refresh_for_level(class_data, level, true)


## Met à jour la liste des sorts et les emplacements pour un niveau donné.
## `refill` : remet tous les emplacements au maximum (montée de niveau, repos).
func refresh_for_level(class_data: Dictionary, level: int, refill: bool) -> void:
	var list: Array[String] = []
	for c in class_data.get("cantrips_known", []):
		list.append(c)
	var by_level: Dictionary = class_data.get("spells_by_level", {})
	for lvl in range(1, level + 1):
		for s in by_level.get(str(lvl), []):
			if s not in list:
				list.append(s)
	known = list
	var table: Dictionary = class_data.get("spell_slots_by_level", {})
	var best := {}
	for lvl in range(1, level + 1):
		if table.has(str(lvl)):
			best = table[str(lvl)]
	var clean := {}
	for k in best:
		clean[str(k)] = int(best[k])
	max_slots = clean.duplicate()
	if refill or slots.is_empty():
		slots = clean.duplicate()
	else:
		# Conserve les emplacements restants, plafonnés au nouveau maximum.
		var s := slots.duplicate()
		for k in clean:
			s[k] = mini(int(s.get(k, 0)), int(clean[k]))
		slots = s
	if selected >= known.size():
		selected = 0


func is_caster() -> bool:
	return not known.is_empty()


func selected_spell_id() -> String:
	return known[selected] if selected >= 0 and selected < known.size() else ""


func selected_spell() -> Dictionary:
	return GameData.spell(selected_spell_id())


func select(index: int) -> void:
	if known.is_empty():
		return
	selected = posmod(index, known.size())


func select_next(delta: int) -> void:
	select(selected + delta)


## Niveau d'emplacement utilisable pour ce sort (le plus bas disponible), ou -1.
## Les tours de magie (niveau 0) renvoient 0.
func slot_level_for(spell: Dictionary) -> int:
	var lvl: int = spell.get("level", 0)
	if lvl == 0:
		return 0
	var keys := slots.keys()
	keys.sort()
	for k in keys:
		if int(k) >= lvl and int(slots[k]) > 0:
			return int(k)
	return -1


func on_cooldown(spell_id: String) -> bool:
	return GameData.now() < float(_cooldown_until.get(spell_id, 0.0))


func can_cast(spell_id: String) -> bool:
	var spell := GameData.spell(spell_id)
	if spell.is_empty() or spell_id not in known or on_cooldown(spell_id):
		return false
	return slot_level_for(spell) >= 0


## Consomme l'emplacement et démarre le temps de recharge. Renvoie le niveau d'emplacement utilisé.
func consume(spell_id: String) -> int:
	var spell := GameData.spell(spell_id)
	var lvl := slot_level_for(spell)
	if lvl > 0:
		var s := slots.duplicate()
		s[str(lvl)] = int(s[str(lvl)]) - 1
		slots = s
	_cooldown_until[spell_id] = GameData.now() + float(spell.get("cooldown", 1.0))
	return lvl


func restore_all() -> void:
	slots = max_slots.duplicate()
	_cooldown_until.clear()

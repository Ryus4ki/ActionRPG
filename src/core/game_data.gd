extends Node
## Autoload « GameData » : charge toutes les tables JSON de res://data/ au démarrage.
## Accès : GameData.classes["fighter"], GameData.spells["fireball"], GameData.monster("goblin")…
## Les données sont identiques sur l'hôte et le client (fichiers embarqués) : pas de réplication nécessaire.

var classes: Dictionary = {}
var races: Dictionary = {}
var spells: Dictionary = {}
var monsters: Dictionary = {}
var items: Dictionary = {}
var rarities: Dictionary = {}
var loot_tables: Dictionary = {}
var weapon_skills: Dictionary = {}
var balance: Dictionary = {}
var quests: Dictionary = {}


func _ready() -> void:
	load_all()


func load_all() -> void:
	classes = _load_dir("res://data/classes")
	races = _load_dir("res://data/races")
	spells = _load_file("res://data/spells/spells.json")
	monsters = _load_file("res://data/monsters/monsters.json")
	items = _load_file("res://data/items/items.json")
	rarities = items.get("_rarity_table", {})
	items.erase("_rarity_table")
	loot_tables = _load_file("res://data/items/loot_tables.json")
	loot_tables.erase("_comment")
	weapon_skills = _load_file("res://data/combat/weapon_skills.json")
	weapon_skills.erase("_comment")
	balance = _load_file("res://data/combat/balance.json")
	balance.erase("_comment")
	quests = _load_file("res://data/quests/quests.json")
	quests.erase("_comment")


## Charge chaque .json d'un dossier ; la clé est le champ "id" (ou le nom du fichier).
func _load_dir(path: String) -> Dictionary:
	var result := {}
	var dir := DirAccess.open(path)
	if dir == null:
		push_error("Dossier introuvable : " + path)
		return result
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var data := _load_file(path.path_join(f))
		var id: String = data.get("id", f.get_basename())
		result[id] = data
	return result


func _load_file(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("Fichier vide ou introuvable : " + path)
		return {}
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		push_error("JSON invalide : " + path)
		return {}
	return parsed


# --- Accès pratiques ---

func player_class(id: String) -> Dictionary:
	return classes.get(id, {})


func race(id: String) -> Dictionary:
	return races.get(id, {})


func spell(id: String) -> Dictionary:
	return spells.get(id, {})


func monster(id: String) -> Dictionary:
	return monsters.get(id, {})


func item(id: String) -> Dictionary:
	return items.get(id, {})


## Vérifie les références croisées (appelé par les tests, utile aussi en debug).
## Renvoie la liste des erreurs trouvées (vide = OK).
func validate() -> Array[String]:
	var errors: Array[String] = []
	for cid in classes:
		var c: Dictionary = classes[cid]
		for item_id in c.get("starting_equipment", []):
			if not items.has(item_id):
				errors.append("Classe %s : objet inconnu '%s'" % [cid, item_id])
		for sid in c.get("cantrips_known", []):
			if not spells.has(sid):
				errors.append("Classe %s : sort inconnu '%s'" % [cid, sid])
		for lvl in c.get("spells_by_level", {}):
			for sid in c["spells_by_level"][lvl]:
				if not spells.has(sid):
					errors.append("Classe %s niv %s : sort inconnu '%s'" % [cid, lvl, sid])
		for lvl in c.get("features_by_level", {}):
			for fid in c["features_by_level"][lvl]:
				if not c.get("features", {}).has(fid):
					errors.append("Classe %s niv %s : capacité non définie '%s'" % [cid, lvl, fid])
	for mid in monsters:
		var m: Dictionary = monsters[mid]
		for phase in m.get("phases", []):
			var summon: Dictionary = phase.get("summon", {})
			if summon and not monsters.has(summon.get("monster", "")):
				errors.append("Monstre %s : invocation inconnue '%s'" % [mid, summon.get("monster")])
		for atk in m.get("attacks", []):
			if atk.has("damage") and Dice.parse(atk["damage"]).sides == 0:
				errors.append("Monstre %s : dés invalides '%s'" % [mid, atk["damage"]])
	for sid in spells:
		var s: Dictionary = spells[sid]
		if s.has("damage") and Dice.parse(s["damage"]).sides == 0:
			errors.append("Sort %s : dés invalides '%s'" % [sid, s["damage"]])
	return errors


func weapon_skill(id: String) -> Dictionary:
	return weapon_skills.get(id, {})


## Réglage d'équilibrage global (data/combat/balance.json), avec valeur par défaut.
func bal(key: String, default_value: float = 1.0) -> float:
	return float(balance.get(key, default_value))


## Horloge de jeu (s) : suit Engine.time_scale (banc d'équilibrage accéléré) ; = temps réel en jeu normal.
## L'échelle doit rester constante pendant une partie (elle multiplie le temps écoulé depuis le lancement).
func now() -> float:
	return Time.get_ticks_msec() / 1000.0 * Engine.time_scale

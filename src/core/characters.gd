extends Node
## Autoload « Characters » : personnages façon MMO et coffre partagé, sauvegardés sur CE PC.
##   user://characters/<id>.json   un fichier par personnage (identité, zone, position, état complet)
##   user://shared_chest.json      coffre commun à tous les personnages du PC (objets + or)
## Sur Windows : %APPDATA%\Godot\app_userdata\ActionRPG\.
##
## En réseau, chacun garde ses personnages chez lui : le client envoie son personnage à l'hôte en
## rejoignant, l'hôte simule, puis renvoie régulièrement l'état à jour au propriétaire qui l'écrit.

signal list_changed
signal chest_changed

const DIR := "user://characters/"
const CHEST_PATH := "user://shared_chest.json"
const CHEST_SLOTS := 60
const NAME_MAX := 16

var current: Dictionary = {}   # personnage choisi au menu principal ({} = aucun : mode test / ancien flux)
var base_dir := DIR            # les tests utilisent un autre dossier
var chest_path := CHEST_PATH
var _chest: Dictionary = {}
var _chest_loaded := false


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)


## Fermeture de la fenêtre : on sauvegarde la partie en cours avant de quitter.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()


func quit_game() -> void:
	var game := get_tree().get_first_node_in_group("game")
	if game and game.has_method("save_party_now"):
		await game.save_party_now()
	SessionLog.finish()
	get_tree().quit()


# ------------------------------------------------------------------ personnages

func has_current() -> bool:
	return not current.is_empty()


func list() -> Array:
	var out: Array = []
	DirAccess.make_dir_recursive_absolute(base_dir)
	var dir := DirAccess.open(base_dir)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json"):
			var ch := _read_json(base_dir + f)
			if not ch.is_empty() and ch.has("id"):
				out.append(ch)
	out.sort_custom(func(a, b): return int(a.get("last_played", 0)) > int(b.get("last_played", 0)))
	return out


func find(id: String) -> Dictionary:
	return _read_json(base_dir + id + ".json")


## Crée un personnage niveau 1. Renvoie {} et un message d'erreur via `error` si le nom est pris / vide.
var error := ""
func create(char_name: String, class_id: String, race_id: String) -> Dictionary:
	error = ""
	char_name = char_name.strip_edges().substr(0, NAME_MAX)
	if char_name.is_empty():
		error = "Choisis un nom."
		return {}
	for ch in list():
		if str(ch.get("name", "")).to_lower() == char_name.to_lower():
			error = "Ce nom est déjà pris par un de tes personnages."
			return {}
	var id := _slug(char_name)
	var n := 2
	while FileAccess.file_exists(base_dir + id + ".json"):
		id = "%s_%d" % [_slug(char_name), n]
		n += 1
	var now := int(Time.get_unix_time_from_system())
	var ch := {
		"id": id, "name": char_name, "class_id": class_id, "race_id": race_id,
		"created": now, "last_played": now, "play_time": 0,
		"level": 1, "zone": "res://scenes/outdoor_village.tscn", "spawn_id": "default",
		"state": {}, "progress": [],
	}
	_write(ch)
	list_changed.emit()
	return ch


func delete(id: String) -> void:
	var path := base_dir + id + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if current.get("id", "") == id:
		current = {}
	list_changed.emit()


func select(id: String) -> bool:
	var ch := find(id)
	if ch.is_empty():
		return false
	current = ch
	return true


## Écrit l'état reçu de l'hôte dans le personnage courant (zone, position, niveau, sac, quêtes, progression…).
func save_current(state: Dictionary, zone: String, spawn_id: String) -> void:
	if current.is_empty():
		return
	var st := state.duplicate(true)
	current["state"] = st
	current["level"] = int(st.get("level", current.get("level", 1)))
	current["progress"] = st.get("progress", current.get("progress", []))
	if zone != "":
		current["zone"] = zone
		current["spawn_id"] = spawn_id
	var now := int(Time.get_unix_time_from_system())
	current["play_time"] = int(current.get("play_time", 0)) + clampi(now - int(current.get("last_played", now)), 0, 600)
	current["last_played"] = now
	_write(current)


## Résumé d'une ligne pour la liste du menu.
static func summary(ch: Dictionary) -> String:
	var st: Dictionary = ch.get("state", {})
	var job: String = str(st.get("job", ch.get("class_id", "")))
	var cls: String = GameData.classes.get(job, {}).get("name", job)
	var others: Array[String] = []
	for jid in st.get("jobs", {}):
		if jid != job:
			others.append("%s %d" % [GameData.classes.get(jid, {}).get("name", jid), int(st.jobs[jid].get("level", 1))])
	var extra := (" · " + ", ".join(others)) if not others.is_empty() else ""
	var race: String = GameData.races.get(ch.get("race_id", ""), {}).get("name", ch.get("race_id", "?"))
	var zone: String = Net.LEVELS.get(ch.get("zone", ""), "?")
	var hours := int(ch.get("play_time", 0)) / 3600
	var minutes := (int(ch.get("play_time", 0)) % 3600) / 60
	return "%s — %s %s niv. %d%s — %s  (%dh%02d)" % [ch.get("name", "?"), race, cls, int(ch.get("level", 1)), extra, zone, hours, minutes]


func _write(ch: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(base_dir)
	var f := FileAccess.open(base_dir + str(ch.id) + ".json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(ch, "\t"))


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return _intify(data) if data is Dictionary else {}


## JSON ne connaît que des flottants : on remet en entiers les nombres ronds (quantités, niveaux, emplacements…).
static func _intify(v: Variant) -> Variant:
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1e15:
		return int(v)
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _intify(v[k])
		return d
	if v is Array:
		var a := []
		for x in v:
			a.append(_intify(x))
		return a
	return v


static func _slug(s: String) -> String:
	var out := ""
	for c in s.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif c in "àâä":
			out += "a"
		elif c in "éèêë":
			out += "e"
		elif c in "îï":
			out += "i"
		elif c in "ôö":
			out += "o"
		elif c in "ùûü":
			out += "u"
		elif c == "ç":
			out += "c"
		else:
			out += "_"
	return out if out.strip_edges() != "" else "perso"


# ------------------------------------------------------------------ coffre partagé (local à ce PC)

func chest() -> Dictionary:
	if not _chest_loaded:
		_chest = _read_json(chest_path)
		if not _chest.has("items"):
			_chest = {"items": [], "gold": 0}
		_chest_loaded = true
	return _chest


func chest_add(entry: Dictionary) -> void:
	var c := chest()
	var data := Inventory.item_data(entry)
	if data.get("type", "") == "currency":
		c.gold = int(c.get("gold", 0)) + int(entry.get("qty", 1))
	else:
		var merged := false
		if data.get("stackable", false):
			for e in c.items:
				if e.get("id") == entry.get("id") and e.get("rarity", "common") == entry.get("rarity", "common"):
					e["qty"] = int(e.get("qty", 1)) + int(entry.get("qty", 1))
					merged = true
					break
		if not merged:
			c.items.append(entry.duplicate(true))
	_save_chest()


## Retire l'objet `index` du coffre et le renvoie ({} si invalide).
func chest_take(index: int) -> Dictionary:
	var c := chest()
	if index < 0 or index >= c.items.size():
		return {}
	var entry: Dictionary = c.items[index]
	c.items.remove_at(index)
	_save_chest()
	return entry


func chest_add_gold(amount: int) -> void:
	var c := chest()
	c.gold = maxi(0, int(c.get("gold", 0)) + amount)
	_save_chest()


func chest_is_full() -> bool:
	return chest().items.size() >= CHEST_SLOTS


func _save_chest() -> void:
	var f := FileAccess.open(chest_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_chest, "\t"))
	chest_changed.emit()


## Tests : repartir d'un coffre / dossier vierges.
func use_test_storage(suffix := "") -> void:
	base_dir = "user://test_characters%s/" % suffix
	chest_path = "user://test_shared_chest%s.json" % suffix
	_chest_loaded = false
	current = {}
	DirAccess.make_dir_recursive_absolute(base_dir)
	var d := DirAccess.open(base_dir)
	if d:
		for f in d.get_files():
			d.remove(f)
	if FileAccess.file_exists(chest_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(chest_path))

class_name RunePuzzle
extends Node3D
## Énigme : des runes murales à activer dans le bon ordre (indiqué par une devinette sur une plaque).
## Résolue → désamorce tous les pièges de la zone `zone`. Mauvais ordre → tout s'éteint.
## `progress` (nombre de runes justes enchaînées) et `solved` sont répliqués.

signal solved_changed

const RUNE_SCENE := preload("res://scenes/rune.tscn")

@export var puzzle_id := "runes"
@export var zone := ""
@export var riddle := ""
@export var rune_names: Array[String] = []     # ex. ["Lune", "Soleil", "Étoile"]
@export var order: Array[int] = []             # indices des runes dans l'ordre attendu
## Position / orientation de chaque rune et de la plaque, remplies par le donjon avant add_child.
var rune_transforms: Array[Transform3D] = []
var plaque_transform := Transform3D.IDENTITY

var progress := 0:
	set(v):
		progress = v
		_refresh()
var solved := false:
	set(v):
		var was := solved
		solved = v
		_refresh()
		if v and not was:
			solved_changed.emit()

var _runes: Array[Node3D] = []


func _ready() -> void:
	add_to_group("puzzles")
	for i in rune_names.size():
		var rune: Node3D = RUNE_SCENE.instantiate()
		rune.name = "Rune_%d" % i
		rune.rune_index = i
		rune.rune_name = rune_names[i]
		rune.puzzle = self
		if i < rune_transforms.size():
			rune.transform = rune_transforms[i]
		add_child(rune)
		_runes.append(rune)
	var plaque := Label3D.new()
	plaque.name = "Plaque"
	plaque.text = "« %s »" % riddle
	plaque.font_size = 30
	plaque.outline_size = 8
	plaque.pixel_size = 0.004
	plaque.modulate = Color(0.85, 0.8, 0.65)
	plaque.width = 420
	plaque.autowrap_mode = TextServer.AUTOWRAP_WORD
	plaque.transform = plaque_transform
	add_child(plaque)
	_refresh()


## Hôte : un joueur active la rune `index`.
func press(index: int, by: Node) -> bool:
	if solved or not multiplayer.is_server():
		return false
	var game := get_tree().get_first_node_in_group("game")
	if progress < order.size() and order[progress] == index:
		progress += 1
		if progress >= order.size():
			solved = true
			var n := 0
			for t in get_tree().get_nodes_in_group("traps"):
				if t is Trap and t.zone == zone:
					t.disarm()
					n += 1
			if game:
				game.system_message("Les runes s'embrasent : %d piège(s) désamorcé(s) dans la zone." % n)
		elif game:
			game.system_message("La rune %s s'allume (%d/%d)." % [rune_names[index], progress, order.size()])
	else:
		progress = 0
		if game:
			game.system_message("Mauvais ordre : les runes s'éteignent. (%s)" % (by.player_name if by is PlayerCharacter else ""))
	return true


## Vrai si la rune `index` doit être allumée (fait partie des `progress` premières de l'ordre).
func is_lit(index: int) -> bool:
	if solved:
		return true
	for k in progress:
		if order[k] == index:
			return true
	return false


func _refresh() -> void:
	for r in _runes:
		if r.has_method("refresh"):
			r.refresh()

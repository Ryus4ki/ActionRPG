class_name Campfire
extends StaticBody3D
## Feu de camp : E pour se reposer (hôte). Tous les joueurs à moins de 8 m retrouvent leurs PV et
## leurs emplacements de sorts ; le point de réapparition est déplacé ici. Réutilisable après un
## temps de recharge (`cooldown`), pendant lequel le feu n'est que braises.

const REST_RANGE := 8.0

@export var cooldown := 30.0

@export var label_text := "Feu de camp"

## Vrai pendant la recharge (répliqué).
var used := false:
	set(v):
		used = v
		_refresh()

@onready var label: Label3D = $Label
@onready var light: OmniLight3D = $Light
@onready var flame: MeshInstance3D = $Flame

var _flicker := 0.0


func _ready() -> void:
	add_to_group("campfires")
	add_to_group("interactables")
	_refresh()


func _process(delta: float) -> void:
	_flicker += delta * 9.0
	light.light_energy = (0.5 if used else 1.6) + sin(_flicker) * 0.12 + sin(_flicker * 2.7) * 0.08


func interact(by: Node) -> bool:
	if used or not multiplayer.is_server():
		return false
	used = true
	var game := get_tree().get_first_node_in_group("game")
	for p in get_tree().get_nodes_in_group("players"):
		if p is PlayerCharacter and p.global_position.distance_to(global_position) <= REST_RANGE:
			if p.health.is_downed:
				p.health.revive(1.0)
			p.health.heal(p.health.max_hp)
			if p.spell_book:
				p.spell_book.restore_all()
	if game:
		game.set_checkpoint(global_position + Vector3(0, 0.1, 2.0))
		game.system_message("Le groupe se repose au feu de camp : PV et sorts restaurés. Point de réapparition enregistré.")
	get_tree().create_timer(cooldown).timeout.connect(func():
		if is_instance_valid(self):
			used = false)
	return true


func _refresh() -> void:
	if not is_node_ready():
		return
	label.text = "%s  (F) — se reposer" % label_text if not used else "%s — braises (le feu reprend)" % label_text
	label.modulate = Color(1, 0.75, 0.4) if not used else Color(0.6, 0.55, 0.5)
	flame.visible = not used

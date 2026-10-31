class_name Lever
extends StaticBody3D
## Levier mural : E pour l'actionner (hôte), `pulled` répliqué. Le donjon écoute `pulled_changed`.

signal pulled_changed

@export var lever_id := "lever"
@export var label_text := "Levier"

var pulled := false:
	set(v):
		var was := pulled
		pulled = v
		_refresh()
		if v and not was:
			pulled_changed.emit()

@onready var label: Label3D = $Label
@onready var handle: MeshInstance3D = $Handle


func _ready() -> void:
	add_to_group("levers")
	add_to_group("interactables")
	_refresh()


func interact(_by: Node) -> bool:
	if pulled or not multiplayer.is_server():
		return false
	pulled = true
	var game := get_tree().get_first_node_in_group("game")
	if game:
		game.system_message("%s actionné." % label_text)
	return true


func _refresh() -> void:
	if not is_node_ready():
		return
	label.text = "%s  (F)" % label_text if not pulled else "%s — actionné" % label_text
	label.modulate = Color(1, 0.9, 0.6) if not pulled else Color(0.6, 0.9, 0.6)
	handle.rotation_degrees.x = 40.0 if pulled else -40.0

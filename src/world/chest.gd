class_name Chest
extends StaticBody3D
## Coffre à ouvrir avec E (joueur à moins de 2,5 m). Butin de la table "chest". `opened` est répliqué.

@export var loot_table := "chest"

var opened := false:
	set(v):
		var was := opened
		opened = v
		if v and not was:
			_show_opened()

@onready var label: Label3D = $Label
@onready var model_root: Node3D = $ModelRoot


func _ready() -> void:
	add_to_group("chests")
	var scene: PackedScene = load("res://assets/models/sm_chest.glb")
	if scene:
		model_root.add_child(scene.instantiate())
	if opened:
		_show_opened()


## Hôte uniquement.
func open(by: Node) -> void:
	if opened or not multiplayer.is_server():
		return
	opened = true
	var game := get_tree().get_first_node_in_group("game")
	if game:
		Loot.drop_at(game, global_position + global_transform.basis.z * 1.2, Loot.roll(loot_table))


func _show_opened() -> void:
	if label:
		label.visible = false
	if model_root:
		# Placeholder : le couvercle "s'ouvre" en basculant le modèle entier légèrement en arrière.
		model_root.rotation_degrees.x = -25
		for mi in model_root.find_children("*", "MeshInstance3D", true, false):
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.35, 0.25, 0.15)
			mi.material_override = mat

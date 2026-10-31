class_name Npc
extends StaticBody3D
## Personnage non joueur (marchand, donneur de quêtes). E pour parler : l'hôte ouvre le dialogue
## sur la machine du joueur (données du PNJ lues dans le plan de la zone, identiques partout).

@export var npc_id := "npc"
@export var npc_name := "Villageois"
@export var role := "talk"     # "merchant" | "quest" | "talk"
@export var tint := Color(0.7, 0.6, 0.5)
@export var model_name := "sk_humanoid"

@onready var label: Label3D = $Label
@onready var model_root: Node3D = $ModelRoot


func _ready() -> void:
	add_to_group("npcs")
	add_to_group("interactables")
	label.text = "%s  (F)" % npc_name
	label.modulate = {"merchant": Color(1.0, 0.85, 0.4), "quest": Color(0.6, 1.0, 0.6)}.get(role, Color(0.9, 0.9, 0.9))
	var scene: PackedScene = load("res://assets/models/%s.glb" % model_name)
	if scene:
		var m: Node3D = scene.instantiate()
		m.rotation_degrees.y = 180.0
		model_root.add_child(m)
		for mi in m.find_children("*", "MeshInstance3D", true, false):
			var mesh_inst: MeshInstance3D = mi
			for i in mesh_inst.get_surface_override_material_count():
				var base := mesh_inst.mesh.surface_get_material(i)
				if base is BaseMaterial3D:
					var mat: BaseMaterial3D = base.duplicate()
					mat.albedo_color = mat.albedo_color.lerp(tint, 0.55)
					mesh_inst.set_surface_override_material(i, mat)
		var anim := m.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if anim and anim.has_animation("idle"):
			anim.get_animation("idle").loop_mode = Animation.LOOP_LINEAR
			anim.play("idle")


func interact(by: Node) -> bool:
	if not multiplayer.is_server() or not (by is PlayerCharacter):
		return false
	# Le PNJ se tourne vers le joueur, puis le dialogue s'ouvre chez lui.
	var to: Vector3 = by.global_position - global_position
	to.y = 0.0
	if to.length_squared() > 0.001:
		rotation.y = atan2(-to.x, -to.z)
	by.open_npc(npc_id)
	return true

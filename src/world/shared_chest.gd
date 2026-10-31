class_name SharedChest
extends StaticBody3D
## Coffre partagé : commun à tous les personnages de ton PC (contenu dans user://shared_chest.json).
## F / Rond à côté : l'hôte ouvre la fenêtre du coffre chez le joueur qui l'utilise. Construit en code.


func _ready() -> void:
	add_to_group("shared_chests")
	add_to_group("interactables")
	collision_layer = 1
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 0.8, 0.75)
	shape.shape = box
	shape.position.y = 0.4
	add_child(shape)
	var scene: PackedScene = load("res://assets/models/sm_chest.glb")
	if scene:
		var m: Node3D = scene.instantiate()
		m.scale = Vector3.ONE * 1.25
		add_child(m)
		# Teinte bleutée pour le distinguer des coffres à butin.
		for mi in m.find_children("*", "MeshInstance3D", true, false):
			var mesh_inst: MeshInstance3D = mi
			for i in mesh_inst.mesh.get_surface_count():
				var base := mesh_inst.mesh.surface_get_material(i)
				if base is BaseMaterial3D:
					var mat: BaseMaterial3D = base.duplicate()
					mat.albedo_color = mat.albedo_color.lerp(Color(0.35, 0.5, 0.9), 0.45)
					mesh_inst.set_surface_override_material(i, mat)
	var label := Label3D.new()
	label.text = "Coffre partagé  (F)"
	label.position.y = 1.35
	label.pixel_size = 0.004
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(0.7, 0.85, 1.0)
	label.font_size = 40
	label.outline_size = 10
	add_child(label)


## Hôte uniquement (appelé par PlayerCharacter.try_interact).
func interact(by: Node) -> bool:
	if not multiplayer.is_server() or not (by is PlayerCharacter):
		return false
	(by as PlayerCharacter).open_shared_chest()
	return true

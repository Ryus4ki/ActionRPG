extends SceneTree
## Outil : calcule les transformations d'attache (bouclier en garde, épée au repos).
func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var model: Node3D = load("res://assets/models/sk_humanoid.glb").instantiate()
	root.add_child(model)
	var anim: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	var skel: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	# Repère modèle : le personnage regarde vers +Z (avant rotation de 180° dans Creature).
	for setup in [["block", 1.0 / 30.0, "forearm.L", Basis.from_euler(Vector3(0, PI, 0)), "bouclier"],
				  ["idle", 0.0, "hand.R", Basis.from_euler(Vector3(deg_to_rad(60), 0, 0)), "épée"]]:
		anim.stop(true)
		skel.reset_bone_poses()
		anim.play(setup[0])
		anim.seek(setup[1], true)
		await process_frame
		await process_frame
		var idx := skel.find_bone(setup[2])
		var B: Transform3D = skel.get_bone_global_pose(idx)
		var A: Basis = B.basis.inverse() * setup[3]
		var e := A.get_euler()
		print("%s sur %s : pos os=%s  euler(deg)=%s" % [setup[4], setup[2], B.origin, Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))])
		# vérification : normale/lame résultante en espace modèle
		var check: Vector3 = B.basis * A * (Vector3(0, 0, -1) if setup[4] == "bouclier" else Vector3(0, 1, 0))
		print("   direction résultante (modèle, +Z = avant) = %s" % check)
		# axes locaux de l'os pour placer l'objet : X, Y, Z en espace modèle
		var origin: Vector3
		if setup[4] == "bouclier":
			# centre de l'avant-bras (+0.13 le long de l'os) puis 0.12 m vers l'avant (modèle +Z), en espace os
			origin = Vector3(0, 0.13, 0) + B.basis.inverse() * Vector3(0, 0, 0.12)
		else:
			# centre de la main (+0.05 le long de l'os), poignée centrée (origine de l'épée = bas de la poignée, 0.09 sous le centre)
			origin = Vector3(0, 0.05, 0) - A * Vector3(0, 0.09, 0)
		print("   >>> Transform3D(Basis.from_euler(Vector3(deg_to_rad(%.2f), deg_to_rad(%.2f), deg_to_rad(%.2f))), Vector3(%.3f, %.3f, %.3f))" % [rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z), origin.x, origin.y, origin.z])
	quit()

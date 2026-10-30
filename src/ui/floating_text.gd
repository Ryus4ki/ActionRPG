class_name FloatingText
extends Label3D
## Chiffre de dégâts (ou « Raté ») qui monte et s'efface au-dessus de la cible.

static func spawn(parent: Node, world_pos: Vector3, text_value: String, color: Color, big := false) -> void:
	var label := FloatingText.new()
	label.text = text_value
	label.modulate = color
	label.outline_modulate = Color(0, 0, 0, 0.9)
	label.outline_size = 12
	label.font_size = 96 if big else 64
	label.pixel_size = 0.004
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = false
	parent.add_child(label)
	label.global_position = world_pos + Vector3(randf_range(-0.2, 0.2), 0.0, randf_range(-0.2, 0.2))
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", label.global_position + Vector3(0, 1.2, 0), 0.9).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.9).set_delay(0.3)
	if big:
		label.scale = Vector3.ONE * 1.6
		tween.tween_property(label, "scale", Vector3.ONE, 0.25).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(label.queue_free)


## Installe l'écouteur global : chaque attaque résolue affiche son résultat.
static func install(parent: Node) -> void:
	EventBus.hit_resolved.connect(func(target: Node3D, result: Dictionary):
		if not is_instance_valid(target):
			return
		var pos := target.global_position + Vector3(0, 1.9, 0)
		if not result.get("hit", false):
			spawn(parent, pos, "Bloqué" if result.get("blocked", false) else "Raté", Color(0.6, 0.8, 1.0) if result.get("blocked", false) else Color(0.75, 0.75, 0.75))
		else:
			var is_player_target := target.is_in_group("players")
			var color := Color(1.0, 0.35, 0.3) if is_player_target else Color(1.0, 0.95, 0.6)
			var txt := str(result.get("damage", 0))
			if result.get("crit", false):
				txt += " !"
				color = Color(1.0, 0.6, 0.1)
			elif result.get("blocked", false):
				txt += " (bloqué)"
				color = Color(0.6, 0.8, 1.0)
			spawn(parent, pos, txt, color, result.get("crit", false))
	)

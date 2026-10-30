extends Node
## Test de fumée headless : charge l'arène, laisse l'IA poursuivre le joueur,
## fait attaquer le joueur, et vérifie que des dégâts ont été échangés.
## Exécution : godot --headless --path . res://tests/smoke_arena.tscn

var hits := 0
var player_hits_taken := 0
var enemy_hits_taken := 0
var blocked := 0
var blocked_hits := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	EventBus.hit_resolved.connect(func(target: Node3D, r: Dictionary):
		hits += 1
		if r.get("hit", false):
			if target.is_in_group("players"):
				player_hits_taken += 1
			else:
				enemy_hits_taken += 1
	)
	var scene: PackedScene = load("res://scenes/test_arena.tscn")
	var arena: Node3D = scene.instantiate()
	add_child(arena)
	var player_node: Node = arena.get_node("Player")
	if not (player_node is PlayerCharacter):
		push_error("Le script du joueur n'a pas compilé (voir erreurs ci-dessus)")
		get_tree().quit(1)
		return
	var player: PlayerCharacter = player_node
	player.is_local = false  # pas de souris / caméra en headless
	for _i in 5:
		await get_tree().physics_frame
	var enemies: Array = arena.get_node("Enemies").get_children()
	print("Joueur : %s, PV %d/%d, CA %d, arme %s" % [player.stats.display_name, player.health.hp, player.health.max_hp, player.stats.armor_class(), player.weapon.get("name")])
	print("Ennemis spawnés : %d" % enemies.size())
	if enemies.size() != 3:
		push_error("3 ennemis attendus")
		get_tree().quit(1)
		return
	var first: Enemy = enemies[0]
	var d0 := first.global_position.distance_to(player.global_position)

	# Rapproche le joueur pour déclencher l'aggro et laisse l'IA venir (~6 s).
	# 5 m de l'ennemi, vers le centre de l'arène (pour rester dans les murs).
	var toward_center := -Vector3(first.global_position.x, 0, first.global_position.z).normalized()
	player.global_position = first.global_position + toward_center * 5.0 + Vector3(0, 0.1, 0)
	var attacked := 0
	for i in 60 * 10:
		await get_tree().physics_frame
		# Dès qu'un ennemi vivant est à portée, le joueur frappe dans sa direction.
		var nearest: Enemy = null
		var nd := 999.0
		for e in arena.get_node("Enemies").get_children():
			if e.health.is_alive():
				var d: float = e.global_position.distance_to(player.global_position)
				if d < nd:
					nd = d
					nearest = e
		if nearest and nd < 2.0:
			var dir := nearest.global_position - player.global_position
			player.camera_pivot.global_rotation.y = atan2(-dir.x, -dir.z)
			if player.try_attack():
				attacked += 1
		if enemy_hits_taken >= 3 and player_hits_taken >= 1:
			break
	var d1 := first.global_position.distance_to(player.global_position) if is_instance_valid(first) else 0.0
	print("Distance ennemi→joueur : %.1f → %.1f" % [d0, d1])
	print("Attaques joueur lancées : %d ; résolutions : %d ; touches sur ennemis : %d ; touches sur joueur : %d" % [attacked, hits, enemy_hits_taken, player_hits_taken])
	print("PV joueur : %d/%d ; état ennemi 1 : %s" % [player.health.hp, player.health.max_hp, "mort" if not is_instance_valid(first) or first.health.is_dead else "vivant %d PV" % first.health.hp])
	# Phase garde : le joueur se met en garde face au 2e ennemi, on compte les attaques bloquées.
	# (compteurs membres : une lambda GDScript capture les locales par copie)
	EventBus.hit_resolved.connect(func(target: Node3D, r: Dictionary):
		if target.is_in_group("players") and r.get("blocked", false):
			blocked += 1
			if r.get("hit", false):
				blocked_hits += 1
	)
	player.health.heal(999)
	var second: Enemy = null
	for e in arena.get_node("Enemies").get_children():
		if e.health.is_alive():
			second = e
			break
	if second:
		var tc := -Vector3(second.global_position.x, 0, second.global_position.z).normalized()
		player.global_position = second.global_position + tc * 4.0 + Vector3(0, 0.1, 0)
		var look := second.global_position - player.global_position
		player.camera_pivot.global_rotation.y = atan2(-look.x, -look.z)
		player.rotation.y = player.camera_pivot.global_rotation.y
		player._one_shot_until = 0.0
		player.set_blocking(true)
		for i in 60 * 8:
			await get_tree().physics_frame
			player.face_direction(player.camera_forward(), 1.0, 100.0)
			if blocked >= 3:
				break
		player.set_blocking(false)
	print("Garde : %d attaques bloquées (dont %d touchent quand même)" % [blocked, blocked_hits])
	var ok := attacked > 0 and hits > 0 and (enemy_hits_taken > 0 or player_hits_taken > 0) and blocked > 0
	print("=== SMOKE %s ===" % ("OK" if ok else "ÉCHEC"))
	get_tree().quit(0 if ok else 1)

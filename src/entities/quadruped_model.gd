class_name QuadrupedModel
extends RefCounted
## Modèles d'animaux placeholders construits en code (boîtes), avec un AnimationPlayer procédural :
## idle, walk, run, attack, hit, death. Utilisés via model_path = "proc:<espèce>" (lapin, loup, sanglier, abeille).
## Le modèle regarde vers +Z (comme les exports Blender) : Creature le retourne de 180°.

const SPECIES := {
	"rabbit": {"body": Vector3(0.35, 0.3, 0.5), "head": Vector3(0.25, 0.25, 0.28), "leg": Vector3(0.09, 0.22, 0.09),
		"height": 0.3, "color": "#b89a78", "ears": true, "tail": 0.08, "bob": 0.06, "flying": false},
	"wolf": {"body": Vector3(0.45, 0.45, 1.1), "head": Vector3(0.3, 0.3, 0.42), "leg": Vector3(0.12, 0.5, 0.12),
		"height": 0.55, "color": "#5a5a60", "ears": true, "tail": 0.4, "bob": 0.04, "flying": false},
	"boar": {"body": Vector3(0.6, 0.55, 1.1), "head": Vector3(0.4, 0.38, 0.45), "leg": Vector3(0.14, 0.4, 0.14),
		"height": 0.45, "color": "#4a3a2a", "ears": false, "tail": 0.15, "bob": 0.03, "tusks": true, "flying": false},
	"bee": {"body": Vector3(0.35, 0.3, 0.55), "head": Vector3(0.22, 0.22, 0.22), "leg": Vector3(0.03, 0.12, 0.03),
		"height": 1.2, "color": "#d8b020", "ears": false, "tail": 0.0, "bob": 0.12, "wings": true, "flying": true},
}


static func build(species: String) -> Node3D:
	var sp: Dictionary = SPECIES.get(species, SPECIES["rabbit"])
	var root := Node3D.new()
	root.name = "Quadruped_" + species
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(sp.color)
	mat.roughness = 0.9
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(sp.color).darkened(0.35)
	var h: float = sp.height
	var body_size: Vector3 = sp.body
	# Corps (pivot : centre du corps à la hauteur `height`).
	var body := _box("Body", body_size, Vector3(0, h + body_size.y * 0.5, 0), mat)
	root.add_child(body)
	# Tête à l'avant (+Z).
	var head_size: Vector3 = sp.head
	var head := _box("Head", head_size, Vector3(0, body_size.y * 0.35, body_size.z * 0.5 + head_size.z * 0.4), mat)
	body.add_child(head)
	if sp.get("ears", false):
		for sx in [-1.0, 1.0]:
			var ear := _box("Ear", Vector3(0.06, 0.22 if species == "rabbit" else 0.12, 0.05), Vector3(sx * head_size.x * 0.3, head_size.y * 0.5 + 0.08, 0), dark)
			head.add_child(ear)
	if sp.get("tusks", false):
		for sx in [-1.0, 1.0]:
			var tusk := _box("Tusk", Vector3(0.04, 0.1, 0.04), Vector3(sx * head_size.x * 0.3, -head_size.y * 0.3, head_size.z * 0.5), _white())
			head.add_child(tusk)
	# Yeux.
	for sx in [-1.0, 1.0]:
		var eye := _box("Eye", Vector3(0.05, 0.05, 0.02), Vector3(sx * head_size.x * 0.3, head_size.y * 0.15, head_size.z * 0.5), _black())
		head.add_child(eye)
	# Queue.
	if float(sp.tail) > 0.0:
		var tail := _box("Tail", Vector3(0.08, 0.08, float(sp.tail)), Vector3(0, body_size.y * 0.3, -body_size.z * 0.5 - float(sp.tail) * 0.4), dark)
		body.add_child(tail)
	# Pattes : pivot en haut de la patte (rotation de marche autour de X).
	var leg_size: Vector3 = sp.leg
	var legs: Array[Node3D] = []
	for i in 4:
		var sx := -1.0 if i % 2 == 0 else 1.0
		var sz := 1.0 if i < 2 else -1.0
		var pivot := Node3D.new()
		pivot.name = "Leg%d" % i
		pivot.position = Vector3(sx * body_size.x * 0.35, -body_size.y * 0.45, sz * body_size.z * 0.35)
		body.add_child(pivot)
		var leg := _box("LegMesh", leg_size, Vector3(0, -leg_size.y * 0.5, 0), dark)
		pivot.add_child(leg)
		legs.append(pivot)
	var wings: Array[Node3D] = []
	if sp.get("wings", false):
		for sx in [-1.0, 1.0]:
			var pivot := Node3D.new()
			pivot.name = "Wing%s" % ("L" if sx < 0 else "R")
			pivot.position = Vector3(sx * body_size.x * 0.4, body_size.y * 0.5, 0)
			body.add_child(pivot)
			var wing := _box("WingMesh", Vector3(0.45, 0.02, 0.25), Vector3(sx * 0.25, 0, 0), _white(0.6))
			pivot.add_child(wing)
			wings.append(pivot)
	# Animations.
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	var lib := AnimationLibrary.new()
	var bob: float = sp.bob
	lib.add_animation("idle", _anim_idle(body, bob * 0.5, 2.0))
	lib.add_animation("walk", _anim_gait(body, legs, wings, bob, 0.8, 25.0))
	lib.add_animation("run", _anim_gait(body, legs, wings, bob * 1.5, 0.45, 40.0))
	lib.add_animation("attack", _anim_attack(body, head))
	lib.add_animation("cast", _anim_attack(body, head))
	lib.add_animation("hit", _anim_hit(body))
	lib.add_animation("death", _anim_death(body))
	lib.add_animation("downed", _anim_death(body))
	player.add_animation_library("", lib)
	return root


static func _box(name: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	return mi


static func _white(alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.95, 0.9, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


static func _black() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.05, 0.05, 0.05)
	return m


static func _path(node: Node3D, prop: String) -> String:
	# Chemins relatifs à la racine du modèle (parent de l'AnimationPlayer).
	var parts: Array[String] = []
	var n: Node = node
	while n and n.name != "" and not n.name.begins_with("Quadruped_"):
		parts.push_front(n.name)
		n = n.get_parent()
	return "/".join(parts) + ((":" + prop) if prop != "" else "")


static func _anim_idle(body: Node3D, bob: float, length: float) -> Animation:
	var a := Animation.new()
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR
	var t := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(t, _path(body, ""))
	var base := body.position
	a.position_track_insert_key(t, 0.0, base)
	a.position_track_insert_key(t, length * 0.5, base + Vector3(0, bob, 0))
	a.position_track_insert_key(t, length, base)
	return a


static func _anim_gait(body: Node3D, legs: Array[Node3D], wings: Array[Node3D], bob: float, period: float, swing_deg: float) -> Animation:
	var a := Animation.new()
	a.length = period
	a.loop_mode = Animation.LOOP_LINEAR
	var t := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(t, _path(body, ""))
	var base := body.position
	a.position_track_insert_key(t, 0.0, base)
	a.position_track_insert_key(t, period * 0.25, base + Vector3(0, bob, 0))
	a.position_track_insert_key(t, period * 0.5, base)
	a.position_track_insert_key(t, period * 0.75, base + Vector3(0, bob, 0))
	a.position_track_insert_key(t, period, base)
	for i in legs.size():
		var tr := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(tr, _path(legs[i], ""))
		var phase := 0.0 if (i == 0 or i == 3) else period * 0.5
		var s := deg_to_rad(swing_deg)
		for k in 5:
			var time := period * k / 4.0
			var ang := s * sin(TAU * (time + phase) / period)
			a.rotation_track_insert_key(tr, time, Quaternion(Vector3.RIGHT, ang))
	for w in wings:
		var tr := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(tr, _path(w, ""))
		var sign := 1.0 if w.position.x < 0 else -1.0
		for k in 9:
			var time := period * k / 8.0
			a.rotation_track_insert_key(tr, time, Quaternion(Vector3.FORWARD, sign * deg_to_rad(35.0) * sin(TAU * k / 2.0)))
	return a


static func _anim_attack(body: Node3D, head: Node3D) -> Animation:
	var a := Animation.new()
	a.length = 0.8
	var t := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(t, _path(body, ""))
	var base := body.position
	a.position_track_insert_key(t, 0.0, base)
	a.position_track_insert_key(t, 0.25, base + Vector3(0, 0, -0.15))
	a.position_track_insert_key(t, 0.4, base + Vector3(0, 0.05, 0.35))
	a.position_track_insert_key(t, 0.8, base)
	var th := a.add_track(Animation.TYPE_ROTATION_3D)
	a.track_set_path(th, _path(head, ""))
	a.rotation_track_insert_key(th, 0.0, Quaternion.IDENTITY)
	a.rotation_track_insert_key(th, 0.25, Quaternion(Vector3.RIGHT, deg_to_rad(-25)))
	a.rotation_track_insert_key(th, 0.4, Quaternion(Vector3.RIGHT, deg_to_rad(20)))
	a.rotation_track_insert_key(th, 0.8, Quaternion.IDENTITY)
	return a


static func _anim_hit(body: Node3D) -> Animation:
	var a := Animation.new()
	a.length = 0.4
	var t := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(t, _path(body, ""))
	var base := body.position
	a.position_track_insert_key(t, 0.0, base)
	a.position_track_insert_key(t, 0.1, base + Vector3(0, 0, -0.2))
	a.position_track_insert_key(t, 0.4, base)
	return a


static func _anim_death(body: Node3D) -> Animation:
	var a := Animation.new()
	a.length = 1.0
	var tr := a.add_track(Animation.TYPE_ROTATION_3D)
	a.track_set_path(tr, _path(body, ""))
	a.rotation_track_insert_key(tr, 0.0, Quaternion.IDENTITY)
	a.rotation_track_insert_key(tr, 0.6, Quaternion(Vector3.FORWARD, deg_to_rad(85)))
	a.rotation_track_insert_key(tr, 1.0, Quaternion(Vector3.FORWARD, deg_to_rad(85)))
	var t := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(t, _path(body, ""))
	var base := body.position
	a.position_track_insert_key(t, 0.0, base)
	a.position_track_insert_key(t, 0.6, Vector3(base.x, body.position.y * 0.5, base.z))
	a.position_track_insert_key(t, 1.0, Vector3(base.x, body.position.y * 0.5, base.z))
	return a

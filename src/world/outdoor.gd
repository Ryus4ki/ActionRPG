class_name Outdoor
extends Node3D
## Zone extérieure (village, prairie, forêt) construite depuis un plan JSON : sol, bordures,
## bâtiments, arbres/rochers/barrières (dispersion déterministe par graine), PNJ, lignes de zone,
## points d'apparition des monstres (avec réapparition) et des joueurs. Identique sur tous les pairs.

const NPC_SCENE := preload("res://scenes/npc.tscn")
const ZONE_LINE_SCENE := preload("res://scenes/zone_line.tscn")
const CAMPFIRE_SCENE := preload("res://scenes/campfire.tscn")
const CHEST_SCENE := preload("res://scenes/chest.tscn")

@export_file("*.json") var layout_path := "res://data/levels/village.json"

@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var geometry: Node3D = $NavigationRegion3D/Geometry
@onready var objects: Node3D = $Objects

var layout: Dictionary = {}
var zone_name := "Zone"
var size := Vector2(80, 80)
var track_clear := false   # pas de « zone nettoyée » dehors : les monstres réapparaissent
var _rng := RandomNumberGenerator.new()
var _spawns: Array[Dictionary] = []
var _player_spawns: Dictionary = {}
var _blockers: Array[Rect2] = []   # zones (x, z, w, h) à garder libres (bâtiments, routes)
var _mats: Dictionary = {}


func _ready() -> void:
	layout = _load_layout()
	if layout.is_empty():
		push_error("Plan de zone introuvable : " + layout_path)
		return
	zone_name = layout.get("name", "Zone")
	var sz: Array = layout.get("size", [80, 80])
	size = Vector2(float(sz[0]), float(sz[1]))
	_rng.seed = int(layout.get("seed", 1))
	_build_ground()
	_build_buildings()
	_build_borders()
	_build_props()
	_build_objects()
	_collect_spawns()
	if multiplayer.is_server():
		_bake_navigation()


# ------------------------------------------------------------------ interface niveau

func enemy_spawn_list() -> Array[Dictionary]:
	return _spawns


func player_spawn_position(index: int) -> Vector3:
	return player_spawn_by_id("default", index)


func player_spawn_by_id(id: String, index: int) -> Vector3:
	var base: Vector3 = _player_spawns.get(id, _player_spawns.get("default", Vector3.ZERO))
	return base + Vector3(1.2 * index, 0.1, 0.0)


## Orientation à l'arrivée : en entrant par une ligne de zone, on regarde vers le centre de la zone (le long de
## la route d'entrée) plutôt que vers la sortie. "player_spawn_yaw": {"id": degrés} dans le plan JSON pour forcer.
func player_spawn_yaw(id: String) -> float:
	var forced: Dictionary = layout.get("player_spawn_yaw", {})
	if forced.has(id):
		return deg_to_rad(float(forced[id]))
	var p: Vector3 = _player_spawns.get(id, _player_spawns.get("default", Vector3.ZERO))
	var to := -Vector3(p.x, 0.0, p.z)
	if to.length() < 4.0:
		return 0.0
	return atan2(-to.x, -to.z)


func npc_data(npc_id: String) -> Dictionary:
	for n in layout.get("npcs", []):
		if n.get("id", "") == npc_id:
			return n
	return {}


# ------------------------------------------------------------------ construction

func _load_layout() -> Dictionary:
	if not FileAccess.file_exists(layout_path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(layout_path))
	return data if data is Dictionary else {}


func _mat(color_hex: String, rough := 1.0) -> StandardMaterial3D:
	var key := color_hex + str(rough)
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(color_hex)
		m.roughness = rough
		_mats[key] = m
	return _mats[key]


func _add_box(parent: Node3D, box_size: Vector3, pos: Vector3, mat: Material, collide := true, rot_y := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	body.rotation.y = rot_y
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = box_size
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	if collide:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = box_size
		cs.shape = shape
		body.add_child(cs)
	parent.add_child(body)
	return body


func _build_ground() -> void:
	_add_box(geometry, Vector3(size.x, 1.0, size.y), Vector3(0, -0.5, 0), _mat(layout.get("ground", "#5a7a3a")))
	# Taches d'herbe / terre pour casser l'uniformité (sans collision).
	var patches: int = int(layout.get("patches", 40))
	for i in patches:
		var w := _rng.randf_range(3.0, 9.0)
		var d := _rng.randf_range(3.0, 9.0)
		var p := Vector3(_rng.randf_range(-size.x / 2 + 5, size.x / 2 - 5), 0.02, _rng.randf_range(-size.y / 2 + 5, size.y / 2 - 5))
		var col: Color = Color(layout.get("ground", "#5a7a3a")).lerp(Color(layout.get("patch_color", "#4a6a2a")), _rng.randf_range(0.3, 1.0))
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		_add_box(geometry, Vector3(w, 0.04, d), p, m, false)
	# Routes (dalles claires, sans collision).
	for road in layout.get("roads", []):
		var a := Vector3(road.from[0], 0.03, road.from[1])
		var b := Vector3(road.to[0], 0.03, road.to[1])
		var mid := (a + b) * 0.5
		var length := a.distance_to(b)
		var ang := atan2(-(b.x - a.x), -(b.z - a.z))
		_add_box(geometry, Vector3(float(road.get("width", 4.0)), 0.06, length), mid, _mat(layout.get("road_color", "#8a7a5a")), false, ang)
		_blockers.append(Rect2(mid.x - length / 2 - 2, mid.z - length / 2 - 2, length + 4, length + 4))


func _build_buildings() -> void:
	for b in layout.get("buildings", []):
		var pos := Vector3(b.pos[0], 0, b.pos[1])
		var bs := Vector3(b.size[0], b.size[1], b.size[2])
		var rot: float = deg_to_rad(float(b.get("rot", 0.0)))
		_add_box(geometry, bs, pos + Vector3(0, bs.y / 2, 0), _mat(b.get("color", "#8a6a4a")), true, rot)
		# Toit : prisme.
		var roof := MeshInstance3D.new()
		var prism := PrismMesh.new()
		prism.size = Vector3(bs.x + 0.8, bs.y * 0.45, bs.z + 0.8)
		roof.mesh = prism
		roof.material_override = _mat(b.get("roof", "#6a3a2a"))
		roof.position = pos + Vector3(0, bs.y + prism.size.y / 2, 0)
		roof.rotation.y = rot
		geometry.add_child(roof)
		# Porte (décor).
		var door := MeshInstance3D.new()
		var dm := BoxMesh.new()
		dm.size = Vector3(1.2, 2.2, 0.1)
		door.mesh = dm
		door.material_override = _mat("#3a2a1a")
		door.position = pos + Vector3(0, 1.1, bs.z / 2 + 0.05).rotated(Vector3.UP, rot)
		door.rotation.y = rot
		geometry.add_child(door)
		_blockers.append(Rect2(pos.x - bs.x / 2 - 3, pos.z - bs.z / 2 - 3, bs.x + 6, bs.z + 6))


## Bordures : murs invisibles sur les quatre côtés, sauf au niveau des lignes de zone.
func _build_borders() -> void:
	var gaps := {}
	for zl in layout.get("zone_lines", []):
		gaps[zl.side] = float(zl.get("at", 0.0))
	for side in ["n", "s", "w", "e"]:
		var horizontal: bool = side in ["n", "s"]
		var length := size.x if horizontal else size.y
		var edge := (-size.y / 2 if side == "n" else size.y / 2) if horizontal else (-size.x / 2 if side == "w" else size.x / 2)
		var segments: Array = [[-length / 2, length / 2]]
		if gaps.has(side):
			var at: float = gaps[side]
			segments = [[-length / 2, at - 6.0], [at + 6.0, length / 2]]
		for seg in segments:
			var a: float = seg[0]
			var b: float = seg[1]
			if b - a < 0.5:
				continue
			var mid := (a + b) / 2
			var wall_size := Vector3(b - a, 6, 0.5) if horizontal else Vector3(0.5, 6, b - a)
			var pos := Vector3(mid, 3, edge) if horizontal else Vector3(edge, 3, mid)
			var body := _add_box(geometry, wall_size, pos, _mat("#000000"), true)
			body.get_child(0).visible = false
		# Haie / lisière visible le long des bords (décor bas, sans collision).
		var hedge_size := Vector3(length, 1.2, 1.5) if horizontal else Vector3(1.5, 1.2, length)
		var hpos := Vector3(0, 0.6, edge) if horizontal else Vector3(edge, 0.6, 0)
		_add_box(geometry, hedge_size, hpos, _mat(layout.get("edge_color", "#2f4a22")), false)


func _free_spot(x: float, z: float, margin: float) -> bool:
	for r in _blockers:
		if r.grow(margin).has_point(Vector2(x, z)):
			return false
	for sp in layout.get("player_spawns", {}).values():
		if Vector2(x, z).distance_to(Vector2(sp[0], sp[2])) < 6.0:
			return false
	return true


func _build_props() -> void:
	for group in layout.get("props", []):
		var kind: String = group.get("kind", "tree")
		var count: int = int(group.get("count", 10))
		var area: Array = group.get("area", [-size.x / 2 + 4, -size.y / 2 + 4, size.x / 2 - 4, size.y / 2 - 4])
		var placed := 0
		var tries := 0
		while placed < count and tries < count * 20:
			tries += 1
			var x := _rng.randf_range(float(area[0]), float(area[2]))
			var z := _rng.randf_range(float(area[1]), float(area[3]))
			if not _free_spot(x, z, 2.0):
				continue
			_place_prop(kind, Vector3(x, 0, z), group)
			placed += 1


func _place_prop(kind: String, pos: Vector3, opts: Dictionary) -> void:
	match kind:
		"tree":
			var h := _rng.randf_range(float(opts.get("min_height", 4.0)), float(opts.get("max_height", 7.0)))
			var trunk := _add_box(geometry, Vector3(0.6, h * 0.55, 0.6), pos + Vector3(0, h * 0.275, 0), _mat("#5a3a22"))
			var canopy := MeshInstance3D.new()
			if opts.get("conifer", false):
				var cone := CylinderMesh.new()
				cone.top_radius = 0.0
				cone.bottom_radius = h * 0.35
				cone.height = h * 0.75
				canopy.mesh = cone
				canopy.position = Vector3(0, h * 0.35 + h * 0.3, 0)
			else:
				var ball := SphereMesh.new()
				ball.radius = h * 0.32
				ball.height = h * 0.6
				canopy.mesh = ball
				canopy.position = Vector3(0, h * 0.5, 0)
			canopy.material_override = _mat(opts.get("color", "#2e6b2a"))
			trunk.add_child(canopy)
			trunk.rotation.y = _rng.randf() * TAU
		"rock":
			var s := _rng.randf_range(0.8, 2.2)
			_add_box(geometry, Vector3(s, s * 0.7, s * 0.8), pos + Vector3(0, s * 0.3, 0), _mat("#6a6a66"), true, _rng.randf() * TAU)
		"bush":
			var s := _rng.randf_range(0.8, 1.6)
			var bush := MeshInstance3D.new()
			var ball := SphereMesh.new()
			ball.radius = s * 0.6
			ball.height = s
			bush.mesh = ball
			bush.material_override = _mat(opts.get("color", "#3f7a33"))
			bush.position = pos + Vector3(0, s * 0.4, 0)
			geometry.add_child(bush)
		"stump":
			_add_box(geometry, Vector3(0.9, 0.5, 0.9), pos + Vector3(0, 0.25, 0), _mat("#6a4a2a"), true, _rng.randf() * TAU)
		"fence":
			var length := float(opts.get("length", 6.0))
			var ang := _rng.randf() * TAU
			_add_box(geometry, Vector3(length, 1.0, 0.15), pos + Vector3(0, 0.6, 0), _mat("#7a5a3a"), true, ang)
		"flowers":
			var m := StandardMaterial3D.new()
			m.albedo_color = Color.from_hsv(_rng.randf(), 0.6, 0.95)
			_add_box(geometry, Vector3(1.5, 0.2, 1.5), pos + Vector3(0, 0.1, 0), m, false)


func _build_objects() -> void:
	for n in layout.get("npcs", []):
		var npc: Npc = NPC_SCENE.instantiate()
		npc.name = "Npc_" + n.id
		npc.npc_id = n.id
		npc.npc_name = n.get("name", "Villageois")
		npc.role = n.get("role", "talk")
		npc.tint = Color(n.get("tint", "#a08060"))
		npc.position = Vector3(n.pos[0], 0, n.pos[1])
		npc.rotation.y = deg_to_rad(float(n.get("rot", 180.0)))
		objects.add_child(npc)
		_blockers.append(Rect2(npc.position.x - 1.5, npc.position.z - 1.5, 3, 3))
	for zl in layout.get("zone_lines", []):
		var line: ZoneLine = ZONE_LINE_SCENE.instantiate()
		line.name = "ZoneLine_" + zl.side
		line.target_level = zl.target
		line.target_spawn = zl.get("spawn", "default")
		line.label_text = zl.get("label", "Zone")
		line.requires = zl.get("requires", "")
		line.requires_text = zl.get("requires_text", "")
		var at: float = float(zl.get("at", 0.0))
		match zl.side:
			"n":
				line.position = Vector3(at, 0, -size.y / 2 + 1.0)
			"s":
				line.position = Vector3(at, 0, size.y / 2 - 1.0)
				line.rotation.y = PI
			"w":
				line.position = Vector3(-size.x / 2 + 1.0, 0, at)
				line.rotation.y = PI / 2
			"e":
				line.position = Vector3(size.x / 2 - 1.0, 0, at)
				line.rotation.y = -PI / 2
		objects.add_child(line)
	for f in layout.get("campfires", []):
		var fire: Campfire = CAMPFIRE_SCENE.instantiate()
		fire.name = f.get("id", "campfire")
		fire.position = Vector3(f.pos[0], 0, f.pos[1])
		objects.add_child(fire)
	for c in layout.get("shared_chests", []):
		var sc := SharedChest.new()
		sc.name = c.get("id", "shared_chest")
		sc.position = Vector3(c.pos[0], 0, c.pos[1])
		sc.rotation.y = deg_to_rad(float(c.get("rot", 0.0)))
		objects.add_child(sc)
		_blockers.append(Rect2(sc.position.x - 1.5, sc.position.z - 1.5, 3, 3))
	for c in layout.get("chests", []):
		var chest: Chest = CHEST_SCENE.instantiate()
		chest.name = c.get("id", "chest")
		chest.position = Vector3(c.pos[0], 0, c.pos[1])
		objects.add_child(chest)


func _collect_spawns() -> void:
	for id in layout.get("player_spawns", {}):
		var p: Array = layout.player_spawns[id]
		_player_spawns[id] = Vector3(p[0], p[1], p[2])
	for sp in layout.get("spawns", []):
		var area: Array = sp.area
		var count: int = int(sp.get("count", 1))
		for i in count:
			var x := _rng.randf_range(float(area[0]), float(area[2]))
			var z := _rng.randf_range(float(area[1]), float(area[3]))
			_spawns.append({"monster_id": sp.monster, "position": Vector3(x, 0.1, z), "respawn": float(sp.get("respawn", 60.0))})


func _bake_navigation() -> void:
	var mesh := NavigationMesh.new()
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = 1
	mesh.agent_radius = 0.5
	mesh.agent_height = 2.0
	mesh.agent_max_climb = 0.5
	mesh.cell_size = 0.5
	mesh.cell_height = 0.25
	nav_region.navigation_mesh = mesh
	nav_region.bake_navigation_mesh(false)

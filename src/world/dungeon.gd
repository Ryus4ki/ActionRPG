class_name Dungeon
extends Node3D
## Niveau « donjon » construit à partir d'un plan JSON (data/levels/*.json) : grille de cellules,
## sols et murs générés automatiquement, portes/leviers/feux de camp/pièges/coffres instanciés,
## torches murales, navmesh cuit à l'exécution (hôte). Construit à l'identique chez tous les
## pairs (déterministe) ; l'état des objets interactifs est répliqué par leurs propres scènes.

const DOOR_SCENE := preload("res://scenes/door.tscn")
const LEVER_SCENE := preload("res://scenes/lever.tscn")
const CAMPFIRE_SCENE := preload("res://scenes/campfire.tscn")
const TRAP_SCENE := preload("res://scenes/trap.tscn")
const CHEST_SCENE := preload("res://scenes/chest.tscn")
const PUZZLE_SCENE := preload("res://scenes/rune_puzzle.tscn")
const ZONE_LINE_SCENE := preload("res://scenes/zone_line.tscn")
const WALL_DIRS := {"n": Vector2i(0, -1), "s": Vector2i(0, 1), "w": Vector2i(-1, 0), "e": Vector2i(1, 0)}

const WALL_HEIGHT := 3.2
const WALL_THICKNESS := 0.3

@export_file("*.json") var layout_path := "res://data/levels/dungeon_01.json"

@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var geometry: Node3D = $NavigationRegion3D/Geometry
@onready var objects: Node3D = $Objects

var layout: Dictionary = {}
var zone_name := "Donjon"
var track_clear := true
var _openings: Dictionary = {}  # Vector2i cellule -> direction (mur omis : ligne de zone)
var cell := 4.0
var floor_cells: Dictionary = {}      # Vector2i -> room id ("" pour un couloir)
var room_by_id: Dictionary = {}
var _torch_lights: Array[OmniLight3D] = []
var _flicker := 0.0
var _player_spawns: Array[Vector3] = []
var _enemy_spawns: Array[Dictionary] = []
var _doors: Array[Door] = []
var _levers: Array[Lever] = []

var _mat_wall: StandardMaterial3D
var _floor_mats: Dictionary = {}


func _ready() -> void:
	layout = _load_layout()
	if layout.is_empty():
		push_error("Plan de donjon introuvable : " + layout_path)
		return
	cell = float(layout.get("cell", 4.0))
	zone_name = layout.get("name", "Donjon")
	for zl in layout.get("zone_lines", []):
		_openings[Vector2i(int(zl.cell[0]), int(zl.cell[1]))] = WALL_DIRS.get(zl.get("side", "s"), Vector2i(0, 1))
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_color = Color(0.42, 0.41, 0.44)
	_mat_wall.roughness = 0.95
	_collect_cells()
	_build_floors()
	_build_walls()
	_build_torches()
	_build_props()
	_build_objects()
	_collect_spawns()
	if multiplayer.is_server():
		_bake_navigation()


func _process(delta: float) -> void:
	_flicker += delta
	for i in _torch_lights.size():
		var l := _torch_lights[i]
		l.light_energy = 1.1 + sin(_flicker * 7.0 + i * 1.7) * 0.12 + sin(_flicker * 13.0 + i) * 0.06


# ------------------------------------------------------------------ interface niveau

func enemy_spawn_list() -> Array[Dictionary]:
	return _enemy_spawns


func player_spawn_position(index: int) -> Vector3:
	if _player_spawns.is_empty():
		return Vector3(0, 0.1, 0)
	return _player_spawns[index % _player_spawns.size()]


# ------------------------------------------------------------------ construction

func _load_layout() -> Dictionary:
	if not FileAccess.file_exists(layout_path):
		return {}
	var txt := FileAccess.get_file_as_string(layout_path)
	var data = JSON.parse_string(txt)
	return data if data is Dictionary else {}


func cell_center(c: Vector2i) -> Vector3:
	return Vector3((c.x + 0.5) * cell, 0.0, (c.y + 0.5) * cell)


func _collect_cells() -> void:
	for room in layout.get("rooms", []):
		var r: Array = room.rect
		room_by_id[room.id] = room
		for x in range(int(r[0]), int(r[0]) + int(r[2])):
			for z in range(int(r[1]), int(r[1]) + int(r[3])):
				floor_cells[Vector2i(x, z)] = room.id
	for cor in layout.get("corridors", []):
		for c in cor.cells:
			var key := Vector2i(int(c[0]), int(c[1]))
			if not floor_cells.has(key):
				floor_cells[key] = ""


func _floor_material(room_id: String) -> StandardMaterial3D:
	var color_hex: String = room_by_id.get(room_id, {}).get("floor", "#3c3c42") if room_id != "" else "#38383e"
	if not _floor_mats.has(color_hex):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(color_hex)
		m.roughness = 1.0
		_floor_mats[color_hex] = m
	return _floor_mats[color_hex]


func _add_box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, with_collision := true, name_hint := "Box") -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = name_hint
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	if with_collision:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
	parent.add_child(body)
	return body


func _build_floors() -> void:
	for key in floor_cells:
		var c: Vector2i = key
		var center := cell_center(c)
		_add_box(geometry, Vector3(cell, 0.4, cell), center + Vector3(0, -0.2, 0), _floor_material(floor_cells[key]), true, "Floor_%d_%d" % [c.x, c.y])


## Un mur par arête entre une cellule de sol et une cellule vide.
func _build_walls() -> void:
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for key in floor_cells:
		var c: Vector2i = key
		var center := cell_center(c)
		for d in dirs:
			if floor_cells.has(c + d):
				continue
			if _openings.get(c, Vector2i(9, 9)) == d:
				continue  # ouverture vers une autre zone
			var offset := Vector3(d.x, 0, d.y) * (cell / 2.0)
			var size := Vector3(WALL_THICKNESS, WALL_HEIGHT, cell + WALL_THICKNESS) if d.x != 0 else Vector3(cell + WALL_THICKNESS, WALL_HEIGHT, WALL_THICKNESS)
			_add_box(geometry, size, center + offset + Vector3(0, WALL_HEIGHT / 2.0, 0), _mat_wall, true, "Wall_%d_%d_%d_%d" % [c.x, c.y, d.x, d.y])


## Torches : réparties sur les murs de chaque salle (et une par couloir de 3+ cellules).
func _build_torches() -> void:
	var per_room: int = int(layout.get("torches_per_room", 4))
	var torch_scene: PackedScene = load("res://assets/models/sm_torch.glb")
	for room in layout.get("rooms", []):
		var candidates: Array = []  # [position, direction normale vers l'intérieur]
		var r: Array = room.rect
		for x in range(int(r[0]), int(r[0]) + int(r[2])):
			for z in range(int(r[1]), int(r[1]) + int(r[3])):
				var c := Vector2i(x, z)
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if not floor_cells.has(c + d):
						var n := Vector3(-d.x, 0, -d.y)
						candidates.append([cell_center(c) + Vector3(d.x, 0, d.y) * (cell / 2.0 - 0.2), n])
		if candidates.is_empty():
			continue
		var step := maxi(1, candidates.size() / per_room)
		var i := 0
		while i < candidates.size():
			_add_torch(candidates[i][0], candidates[i][1], torch_scene)
			i += step
	for cor in layout.get("corridors", []):
		var cells: Array = cor.cells
		if cells.size() >= 3:
			var mid: Array = cells[cells.size() / 2]
			var c := Vector2i(int(mid[0]), int(mid[1]))
			for d in [Vector2i(1, 0), Vector2i(0, 1)]:
				if not floor_cells.has(c + d):
					_add_torch(cell_center(c) + Vector3(d.x, 0, d.y) * (cell / 2.0 - 0.2), Vector3(-d.x, 0, -d.y), torch_scene)
					break


func _add_torch(pos: Vector3, normal: Vector3, torch_scene: PackedScene) -> void:
	var holder := Node3D.new()
	holder.position = pos
	holder.look_at_from_position(pos, pos + normal, Vector3.UP)
	objects.add_child(holder)
	if torch_scene:
		var inst: Node3D = torch_scene.instantiate()  # la torche s'avance vers -Z, donc vers l'intérieur
		holder.add_child(inst)
	var light := OmniLight3D.new()
	light.position = Vector3(0, 2.1, 0) + Vector3(0, 0, -0.5)
	light.light_color = Color(1.0, 0.72, 0.42)
	light.light_energy = 1.1
	light.omni_range = 9.0
	light.omni_attenuation = 1.4
	light.shadow_enabled = false
	holder.add_child(light)
	_torch_lights.append(light)


func _build_props() -> void:
	for prop in layout.get("props", []):
		var scene: PackedScene = load("res://assets/models/%s.glb" % prop.model)
		if scene == null:
			continue
		var c := Vector2i(int(prop.cell[0]), int(prop.cell[1]))
		var inst: Node3D = scene.instantiate()
		var off: Array = prop.get("offset", [0, 0, 0])
		inst.position = cell_center(c) + Vector3(off[0], off[1], off[2])
		objects.add_child(inst)
		# Collision simple pour les piliers (les joueurs ne traversent pas).
		if prop.model == "sm_pillar" or prop.model == "sm_altar":
			var size := Vector3(0.8, WALL_HEIGHT, 0.8) if prop.model == "sm_pillar" else Vector3(1.6, 1.0, 0.9)
			var body := _add_box(geometry, size, inst.position + Vector3(0, size.y / 2.0, 0), _mat_wall, true, "Prop_%d_%d" % [c.x, c.y])
			body.get_child(0).visible = false  # le modèle .glb fait le visuel


func _build_objects() -> void:
	for d in layout.get("doors", []):
		var door: Door = DOOR_SCENE.instantiate()
		door.name = d.id
		door.door_id = d.id
		door.label_text = d.get("label", "Porte")
		var req: Array[String] = []
		for l in d.get("levers", []):
			req.append(str(l))
		door.required_levers = req
		var c := Vector2i(int(d.cell[0]), int(d.cell[1]))
		door.position = cell_center(c)
		if d.get("axis", "x") == "z":
			door.rotation_degrees.y = 90.0
		objects.add_child(door)
		_doors.append(door)
	for l in layout.get("levers", []):
		var lever: Lever = LEVER_SCENE.instantiate()
		lever.name = l.id
		lever.lever_id = l.id
		lever.label_text = l.get("label", "Levier")
		var c := Vector2i(int(l.cell[0]), int(l.cell[1]))
		lever.position = _against_wall(c, 0.45)
		lever.pulled_changed.connect(_on_lever_pulled)
		objects.add_child(lever)
		_levers.append(lever)
	for f in layout.get("campfires", []):
		var fire: Campfire = CAMPFIRE_SCENE.instantiate()
		fire.name = f.id
		fire.position = cell_center(Vector2i(int(f.cell[0]), int(f.cell[1])))
		objects.add_child(fire)
	for t in layout.get("traps", []):
		var i := 0
		for tc in t.cells:
			var trap: Trap = TRAP_SCENE.instantiate()
			trap.name = "%s_%d" % [t.id, i]
			trap.kind = t.get("kind", "spikes")
			trap.zone = t.get("zone", t.id)
			trap.position = cell_center(Vector2i(int(tc[0]), int(tc[1])))
			objects.add_child(trap)
			i += 1
	for pz in layout.get("puzzles", []):
		var puzzle: RunePuzzle = PUZZLE_SCENE.instantiate()
		puzzle.name = pz.id
		puzzle.puzzle_id = pz.id
		puzzle.zone = pz.get("zone", "")
		puzzle.riddle = pz.get("riddle", "")
		var names: Array[String] = []
		var tfs: Array[Transform3D] = []
		for r in pz.get("runes", []):
			names.append(str(r.name))
			tfs.append(_wall_transform(Vector2i(int(r.cell[0]), int(r.cell[1])), r.get("wall", "n"), 0.15))
		puzzle.rune_names = names
		puzzle.rune_transforms = tfs
		var ord: Array[int] = []
		for o in pz.get("order", []):
			ord.append(int(o))
		puzzle.order = ord
		var plaque: Dictionary = pz.get("plaque", {})
		if not plaque.is_empty():
			var ptf := _wall_transform(Vector2i(int(plaque.cell[0]), int(plaque.cell[1])), plaque.get("wall", "n"), 0.1)
			ptf.origin.y = 1.9
			puzzle.plaque_transform = ptf
		objects.add_child(puzzle)
	for zl in layout.get("zone_lines", []):
		var line: ZoneLine = ZONE_LINE_SCENE.instantiate()
		line.name = "ZoneLine_" + zl.get("side", "s")
		line.target_level = zl.target
		line.target_spawn = zl.get("spawn", "default")
		line.label_text = zl.get("label", "Sortie")
		var c := Vector2i(int(zl.cell[0]), int(zl.cell[1]))
		var tf := _wall_transform(c, zl.get("side", "s"), -0.5)
		line.transform = tf
		objects.add_child(line)
	for ch in layout.get("chests", []):
		var chest: Chest = CHEST_SCENE.instantiate()
		chest.name = ch.id
		var c := Vector2i(int(ch.cell[0]), int(ch.cell[1]))
		chest.position = _against_wall(c, 0.6)
		if chest.position.distance_to(cell_center(c)) > 0.1:
			chest.look_at_from_position(chest.position, cell_center(c), Vector3.UP)
		objects.add_child(chest)


## Transform collé au mur `wall` ("n","s","w","e") d'une cellule, face vers l'intérieur (-Z local).
func _wall_transform(c: Vector2i, wall: String, inset: float) -> Transform3D:
	var d: Vector2i = WALL_DIRS.get(wall, Vector2i(0, -1))
	var pos := cell_center(c) + Vector3(d.x, 0, d.y) * (cell / 2.0 - inset)
	var inward := Vector3(-d.x, 0, -d.y)
	return Transform3D.IDENTITY.looking_at(inward, Vector3.UP).translated(pos)


## Position collée au mur le plus proche d'une cellule (pour leviers, coffres).
func _against_wall(c: Vector2i, inset: float) -> Vector3:
	var center := cell_center(c)
	for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		if not floor_cells.has(c + d):
			return center + Vector3(d.x, 0, d.y) * (cell / 2.0 - inset)
	return center


func _collect_spawns() -> void:
	for ps in layout.get("player_spawns", []):
		_player_spawns.append(cell_center(Vector2i(int(ps[0]), int(ps[1]))) + Vector3(0, 0.1, 0))
	for sp in layout.get("spawns", []):
		var c := Vector2i(int(sp.cell[0]), int(sp.cell[1]))
		_enemy_spawns.append({"monster_id": sp.monster, "position": cell_center(c) + Vector3(0, 0.1, 0)})


func _on_lever_pulled() -> void:
	if not multiplayer.is_server():
		return
	var pulled: Array = []
	for l in _levers:
		if l.pulled:
			pulled.append(l.lever_id)
	for d in _doors:
		var was_open := d.open
		d.check_levers(pulled)
		if d.open and not was_open:
			# La porte ne bloque plus : on recuit le navmesh pour que les monstres puissent passer.
			get_tree().create_timer(1.6).timeout.connect(_bake_navigation)


func _bake_navigation() -> void:
	var mesh := nav_region.navigation_mesh
	if mesh == null:
		mesh = NavigationMesh.new()
		mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
		mesh.geometry_collision_mask = 1
		mesh.agent_radius = 0.5
		mesh.agent_height = 2.0
		mesh.agent_max_climb = 0.25
		mesh.cell_size = 0.25
		mesh.cell_height = 0.25
		nav_region.navigation_mesh = mesh
	nav_region.bake_navigation_mesh(false)

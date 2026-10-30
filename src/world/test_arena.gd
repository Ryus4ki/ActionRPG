extends Node3D
## Niveau « arène de test » : géométrie, navmesh cuit au lancement, points d'apparition.
## Les monstres sont instanciés par Game (hôte) à partir des Marker3D de « Spawns »
## (nom du marker = id du monstre, suffixe numérique ignoré). Les joueurs sur « PlayerSpawns ».

@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var spawns: Node3D = $Spawns
@onready var player_spawns: Node3D = $PlayerSpawns


func _ready() -> void:
	if multiplayer.is_server():
		_bake_navigation()


func _bake_navigation() -> void:
	var mesh := NavigationMesh.new()
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = 1
	mesh.agent_radius = 0.5
	mesh.agent_height = 2.0
	mesh.agent_max_climb = 0.25
	mesh.cell_size = 0.25
	mesh.cell_height = 0.25
	nav_region.navigation_mesh = mesh
	nav_region.bake_navigation_mesh(false)


## Liste [{monster_id, position}] des monstres à faire apparaître.
func enemy_spawn_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for marker in spawns.get_children():
		if marker is Marker3D:
			var id: String = marker.name.rstrip("0123456789").trim_suffix("_")
			out.append({"monster_id": id, "position": marker.global_position})
	return out


func player_spawn_position(index: int) -> Vector3:
	var markers := player_spawns.get_children()
	if markers.is_empty():
		return Vector3(0, 0.1, 0)
	return (markers[index % markers.size()] as Node3D).global_position

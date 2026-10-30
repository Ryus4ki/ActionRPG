class_name Projectile
extends Area3D
## Projectile de sort (trait de feu, projectile magique, rayon ardent, boule de feu en vol).
## Simulé par l'hôte ; position répliquée pour l'affichage chez les clients.

@export var speed := 25.0
@export var max_range := 36.0
@export var radius := 0.15
@export var color := Color(1.0, 0.5, 0.1)
@export var homing := false
@export var explode_on_arrival := false  # boule de feu : explose au point visé

var direction := Vector3.FORWARD
var caster_path := NodePath()
var target_path := NodePath()      # cible (homing) ou point d'arrivée
var target_point := Vector3.ZERO
var spell_id := ""
var slot_level := 0
var _travelled := 0.0
var _done := false

@onready var mesh: MeshInstance3D = $Mesh
@onready var light: OmniLight3D = $Light


func _ready() -> void:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	mesh.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	mesh.material_override = mat
	light.light_color = color
	($Shape as CollisionShape3D).shape.radius = radius
	if not multiplayer.is_server():
		set_physics_process(false)


func _physics_process(delta: float) -> void:
	if _done:
		return
	var target := get_node_or_null(target_path) as Node3D
	if homing and target and is_instance_valid(target):
		var to := (target.global_position + Vector3(0, 1.0, 0)) - global_position
		direction = direction.slerp(to.normalized(), minf(1.0, 14.0 * delta))
	var step := speed * delta
	if explode_on_arrival:
		var remaining := global_position.distance_to(target_point)
		if remaining <= step:
			global_position = target_point
			_explode()
			return
	# Lancer de rayon sur le segment parcouru ce tick : pas de tunnel à grande vitesse.
	var from := global_position
	var to := from + direction * (step + radius)
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask)
	var caster := get_node_or_null(caster_path)
	if caster:
		query.exclude = [caster.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		global_position = hit.position
		_on_hit(hit.collider)
		return
	global_position = from + direction * step
	_travelled += step
	if _travelled >= max_range or global_position.y < -5.0:
		_finish()


func _on_hit(body: Node) -> void:
	if _done:
		return
	var caster := get_node_or_null(caster_path)
	if explode_on_arrival:
		_explode()
		return
	if body is Creature:
		if body.is_in_group("enemies") and body.health.is_alive():
			SpellCaster.projectile_hit(caster, body, spell_id, slot_level)
		_finish()
	else:
		_finish()  # mur, sol


func _explode() -> void:
	var caster := get_node_or_null(caster_path)
	SpellCaster.explode_at(caster, global_position, spell_id, slot_level)
	_finish()


func _finish() -> void:
	_done = true
	queue_free()

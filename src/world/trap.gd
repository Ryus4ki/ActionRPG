class_name Trap
extends Area3D
## Piège de sol (une cellule) : pointes ou jets de flammes. Se déclenche quand un joueur marche
## dessus (hôte) : jet de sauvegarde de Dextérité DD 12, 2d6 de dégâts (moitié si réussi).
## La plaque est plus étroite que le couloir : on peut la longer en rasant le mur.
## Repérage : en approchant à 6 m, chaque joueur fait un jet de Perception (Sagesse) DD 12 ;
## réussi → le piège se révèle (il brille). Les énigmes de runes peuvent le désamorcer.
## `fire_seq`, `revealed` et `disarmed` sont répliqués.

const COOLDOWN := 3.0
const SAVE_DC := 12
const PERCEPTION_DC := 12
const PERCEPTION_RANGE := 6.0

@export var kind := "spikes"  # "spikes" | "flames"
@export var zone := ""        # identifiant de zone (pour le désamorçage)

var fire_seq := 0:
	set(v):
		var was := fire_seq
		fire_seq = v
		if v != was and is_node_ready():
			_play_effect()
var revealed := false:
	set(v):
		revealed = v
		_refresh()
var disarmed := false:
	set(v):
		disarmed = v
		_refresh()

var _ready_at := 0.0
var _perception_rolled: Dictionary = {}  # peer_id -> true
var _check_timer := 0.0
var _mat: StandardMaterial3D

@onready var plate: MeshInstance3D = $Plate
@onready var spikes: MeshInstance3D = $Spikes
@onready var label: Label3D = $Label


func kind_name() -> String:
	return "Jet de flammes" if kind == "flames" else "Pointes"


func _ready() -> void:
	add_to_group("traps")
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.25, 0.15, 0.1) if kind == "flames" else Color(0.3, 0.3, 0.33)
	plate.material_override = _mat
	if kind == "flames":
		spikes.visible = false
	spikes.position.y = -0.6
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)
	_refresh()


func _process(delta: float) -> void:
	if not multiplayer.is_server() or disarmed:
		return
	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = 0.5
	for p in get_tree().get_nodes_in_group("players"):
		if not (p is PlayerCharacter) or _perception_rolled.has(p.peer_id) or not p.health.is_alive():
			continue
		if p.global_position.distance_to(global_position) > PERCEPTION_RANGE:
			continue
		_perception_rolled[p.peer_id] = true
		var roll: int = Dice.roll_d20() + p.stats.ability_mod("wis") + p.stats.proficiency()
		if roll >= PERCEPTION_DC and not revealed:
			revealed = true
			var game := get_tree().get_first_node_in_group("game")
			if game:
				game.system_message("%s repère un piège (%s) ! Perception %d vs DD %d." % [p.player_name, kind_name().to_lower(), roll, PERCEPTION_DC])


func _on_body_entered(body: Node3D) -> void:
	if disarmed or not (body is PlayerCharacter) or not body.health.is_alive():
		return
	var now := GameData.now()
	if now < _ready_at:
		return
	_ready_at = now + COOLDOWN
	revealed = true
	fire_seq += 1  # le setter joue l'effet ici et chez les clients
	# Dégâts à tous les joueurs présents sur la plaque.
	for b in get_overlapping_bodies():
		if b is PlayerCharacter and b.health.is_alive():
			var dmg_type := "fire" if kind == "flames" else "piercing"
			CombatResolver.save_damage(self, b, "2d6", dmg_type, "dex", SAVE_DC, true, kind_name())


## Hôte : désamorce définitivement (énigme résolue).
func disarm() -> void:
	if multiplayer.is_server():
		disarmed = true


func _play_effect() -> void:
	if kind == "flames":
		var game := get_tree().get_first_node_in_group("game")
		if game and game.has_method("_rpc_vfx"):
			game._rpc_vfx(global_position + Vector3(0, 0.8, 0), 1.6, Color(1.0, 0.5, 0.1))
	else:
		var tw := create_tween()
		tw.tween_property(spikes, "position:y", 0.0, 0.08)
		tw.tween_interval(0.6)
		tw.tween_property(spikes, "position:y", -0.6, 0.4)


func _refresh() -> void:
	if not is_node_ready():
		return
	if disarmed:
		label.visible = true
		label.text = "%s — désamorcé" % kind_name()
		label.modulate = Color(0.6, 0.9, 0.6)
		_mat.emission_enabled = false
		_mat.albedo_color = Color(0.2, 0.22, 0.2)
		plate.position.y = -0.08
	elif revealed:
		label.visible = true
		label.text = "Piège : %s" % kind_name().to_lower()
		label.modulate = Color(1.0, 0.5, 0.3)
		_mat.emission_enabled = true
		_mat.emission = Color(0.9, 0.3, 0.1)
		_mat.emission_energy_multiplier = 0.6
	else:
		label.visible = false
		_mat.emission_enabled = false

class_name Creature
extends CharacterBody3D
## Base commune joueur / monstre : modèle 3D, animations, teinte, gravité, mort.
## Attend les enfants : StatBlock, Health, ModelRoot (Node3D où le .glb est instancié).
##
## Réseau : la simulation (physique, IA, dés) ne tourne que sur l'hôte. Les clients reçoivent
## position / rotation / animation / PV via le MultiplayerSynchronizer de la scène.

const LOOPING_ANIMS := ["idle", "walk", "run", "downed", "block", "block_walk"]
const BLOCK_CONE_DOT := 0.0  # bloque les attaques venant de l'hémisphère avant (±90°)
const GRAVITY := 18.0

@export var model_path := "res://assets/models/sk_humanoid.glb"
@export var model_scale := 1.0
@export var tint := Color.WHITE
@export var faction := "neutral"  # "players" / "enemies"

@onready var stats: StatBlock = $StatBlock
@onready var health: Health = $Health
@onready var model_root: Node3D = $ModelRoot

var model: Node3D
var anim: AnimationPlayer
var skeleton: Skeleton3D
var attachments: Dictionary = {}  # bone -> BoneAttachment3D

## État d'animation répliqué : nom + compteur (pour rejouer deux fois la même animation one-shot).
var anim_name := "":
	set(v):
		anim_name = v
		if not is_server():
			_apply_remote_anim()
var anim_seq := 0:
	set(v):
		anim_seq = v
		if not is_server():
			_apply_remote_anim()
## Garde active (bouclier levé) : voir blocks_attack_from(). Répliqué.
var is_blocking := false

## Conditions temporaires (hôte) : nom -> instant de fin (s). Ex. "restrained" (entravé : immobile).
var conditions: Dictionary = {}
## Vitesse externe (recul d'un coup de massue…), amortie chaque image. Hôte.
var knock_velocity := Vector3.ZERO

var _current_anim := ""
var _one_shot_until := 0.0  # temps (s) jusqu'auquel une animation non bouclée a priorité
var _remote_applied_seq := -1


func _ready() -> void:
	add_to_group(faction)
	_load_model()
	health.died.connect(_on_died)
	health.downed.connect(_on_downed)
	health.revived.connect(_on_revived)
	if not is_server():
		_apply_remote_anim()


## Vrai sur l'hôte (et en jeu hors ligne : pas de pair réseau = autorité locale).
func is_server() -> bool:
	return multiplayer.is_server()


func _load_model() -> void:
	if model_path.begins_with("proc:"):
		# Modèle procédural (animaux) : voir QuadrupedModel.
		model = QuadrupedModel.build(model_path.trim_prefix("proc:"))
	else:
		var scene: PackedScene = load(model_path)
		if scene == null:
			push_error("Modèle introuvable : " + model_path)
			return
		model = scene.instantiate()
	model_root.add_child(model)
	# Blender exporte le personnage face à +Z (Godot) ; notre avant est -Z.
	model.rotation_degrees.y = 180.0
	model.scale = Vector3.ONE * model_scale
	anim = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for child in model.find_children("*", "Skeleton3D", true, false):
		skeleton = child
		break
	if anim:
		for name in anim.get_animation_list():
			if name in LOOPING_ANIMS:
				anim.get_animation(name).loop_mode = Animation.LOOP_LINEAR
		if is_server():
			play_anim("idle")
	if tint != Color.WHITE:
		apply_tint(tint)
	# Ajuste la capsule de collision à l'échelle du modèle.
	var shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape and shape.shape is CapsuleShape3D:
		var cap: CapsuleShape3D = shape.shape.duplicate()
		cap.height = 1.8 * model_scale
		cap.radius = 0.3 * model_scale
		shape.shape = cap
		shape.position.y = cap.height / 2.0


## Teinte chaque matériau du modèle (copie par instance, pour ne pas affecter les autres).
func apply_tint(color: Color) -> void:
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_inst: MeshInstance3D = mi
		for i in mesh_inst.get_surface_override_material_count():
			var base := mesh_inst.mesh.surface_get_material(i)
			if base is BaseMaterial3D:
				var mat: BaseMaterial3D = base.duplicate()
				mat.albedo_color = mat.albedo_color.lerp(color, 0.55)
				mesh_inst.set_surface_override_material(i, mat)


## Attache un modèle d'objet sur un os (ex. "hand.R").
func attach_to_bone(bone: String, item_model_path: String, local_offset := Transform3D.IDENTITY) -> Node3D:
	if skeleton == null:
		return null
	var att: BoneAttachment3D = attachments.get(bone)
	if att == null:
		att = BoneAttachment3D.new()
		att.bone_name = bone
		skeleton.add_child(att)
		attachments[bone] = att
	for c in att.get_children():
		c.queue_free()
	var scene: PackedScene = load(item_model_path)
	if scene == null:
		return null
	var inst: Node3D = scene.instantiate()
	att.add_child(inst)
	inst.transform = local_offset
	return inst


## Joue une animation (hôte). Les animations non bouclées gardent la priorité jusqu'à leur fin.
func play_anim(name: String, blend := 0.15, force := false) -> void:
	if anim == null or not anim.has_animation(name):
		return
	var now := GameData.now()
	if not force and now < _one_shot_until and name in LOOPING_ANIMS:
		return
	if name == _current_anim and name in LOOPING_ANIMS:
		return
	_current_anim = name
	anim.play(name, blend)
	anim_name = name
	if name not in LOOPING_ANIMS:
		anim_seq += 1
		_one_shot_until = now + anim.get_animation(name).length
		Sound.on_anim(self, name)


## Client : applique l'animation reçue de l'hôte.
func _apply_remote_anim() -> void:
	if anim == null or anim_name.is_empty() or not anim.has_animation(anim_name):
		return
	if anim_name == _current_anim and anim_seq == _remote_applied_seq:
		return
	_current_anim = anim_name
	_remote_applied_seq = anim_seq
	anim.play(anim_name, 0.1)
	if anim_name not in LOOPING_ANIMS:
		Sound.on_anim(self, anim_name)


func is_busy() -> bool:
	return GameData.now() < _one_shot_until


## Applique une condition pendant `duration` secondes (hôte).
func apply_condition(cond: String, duration: float) -> void:
	var until := GameData.now() + duration
	conditions[cond] = maxf(conditions.get(cond, 0.0), until)


func has_condition(cond: String) -> bool:
	if not conditions.has(cond):
		return false
	if GameData.now() >= conditions[cond]:
		conditions.erase(cond)
		return false
	return true


## Entravé (toile d'araignée) : ne peut pas se déplacer, peut encore attaquer.
func is_restrained() -> bool:
	return has_condition("restrained")


## Étourdi : ne peut ni agir ni se déplacer.
func is_stunned() -> bool:
	return has_condition("stunned")


## ±2 à l'attaque selon les conditions (affaibli / renforcé).
func condition_attack_bonus() -> int:
	var b := 0
	if has_condition("weakened"):
		b -= 2
	if has_condition("strengthened"):
		b += 2
	return b


## Noms affichables des conditions actives (pour le HUD).
func condition_names() -> Array[String]:
	var out: Array[String] = []
	for c in conditions.keys():
		if has_condition(c):
			out.append(CONDITION_NAMES.get(c, c))
	return out


const CONDITION_NAMES := {"restrained": "Entravé", "stunned": "Étourdi", "poisoned": "Empoisonné",
	"blinded": "Aveuglé", "weakened": "Affaibli", "strengthened": "Renforcé"}
var _poison_tick := 0.0


## Hôte : effets périodiques des conditions (poison : 1d4 toutes les 2 s).
func tick_conditions(delta: float) -> void:
	if has_condition("poisoned") and health.is_alive():
		_poison_tick += delta
		if _poison_tick >= 2.0:
			_poison_tick = 0.0
			var dmg := Dice.roll(1, 4, CombatResolver.rng)
			health.take_damage(dmg, StatBlock.damage_type_from_string("poison"), false, null)
			EventBus.hit_resolved.emit(self, {"attacker": null, "target": self, "attack_name": "Poison", "hit": true,
				"auto_hit": true, "crit": false, "fumble": false, "damage": dmg,
				"damage_type": StatBlock.damage_type_from_string("poison")})
	else:
		_poison_tick = 0.0


## Pousse la créature dans `dir` (horizontal) à `strength` m/s, amorti ensuite.
func apply_knockback(dir: Vector3, strength: float) -> void:
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	knock_velocity = dir.normalized() * strength


## À appeler avant move_and_slide : ajoute le recul à la vitesse et l'amortit.
func apply_knock(delta: float) -> void:
	if knock_velocity.length_squared() < 0.01:
		knock_velocity = Vector3.ZERO
		return
	velocity.x += knock_velocity.x
	velocity.z += knock_velocity.z
	knock_velocity = knock_velocity.move_toward(Vector3.ZERO, 12.0 * delta)


func apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = minf(velocity.y, 0.0)


## Tourne progressivement vers une direction horizontale.
func face_direction(dir: Vector3, delta: float, turn_speed := 12.0) -> void:
	if dir.length_squared() < 0.0001:
		return
	var target_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, minf(1.0, turn_speed * delta))


func forward() -> Vector3:
	return -global_transform.basis.z


## Vrai si la créature est en garde et que l'attaque vient de devant.
func blocks_attack_from(attacker_position: Vector3) -> bool:
	if not is_blocking:
		return false
	var to_attacker := attacker_position - global_position
	to_attacker.y = 0.0
	if to_attacker.length_squared() < 0.0001:
		return true
	return forward().dot(to_attacker.normalized()) >= BLOCK_CONE_DOT


func _on_died() -> void:
	if is_server():
		play_anim("death", 0.1, true)
	_one_shot_until = INF
	EventBus.creature_died.emit(self)
	set_collision_layer_value(2, false)
	set_collision_layer_value(3, false)


func _on_downed() -> void:
	if is_server():
		play_anim("downed", 0.2, true)
	_one_shot_until = INF
	EventBus.creature_downed.emit(self)


func _on_revived() -> void:
	_one_shot_until = 0.0
	if is_server():
		play_anim("revive", 0.1, true)

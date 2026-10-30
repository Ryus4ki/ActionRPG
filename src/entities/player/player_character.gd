class_name PlayerCharacter
extends Creature
## Personnage joueur en vue TPS.
##
## Réseau : chaque machine ne lit QUE les entrées de son propre joueur (`is_local`) et les
## envoie à l'hôte (direction, lacet caméra, garde ; attaque/esquive/interaction en fiable).
## L'hôte simule tous les joueurs ; position, animation, PV sont répliqués vers les clients.
## La caméra reste 100 % locale.

const ATTACK_IMPACT_DELAY := 0.4   # frame 12 / 30 fps de l'animation "attack"
const ATTACK_DURATION := 0.8
const DODGE_DURATION := 0.35
const DODGE_SPEED := 9.0
const CAMERA_OFFSET := Vector3(0, 1.5, 0)
const STICK_LOOK_SPEED := 2.6  # rad/s à fond de stick
const REVIVE_RANGE := 2.5
const CAST_RELEASE_DELAY := 0.47   # frame 14 / 30 fps de l'animation "cast"
const CAST_HEIGHT := 1.25  # hauteur de départ des sorts (poitrine)
## Seul (aucun coéquipier vivant) : un joueur à terre se relève après ce délai.
const SOLO_REVIVE_DELAY := 5.0
## Transformations d'attache calculées depuis les poses réelles (tests/calc_attach.gd) :
## épée : poignée centrée dans la main droite, lame vers l'avant relevée de 30° au repos.
static var WEAPON_GRIP := Transform3D(Basis.from_euler(Vector3(deg_to_rad(-57.11), deg_to_rad(167.44), deg_to_rad(-165.14))), Vector3(0.007, 0.097, 0.076))
## bouclier : sanglé sur l'avant-bras gauche, droit et face à l'ennemi en position de garde.
static var SHIELD_STRAP := Transform3D(Basis.from_euler(Vector3(deg_to_rad(40.44), deg_to_rad(-176.64), deg_to_rad(42.06))), Vector3(0.005, 0.208, 0.091))

@export var class_id := "fighter"
@export var race_id := "human"
@export var peer_id := 1
@export var player_name := "Aventurier"

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var melee_area: Area3D = $MeleeArea
@onready var spell_book: SpellBook = $SpellBook
@onready var inventory: Inventory = $Inventory

var mouse_sensitivity := 0.0025
var pitch_min := deg_to_rad(-60)
var pitch_max := deg_to_rad(35)

var weapon: Dictionary = {}
var has_shield := false
var is_local := true  # le joueur contrôlé sur cette machine (caméra + souris)

# Entrées courantes (sur l'hôte : reçues du client ou lues localement)
var _input_dir := Vector2.ZERO
var _cam_yaw := 0.0
var _cam_pitch := 0.0
var _want_block := false
var _attack_cooldown := 0.0
var _dodge_time := 0.0
var _dodge_dir := Vector3.ZERO
var _last_sent_input := Vector2.ZERO
var _last_sent_yaw := 0.0


func _ready() -> void:
	faction = "players"
	is_local = peer_id == multiplayer.get_unique_id()
	super()
	health.can_be_downed = true
	health.downed.connect(_on_player_downed)
	_setup_character()
	# Le pivot de caméra ne doit PAS hériter de la rotation du corps : on le détache
	# de la hiérarchie (top_level) et on le fait suivre la position du joueur à chaque image.
	camera_pivot.top_level = true
	camera_pivot.global_position = global_position + CAMERA_OFFSET
	camera_pivot.rotation = Vector3(deg_to_rad(-15.0), rotation.y, 0.0)
	_cam_yaw = rotation.y
	if is_local:
		camera.current = true
		if DisplayServer.get_name() != "headless":
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		EventBus.local_player_ready.emit(self)


func _process(delta: float) -> void:
	camera_pivot.global_position = global_position + CAMERA_OFFSET
	if is_local:
		var look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		if look.length_squared() > 0.0:
			camera_pivot.rotation.y -= look.x * STICK_LOOK_SPEED * delta
			camera_pivot.rotation.x = clampf(camera_pivot.rotation.x - look.y * STICK_LOOK_SPEED * 0.6 * delta, pitch_min, pitch_max)


func _setup_character() -> void:
	stats.setup_from_class(class_id, race_id)
	if not player_name.is_empty():
		stats.display_name = "%s (%s)" % [player_name, stats.display_name]
	var cls: Dictionary = GameData.player_class(class_id)
	inventory.changed.connect(_apply_equipment)
	if is_server():
		# Équipement de départ : tout dans le sac, puis on équipe arme / armure / bouclier.
		for item_id in cls.get("starting_equipment", []):
			inventory.add({"id": item_id, "qty": 1, "rarity": "common"})
		for slot in ["weapon", "armor", "shield"]:
			for i in inventory.items.size():
				if Inventory.item_data(inventory.items[i]).get("type", "") == slot:
					inventory.equip(i)
					break
	_apply_equipment()
	if cls.has("spellcasting_ability"):
		spell_book.setup(cls, stats.level)
		stats.level_changed.connect(func(lvl: int):
			if is_server():
				spell_book.refresh_for_level(cls, lvl, true)
				health.max_hp = stats.max_hp()
				health.heal(health.max_hp))
	if is_server():
		health.setup(stats.max_hp())


## Applique l'équipement (stats + modèles 3D). Appelé sur toutes les machines à chaque changement.
func _apply_equipment() -> void:
	var eq := inventory.equipped
	# Arme
	if eq.has("weapon"):
		var data := Inventory.item_data(eq["weapon"]).duplicate()
		data["magic_bonus"] = Inventory.magic_bonus(eq["weapon"])
		data["name"] = Inventory.display_name(eq["weapon"])
		weapon = data
		attach_to_bone("hand.R", "res://assets/models/%s.glb" % data.get("model", "sm_sword"), WEAPON_GRIP)
	else:
		weapon = {"name": "Poings", "damage": "1d1", "damage_type": "bludgeoning", "ability": "str"}
		_clear_bone("hand.R")
	# Armure
	stats.set_armor(Inventory.item_data(eq["armor"]) if eq.has("armor") else {})
	# Bouclier
	has_shield = eq.has("shield")
	stats.set_shield(Inventory.item_data(eq["shield"]) if has_shield else {})
	if has_shield:
		attach_to_bone("forearm.L", "res://assets/models/sm_shield.glb", SHIELD_STRAP)
	else:
		_clear_bone("forearm.L")
		if is_blocking:
			set_blocking(false)
	# Bonus magiques défensifs
	stats.equipment_ac_bonus = (Inventory.magic_bonus(eq["armor"]) if eq.has("armor") else 0) \
		+ (Inventory.magic_bonus(eq["shield"]) if eq.has("shield") else 0)


func _clear_bone(bone: String) -> void:
	var att: Node = attachments.get(bone)
	if att:
		for c in att.get_children():
			c.queue_free()


## Hôte : un objet vient d'être ramassé par ce joueur → prévenir sa machine.
func on_item_picked(entry: Dictionary) -> void:
	if peer_id == multiplayer.get_unique_id():
		EventBus.item_picked.emit(entry)
	else:
		_rpc_picked.rpc_id(peer_id, entry)


@rpc("authority", "reliable")
func _rpc_picked(entry: Dictionary) -> void:
	EventBus.item_picked.emit(entry)


# ------------------------------------------------------------------ entrées locales

func _unhandled_input(event: InputEvent) -> void:
	if not is_local:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotation.y -= event.relative.x * mouse_sensitivity
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x - event.relative.y * mouse_sensitivity, pitch_min, pitch_max)
	elif event is InputEventMouseButton and event.pressed and spell_book.is_caster() \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		request_action("spell_next" if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else "spell_prev")
	elif event is InputEventKey and event.pressed and not event.echo and spell_book.is_caster() \
			and event.physical_keycode >= KEY_1 and event.physical_keycode <= KEY_9:
		request_action("spell_%d" % (event.physical_keycode - KEY_1))
	elif event.is_action_pressed("menu"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("debug_god"):
		request_action("debug_god")
	elif event.is_action_pressed("debug_heal"):
		request_action("debug_heal")
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Envoie une action ponctuelle à l'hôte (ou l'exécute directement si on est l'hôte).
func request_action(action: String) -> void:
	if is_server():
		_do_action(action)
	else:
		_rpc_action.rpc_id(1, action)


@rpc("any_peer", "reliable")
func _rpc_action(action: String) -> void:
	if is_server() and multiplayer.get_remote_sender_id() == peer_id:
		_do_action(action)


@rpc("any_peer", "unreliable_ordered")
func _rpc_input(dir: Vector2, cam_yaw: float, cam_pitch: float, block: bool) -> void:
	if is_server() and multiplayer.get_remote_sender_id() == peer_id:
		_input_dir = dir.limit_length(1.0)
		_cam_yaw = cam_yaw
		_cam_pitch = cam_pitch
		_want_block = block


func _do_action(action: String) -> void:
	match action:
		"attack":
			try_attack()
		"dodge":
			try_dodge()
		"interact":
			try_interact()
		"debug_god":
			health.invulnerable = not health.invulnerable
			print("[debug] invulnérabilité de %s : %s" % [stats.display_name, health.invulnerable])
		"debug_heal":
			health.heal(health.max_hp)
			spell_book.restore_all()
		"cast":
			try_cast()
		"use_potion":
			use_potion()
		"spell_next":
			spell_book.select_next(1)
		"spell_prev":
			spell_book.select_next(-1)
		_:
			if action.begins_with("spell_"):
				spell_book.select(int(action.trim_prefix("spell_")))
			elif action.begins_with("equip:"):
				inventory.equip(int(action.trim_prefix("equip:")))
			elif action.begins_with("unequip:"):
				inventory.unequip(action.trim_prefix("unequip:"))
			elif action.begins_with("use:"):
				use_item(int(action.trim_prefix("use:")))


func _gather_local_input() -> void:
	# Actions ponctuelles sondées ici : fonctionne pareil pour clavier, souris et manette
	# (une gâchette analogique ne déclenche qu'une fois par pression).
	if Input.is_action_just_pressed("attack"):
		request_action("attack")
	if Input.is_action_just_pressed("secondary") and spell_book.is_caster():
		request_action("cast")
	if Input.is_action_just_pressed("dodge"):
		request_action("dodge")
	if Input.is_action_just_pressed("interact"):
		request_action("interact")
	if Input.is_action_just_pressed("use_potion"):
		request_action("use_potion")
	if spell_book.is_caster():
		if Input.is_action_just_pressed("spell_prev"):
			request_action("spell_prev")
		if Input.is_action_just_pressed("spell_next"):
			request_action("spell_next")
	var dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var yaw := camera_pivot.global_rotation.y
	var pitch := camera_pivot.rotation.x
	var block := has_shield and Input.is_action_pressed("secondary")
	if is_server():
		_input_dir = dir
		_cam_yaw = yaw
		_cam_pitch = pitch
		_want_block = block
	else:
		# Envoi à chaque tick physique (léger : 3 floats + 1 bool, non fiable).
		_rpc_input.rpc_id(1, dir, yaw, pitch, block)


# ------------------------------------------------------------------ simulation (hôte)

func _physics_process(delta: float) -> void:
	if is_local:
		_gather_local_input()
	if not is_server():
		return

	apply_gravity(delta)
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)

	if not health.is_alive():
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	set_blocking(_want_block)

	_dodge_time = maxf(0.0, _dodge_time - delta)
	if _dodge_time > 0.0:
		velocity.x = _dodge_dir.x * DODGE_SPEED
		velocity.z = _dodge_dir.z * DODGE_SPEED
	elif is_busy():
		# Pendant une attaque on ne se déplace pas.
		velocity.x = move_toward(velocity.x, 0.0, 30.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 30.0 * delta)
	elif is_blocking:
		# En garde : on marche, et on reste face à la caméra pour présenter le bouclier.
		var dir := _camera_relative_direction(_input_dir)
		var speed := stats.move_speed_mps(false)
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		face_direction(camera_forward(), delta)
		play_anim("block_walk" if dir.length_squared() > 0.01 else "block")
	else:
		var dir := _camera_relative_direction(_input_dir)
		var speed := stats.move_speed_mps(true)
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
		if dir.length_squared() > 0.01:
			face_direction(dir, delta)
			play_anim("run")
		else:
			play_anim("idle")
	move_and_slide()


func set_blocking(value: bool) -> void:
	if value == is_blocking:
		return
	if value and (is_busy() or not health.is_alive()):
		return
	is_blocking = value
	if not value:
		play_anim("idle", 0.15, true)
		_one_shot_until = 0.0


func _camera_relative_direction(input: Vector2) -> Vector3:
	if input.length_squared() < 0.01:
		return Vector3.ZERO
	var fwd := Vector3(-sin(_cam_yaw), 0, -cos(_cam_yaw))
	var right := Vector3(cos(_cam_yaw), 0, -sin(_cam_yaw))
	return (fwd * -input.y + right * input.x).normalized()


## Direction horizontale vers laquelle regarde la caméra de ce joueur (connue de l'hôte).
func camera_forward() -> Vector3:
	return Vector3(-sin(_cam_yaw), 0, -cos(_cam_yaw))


## Direction de visée complète (lacet + tangage de la caméra).
func aim_direction() -> Vector3:
	return (Basis.from_euler(Vector3(_cam_pitch, _cam_yaw, 0)) * Vector3.FORWARD).normalized()


func try_cast() -> bool:
	if is_busy() or is_blocking or not health.is_alive() or not spell_book.is_caster():
		return false
	var spell_id := spell_book.selected_spell_id()
	if not spell_book.can_cast(spell_id):
		return false
	rotation.y = atan2(-camera_forward().x, -camera_forward().z)
	play_anim("cast", 0.05, true)
	get_tree().create_timer(CAST_RELEASE_DELAY).timeout.connect(func():
		if is_instance_valid(self) and health.is_alive():
			var eye := global_position + Vector3(0, CAST_HEIGHT, 0)
			SpellCaster.cast(self, spell_id, eye, aim_direction()))
	return true


func try_attack() -> bool:
	if is_busy() or is_blocking or _attack_cooldown > 0.0 or not health.is_alive():
		return false
	# On frappe dans la direction de la caméra.
	rotation.y = atan2(-camera_forward().x, -camera_forward().z)
	play_anim("attack", 0.05, true)
	_attack_cooldown = ATTACK_DURATION / weapon.get("attack_speed", 1.0)
	get_tree().create_timer(ATTACK_IMPACT_DELAY).timeout.connect(_resolve_melee_hit)
	return true


func _resolve_melee_hit() -> void:
	if not health.is_alive():
		return
	var targets: Array = []
	for body in melee_area.get_overlapping_bodies():
		if body is Creature and body.is_in_group("enemies") and body.health.is_alive():
			targets.append(body)
	if targets.is_empty():
		return
	targets.sort_custom(func(a, b): return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position))
	CombatResolver.weapon_attack(self, targets[0], weapon)


func try_dodge() -> bool:
	if is_busy() or _dodge_time > 0.0 or not health.is_alive():
		return false
	set_blocking(false)
	var dir := _camera_relative_direction(_input_dir)
	if dir.length_squared() < 0.01:
		dir = -forward()  # recul par défaut, sans se retourner
	else:
		face_direction(dir, 1.0, 100.0)
	_dodge_dir = dir
	_dodge_time = DODGE_DURATION
	return true


## E : relève un coéquipier à terre à portée, sinon ouvre un coffre proche.
func try_interact() -> bool:
	if not health.is_alive() or is_busy():
		return false
	for p in get_tree().get_nodes_in_group("players"):
		if p != self and p is PlayerCharacter and p.health.is_downed \
				and global_position.distance_to(p.global_position) <= REVIVE_RANGE:
			p.health.revive(0.25)
			play_anim("cast", 0.1, true)
			return true
	for c in get_tree().get_nodes_in_group("chests"):
		if c.has_method("open") and not c.opened and global_position.distance_to(c.global_position) <= REVIVE_RANGE:
			c.open(self)
			play_anim("cast", 0.1, true)
			return true
	return false


## Boit la meilleure potion de soins disponible.
func use_potion() -> bool:
	if not health.is_alive() or health.hp >= health.max_hp:
		return false
	for pid in ["potion_greater_healing", "potion_healing"]:
		var idx := inventory.find_index(pid)
		if idx >= 0:
			return use_item(idx)
	return false


## Utilise un consommable de l'inventaire (hôte).
func use_item(index: int) -> bool:
	if index < 0 or index >= inventory.items.size() or not health.is_alive():
		return false
	var entry: Dictionary = inventory.items[index]
	var data := Inventory.item_data(entry)
	if data.get("type", "") != "consumable":
		return false
	var effect: Dictionary = data.get("effect", {})
	match effect.get("type", ""):
		"heal":
			if health.hp >= health.max_hp:
				return false
			var amount := Dice.roll_expr(str(effect.get("amount", "2d4+2")), CombatResolver.rng)
			inventory.remove_at(index, 1)
			health.heal(amount)
			play_anim("cast", 0.1, true)
			EventBus.hit_resolved.emit(self, {"attacker": self, "target": self, "attack_name": data.get("name", "Potion"),
				"hit": true, "heal": amount, "damage": 0, "damage_type": 0})
			return true
	return false


func _on_player_downed() -> void:
	if not is_server():
		return
	# Aucun coéquipier vivant pour nous relever : on se relève seul.
	var others := 0
	for p in get_tree().get_nodes_in_group("players"):
		if p != self and p is Creature and p.health.is_alive():
			others += 1
	if others == 0:
		get_tree().create_timer(SOLO_REVIVE_DELAY).timeout.connect(func():
			if is_instance_valid(self) and health.is_downed:
				health.revive(0.5))

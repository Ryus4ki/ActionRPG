class_name PlayerCharacter
extends Creature
## Personnage joueur en vue TPS.
##
## Réseau : chaque machine ne lit QUE les entrées de son propre joueur (`is_local`) et les
## envoie à l'hôte (direction et caméra en continu ; actions ponctuelles en fiable).
## L'hôte simule tous les joueurs ; position, animation, PV, état de combat sont répliqués.
## La caméra reste 100 % locale. Le combat (cible, auto-attaque, TP, sorts…) est dans PlayerCombat.

const DODGE_DURATION := 0.35
const DODGE_SPEED := 9.0
const CAMERA_OFFSET := Vector3(0, 1.5, 0)
const STICK_LOOK_SPEED := 2.6  # rad/s à fond de stick
const TURN_SPEED := 2.4        # rad/s : pavé 4/6 (façon FFXI : le personnage tourne, la caméra suit)
const ZOOM_MIN := 0.0          # 0 = première personne
const ZOOM_MAX := 9.0
const ZOOM_DEFAULT := 4.5
const REVIVE_RANGE := 2.5
const CAST_HEIGHT := 1.25  # hauteur de départ des sorts (poitrine)
## Seul (aucun coéquipier vivant) : un joueur à terre se relève après ce délai.
const SOLO_REVIVE_DELAY := 5.0
## Transformations d'attache calculées depuis les poses réelles (tests/calc_attach.gd) :
## épée : poignée centrée dans la main droite, lame vers l'avant relevée de 30° au repos.
static var WEAPON_GRIP := Transform3D(Basis.from_euler(Vector3(deg_to_rad(-57.11), deg_to_rad(167.44), deg_to_rad(-165.14))), Vector3(0.007, 0.097, 0.076))
## bouclier : sanglé sur l'avant-bras gauche, droit et face à l'ennemi en position de garde.
static var SHIELD_STRAP := Transform3D(Basis.from_euler(Vector3(deg_to_rad(40.44), deg_to_rad(-176.64), deg_to_rad(42.06))), Vector3(0.005, 0.208, 0.091))

## Job ACTUEL (façon FFXI : il suit l'arme équipée). Répliqué ; le setter met à jour la feuille sur chaque machine.
@export var class_id := "fighter":
	set(v):
		var changed := v != class_id
		class_id = v
		if changed and is_node_ready():
			stats.apply_job(v)
			_update_display_name()
			job_changed.emit(v)
## Classe choisie à la création : fixe les caractéristiques de départ (et l'équipement de départ).
@export var start_class := ""
## Niveau et XP de chaque job : {"fighter": {"level": 3, "xp": 900}, "wizard": {...}}. Répliqué (feuille de perso).
var jobs: Dictionary = {}
var _switching_job := false
signal job_changed(job: String)
@export var race_id := "human"
@export var peer_id := 1
@export var player_name := "Aventurier"

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var spell_book: SpellBook = $SpellBook
@onready var inventory: Inventory = $Inventory
@onready var combat: PlayerCombat = $Combat
@onready var quest_log: QuestLog = $QuestLog

var mouse_sensitivity := 0.0025
var pitch_min := deg_to_rad(-60)
var pitch_max := deg_to_rad(35)

var weapon: Dictionary = {}
var has_shield := false
var is_local := true  # le joueur contrôlé sur cette machine (caméra + souris)
var menu_open := false   # menu de commandes ou fenêtre ouverte : les raccourcis qui servent au menu sont ignorés
var ui_blocked := false  # fenêtre modale (dialogue, menu système, options) : le personnage ne bouge plus
## Sélection locale hors combat : PNJ ou autre joueur (Tab hors combat). Les ennemis passent par combat.target.
var selection: Node3D = null
## Progression de l'aventure (hôte) : "quest:<id>", "boss:<monstre>", "zone:<scène>". Celle de l'hôte fait foi
## pour le monde (lignes de zone avec « requires ») ; celle de chaque joueur est sauvegardée avec son personnage.
var progress: Array = []
const CHEST_RANGE := 4.0
const TALK_RANGE := 4.0
var _turning := false   # pavé 4/6 enfoncé (le personnage pivote avec la caméra)
var _mouse_look := false          # clic droit maintenu
var _mouse_look_origin := Vector2.ZERO
var _walking := false   # marche (pavé / ou Maj) au lieu de courir
var _zoom := ZOOM_DEFAULT
var _first_person := false

# Entrées courantes (sur l'hôte : reçues du client ou lues localement)
var _input_dir := Vector2.ZERO
var _cam_yaw := 0.0
var _cam_pitch := 0.0
var _dodge_time := 0.0
var _dodge_dir := Vector3.ZERO
var _last_sent_input := Vector2.ZERO
var _last_sent_yaw := 0.0
## Repos façon FFXI (/heal) : hors combat, assis, on régénère PV (et emplacements de sorts) par paliers.
var resting := false           # vrai sur l'hôte ET chez le propriétaire (RPC), pour le HUD
var _rest_time := 0.0
var _rest_tick_left := 0.0
var _rest_ticks := 0
var _rest_slot_left := 0.0


func _ready() -> void:
	faction = "players"
	is_local = peer_id == multiplayer.get_unique_id()
	super()
	health.can_be_downed = true
	health.downed.connect(_on_player_downed)
	health.downed.connect(func(): if is_server(): combat.disengage(); combat.cancel_cast())
	health.damaged.connect(func(_a: int, _t: int, _c: bool, _s: Node):
		if is_server() and resting:
			stop_rest("Vous êtes attaqué : vous vous levez !"))
	health.downed.connect(func(): if is_server(): stop_rest(""))
	_setup_character()
	combat.setup(self)
	# Le pivot de caméra ne doit PAS hériter de la rotation du corps : on le détache
	# de la hiérarchie (top_level) et on le fait suivre la position du joueur à chaque image.
	camera_pivot.top_level = true
	camera_pivot.global_position = global_position + CAMERA_OFFSET
	camera_pivot.rotation = Vector3(deg_to_rad(-15.0), rotation.y, 0.0)
	_cam_yaw = rotation.y
	if is_local:
		camera.current = true
		camera.fov = Settings.fov
		Settings.changed.connect(_on_settings_changed)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # curseur visible ; clic droit maintenu = caméra
		EventBus.local_player_ready.emit(self)


func _process(delta: float) -> void:
	camera_pivot.global_position = global_position + CAMERA_OFFSET
	if is_local and not ui_blocked:
		# A / E, flèches (hors menu) ou stick droit : caméra libre.
		var look := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		if menu_open:
			# Menu de commandes ouvert : ↑↓ (flèches) servent au menu ; A / E et le stick droit tournent encore.
			look = Vector2(Input.get_axis("look_left", "look_right"), 0.0) if not _arrow_pressed() else Vector2.ZERO
		if look.length_squared() > 0.0:
			var speed := STICK_LOOK_SPEED * Settings.stick_sensitivity
			if Settings.invert_y:
				look.y = -look.y
			camera_pivot.rotation.y -= look.x * speed * delta
			camera_pivot.rotation.x = clampf(camera_pivot.rotation.x - look.y * speed * 0.6 * delta, pitch_min, pitch_max)
		# Pavé 4/6 : on pivote (la caméra reste derrière le personnage).
		var turn := Input.get_axis("turn_left", "turn_right")
		if absf(turn) > 0.01:
			camera_pivot.rotation.y -= turn * TURN_SPEED * delta
		# Zoom (Pg↑/Pg↓, pavé 9/3) et vue 1re/3e personne (pavé 5, V).
		if Input.is_action_pressed("zoom_in"):
			_set_zoom(_zoom - 4.0 * delta)
		if Input.is_action_pressed("zoom_out"):
			_set_zoom(_zoom + 4.0 * delta)
		if Input.is_action_just_pressed("view_toggle"):
			_first_person = not _first_person
			_set_zoom(ZOOM_MIN if _first_person else ZOOM_DEFAULT)
		if Input.is_action_just_pressed("walk_toggle"):
			_walking = not _walking
	if is_local and model:
		# En première personne on cache son propre modèle.
		model.visible = _zoom > 0.6


func _arrow_pressed() -> bool:
	return Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_DOWN)


func _on_settings_changed() -> void:
	camera.fov = Settings.fov


func _set_zoom(value: float) -> void:
	_zoom = clampf(value, ZOOM_MIN, ZOOM_MAX)
	_first_person = _zoom <= 0.05
	spring_arm.spring_length = _zoom


func _setup_character() -> void:
	if start_class == "":
		start_class = class_id
	stats.setup_from_class(start_class, race_id)
	stats.apply_job(class_id)
	_update_display_name()
	var cls: Dictionary = GameData.player_class(start_class)
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
	stats.level_changed.connect(_on_level_changed)
	if is_server():
		_apply_job_spells()
		jobs[class_id] = {"level": stats.level, "xp": stats.xp}
		health.setup(stats.max_hp())


func _update_display_name() -> void:
	var race: Dictionary = GameData.race(race_id)
	var job: Dictionary = GameData.player_class(class_id)
	var base := "%s %s" % [race.get("name", ""), job.get("name", "")]
	stats.display_name = "%s (%s)" % [player_name, base] if not player_name.is_empty() else base


## Montée de niveau du job actuel (hôte) : sorts, PV pleins. Ignoré pendant un changement de job.
func _on_level_changed(lvl: int) -> void:
	if not is_server() or _switching_job:
		return
	jobs[class_id] = {"level": lvl, "xp": stats.xp}
	jobs = jobs.duplicate(true)  # réplication
	_apply_job_spells()
	health.max_hp = stats.max_hp()
	health.heal(health.max_hp)


## Hôte : sorts et emplacements du job actuel (aucun pour un guerrier).
func _apply_job_spells() -> void:
	var cls: Dictionary = GameData.player_class(class_id)
	if cls.has("spellcasting_ability"):
		spell_book.setup(cls, stats.level)
	else:
		spell_book.known = [] as Array[String]
		spell_book.max_slots = {}
		spell_book.slots = {}


## Job lié à une entrée d'inventaire (armes : champ "job" d'items.json), "" sinon.
static func job_for_item(entry: Dictionary) -> String:
	return str(Inventory.item_data(entry).get("job", ""))


## Hôte : change de job (niveau et XP propres à chaque job, PV conservés en proportion).
func change_job(job: String) -> bool:
	if job == class_id or GameData.player_class(job).is_empty():
		return false
	jobs[class_id] = {"level": stats.level, "xp": stats.xp}
	var ratio := float(health.hp) / float(maxi(health.max_hp, 1))
	var j: Dictionary = jobs.get(job, {"level": 1, "xp": 0})
	_switching_job = true
	class_id = job
	stats.xp = int(j.get("xp", 0))
	stats.level = maxi(1, int(j.get("level", 1)))
	_switching_job = false
	jobs[job] = {"level": stats.level, "xp": stats.xp}
	jobs = jobs.duplicate(true)
	_apply_job_spells()
	health.max_hp = stats.max_hp()
	health.hp = clampi(roundi(ratio * health.max_hp), 1, health.max_hp)
	combat.tp = 0
	notify_owner("Vous êtes maintenant %s niveau %d." % [GameData.player_class(job).get("name", job), stats.level])
	return true


## Hôte : équiper un objet ; une arme d'un autre job change de job (hors combat seulement).
func equip_index(index: int) -> bool:
	if index < 0 or index >= inventory.items.size():
		return false
	var job := job_for_item(inventory.items[index])
	if job != "" and job != class_id:
		if combat.engaged or combat.is_casting() or is_hunted():
			notify_owner("Impossible de changer de job en combat : fuyez ou terminez le combat d'abord.")
			return false
		inventory.equip(index)
		change_job(job)
		return true
	inventory.equip(index)
	return true


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
	if event is InputEventMouseMotion and _mouse_look:
		var sens := mouse_sensitivity * Settings.mouse_sensitivity
		var inv_y := -1.0 if Settings.invert_y else 1.0
		camera_pivot.rotation.y -= event.relative.x * sens
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x - event.relative.y * sens * inv_y, pitch_min, pitch_max)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		# Clic droit maintenu : la caméra suit la souris (curseur caché le temps du geste).
		if event.pressed and not _mouse_look:
			_mouse_look = true
			_mouse_look_origin = get_viewport().get_mouse_position()
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif not event.pressed and _mouse_look:
			_mouse_look = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_viewport().warp_mouse(_mouse_look_origin)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not ui_blocked and not _mouse_look:
		# Clic gauche dans le monde : cibler l'ennemi sous le curseur ; un second clic sur la cible engage.
		var e := _enemy_under_mouse(event.position)
		if e:
			if combat.target() == e:
				request_action("engage")
			else:
				set_target_local(e)
	elif event.is_action_pressed("debug_god"):
		request_action("debug_god")
	elif event.is_action_pressed("debug_heal"):
		request_action("debug_heal")


## Lancer de rayon depuis la caméra à travers le curseur : ennemi vivant touché, ou null.
func _enemy_under_mouse(screen_pos: Vector2) -> Creature:
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 60.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 4)  # couche ennemis
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit and hit.collider is Creature and hit.collider.is_in_group("enemies") and hit.collider.health.is_alive():
		return hit.collider
	return null


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
func _rpc_input(dir: Vector2, cam_yaw: float, cam_pitch: float, turning: bool = false) -> void:
	if is_server() and multiplayer.get_remote_sender_id() == peer_id:
		_input_dir = dir.limit_length(1.0)
		_cam_yaw = cam_yaw
		_cam_pitch = cam_pitch
		_turning = turning


func _do_action(action: String) -> void:
	# Toute action (sauf cibler / se reposer) fait se lever.
	if resting and action != "rest" and not action.begins_with("target:"):
		stop_rest("")
	match action:
		"rest":
			if resting:
				stop_rest("Vous vous levez.")
			else:
				start_rest()
		"engage":
			combat.engage()
		"disengage":
			combat.disengage()
		"flee":
			combat.flee()
		"weapon_skill":
			combat.use_weapon_skill()
		"cancel_cast":
			combat.cancel_cast("annulée")
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
		"use_potion":
			use_potion()
		_:
			if action.begins_with("target:"):
				var path := action.trim_prefix("target:")
				combat.set_target(NodePath(path) if path != "" else NodePath())
			elif action.begins_with("cast:"):
				combat.start_cast(action.trim_prefix("cast:"))
			elif action.begins_with("ability:"):
				combat.use_ability(action.trim_prefix("ability:"))
			elif action.begins_with("equip:"):
				equip_index(int(action.trim_prefix("equip:")))
			elif action.begins_with("unequip:"):
				inventory.unequip(action.trim_prefix("unequip:"))
			elif action.begins_with("use:"):
				use_item(int(action.trim_prefix("use:")))
			elif action.begins_with("buy:"):
				buy_item(action.trim_prefix("buy:"))
			elif action.begins_with("sell:"):
				sell_item(int(action.trim_prefix("sell:")))
			elif action.begins_with("quest_accept:"):
				quest_accept(action.trim_prefix("quest_accept:"))
			elif action.begins_with("quest_turnin:"):
				quest_turn_in(action.trim_prefix("quest_turnin:"))
			elif action.begins_with("talk:"):
				talk_to(action.trim_prefix("talk:"))
			elif action.begins_with("give_item:"):
				var parts := action.trim_prefix("give_item:").split("|")
				if parts.size() == 2:
					give_item(int(parts[0]), parts[1])
			elif action.begins_with("give_gold:"):
				var parts := action.trim_prefix("give_gold:").split("|")
				if parts.size() == 2:
					give_gold(int(parts[0]), parts[1])
			elif action.begins_with("revive:"):
				revive_player(action.trim_prefix("revive:"))
			elif action.begins_with("chest_deposit:"):
				chest_deposit(int(action.trim_prefix("chest_deposit:")))
			elif action.begins_with("chest_withdraw:"):
				var entry = JSON.parse_string(action.trim_prefix("chest_withdraw:"))
				if entry is Dictionary:
					chest_withdraw(Characters._intify(entry))
			elif action.begins_with("chest_deposit_gold:"):
				chest_deposit_gold(int(action.trim_prefix("chest_deposit_gold:")))
			elif action.begins_with("chest_withdraw_gold:"):
				chest_withdraw_gold(int(action.trim_prefix("chest_withdraw_gold:")))


func _gather_local_input() -> void:
	# Actions ponctuelles sondées ici : fonctionne pareil pour clavier, souris et manette.
	# Le menu de commandes reste ouvert en combat : on garde les raccourcis qui ne lui servent pas.
	if not ui_blocked:
		if Input.is_action_just_pressed("attack"):
			attack_shortcut()
		if Input.is_action_just_pressed("secondary") and has_shield:
			request_action("ability:guard")  # L2 à la manette (le clic droit est réservé à la caméra)
		if Input.is_action_just_pressed("target_next"):
			cycle_target(1)
		if Input.is_action_just_pressed("target_prev"):
			cycle_target(-1)
		if Input.is_action_just_pressed("target_nearest"):
			var list := target_candidates()
			if not list.is_empty():
				set_target_local(list[0])
		if Input.is_action_just_pressed("dodge"):
			request_action("dodge")
		if Input.is_action_just_pressed("interact") and not menu_open:
			context_action()
		if InputMap.has_action("rest") and Input.is_action_just_pressed("rest"):
			request_action("rest")
	if Input.is_action_just_pressed("use_potion") and not ui_blocked:
		request_action("use_potion")
	var dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# Clic gauche + clic droit maintenus (façon MMO) : on avance, la souris dirige la caméra et donc la course.
	if _mouse_look and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		dir.y = -1.0
	if ui_blocked:
		dir = Vector2.ZERO
	var yaw := camera_pivot.global_rotation.y
	var pitch := camera_pivot.rotation.x
	_turning = absf(Input.get_axis("turn_left", "turn_right")) > 0.01 and not ui_blocked
	if _walking:
		dir *= 0.45  # la vitesse suit la longueur du vecteur (voir _physics_process)
	if is_server():
		_input_dir = dir
		_cam_yaw = yaw
		_cam_pitch = pitch
	else:
		# Envoi à chaque tick physique (léger : 3 floats, non fiable).
		_rpc_input.rpc_id(1, dir, yaw, pitch, _turning)


# ------------------------------------------------------------------ ciblage (local)

## Ennemis vivants ciblables, triés par angle avec la caméra puis distance.
func target_candidates() -> Array:
	var out: Array = []
	var fwd := camera_forward()
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Creature) or not e.health.is_alive():
			continue
		var to: Vector3 = e.global_position - global_position
		to.y = 0.0
		var d := to.length()
		if d > PlayerCombat.TARGET_RANGE or d < 0.01:
			continue
		out.append(e)
	out.sort_custom(func(a, b):
		var ta: Vector3 = a.global_position - global_position
		var tb: Vector3 = b.global_position - global_position
		ta.y = 0.0
		tb.y = 0.0
		var sa := -fwd.dot(ta.normalized()) + ta.length() / PlayerCombat.TARGET_RANGE * 0.5
		var sb := -fwd.dot(tb.normalized()) + tb.length() / PlayerCombat.TARGET_RANGE * 0.5
		return sa < sb)
	return out


## Hors combat : ennemis, PNJ et autres joueurs proches, triés comme les ennemis (devant soi d'abord).
func selectable_candidates() -> Array:
	var out: Array = target_candidates()
	var fwd := camera_forward()
	var extra: Array = []
	for n in get_tree().get_nodes_in_group("npcs") + get_tree().get_nodes_in_group("players"):
		if n == self or not (n is Node3D):
			continue
		var to: Vector3 = (n as Node3D).global_position - global_position
		to.y = 0.0
		if to.length() <= PlayerCombat.TARGET_RANGE * 0.6:
			extra.append(n)
	extra.sort_custom(func(a, b):
		var ta: Vector3 = a.global_position - global_position
		var tb: Vector3 = b.global_position - global_position
		ta.y = 0.0
		tb.y = 0.0
		return -fwd.dot(ta.normalized()) + ta.length() / 18.0 < -fwd.dot(tb.normalized()) + tb.length() / 18.0)
	return out + extra


## Ce qui est sélectionné : la cible de combat si elle existe, sinon le PNJ / joueur choisi.
func current_selection() -> Node3D:
	var t := combat.target()
	if t and is_instance_valid(t):
		return t
	if selection and is_instance_valid(selection) and selection.is_inside_tree():
		return selection
	selection = null
	return null


## Tab / L1-R1 : cible suivante ou précédente (en combat : ennemis seulement ; sinon aussi PNJ et joueurs).
func cycle_target(dir: int) -> void:
	var list := target_candidates() if combat.engaged else selectable_candidates()
	# Les monstres qui nous attaquent passent en tête (L1/R1 en combat : on saute de l'un à l'autre).
	var mine: Array = list.filter(func(n): return n is Enemy and n.target_peer == peer_id)
	if not mine.is_empty():
		list = mine + list.filter(func(n): return not (n in mine))
	if list.is_empty():
		set_target_local(null)
		return
	var cur := current_selection()
	var idx := list.find(cur) if cur else -1
	var next: Node = list[(idx + dir + list.size()) % list.size()] if idx >= 0 else list[0]
	select_node(next)


## Sélectionne un ennemi (cible de combat, confirmée par l'hôte) ou un PNJ / joueur (sélection locale).
func select_node(n: Node) -> void:
	if n == null or n.is_in_group("enemies"):
		selection = null
		set_target_local(n)
	else:
		selection = n as Node3D
		if combat.target():
			set_target_local(null)


func set_target_local(t: Node) -> void:
	var path := str(t.get_path()) if t else ""
	if t:
		selection = null
	combat.target_path = NodePath(path)  # affichage immédiat ; l'hôte confirme
	request_action("target:" + path)


## Touche d'action (F, Entrée, Croix) quand aucun menu n'est ouvert, selon la sélection — appelée par le HUD.
## Renvoie ce qui a été fait : "talk", "player", "combat" ou "interact" (le HUD ouvre le menu voulu).
func context_kind() -> String:
	var sel := current_selection()
	if sel is Npc:
		return "talk"
	if sel is PlayerCharacter:
		return "player"
	if sel and sel.is_in_group("enemies"):
		return "combat"
	if _interactable_nearby():
		return "interact"
	return "combat"


## Rond / interagir : parle au PNJ sélectionné ou agit sur ce qui est à portée (levier, coffre, allié à terre…).
func context_action() -> void:
	var sel := current_selection()
	if sel is Npc:
		request_action("talk:" + str(sel.get_path()))
	else:
		request_action("interact")


func _interactable_nearby() -> bool:
	for group in ["interactables", "chests"]:
		for n in get_tree().get_nodes_in_group(group):
			if n is Node3D and global_position.distance_to(n.global_position) <= REVIVE_RANGE + 0.5:
				return true
	for p in get_tree().get_nodes_in_group("players"):
		if p != self and p is PlayerCharacter and p.health.is_downed and global_position.distance_to(p.global_position) <= REVIVE_RANGE:
			return true
	return false


## Clic gauche / Carré : engage la cible (en choisit une devant soi s'il n'y en a pas).
func attack_shortcut() -> void:
	if not combat.target_alive():
		var list := target_candidates()
		if list.is_empty():
			return
		set_target_local(list[0])
	request_action("engage")


# ------------------------------------------------------------------ simulation (hôte)

func _physics_process(delta: float) -> void:
	if is_local:
		_gather_local_input()
	if not is_server():
		return

	apply_gravity(delta)

	if not health.is_alive():
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	tick_conditions(delta)
	var move_dir := _camera_relative_direction(_input_dir)
	var moving := move_dir.length_squared() > 0.01
	if resting:
		if moving or is_stunned() or combat.engaged or combat.is_casting():
			stop_rest("Vous vous levez.")
		else:
			_tick_rest(delta)
	if is_stunned():
		# Étourdi : immobile, incantation perdue, rien d'autre.
		combat.cancel_cast("étourdi")
		velocity.x = move_toward(velocity.x, 0.0, 30.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 30.0 * delta)
		play_anim("hit" if anim and anim.has_animation("hit") else "idle")
		apply_knock(delta)
		move_and_slide()
		return
	combat.tick(delta, moving)

	_dodge_time = maxf(0.0, _dodge_time - delta)
	if _dodge_time > 0.0:
		velocity.x = _dodge_dir.x * DODGE_SPEED
		velocity.z = _dodge_dir.z * DODGE_SPEED
	elif combat.is_casting():
		# Incantation : immobile face à la cible ; bouger l'interrompt (géré dans combat.tick).
		velocity.x = move_toward(velocity.x, 0.0, 30.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 30.0 * delta)
		if combat.target_alive():
			face_target(combat.target(), delta)
		if not is_busy():
			play_anim("cast", 0.2, true)  # on prolonge le geste tant que ça incante
	elif is_busy() or is_restrained():
		# Pendant un coup (ou entravé) on ne se déplace pas.
		velocity.x = move_toward(velocity.x, 0.0, 30.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 30.0 * delta)
		if is_restrained() and not is_busy():
			if moving:
				face_direction(move_dir, delta)
			play_anim("idle")
	elif is_blocking:
		# En garde : on marche, face à la cible (ou à la caméra) pour présenter le bouclier.
		var speed := stats.move_speed_mps(false)
		velocity.x = move_dir.x * speed
		velocity.z = move_dir.z * speed
		if combat.target_alive():
			face_target(combat.target(), delta)
		else:
			face_direction(camera_forward(), delta)
		play_anim("block_walk" if moving else "block")
	else:
		var speed := stats.move_speed_mps(true) * combat.speed_multiplier()
		velocity.x = move_dir.x * speed
		velocity.z = move_dir.z * speed
		if moving:
			face_direction(move_dir.normalized(), delta)
			play_anim("walk" if move_dir.length() < 0.6 else "run")
		else:
			if _turning:
				face_direction(camera_forward(), delta, 10.0)
			elif combat.engaged and combat.target_alive():
				face_target(combat.target(), delta, 10.0)
			play_anim("idle")
	apply_knock(delta)
	move_and_slide()


# ------------------------------------------------------------------ repos (/heal)

## Hôte : vrai si un monstre vivant s'en prend à ce joueur (on ne peut pas se reposer).
func is_hunted() -> bool:
	for e in get_tree().get_nodes_in_group("enemies"):
		if e is Enemy and e.state != Enemy.State.IDLE and e.state != Enemy.State.DEAD and e.target == self:
			return true
	return false


func start_rest() -> bool:
	if not health.is_alive():
		return false
	if combat.engaged or combat.is_casting():
		notify_owner("Impossible de se reposer en combat.")
		return false
	if is_hunted():
		notify_owner("Impossible de se reposer : un ennemi vous poursuit.")
		return false
	if health.hp >= health.max_hp and (spell_book.slots == spell_book.max_slots):
		notify_owner("Vous êtes déjà en pleine forme.")
		return false
	_set_resting(true)
	_rest_time = 0.0
	_rest_ticks = 0
	_rest_tick_left = GameData.bal("rest_delay", 4.0)
	_rest_slot_left = GameData.bal("rest_slot_every", 12.0)
	set_blocking(false)
	notify_owner("Vous vous asseyez pour vous reposer… (bouger ou agir vous relève)")
	return true


func stop_rest(message: String) -> void:
	if not resting:
		return
	_set_resting(false)
	if message != "":
		notify_owner(message)


func _set_resting(v: bool) -> void:
	resting = v
	if is_server() and peer_id != multiplayer.get_unique_id():
		_rpc_resting.rpc_id(peer_id, v)


@rpc("authority", "reliable")
func _rpc_resting(v: bool) -> void:
	resting = v


## Paliers : après `rest_delay` s, un soin toutes les `rest_tick` s, de 4 % à 10 % des PV max (+1 % par palier) ;
## un emplacement de sort (le plus bas manquant) toutes les `rest_slot_every` s.
func _tick_rest(delta: float) -> void:
	_rest_time += delta
	velocity.x = 0.0
	velocity.z = 0.0
	play_anim("idle")
	_rest_tick_left -= delta
	if _rest_tick_left <= 0.0:
		_rest_tick_left = GameData.bal("rest_tick", 2.0)
		var pct := minf(GameData.bal("rest_heal_pct_start", 0.04) + GameData.bal("rest_heal_pct_step", 0.01) * _rest_ticks,
			GameData.bal("rest_heal_pct_max", 0.10))
		_rest_ticks += 1
		if health.hp < health.max_hp:
			health.heal(maxi(1, ceili(health.max_hp * pct)))
	_rest_slot_left -= delta
	if _rest_slot_left <= 0.0:
		_rest_slot_left = GameData.bal("rest_slot_every", 12.0)
		var keys: Array = spell_book.max_slots.keys()
		keys.sort()
		for k in keys:
			if int(spell_book.slots.get(k, 0)) < int(spell_book.max_slots[k]):
				var sl := spell_book.slots.duplicate()
				sl[k] = int(sl.get(k, 0)) + 1
				spell_book.slots = sl
				notify_owner("Repos : un emplacement de sort de niveau %s récupéré." % k)
				break
	if health.hp >= health.max_hp and spell_book.slots == spell_book.max_slots:
		stop_rest("Vous êtes reposé.")


## Vrai pendant la roulade d'esquive (zones et souffles passent au travers).
func is_dodging() -> bool:
	return _dodge_time > 0.0


func face_target(t: Node3D, delta: float, turn_speed := 12.0) -> void:
	var to := t.global_position - global_position
	to.y = 0.0
	face_direction(to, delta, turn_speed)


func face_target_now(t: Node3D) -> void:
	if t == null or not is_instance_valid(t):
		return
	var to := t.global_position - global_position
	to.y = 0.0
	if to.length_squared() > 0.0001:
		rotation.y = atan2(-to.x, -to.z)


## Met fin tout de suite à l'animation one-shot en cours (incantation annulée).
func release_anim() -> void:
	_one_shot_until = 0.0
	play_anim("idle", 0.15, true)


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
	# Longueur conservée (≤ 1) : un demi-stick ou la marche (pavé /) ralentissent.
	return (fwd * -input.y + right * input.x).limit_length(1.0)


## Direction horizontale vers laquelle regarde la caméra de ce joueur (connue de l'hôte).
func camera_forward() -> Vector3:
	return Vector3(-sin(_cam_yaw), 0, -cos(_cam_yaw))


## Direction de visée complète (lacet + tangage de la caméra).
func aim_direction() -> Vector3:
	return (Basis.from_euler(Vector3(_cam_pitch, _cam_yaw, 0)) * Vector3.FORWARD).normalized()


func try_dodge() -> bool:
	if is_busy() or _dodge_time > 0.0 or not health.is_alive() or is_restrained() or is_stunned():
		return false
	set_blocking(false)
	combat.cancel_cast("esquive")
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
	if not health.is_alive() or is_busy() or is_stunned():
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
	# Leviers, feux de camp, portes… : le plus proche à portée.
	var best: Node3D = null
	var best_d := REVIVE_RANGE + 0.5
	for n in get_tree().get_nodes_in_group("interactables"):
		if n is Node3D and n.has_method("interact"):
			var d: float = global_position.distance_to(n.global_position)
			if d < best_d:
				best_d = d
				best = n
	if best and best.interact(self):
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
			var amount := int(Dice.roll_expr(str(effect.get("amount", "2d4+2")), CombatResolver.rng) * GameData.bal("healing_mult"))
			inventory.remove_at(index, 1)
			health.heal(amount)
			play_anim("cast", 0.1, true)
			EventBus.hit_resolved.emit(self, {"attacker": self, "target": self, "attack_name": data.get("name", "Potion"),
				"hit": true, "heal": amount, "damage": 0, "damage_type": 0})
			return true
	return false


# ------------------------------------------------------------------ PNJ, boutique, quêtes (hôte)

## Gain d'XP affiché dans le journal de combat du propriétaire (en doré).
func notify_xp(text: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		EventBus.system_message.emit("[color=#ffd866]%s[/color]" % text)
	else:
		_rpc_notify_xp.rpc_id(peer_id, text)


@rpc("authority", "reliable")
func _rpc_notify_xp(text: String) -> void:
	EventBus.system_message.emit("[color=#ffd866]%s[/color]" % text)


## Message pour ce joueur seulement (journal de sa machine).
func notify_owner(text: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		EventBus.quest_updated.emit(text)
	else:
		_rpc_notify.rpc_id(peer_id, text)


@rpc("authority", "reliable")
func _rpc_notify(text: String) -> void:
	EventBus.quest_updated.emit(text)


# ------------------------------------------------------------------ coffre partagé (hôte ↔ propriétaire)
# Le contenu du coffre vit sur le PC du propriétaire (Characters) ; l'hôte ne gère que le sac du personnage.

func near_shared_chest() -> bool:
	for c in get_tree().get_nodes_in_group("shared_chests"):
		if global_position.distance_to((c as Node3D).global_position) <= CHEST_RANGE:
			return true
	return false


## Hôte : ouvre la fenêtre du coffre chez le propriétaire.
func open_shared_chest() -> void:
	if peer_id == multiplayer.get_unique_id():
		EventBus.shared_chest_open.emit()
	else:
		_rpc_open_chest.rpc_id(peer_id)


@rpc("authority", "reliable")
func _rpc_open_chest() -> void:
	EventBus.shared_chest_open.emit()


## Hôte → propriétaire : un objet (ou de l'or) entre dans son coffre partagé.
func _to_owner_chest(entry: Dictionary) -> void:
	if peer_id == multiplayer.get_unique_id():
		Characters.chest_add(entry)
	else:
		_rpc_chest_receive.rpc_id(peer_id, entry)


@rpc("authority", "reliable")
func _rpc_chest_receive(entry: Dictionary) -> void:
	Characters.chest_add(entry)


func chest_deposit(index: int) -> bool:
	if not near_shared_chest() or index < 0 or index >= inventory.items.size():
		notify_owner("Approchez-vous du coffre partagé.")
		return false
	var items := inventory.items.duplicate(true)
	var entry: Dictionary = items[index]
	items.remove_at(index)
	inventory.items = items
	_to_owner_chest(entry)
	return true


## L'objet a déjà été retiré du coffre chez le propriétaire : s'il ne rentre pas, on le lui rend.
func chest_withdraw(entry: Dictionary) -> bool:
	if not near_shared_chest():
		notify_owner("Approchez-vous du coffre partagé.")
		_to_owner_chest(entry)
		return false
	if not inventory.add(entry):
		notify_owner("Sac plein.")
		_to_owner_chest(entry)
		return false
	return true


func chest_deposit_gold(amount: int) -> bool:
	amount = mini(amount, inventory.gold)
	if amount <= 0 or not near_shared_chest():
		return false
	inventory.gold -= amount
	_to_owner_chest({"id": "gold", "qty": amount})
	return true


func chest_withdraw_gold(amount: int) -> bool:
	if amount <= 0:
		return false
	if not near_shared_chest():
		_to_owner_chest({"id": "gold", "qty": amount})
		return false
	inventory.gold += amount
	return true


## Hôte : parler au PNJ sélectionné (à portée).
func talk_to(path: String) -> bool:
	var n := get_node_or_null(NodePath(path))
	if not (n is Npc) or not health.is_alive():
		return false
	if global_position.distance_to((n as Node3D).global_position) > TALK_RANGE:
		notify_owner("Trop loin pour parler à %s : approchez-vous." % (n as Npc).npc_name)
		return false
	return n.interact(self)


func _other_player(path: String) -> PlayerCharacter:
	var n := get_node_or_null(NodePath(path))
	if n is PlayerCharacter and n != self:
		return n
	return null


const GIVE_RANGE := 6.0

## Hôte : donne un objet du sac à un autre joueur proche (échange simple).
func give_item(index: int, path: String) -> bool:
	var other := _other_player(path)
	if other == null or index < 0 or index >= inventory.items.size():
		return false
	if global_position.distance_to(other.global_position) > GIVE_RANGE:
		notify_owner("Trop loin pour donner un objet (%d m max)." % int(GIVE_RANGE))
		return false
	var entry: Dictionary = inventory.items[index].duplicate(true)
	if not other.inventory.add(entry):
		notify_owner("Le sac de %s est plein." % other.player_name)
		return false
	var items := inventory.items.duplicate(true)
	items.remove_at(index)
	inventory.items = items
	var label := "%s%s" % [Inventory.display_name(entry), (" ×%d" % int(entry.get("qty", 1))) if int(entry.get("qty", 1)) > 1 else ""]
	notify_owner("Donné à %s : %s." % [other.player_name, label])
	other.notify_owner("%s vous donne : %s." % [player_name, label])
	return true


func give_gold(amount: int, path: String) -> bool:
	var other := _other_player(path)
	if other == null or amount <= 0:
		return false
	if global_position.distance_to(other.global_position) > GIVE_RANGE:
		notify_owner("Trop loin pour donner de l'or (%d m max)." % int(GIVE_RANGE))
		return false
	amount = mini(amount, inventory.gold)
	if amount <= 0:
		notify_owner("Vous n'avez pas d'or.")
		return false
	inventory.gold -= amount
	other.inventory.gold += amount
	notify_owner("Donné à %s : %d po." % [other.player_name, amount])
	other.notify_owner("%s vous donne %d po." % [player_name, amount])
	return true


func revive_player(path: String) -> bool:
	var other := _other_player(path)
	if other == null or not other.health.is_downed or not health.is_alive():
		return false
	if global_position.distance_to(other.global_position) > REVIVE_RANGE + 0.5:
		notify_owner("Approchez-vous pour relever %s." % other.player_name)
		return false
	other.health.revive(0.25)
	play_anim("cast", 0.1, true)
	return true


## Hôte : un PNJ demande l'ouverture de son dialogue chez ce joueur.
func open_npc(npc_id: String) -> void:
	var game := get_tree().get_first_node_in_group("game")
	if game:
		game.open_npc_for(peer_id, npc_id)


func _npc_shop(npc_id: String) -> Array:
	var game := get_tree().get_first_node_in_group("game")
	if game and game.level and game.level.has_method("npc_data"):
		return game.level.npc_data(npc_id).get("shop", [])
	return []


func buy_item(item_id: String) -> bool:
	var data := GameData.item(item_id)
	if data.is_empty():
		return false
	# L'objet doit être vendu par un marchand à portée (2,5 m).
	var sold := false
	for n in get_tree().get_nodes_in_group("npcs"):
		if n is Npc and global_position.distance_to(n.global_position) <= 4.0 and item_id in _npc_shop(n.npc_id):
			sold = true
	if not sold:
		return false
	var price := int(data.get("value", 10))
	if inventory.gold < price:
		notify_owner("Pas assez d'or (%d po nécessaires)." % price)
		return false
	if not inventory.add({"id": item_id, "qty": 1, "rarity": "common"}):
		notify_owner("Sac plein.")
		return false
	inventory.gold -= price
	notify_owner("Acheté : %s (−%d po)." % [data.get("name", item_id), price])
	return true


func sell_item(index: int) -> bool:
	if index < 0 or index >= inventory.items.size():
		return false
	var near := false
	for n in get_tree().get_nodes_in_group("npcs"):
		if n is Npc and n.role == "merchant" and global_position.distance_to(n.global_position) <= 4.0:
			near = true
	if not near:
		return false
	var entry: Dictionary = inventory.items[index]
	var data := Inventory.item_data(entry)
	var price := maxi(1, int(data.get("value", 1)) / 2)
	inventory.remove_at(index, 1)
	inventory.gold += price
	notify_owner("Vendu : %s (+%d po)." % [Inventory.display_name(entry), price])
	return true


func quest_accept(id: String) -> bool:
	if not quest_log.accept(id):
		return false
	var q := QuestLog.quest_data(id)
	notify_owner("Nouvelle quête : %s" % q.get("title", id))
	return true


func quest_turn_in(id: String) -> bool:
	if not quest_log.turn_in(id, inventory):
		notify_owner("Objectif non atteint.")
		return false
	var q := QuestLog.quest_data(id)
	var reward: Dictionary = q.get("reward", {})
	inventory.gold += int(reward.get("gold", 0))
	for it in reward.get("items", []):
		inventory.add({"id": it.get("id", ""), "qty": int(it.get("qty", 1)), "rarity": it.get("rarity", "common")})
	if int(reward.get("xp", 0)) > 0:
		stats.add_xp(int(reward.get("xp", 0)))
	notify_owner("Quête terminée : %s — +%d po, +%d XP." % [q.get("title", id), int(reward.get("gold", 0)), int(reward.get("xp", 0))])
	add_progress("quest:" + id)
	return true


func add_progress(flag: String) -> void:
	if not flag in progress:
		progress.append(flag)


func has_progress(flag: String) -> bool:
	return flag in progress


## Hôte : un monstre tué par le groupe fait avancer les quêtes de chasse.
func on_party_kill(monster_id: String) -> void:
	if GameData.monster(monster_id).get("is_boss", false):
		add_progress("boss:" + monster_id)
	for id in quest_log.on_kill(monster_id):
		var q := QuestLog.quest_data(id)
		var obj: Dictionary = q.get("objective", {})
		notify_owner("%s : %d / %d" % [q.get("title", id), quest_log.progress_of(id), int(obj.get("count", 1))])


# ------------------------------------------------------------------ persistance entre zones (hôte)

func save_state() -> Dictionary:
	return {
		"level": stats.level, "xp": stats.xp, "hp": health.hp,
		"gold": inventory.gold, "items": inventory.items.duplicate(true), "equipped": inventory.equipped.duplicate(true),
		"slots": spell_book.slots.duplicate(true) if spell_book else {},
		"quests": quest_log.quests.duplicate(true),
		"progress": progress.duplicate(),
		"job": class_id,
		"jobs": _jobs_with_current(),
	}


func _jobs_with_current() -> Dictionary:
	var j := jobs.duplicate(true)
	j[class_id] = {"level": stats.level, "xp": stats.xp}
	return j


func load_state(st: Dictionary) -> void:
	if not is_server():
		return
	# Jobs : anciennes sauvegardes (sans « jobs ») → le niveau enregistré est celui du job de départ.
	var saved_jobs: Dictionary = st.get("jobs", {})
	if saved_jobs.is_empty():
		saved_jobs = {class_id: {"level": int(st.get("level", 1)), "xp": int(st.get("xp", 0))}}
	var job: String = str(st.get("job", class_id))
	if GameData.player_class(job).is_empty():
		job = class_id
	_switching_job = true
	jobs = saved_jobs.duplicate(true)
	class_id = job
	var cur: Dictionary = jobs.get(job, {"level": int(st.get("level", 1)), "xp": int(st.get("xp", 0))})
	stats.xp = int(cur.get("xp", 0))
	stats.level = maxi(1, int(cur.get("level", 1)))
	_switching_job = false
	jobs[job] = {"level": stats.level, "xp": stats.xp}
	if not (spell_book and GameData.player_class(job).has("spellcasting_ability")):
		_apply_job_spells()
	health.max_hp = stats.max_hp()
	inventory.gold = int(st.get("gold", 0))
	inventory.items = st.get("items", []).duplicate(true)
	inventory.equipped = st.get("equipped", {}).duplicate(true)
	if spell_book and GameData.player_class(class_id).has("spellcasting_ability"):
		spell_book.casting_ability = GameData.player_class(class_id).get("spellcasting_ability", "int")
		spell_book.refresh_for_level(GameData.player_class(class_id), stats.level, false)
		spell_book.slots = st.get("slots", spell_book.slots).duplicate(true)
	quest_log.quests = st.get("quests", {}).duplicate(true)
	progress = st.get("progress", []).duplicate()
	health.hp = clampi(int(st.get("hp", health.max_hp)), 1, health.max_hp)
	_apply_equipment()


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

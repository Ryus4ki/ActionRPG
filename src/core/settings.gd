extends Node
## Autoload « Settings » : réglages du joueur (affichage, son, commandes), sauvegardés dans
## user://settings.cfg (sur Windows : %APPDATA%\Godot\app_userdata\ActionRPG\settings.cfg).
## Les touches modifiées sont stockées action par action ; « Réinitialiser » revient aux touches du projet.

signal changed

var path := "user://settings.cfg"  # les tests utilisent un autre fichier
const BUS_SFX := "SFX"
const BUS_AMBIENT := "Ambiance"

const WINDOW_MODES := ["Fenêtré", "Plein écran (fenêtre sans bordure)", "Plein écran exclusif"]
const RESOLUTIONS: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3840, 2160)]
const FPS_LIMITS: Array[int] = [0, 30, 60, 120, 144, 165, 240]

## Actions modifiables dans l'écran Commandes : [action, libellé]. Les en-têtes commencent par « # ».
const REBINDABLE := [
	["#", "Déplacement"],
	["move_forward", "Avancer"], ["move_back", "Reculer"], ["move_left", "Pas de côté à gauche"],
	["move_right", "Pas de côté à droite"], ["turn_left", "Pivoter à gauche"], ["turn_right", "Pivoter à droite"],
	["walk_toggle", "Marcher / courir"], ["dodge", "Esquive (roulade)"],
	["#", "Combat"],
	["attack", "Attaquer la cible (engager)"], ["secondary", "Garde au bouclier"], ["target_next", "Cible suivante"],
	["target_prev", "Cible précédente"], ["target_nearest", "Cible la plus proche"], ["use_potion", "Boire une potion"],
	["rest", "Se reposer / se lever"], ["menu_toggle", "Action (combat, parler, joueur) / valider"], ["menu_back", "Retour (menu de commandes)"],
	["#", "Interface"],
	["interact", "Interagir (manette : Rond)"], ["inventory", "Inventaire"], ["character_sheet", "Feuille de personnage"],
	["journal", "Journal de quêtes"], ["menu", "Menu système (options)"],
	["#", "Caméra"],
	["look_left", "Caméra à gauche"], ["look_right", "Caméra à droite"], ["look_up", "Caméra en haut"],
	["look_down", "Caméra en bas"], ["zoom_in", "Zoom avant"], ["zoom_out", "Zoom arrière"],
	["view_toggle", "Vue 1re / 3e personne"],
]
const STICK_ACTIONS := ["move_forward", "move_back", "move_left", "move_right", "look_left", "look_right", "look_up", "look_down"]

# --- valeurs (défauts) ---
var window_mode := 0
var resolution := Vector2i(1600, 900)
var vsync := true
var fps_limit := 0
var ui_scale := 1.0
var render_scale := 1.0
var fov := 65.0
var vol_master := 1.0
var vol_sfx := 1.0
var vol_ambient := 1.0
var mouse_sensitivity := 1.0   # multiplicateur
var stick_sensitivity := 1.0   # multiplicateur
var invert_y := false
var stick_deadzone := 0.2
var show_help := true        # panneau des commandes (H) : reste fermé d'une zone à l'autre

var _cfg := ConfigFile.new()
var _has_file := false


func _ready() -> void:
	_ensure_buses()
	_ensure_ui_gamepad_actions()
	load_settings()
	# Premier lancement : on ne touche pas à la fenêtre (taille du projet), seulement au reste.
	apply_video(_has_file)
	apply_audio()
	apply_controls()


## Bus audio « SFX » et « Ambiance » créés à l'exécution (pas besoin de fichier default_bus_layout).
func _ensure_buses() -> void:
	for bus in [BUS_SFX, BUS_AMBIENT]:
		if AudioServer.get_bus_index(bus) == -1:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, bus)
			AudioServer.set_bus_send(i, "Master")


## Croix / Rond de la manette pour valider / annuler dans toutes les interfaces (boutons, listes…).
func _ensure_ui_gamepad_actions() -> void:
	for pair in [["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B]]:
		var has := false
		for e in InputMap.action_get_events(pair[0]):
			if e is InputEventJoypadButton and e.button_index == pair[1]:
				has = true
		if not has:
			var ev := InputEventJoypadButton.new()
			ev.button_index = pair[1]
			InputMap.action_add_event(pair[0], ev)


# ------------------------------------------------------------------ chargement / sauvegarde

func load_settings() -> void:
	if _cfg.load(path) != OK:
		return
	_has_file = true
	window_mode = clampi(int(_cfg.get_value("video", "window_mode", window_mode)), 0, WINDOW_MODES.size() - 1)
	resolution = _cfg.get_value("video", "resolution", resolution)
	vsync = bool(_cfg.get_value("video", "vsync", vsync))
	fps_limit = int(_cfg.get_value("video", "fps_limit", fps_limit))
	ui_scale = clampf(float(_cfg.get_value("video", "ui_scale", ui_scale)), 0.75, 2.0)
	render_scale = clampf(float(_cfg.get_value("video", "render_scale", render_scale)), 0.5, 1.0)
	fov = clampf(float(_cfg.get_value("video", "fov", fov)), 50.0, 100.0)
	vol_master = float(_cfg.get_value("audio", "master", vol_master))
	vol_sfx = float(_cfg.get_value("audio", "sfx", vol_sfx))
	vol_ambient = float(_cfg.get_value("audio", "ambient", vol_ambient))
	mouse_sensitivity = float(_cfg.get_value("controls", "mouse_sensitivity", mouse_sensitivity))
	stick_sensitivity = float(_cfg.get_value("controls", "stick_sensitivity", stick_sensitivity))
	invert_y = bool(_cfg.get_value("controls", "invert_y", invert_y))
	stick_deadzone = clampf(float(_cfg.get_value("controls", "stick_deadzone", stick_deadzone)), 0.05, 0.6)
	show_help = bool(_cfg.get_value("interface", "show_help", show_help))
	if _cfg.has_section("bindings"):
		for action in _cfg.get_section_keys("bindings"):
			if not InputMap.has_action(action):
				continue
			var events: Array = _cfg.get_value("bindings", action, [])
			InputMap.action_erase_events(action)
			for e in events:
				if e is InputEvent:
					InputMap.action_add_event(action, e)


func save_settings() -> void:
	_cfg.set_value("video", "window_mode", window_mode)
	_cfg.set_value("video", "resolution", resolution)
	_cfg.set_value("video", "vsync", vsync)
	_cfg.set_value("video", "fps_limit", fps_limit)
	_cfg.set_value("video", "ui_scale", ui_scale)
	_cfg.set_value("video", "render_scale", render_scale)
	_cfg.set_value("video", "fov", fov)
	_cfg.set_value("audio", "master", vol_master)
	_cfg.set_value("audio", "sfx", vol_sfx)
	_cfg.set_value("audio", "ambient", vol_ambient)
	_cfg.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	_cfg.set_value("controls", "stick_sensitivity", stick_sensitivity)
	_cfg.set_value("controls", "invert_y", invert_y)
	_cfg.set_value("controls", "stick_deadzone", stick_deadzone)
	_cfg.set_value("interface", "show_help", show_help)
	_cfg.save(path)


# ------------------------------------------------------------------ application

func apply_all() -> void:
	apply_video()
	apply_audio()
	apply_controls()


func apply_video(window := true) -> void:
	if window and DisplayServer.get_name() != "headless":
		match window_mode:
			0:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				var screen := DisplayServer.window_get_current_screen()
				var usable := DisplayServer.screen_get_usable_rect(screen)
				var size := Vector2i(mini(resolution.x, usable.size.x), mini(resolution.y, usable.size.y))
				DisplayServer.window_set_size(size)
				DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)
			1:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			2:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = fps_limit
	get_tree().root.content_scale_factor = ui_scale
	get_tree().root.scaling_3d_scale = render_scale
	changed.emit()


func apply_audio() -> void:
	_set_bus_volume("Master", vol_master)
	_set_bus_volume(BUS_SFX, vol_sfx)
	_set_bus_volume(BUS_AMBIENT, vol_ambient)


func _set_bus_volume(bus: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i == -1:
		return
	AudioServer.set_bus_mute(i, linear <= 0.001)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.001)))


func apply_controls() -> void:
	for action in STICK_ACTIONS:
		if InputMap.has_action(action):
			InputMap.action_set_deadzone(action, stick_deadzone)
	changed.emit()


# ------------------------------------------------------------------ touches

## Remplace les événements de l'action pour un « emplacement » : 0 et 1 = clavier/souris, 2 = manette.
## `event` null = effacer l'emplacement. Sauvegarde immédiate.
func rebind(action: String, slot: int, event: InputEvent) -> void:
	var keys := events_of(action, false)
	var pads := events_of(action, true)
	if slot < 2:
		while keys.size() <= slot:
			keys.append(null)
		keys[slot] = event
	else:
		pads = [event] + (pads.slice(1) if pads.size() > 1 else [])
	InputMap.action_erase_events(action)
	var stored: Array = []
	for e in keys + pads:
		if e != null:
			InputMap.action_add_event(action, e)
			stored.append(e)
	_cfg.set_value("bindings", action, stored)
	if action in STICK_ACTIONS:
		InputMap.action_set_deadzone(action, stick_deadzone)
	save_settings()


## Événements clavier/souris (`pad` = false) ou manette (`pad` = true) d'une action, dans l'ordre.
func events_of(action: String, pad: bool) -> Array:
	var out: Array = []
	if not InputMap.has_action(action):
		return out
	for e in InputMap.action_get_events(action):
		var is_pad := e is InputEventJoypadButton or e is InputEventJoypadMotion
		if is_pad == pad:
			out.append(e)
	return out


## Actions (modifiables) qui utilisent déjà cet événement, hors `except`.
func conflicts(event: InputEvent, except: String) -> Array[String]:
	var out: Array[String] = []
	for row in REBINDABLE:
		var action: String = row[0]
		if action == "#" or action == except or not InputMap.has_action(action):
			continue
		for e in InputMap.action_get_events(action):
			if same_event(e, event):
				out.append(row[1])
				break
	return out


static func same_event(a: InputEvent, b: InputEvent) -> bool:
	if a is InputEventKey and b is InputEventKey:
		var ka: int = a.keycode if a.keycode != 0 else physical_to_keycode(a.physical_keycode)
		var kb: int = b.keycode if b.keycode != 0 else physical_to_keycode(b.physical_keycode)
		return ka == kb and a.shift_pressed == b.shift_pressed and a.ctrl_pressed == b.ctrl_pressed
	if a is InputEventMouseButton and b is InputEventMouseButton:
		return a.button_index == b.button_index
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		return a.button_index == b.button_index
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		return a.axis == b.axis and signf(a.axis_value) == signf(b.axis_value)
	return false


## Remet toutes les touches du projet et oublie les modifications.
func reset_bindings() -> void:
	InputMap.load_from_project_settings()
	_ensure_ui_gamepad_actions()
	if _cfg.has_section("bindings"):
		_cfg.erase_section("bindings")
	apply_controls()
	save_settings()


## Touche « physique » (position QWERTY) → touche réelle selon la disposition du clavier (AZERTY).
static func physical_to_keycode(physical: int) -> int:
	if DisplayServer.get_name() == "headless":
		return physical
	return DisplayServer.keyboard_get_keycode_from_physical(physical as Key)


## Nom lisible d'un événement (touche affichée selon la disposition du clavier, donc AZERTY chez Grég).
static func event_label(e: InputEvent) -> String:
	if e == null:
		return "—"
	if e is InputEventKey:
		var code: int = e.keycode
		if code == 0:
			code = physical_to_keycode(e.physical_keycode)
		var txt := OS.get_keycode_string(code)
		txt = KEY_NAMES_FR.get(txt, txt)
		if e.shift_pressed and code != KEY_SHIFT:
			txt = "Maj+" + txt
		if e.ctrl_pressed and code != KEY_CTRL:
			txt = "Ctrl+" + txt
		return txt
	if e is InputEventMouseButton:
		return {MOUSE_BUTTON_LEFT: "Clic gauche", MOUSE_BUTTON_RIGHT: "Clic droit", MOUSE_BUTTON_MIDDLE: "Clic molette",
			MOUSE_BUTTON_WHEEL_UP: "Molette haut", MOUSE_BUTTON_WHEEL_DOWN: "Molette bas",
			MOUSE_BUTTON_XBUTTON1: "Souris 4", MOUSE_BUTTON_XBUTTON2: "Souris 5"}.get(e.button_index, "Souris %d" % e.button_index)
	if e is InputEventJoypadButton:
		return PAD_BUTTONS.get(e.button_index, "Bouton %d" % e.button_index)
	if e is InputEventJoypadMotion:
		var axis: String = PAD_AXES.get(e.axis, "Axe %d" % e.axis)
		if e.axis in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
			return axis
		return "%s %s" % [axis, PAD_DIRS.get(e.axis, ["−", "+"])[0 if e.axis_value < 0 else 1]]
	return e.as_text()


const KEY_NAMES_FR := {
	"Space": "Espace", "Enter": "Entrée", "Escape": "Échap", "Backspace": "Retour arrière", "Shift": "Maj",
	"Ctrl": "Ctrl", "Alt": "Alt", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "PageUp": "Pg↑",
	"PageDown": "Pg↓", "Kp Enter": "Pavé Entrée", "Kp Divide": "Pavé /", "Kp Multiply": "Pavé *",
	"Kp Subtract": "Pavé −", "Kp Add": "Pavé +", "Kp Period": "Pavé .", "Kp 0": "Pavé 0", "Kp 1": "Pavé 1",
	"Kp 2": "Pavé 2", "Kp 3": "Pavé 3", "Kp 4": "Pavé 4", "Kp 5": "Pavé 5", "Kp 6": "Pavé 6", "Kp 7": "Pavé 7",
	"Kp 8": "Pavé 8", "Kp 9": "Pavé 9", "Insert": "Inser", "Delete": "Suppr", "Home": "Début", "End": "Fin",
	"CapsLock": "Verr. Maj",
}
## Noms PlayStation (manette PS5 de Grég).
const PAD_BUTTONS := {
	JOY_BUTTON_A: "Croix", JOY_BUTTON_B: "Rond", JOY_BUTTON_X: "Carré", JOY_BUTTON_Y: "Triangle",
	JOY_BUTTON_LEFT_SHOULDER: "L1", JOY_BUTTON_RIGHT_SHOULDER: "R1", JOY_BUTTON_LEFT_STICK: "L3",
	JOY_BUTTON_RIGHT_STICK: "R3", JOY_BUTTON_BACK: "Create", JOY_BUTTON_START: "Options",
	JOY_BUTTON_GUIDE: "PS", JOY_BUTTON_DPAD_UP: "Croix ↑", JOY_BUTTON_DPAD_DOWN: "Croix ↓",
	JOY_BUTTON_DPAD_LEFT: "Croix ←", JOY_BUTTON_DPAD_RIGHT: "Croix →", JOY_BUTTON_TOUCHPAD: "Pavé tactile",
	JOY_BUTTON_MISC1: "Micro",
}
const PAD_AXES := {
	JOY_AXIS_LEFT_X: "Stick G", JOY_AXIS_LEFT_Y: "Stick G", JOY_AXIS_RIGHT_X: "Stick D", JOY_AXIS_RIGHT_Y: "Stick D",
	JOY_AXIS_TRIGGER_LEFT: "L2", JOY_AXIS_TRIGGER_RIGHT: "R2",
}
const PAD_DIRS := {
	JOY_AXIS_LEFT_X: ["←", "→"], JOY_AXIS_LEFT_Y: ["↑", "↓"], JOY_AXIS_RIGHT_X: ["←", "→"], JOY_AXIS_RIGHT_Y: ["↑", "↓"],
}

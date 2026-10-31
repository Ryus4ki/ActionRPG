extends CanvasLayer
## HUD en jeu, style MMO : cadre de personnage (haut gauche), cadres des coéquipiers,
## fenêtre de combat type « chat » (bas gauche), aide des commandes (bas droite, touche H),
## barre de sorts (bas centre), message d'état (centre).
## Tout est construit en code pour rester cohérent (une seule palette, une seule taille de police).

const FONT_SMALL := 12
const FONT_NORMAL := 13
const FONT_TITLE := 14
const CHAT_MAX_LINES := 120
const COLOR_PANEL := Color(0.05, 0.05, 0.07, 0.72)
const COLOR_BORDER := Color(0.35, 0.33, 0.28, 0.9)
const COLOR_HP := Color(0.72, 0.16, 0.14)
const COLOR_HP_BG := Color(0.2, 0.06, 0.06, 0.9)
const COLOR_XP := Color(0.78, 0.62, 0.2)
const COLOR_XP_BG := Color(0.18, 0.15, 0.06, 0.9)
const COLOR_ALLY_HP := Color(0.2, 0.6, 0.3)

var player: PlayerCharacter

# Nœuds construits en code
var _root: Control
var _name_label: Label
var _sub_label: Label
var _hp_bar: ProgressBar
var _hp_text: Label
var _xp_bar: ProgressBar
var _xp_text: Label
var _allies_box: VBoxContainer
var _ally_frames: Dictionary = {}  # Node -> {bar, label}
var _chat: RichTextLabel
var _help_panel: PanelContainer
var _tp_bar: ProgressBar
var _cond_label: Label
var _target_sub: Label
var _tp_text: Label
var _target_panel: PanelContainer
var _target_label: Label
var _target_bar: ProgressBar
var _target_text: Label
var _target_marker: MeshInstance3D
var _cast_panel: PanelContainer
var _cast_label: Label
var _cast_bar: ProgressBar
var _menu_panel: PanelContainer
var _menu_box: VBoxContainer
var _menu_title: Label
var _menu_open := false
var _menu_level := ""          # "" racine, "skills", "magic", "items"
var _menu_items: Array = []    # [{label, action, enabled, hint}]
var _menu_index := 0
var _menu_refresh := 0.0
var _warned_actions := false
var _banner: Label
var _dialog_panel: PanelContainer
var _dialog_body: VBoxContainer
var _dialog_npc := ""
var _dialog_mode := ""   # "" | "shop_buy" | "shop_sell" (PNJ) ; "" | "give" (menu joueur)
var _dialog_player: PlayerCharacter = null
var _dialog_chest := false  # fenêtre du coffre partagé  # menu d'un autre joueur (même fenêtre que les dialogues)
var _journal_panel: PanelContainer
var _journal_body: VBoxContainer
var _status: Label
var _gold_label: Label
var _inv_panel: PanelContainer
var _inv_list: VBoxContainer
var _inv_title: Label
var _ally_refresh := 0.0
var _sheet_panel: PanelContainer
var _sheet_body: VBoxContainer
var _end_panel: PanelContainer
var _boss_panel: PanelContainer
var _boss_label: Label
var _boss_bar: ProgressBar
var _boss_text: Label
var _sys_panel: PanelContainer
var _last_job := ""
var _last_level := 0
var _aggro_panel: PanelContainer
var _aggro_box: VBoxContainer
var _aggro_refresh := 0.0
var _prev_target_alive := false
var _sys_body: VBoxContainer
var _quit_armed := false
var _pad_mode := false       # dernière entrée venue de la manette : on donne le focus aux fenêtres ouvertes
var _unblock_timer: SceneTreeTimer


func _ready() -> void:
	_build_ui()
	EventBus.local_player_ready.connect(bind_player)
	EventBus.hit_resolved.connect(_on_hit_resolved)
	EventBus.creature_died.connect(_on_creature_died)
	EventBus.creature_downed.connect(_on_creature_downed)
	EventBus.item_picked.connect(_on_item_picked)
	EventBus.boss_phase.connect(_on_boss_phase)
	EventBus.level_cleared.connect(_on_level_cleared)
	EventBus.system_message.connect(_on_system_message)
	EventBus.run_finished.connect(_show_end_screen)
	EventBus.monster_skill.connect(_on_monster_skill)
	EventBus.zone_entered.connect(_on_zone_entered)
	EventBus.npc_dialog.connect(open_npc_dialog)
	EventBus.quest_updated.connect(_on_quest_updated)
	EventBus.shared_chest_open.connect(open_shared_chest)
	Characters.chest_changed.connect(_on_chest_changed)
	for p in get_tree().get_nodes_in_group("players"):
		if p is PlayerCharacter and p.is_local:
			bind_player(p)
			break
	chat_system("Bienvenue. Appuie sur H pour afficher ou masquer les commandes, Échap pour le menu.")


## Les touches du menu sont lues dans _input (avant l'interface) : un bouton qui aurait le focus
## ne peut pas avaler Entrée. Repli direct sur les touches si la table d'actions n'a pas été rechargée.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5):
		_pad_mode = true
	elif event is InputEventKey or event is InputEventMouseButton:
		_pad_mode = false
	if player == null or OptionsMenu.is_open() or not (event is InputEventKey or event is InputEventJoypadButton):
		return
	# Une fenêtre a le focus : Croix (ou Entrée dans un dialogue / le menu système) valide le bouton sélectionné
	# au lieu d'ouvrir le menu de commandes. Au clavier, Entrée garde la priorité hors fenêtre modale (inventaire
	# ouvert après un clic sur « Équiper », par exemple).
	if not _menu_open and _ui_has_focus() and (_pad_mode or _modal_open()):
		return
	if _action(event, "menu_toggle", [KEY_ENTER, KEY_KP_ENTER, KEY_F], [JOY_BUTTON_A]):
		if not _menu_open and _modal_open():
			_focus_modal()
		elif _menu_open:
			_menu_confirm()
		else:
			context_open()
		get_viewport().set_input_as_handled()
	elif _menu_open and _action(event, "menu_up", [KEY_UP], [JOY_BUTTON_DPAD_UP]):
		_menu_move(-1)
		get_viewport().set_input_as_handled()
	elif _menu_open and _action(event, "menu_down", [KEY_DOWN], [JOY_BUTTON_DPAD_DOWN]):
		_menu_move(1)
		get_viewport().set_input_as_handled()
	elif _menu_open and (_action(event, "menu_back", [KEY_KP_SUBTRACT, KEY_BACKSPACE, KEY_ESCAPE], [JOY_BUTTON_B])
			or event.is_action_pressed("ui_cancel")):
		_menu_back()
		get_viewport().set_input_as_handled()


## Vrai si un bouton/contrôle visible de l'interface a le focus.
func _ui_has_focus() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f != null and f.is_visible_in_tree()


## Fenêtres qui bloquent le personnage (on ne bouge pas en parlant ou dans le menu système).
func _modal_open() -> bool:
	return _dialog_panel.visible or _sys_panel.visible or OptionsMenu.is_open()


func _focus_modal() -> void:
	if _sys_panel.visible:
		UiTheme.focus_first(_sys_body)
	elif _dialog_panel.visible:
		UiTheme.focus_first(_dialog_body)


## Le personnage est bloqué tant qu'un menu ou une fenêtre modale est ouvert. Au déblocage, on attend un
## instant : la touche qui ferme la fenêtre (Rond = aussi « interagir ») ne doit pas agir dans le jeu.
## menu_open : raccourcis du menu ignorés (menu de commandes ou fenêtre) ; ui_blocked : fenêtre modale, on ne bouge plus.
## Le menu de commandes seul laisse se déplacer (façon FFXI).
func _update_player_block(immediate := false) -> void:
	if player == null:
		return
	var modal := _modal_open()
	if modal or _menu_open:
		player.menu_open = true
		player.ui_blocked = modal
		_unblock_timer = null
		return
	if immediate:
		player.menu_open = false
		player.ui_blocked = false
		_unblock_timer = null
	elif player.menu_open or player.ui_blocked:
		var t := get_tree().create_timer(0.2)
		_unblock_timer = t
		t.timeout.connect(func():
			if _unblock_timer == t and is_instance_valid(player) and not (_menu_open or _modal_open()):
				player.menu_open = false
				player.ui_blocked = false)


## Index du contrôle qui a le focus parmi les contrôles focalisables de `root` (-1 si aucun).
func _focus_index(root: Control) -> int:
	var f := get_viewport().gui_get_focus_owner()
	if f == null:
		return -1
	return UiTheme.focusables(root).find(f)


func _restore_focus(root: Control, idx: int) -> void:
	if idx < 0:
		return
	var list := UiTheme.focusables(root)
	if not list.is_empty():
		(list[mini(idx, list.size() - 1)] as Control).grab_focus()


## Vide un conteneur tout de suite (remove_child) pour que les nouveaux contrôles soient les seuls comptés.
func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


## Vrai si `event` déclenche l'action (ou, si l'action n'existe pas dans le projet, l'une des touches de repli).
func _action(event: InputEvent, action: String, keys: Array, buttons: Array) -> bool:
	if InputMap.has_action(action):
		return event.is_action_pressed(action)
	if not _warned_actions:
		_warned_actions = true
		chat_system("[color=#ff9060]Table des touches obsolète : dans Godot, Projet → Recharger le projet actuel.[/color]")
	if event is InputEventKey and event.pressed and not event.echo:
		return event.physical_keycode in keys or event.keycode in keys
	if event is InputEventJoypadButton and event.pressed:
		return event.button_index in buttons
	return false


func _on_system_message(t: String) -> void:
	chat_system(t)


func _on_quest_updated(t: String) -> void:
	chat_line("[color=#ffe080]%s[/color]" % t)


## À la destruction (changement de zone), on coupe toutes les connexions au bus global :
## une méthode d'un nœud détruit ne doit plus être appelée.
func _exit_tree() -> void:
	for sig_name in ["local_player_ready", "hit_resolved", "creature_died", "creature_downed", "item_picked", "boss_phase",
			"level_cleared", "system_message", "run_finished", "monster_skill", "zone_entered", "npc_dialog", "quest_updated",
			"shared_chest_open"]:
		for c in EventBus.get_signal_connection_list(sig_name):
			var cb: Callable = c.callable
			if cb.get_object() == self:
				EventBus.disconnect(sig_name, cb)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_H:
		_toggle_help()
	elif OptionsMenu.is_open():
		return
	elif event.is_action_pressed("menu"):
		toggle_system_menu()
	elif event.is_action_pressed("ui_cancel"):
		# Échap / Rond : ferme la fenêtre du dessus ; Échap (clavier) sans rien d'ouvert = menu système.
		if _sys_panel.visible:
			close_system_menu()
		elif _dialog_panel.visible and _dialog_mode != "":
			_dialog_mode = ""
			_refresh_dialog_mode()
		elif _dialog_panel.visible:
			close_npc_dialog()
		elif _inv_panel.visible or _journal_panel.visible or _sheet_panel.visible:
			_inv_panel.visible = false
			_journal_panel.visible = false
			_sheet_panel.visible = false
		elif event is InputEventKey and not _end_panel.visible:
			open_system_menu()
	elif event.is_action_pressed("journal"):
		toggle_journal()
	elif event.is_action_pressed("character_sheet"):
		toggle_character_sheet()
	elif event.is_action_pressed("inventory"):
		toggle_inventory()


# ============================================================ construction

## Le panneau d'aide se dimensionne sur son contenu et reste calé en bas à droite.
## Affiche / masque l'aide ; le choix est mémorisé (il survit aux changements de zone et aux relances).
func _toggle_help() -> void:
	_help_panel.visible = not _help_panel.visible
	Settings.show_help = _help_panel.visible
	Settings.save_settings()
	_fit_help_panel()


func _fit_help_panel() -> void:
	if _help_panel == null:
		return
	var m := _help_panel.get_combined_minimum_size()
	_help_panel.offset_left = -12 - m.x
	_help_panel.offset_top = -12 - m.y
	_help_panel.offset_right = -12
	_help_panel.offset_bottom = -12


func _panel_style(padding := 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.border_color = COLOR_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(padding)
	return sb


func _bar_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(2)
	return sb


func _make_label(text: String, size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _make_bar(fill: Color, bg: Color, height: int) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(0, height)
	b.show_percentage = false
	b.add_theme_stylebox_override("fill", _bar_style(fill))
	b.add_theme_stylebox_override("background", _bar_style(bg))
	return b


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UiTheme.get_theme()
	add_child(_root)

	# --- Cadre du personnage (haut gauche) ---
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", _panel_style(8))
	frame.position = Vector2(12, 12)
	frame.custom_minimum_size = Vector2(250, 0)
	_root.add_child(frame)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	frame.add_child(v)
	_name_label = _make_label("Personnage", FONT_TITLE)
	v.add_child(_name_label)
	_sub_label = _make_label("", FONT_SMALL, Color(0.75, 0.75, 0.8))
	v.add_child(_sub_label)
	var hp_holder := Control.new()
	hp_holder.custom_minimum_size = Vector2(0, 16)
	v.add_child(hp_holder)
	_hp_bar = _make_bar(COLOR_HP, COLOR_HP_BG, 16)
	_hp_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hp_holder.add_child(_hp_bar)
	_hp_text = _make_label("0 / 0", FONT_SMALL)
	_hp_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_holder.add_child(_hp_text)
	var xp_holder := Control.new()
	xp_holder.custom_minimum_size = Vector2(0, 10)
	v.add_child(xp_holder)
	_xp_bar = _make_bar(COLOR_XP, COLOR_XP_BG, 10)
	_xp_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	xp_holder.add_child(_xp_bar)
	_xp_text = _make_label("", 10, Color(0.9, 0.85, 0.6))
	_xp_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_xp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_xp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	xp_holder.add_child(_xp_text)
	var tp_holder := Control.new()
	tp_holder.custom_minimum_size = Vector2(0, 10)
	v.add_child(tp_holder)
	_tp_bar = _make_bar(Color(0.95, 0.75, 0.2), Color(0.25, 0.2, 0.08), 10)
	_tp_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tp_bar.max_value = PlayerCombat.TP_MAX
	tp_holder.add_child(_tp_bar)
	_tp_text = _make_label("TP 0", 10, Color(1, 0.95, 0.8))
	_tp_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tp_holder.add_child(_tp_text)
	_gold_label = _make_label("", FONT_SMALL, Color(0.95, 0.85, 0.55))
	v.add_child(_gold_label)
	_cond_label = _make_label("", FONT_SMALL, Color(1.0, 0.6, 0.5))
	_cond_label.visible = false
	v.add_child(_cond_label)

	# --- Coéquipiers (sous le cadre) ---
	_allies_box = VBoxContainer.new()
	_allies_box.position = Vector2(12, 132)
	_allies_box.add_theme_constant_override("separation", 4)
	_root.add_child(_allies_box)

	# --- Fenêtre de combat (bas gauche) ---
	var chat_panel := PanelContainer.new()
	chat_panel.add_theme_stylebox_override("panel", _panel_style(6))
	chat_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat_panel.anchor_top = 1.0
	chat_panel.anchor_bottom = 1.0
	chat_panel.offset_left = 12
	chat_panel.offset_top = -172
	chat_panel.offset_right = 12 + 440
	chat_panel.offset_bottom = -12
	chat_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(chat_panel)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 2)
	chat_panel.add_child(cv)
	cv.add_child(_make_label("Combat", FONT_SMALL, Color(0.8, 0.75, 0.6)))
	_chat = RichTextLabel.new()
	_chat.bbcode_enabled = true
	_chat.scroll_following = true
	_chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat.add_theme_font_size_override("normal_font_size", FONT_SMALL)
	_chat.add_theme_font_size_override("bold_font_size", FONT_SMALL)
	_chat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cv.add_child(_chat)

	# --- Aide des commandes (bas droite) ---
	_help_panel = PanelContainer.new()
	_help_panel.add_theme_stylebox_override("panel", _panel_style(8))
	# Taille et position explicites (bas droite) : pas de croissance automatique hors écran.
	_help_panel.anchor_left = 1.0
	_help_panel.anchor_right = 1.0
	_help_panel.anchor_top = 1.0
	_help_panel.anchor_bottom = 1.0
	_help_panel.offset_right = -12
	_help_panel.offset_bottom = -12
	_root.add_child(_help_panel)
	_help_panel.visible = Settings.show_help
	_help_panel.minimum_size_changed.connect(_fit_help_panel)
	_fit_help_panel.call_deferred()
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 2)
	_help_panel.add_child(hv)
	hv.add_child(_make_label("Commandes par défaut   (H : masquer · Échap → Options → Touches)", FONT_SMALL, Color(0.8, 0.75, 0.6)))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 1)
	hv.add_child(grid)
	for row in [
		["Pavé 8 2", "Avancer / reculer"], ["Pavé 4 6", "Pivoter (la caméra suit)"],
		["Pavé /, Maj", "Marcher / courir"], ["ZQSD / stick G", "Pas de côté"],
		["A E, flèches / clic droit maintenu / stick D", "Caméra"], ["Clic G sur un ennemi", "Cibler (re-clic : attaquer)"], ["Pg↑ Pg↓, pavé 9 3", "Zoom"], ["Pavé 5, V", "Vue 1re / 3e personne"],
		["Tab, pavé 0 / L1 R1", "Cibler (hors combat : aussi PNJ, joueurs)"], ["F8", "Cibler le plus proche"], ["Carré", "Attaquer la cible (engager)"],
		["(menu ouvert)", "Attaquer · Compétences · Magie · Objets · Fuir — reste ouvert en combat"],
		["Flèches ↑↓ / croix dir.", "Naviguer dans le menu"], ["Échap, pavé − / Rond", "Revenir en arrière"],
		["Clic D / L2", "Garde au bouclier (guerrier)"], ["Espace / R2", "Esquiver"],
		["F, Entrée / Croix", "Action : combat, parler, menu du joueur, interagir"], ["Rond", "Interagir, relever un allié"],
		["R / menu", "Se reposer (hors combat, régénère)"], ["Échap / Options", "Menu système, réglages, touches"],
		["G / Triangle", "Boire une potion"], ["I / Croix gauche", "Inventaire"],
		["C / Croix droite", "Feuille de personnage"], ["J", "Journal de quêtes"],
		["Maj+Échap", "Retour au menu"], ["F1 · F2", "Debug : invulnérable · soin"],
	]:
		grid.add_child(_make_label(row[0], FONT_SMALL, Color(0.95, 0.9, 0.75)))
		grid.add_child(_make_label(row[1], FONT_SMALL, Color(0.8, 0.8, 0.85)))

	# --- Message d'état (centre) ---
	_status = _make_label("", 22, Color(1, 0.35, 0.35))
	_status.set_anchors_preset(Control.PRESET_CENTER)
	_status.anchor_left = 0.5
	_status.anchor_right = 0.5
	_status.anchor_top = 0.5
	_status.anchor_bottom = 0.5
	_status.offset_left = -320
	_status.offset_right = 320
	_status.offset_top = -40
	_status.offset_bottom = 0
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_status)

	# --- Cible (haut centre) ---
	_target_panel = PanelContainer.new()
	_target_panel.add_theme_stylebox_override("panel", _panel_style(6))
	_target_panel.anchor_left = 0.5
	_target_panel.anchor_right = 0.5
	_target_panel.anchor_top = 0.0
	_target_panel.anchor_bottom = 0.0
	_target_panel.offset_left = -150
	_target_panel.offset_right = 150
	_target_panel.offset_top = 72
	_target_panel.offset_bottom = 72 + 68
	_target_panel.visible = false
	_root.add_child(_target_panel)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 3)
	_target_panel.add_child(tv)
	_target_label = _make_label("Cible", FONT_NORMAL, Color(1, 0.9, 0.7))
	_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(_target_label)
	var th := Control.new()
	th.custom_minimum_size = Vector2(0, 12)
	tv.add_child(th)
	_target_bar = _make_bar(Color(0.8, 0.25, 0.2), Color(0.25, 0.08, 0.06), 12)
	_target_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	th.add_child(_target_bar)
	_target_text = _make_label("", 10)
	_target_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_target_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	th.add_child(_target_text)
	_target_sub = _make_label("", FONT_SMALL, Color(0.85, 0.85, 0.9))
	_target_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(_target_sub)

	# --- Barre d'incantation (centre bas) ---
	_cast_panel = PanelContainer.new()
	_cast_panel.add_theme_stylebox_override("panel", _panel_style(6))
	_cast_panel.anchor_left = 0.5
	_cast_panel.anchor_right = 0.5
	_cast_panel.anchor_top = 1.0
	_cast_panel.anchor_bottom = 1.0
	_cast_panel.offset_left = -130
	_cast_panel.offset_right = 130
	_cast_panel.offset_top = -200
	_cast_panel.offset_bottom = -156
	_cast_panel.visible = false
	_root.add_child(_cast_panel)
	var castv := VBoxContainer.new()
	castv.add_theme_constant_override("separation", 2)
	_cast_panel.add_child(castv)
	_cast_label = _make_label("Incantation", FONT_SMALL, Color(0.75, 0.85, 1.0))
	_cast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	castv.add_child(_cast_label)
	_cast_bar = _make_bar(Color(0.45, 0.6, 1.0), Color(0.1, 0.12, 0.25), 10)
	_cast_bar.custom_minimum_size = Vector2(0, 10)
	_cast_bar.max_value = 1.0
	castv.add_child(_cast_bar)

	# --- Menu de commandes (bas, à droite du journal) ---
	_menu_panel = PanelContainer.new()
	_menu_panel.add_theme_stylebox_override("panel", _panel_style(8))
	# Ancré en bas, juste à droite du journal ; hauteur fixe, taille explicite (pas de croissance automatique).
	_menu_panel.anchor_left = 0.0
	_menu_panel.anchor_right = 0.0
	_menu_panel.anchor_top = 1.0
	_menu_panel.anchor_bottom = 1.0
	_menu_panel.offset_left = 12 + 440 + 12
	_menu_panel.offset_right = 12 + 440 + 12 + 240
	_menu_panel.offset_top = -172
	_menu_panel.offset_bottom = -12
	_menu_panel.visible = false
	_root.add_child(_menu_panel)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 2)
	_menu_panel.add_child(mv)
	_menu_title = _make_label("Commandes   (↑↓ · Entrée · Échap)", FONT_SMALL, Color(0.8, 0.75, 0.6))
	mv.add_child(_menu_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mv.add_child(scroll)
	_menu_box = VBoxContainer.new()
	_menu_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_box.add_theme_constant_override("separation", 1)
	scroll.add_child(_menu_box)

	# --- Monstres qui m'attaquent (à droite du menu de commandes) : icône, nom, PV ; clic = cibler ---
	_aggro_panel = PanelContainer.new()
	_aggro_panel.add_theme_stylebox_override("panel", _panel_style(6))
	_aggro_panel.anchor_left = 0.0
	_aggro_panel.anchor_right = 0.0
	_aggro_panel.anchor_top = 1.0
	_aggro_panel.anchor_bottom = 1.0
	_aggro_panel.offset_left = 12 + 440 + 12 + 240 + 8
	_aggro_panel.offset_right = 12 + 440 + 12 + 240 + 8 + 230
	_aggro_panel.offset_bottom = -12
	_aggro_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_aggro_panel.visible = false
	_root.add_child(_aggro_panel)
	_aggro_box = VBoxContainer.new()
	_aggro_box.add_theme_constant_override("separation", 3)
	_aggro_panel.add_child(_aggro_box)

	# --- Barre de boss (haut centre, visible quand un boss est engagé) ---
	_boss_panel = PanelContainer.new()
	_boss_panel.add_theme_stylebox_override("panel", _panel_style(6))
	_boss_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_boss_panel.anchor_left = 0.5
	_boss_panel.anchor_right = 0.5
	_boss_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_boss_panel.offset_top = 12
	_boss_panel.custom_minimum_size = Vector2(420, 0)
	_boss_panel.visible = false
	_root.add_child(_boss_panel)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 3)
	_boss_panel.add_child(bv)
	_boss_label = _make_label("Boss", FONT_TITLE, Color(1, 0.8, 0.6))
	_boss_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(_boss_label)
	var bh := Control.new()
	bh.custom_minimum_size = Vector2(0, 14)
	bv.add_child(bh)
	_boss_bar = _make_bar(Color(0.75, 0.15, 0.15), Color(0.2, 0.05, 0.05), 14)
	_boss_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bh.add_child(_boss_bar)
	_boss_text = _make_label("", FONT_SMALL)
	_boss_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_boss_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bh.add_child(_boss_text)

	# --- Feuille de personnage (centre gauche, masquée) ---
	_sheet_panel = PanelContainer.new()
	_sheet_panel.add_theme_stylebox_override("panel", _panel_style(12))
	_sheet_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_sheet_panel.anchor_top = 0.5
	_sheet_panel.anchor_bottom = 0.5
	_sheet_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_sheet_panel.offset_left = 12
	_sheet_panel.custom_minimum_size = Vector2(330, 0)
	_sheet_panel.visible = false
	_root.add_child(_sheet_panel)
	_sheet_body = VBoxContainer.new()
	_sheet_body.add_theme_constant_override("separation", 3)
	_sheet_panel.add_child(_sheet_body)

	# --- Écran de fin (centre, masqué) ---
	_end_panel = PanelContainer.new()
	_end_panel.add_theme_stylebox_override("panel", _panel_style(16))
	_end_panel.set_anchors_preset(Control.PRESET_CENTER)
	_end_panel.anchor_left = 0.5
	_end_panel.anchor_right = 0.5
	_end_panel.anchor_top = 0.5
	_end_panel.anchor_bottom = 0.5
	_end_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_end_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_end_panel.custom_minimum_size = Vector2(520, 0)
	_end_panel.visible = false
	_root.add_child(_end_panel)

	# --- Bandeau de zone (haut, centré, s'efface) ---
	_banner = _make_label("", 30, Color(0.95, 0.9, 0.75))
	_banner.anchor_left = 0.5
	_banner.anchor_right = 0.5
	_banner.anchor_top = 0.0
	_banner.anchor_bottom = 0.0
	_banner.offset_left = -400
	_banner.offset_right = 400
	_banner.offset_top = 150
	_banner.offset_bottom = 200
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.modulate.a = 0.0
	_root.add_child(_banner)

	# --- Dialogue PNJ / boutique (centre, masqué) ---
	_dialog_panel = PanelContainer.new()
	_dialog_panel.add_theme_stylebox_override("panel", _panel_style(14))
	_dialog_panel.anchor_left = 0.5
	_dialog_panel.anchor_right = 0.5
	_dialog_panel.anchor_top = 0.5
	_dialog_panel.anchor_bottom = 0.5
	_dialog_panel.offset_left = -260
	_dialog_panel.offset_right = 260
	_dialog_panel.offset_top = -200
	_dialog_panel.offset_bottom = 120
	_dialog_panel.visible = false
	_root.add_child(_dialog_panel)
	var dscroll := ScrollContainer.new()
	dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dialog_panel.add_child(dscroll)
	_dialog_body = VBoxContainer.new()
	_dialog_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dialog_body.add_theme_constant_override("separation", 6)
	dscroll.add_child(_dialog_body)

	# --- Journal de quêtes (centre gauche, masqué) ---
	_journal_panel = PanelContainer.new()
	_journal_panel.add_theme_stylebox_override("panel", _panel_style(12))
	_journal_panel.anchor_left = 0.0
	_journal_panel.anchor_right = 0.0
	_journal_panel.anchor_top = 0.5
	_journal_panel.anchor_bottom = 0.5
	_journal_panel.offset_left = 12
	_journal_panel.offset_right = 12 + 360
	_journal_panel.offset_top = -180
	_journal_panel.offset_bottom = 120
	_journal_panel.visible = false
	_root.add_child(_journal_panel)
	var jscroll := ScrollContainer.new()
	jscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_journal_panel.add_child(jscroll)
	_journal_body = VBoxContainer.new()
	_journal_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_journal_body.add_theme_constant_override("separation", 4)
	jscroll.add_child(_journal_body)

	# --- Inventaire (centre droit, masqué) ---
	_inv_panel = PanelContainer.new()
	_inv_panel.add_theme_stylebox_override("panel", _panel_style(10))
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_inv_panel.anchor_left = 1.0
	_inv_panel.anchor_right = 1.0
	_inv_panel.anchor_top = 0.5
	_inv_panel.anchor_bottom = 0.5
	_inv_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_inv_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_inv_panel.offset_right = -12
	_inv_panel.custom_minimum_size = Vector2(340, 0)
	_inv_panel.visible = false
	_root.add_child(_inv_panel)
	var iv := VBoxContainer.new()
	iv.add_theme_constant_override("separation", 4)
	_inv_panel.add_child(iv)
	_inv_title = _make_label("Inventaire", FONT_TITLE, Color(0.95, 0.9, 0.75))
	iv.add_child(_inv_title)
	_inv_list = VBoxContainer.new()
	_inv_list.add_theme_constant_override("separation", 2)
	iv.add_child(_inv_list)
	iv.add_child(_make_label("I : fermer", 10, Color(0.6, 0.6, 0.65)))

	# --- Menu système (Échap / Options) ---
	_sys_panel = PanelContainer.new()
	_sys_panel.add_theme_stylebox_override("panel", _panel_style(16))
	_sys_panel.anchor_left = 0.5
	_sys_panel.anchor_right = 0.5
	_sys_panel.anchor_top = 0.5
	_sys_panel.anchor_bottom = 0.5
	_sys_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_sys_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_sys_panel.custom_minimum_size = Vector2(300, 0)
	_sys_panel.visible = false
	_root.add_child(_sys_panel)
	_sys_body = VBoxContainer.new()
	_sys_body.add_theme_constant_override("separation", 8)
	_sys_panel.add_child(_sys_body)


# ============================================================ liaison joueur

func bind_player(p: PlayerCharacter) -> void:
	if player == p:
		return
	player = p
	player.health.changed.connect(_on_hp_changed)
	player.health.downed.connect(func(): _status.text = "À TERRE — un allié peut vous relever (F ou Rond)")
	player.health.revived.connect(func(): _status.text = "")
	_last_job = player.class_id
	_last_level = player.stats.level
	player.stats.level_changed.connect(func(lvl: int):
		_refresh_identity()
		# Un changement de job change aussi le niveau : on n'annonce que les vraies montées.
		if player.class_id == _last_job and lvl > _last_level:
			chat_system("[color=#ffd866]Niveau %d atteint ![/color]" % lvl)
		_last_level = lvl
		_last_job = player.class_id)
	player.job_changed.connect(func(job: String):
		_last_job = job
		_last_level = player.stats.level
		_refresh_identity()
		if _sheet_panel.visible:
			_refresh_character_sheet()
		if _menu_open:
			_rebuild_menu())
	_refresh_identity()
	_on_hp_changed(player.health.hp, player.health.max_hp)
	player.inventory.changed.connect(_refresh_inventory)
	player.inventory.changed.connect(_on_chest_changed)
	_target_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.55
	ring.outer_radius = 0.75
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(1.0, 0.75, 0.2, 0.9)
	rm.emission_enabled = true
	rm.emission = Color(1.0, 0.6, 0.1)
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material = rm
	_target_marker.mesh = ring
	_target_marker.visible = false
	_target_marker.top_level = true
	player.add_child(_target_marker)
	_refresh_inventory()


func _process(delta: float) -> void:
	if player == null:
		return
	var nxt := Rules.xp_for_next_level(player.stats.level)
	var prev: int = Rules.XP_TABLE[player.stats.level - 1] if player.stats.level - 1 < Rules.XP_TABLE.size() else 0
	if nxt > 0:
		_xp_bar.max_value = nxt - prev
		_xp_bar.value = player.stats.xp - prev
		_xp_text.text = "XP %d / %d" % [player.stats.xp, nxt]
	else:
		_xp_bar.max_value = 1
		_xp_bar.value = 1
		_xp_text.text = "Niveau max"
	_ally_refresh -= delta
	if _ally_refresh <= 0.0:
		_ally_refresh = 0.25
		_refresh_allies()
	_refresh_boss()
	_refresh_combat(delta)
	_aggro_refresh -= delta
	if _aggro_refresh <= 0.0:
		_aggro_refresh = 0.2
		_refresh_aggro()
	if _menu_open:
		_menu_refresh -= delta
		if _menu_refresh <= 0.0:
			_menu_refresh = 0.5
			_rebuild_menu()


func _refresh_combat(_delta: float) -> void:
	var cb: PlayerCombat = player.combat
	# Fin de combat : la cible meurt (ou disparaît) → on passe à un monstre qui nous attaque encore,
	# sinon le menu de commandes se referme tout seul.
	var alive := cb.target_alive()
	if _prev_target_alive and not alive:
		_on_target_lost()
	elif not alive and player.current_selection() == null:
		# Rien de sélectionné et un monstre nous prend pour cible : il devient la cible.
		var att := attackers()
		if not att.is_empty():
			player.select_node(att[0])
	_prev_target_alive = cb.target_alive()
	_tp_bar.value = cb.tp
	_tp_text.text = "TP %d%%" % cb.tp + ("  — WS prête !" if cb.tp >= PlayerCombat.TP_READY else "")
	_tp_text.add_theme_color_override("font_color", Color(1, 0.95, 0.5) if cb.tp >= PlayerCombat.TP_READY else Color(1, 0.95, 0.8))
	var t: Node3D = cb.target()
	if t == null or not is_instance_valid(t):
		t = player.current_selection()
	if t is Npc:
		_target_panel.visible = true
		_target_label.text = (t as Npc).npc_name
		_target_label.add_theme_color_override("font_color", Color(0.75, 1.0, 0.75))
		_target_bar.max_value = 1
		_target_bar.value = 1
		_target_text.text = "PNJ"
		var d := player.global_position.distance_to(t.global_position)
		_target_sub.text = "F / Entrée : parler" if d <= PlayerCharacter.TALK_RANGE else "Trop loin (%.0f m) — approchez-vous" % d
		_target_sub.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
		_place_marker(t, Color(0.4, 1.0, 0.5, 0.9), _delta)
	elif t and is_instance_valid(t):
		_target_panel.visible = true
		var tname: String = t.stats.display_name if t.has_node("StatBlock") else t.name
		_target_label.text = tname + ("  — engagé" if cb.engaged else "")
		_target_label.add_theme_color_override("font_color", Color(1, 0.6, 0.5) if cb.engaged else Color(1, 0.9, 0.7))
		_target_bar.max_value = t.health.max_hp
		_target_bar.value = t.health.hp
		_target_text.text = "%d / %d" % [t.health.hp, t.health.max_hp]
		var sub := ""
		if t is Enemy:
			if t.preparing != "":
				sub = "⚠ prépare : %s" % t.preparing
			else:
				sub = "TP %d%%" % t.tp
			var conds: Array[String] = t.condition_names()
			if not conds.is_empty():
				sub += "  · " + ", ".join(conds)
		if t is PlayerCharacter:
			sub = "Joueur — F / Entrée : menu (échanges)"
		_target_sub.text = sub
		_target_sub.add_theme_color_override("font_color", Color(1.0, 0.55, 0.3) if (t is Enemy and t.preparing != "") else Color(0.85, 0.85, 0.9))
		if _target_marker:
			_target_marker.visible = true
			_target_marker.global_position = t.global_position + Vector3(0, 0.05, 0)
			_target_marker.rotation.y += _delta * 1.5
			var rm: StandardMaterial3D = _target_marker.mesh.material
			rm.albedo_color = Color(1.0, 0.4, 0.25, 0.9) if cb.engaged else Color(1.0, 0.75, 0.2, 0.9)
	else:
		_target_panel.visible = false
		if _target_marker:
			_target_marker.visible = false
	var my_conds: Array[String] = player.condition_names()
	if player.resting:
		my_conds.push_front("au repos")
	_cond_label.visible = not my_conds.is_empty()
	_cond_label.text = ", ".join(my_conds)
	if cb.is_casting() and cb.cast_total > 0.0:
		_cast_panel.visible = true
		_cast_label.text = GameData.spell(cb.casting_id).get("name", cb.casting_id)
		_cast_bar.value = 1.0 - cb.cast_left / cb.cast_total
	else:
		_cast_panel.visible = false


## Affiche la barre du boss le plus proche encore en vie et engagé (ou récemment blessé).
## Monstres vivants qui s'en prennent au joueur local (le plus proche d'abord).
func attackers() -> Array:
	var out: Array = []
	if player == null:
		return out
	for e in get_tree().get_nodes_in_group("enemies"):
		if e is Enemy and e.target_peer == player.peer_id and e.health.is_alive():
			out.append(e)
	out.sort_custom(func(a, b): return a.global_position.distance_to(player.global_position) < b.global_position.distance_to(player.global_position))
	return out


func _on_target_lost() -> void:
	var att := attackers()
	if not att.is_empty():
		player.select_node(att[0])
		chat_system("Nouvelle cible : [b]%s[/b] vous attaque." % att[0].stats.display_name)
		_prev_target_alive = true
	elif _menu_open:
		close_menu()


func _refresh_aggro() -> void:
	var att := attackers()
	_aggro_panel.visible = not att.is_empty()
	for c in _aggro_box.get_children():
		_aggro_box.remove_child(c)
		c.queue_free()
	if att.is_empty():
		return
	_aggro_box.add_child(_make_label("Vous attaquent (%d) — clic / L1 R1" % att.size(), FONT_SMALL, Color(1.0, 0.65, 0.5)))
	var cur := player.combat.target()
	for e in att.slice(0, 6):
		var en: Enemy = e
		var row := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.45, 0.2, 0.15, 0.85) if en == cur else Color(0, 0, 0, 0.25)
		sb.set_corner_radius_all(3)
		sb.set_content_margin_all(3)
		row.add_theme_stylebox_override("panel", sb)
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		row.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and is_instance_valid(en):
				player.select_node(en))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(h)
		h.add_child(_monster_icon(en.monster_id))
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 1)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(v)
		var name_txt: String = en.stats.display_name + ("  ⚠" if en.preparing != "" else "")
		var nl := _make_label(name_txt, FONT_SMALL, Color(1, 0.9, 0.8) if en == cur else Color(0.9, 0.9, 0.92))
		nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(nl)
		var bar := _make_bar(COLOR_HP, COLOR_HP_BG, 7)
		bar.max_value = maxi(en.health.max_hp, 1)
		bar.value = en.health.hp
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(bar)
		_aggro_box.add_child(row)


## Petite icône du monstre : pastille à sa couleur avec son symbole (en attendant de vrais portraits).
const MONSTER_GLYPHS := {"rabbit": "🐇", "wolf": "🐺", "boar": "🐗", "giant_bee": "🐝", "giant_spider": "🕷",
	"goblin": "G", "goblin_archer": "🏹", "goblin_boss": "♛", "skeleton": "☠", "ogre": "O"}
func _monster_icon(monster_id: String) -> Control:
	var data := GameData.monster(monster_id)
	var tint := Color(str(data.get("tint", "#7a6a5a")))
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = tint.darkened(0.15)
	sb.border_color = tint.lightened(0.4)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(26, 26)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _make_label(MONSTER_GLYPHS.get(monster_id, str(data.get("name", "?")).substr(0, 1)), 14, Color.WHITE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	p.add_child(l)
	return p


func _place_marker(t: Node3D, color: Color, delta: float) -> void:
	if _target_marker == null:
		return
	_target_marker.visible = true
	_target_marker.global_position = t.global_position + Vector3(0, 0.05, 0)
	_target_marker.rotation.y += delta * 1.5
	var rm: StandardMaterial3D = _target_marker.mesh.material
	rm.albedo_color = color


func _refresh_boss() -> void:
	var boss: Enemy = null
	for b in get_tree().get_nodes_in_group("bosses"):
		if b is Enemy and b.health.is_alive() and (b.health.hp < b.health.max_hp or b.global_position.distance_to(player.global_position) < 14.0):
			boss = b
			break
	_boss_panel.visible = boss != null
	if boss:
		_boss_label.text = boss.display_name() + (" — phase %d" % boss.phase if boss.phase > 0 else "")
		_boss_bar.max_value = boss.health.max_hp
		_boss_bar.value = boss.health.hp
		_boss_text.text = "%d / %d" % [boss.health.hp, boss.health.max_hp]


func _on_boss_phase(boss: Node3D, phase: int) -> void:
	var n := _short_name(boss)
	match phase:
		1:
			chat_line("[color=#ffb060][b]%s[/b] hurle et appelle ses gardes ![/color]" % n)
		2:
			chat_line("[color=#ffb060][b]%s[/b] est enragé : des archers arrivent et il frappe plus vite ![/color]" % n)
		_:
			chat_line("[color=#ffb060][b]%s[/b] entre en phase %d.[/color]" % [n, phase])


func _on_monster_skill(m: Node3D, skill_name: String) -> void:
	chat_line("[color=#ffa040]⚠ %s prépare [b]%s[/b] ![/color]" % [_short_name(m), skill_name])


func _on_level_cleared() -> void:
	chat_line("[color=#80ff90][b]Arène nettoyée ![/b] Tous les monstres sont vaincus.[/color]")
	_status.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	_status.text = "ARÈNE NETTOYÉE !"
	get_tree().create_timer(6.0).timeout.connect(func():
		if _status.text == "ARÈNE NETTOYÉE !":
			_status.text = ""
			_status.add_theme_color_override("font_color", Color(1, 0.35, 0.35)))


func _refresh_identity() -> void:
	var cls: Dictionary = GameData.player_class(player.class_id)
	_name_label.text = player.player_name if player.player_name != "" else player.stats.display_name
	_sub_label.text = "Niv %d · %s %s · CA %d" % [player.stats.level, GameData.race(player.race_id).get("name", ""), cls.get("name", ""), player.stats.armor_class()]


func _on_hp_changed(hp: int, max_hp: int) -> void:
	_hp_bar.max_value = max_hp
	_hp_bar.value = hp
	_hp_text.text = "%d / %d" % [hp, max_hp]
	if player:
		_sub_label.text = "Niv %d · %s %s · CA %d" % [player.stats.level, GameData.race(player.race_id).get("name", ""), GameData.player_class(player.class_id).get("name", ""), player.stats.armor_class()]


## Mini-cadres des coéquipiers (nom + barre de PV).
func _refresh_allies() -> void:
	var seen := {}
	for p in get_tree().get_nodes_in_group("players"):
		if not (p is PlayerCharacter) or p == player:
			continue
		seen[p] = true
		if not _ally_frames.has(p):
			var fr := PanelContainer.new()
			fr.add_theme_stylebox_override("panel", _panel_style(5))
			fr.custom_minimum_size = Vector2(200, 0)
			var fv := VBoxContainer.new()
			fv.add_theme_constant_override("separation", 2)
			fr.add_child(fv)
			var lbl := _make_label(p.player_name, FONT_SMALL)
			fv.add_child(lbl)
			var holder := Control.new()
			holder.custom_minimum_size = Vector2(0, 10)
			fv.add_child(holder)
			var bar := _make_bar(COLOR_ALLY_HP, COLOR_HP_BG, 10)
			bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			holder.add_child(bar)
			_allies_box.add_child(fr)
			_ally_frames[p] = {"frame": fr, "bar": bar, "label": lbl}
		var f: Dictionary = _ally_frames[p]
		f.bar.max_value = p.health.max_hp
		f.bar.value = p.health.hp
		var state := ""
		if p.health.is_downed:
			state = "  [À TERRE]"
		elif p.health.is_dead:
			state = "  [mort]"
		f.label.text = "%s · %d/%d%s" % [p.player_name, p.health.hp, p.health.max_hp, state]
	for p in _ally_frames.keys():
		if not seen.has(p):
			_ally_frames[p].frame.queue_free()
			_ally_frames.erase(p)


# ============================================================ fenêtre de combat

func chat_line(bbcode: String) -> void:
	var t := Time.get_time_dict_from_system()
	_chat.append_text("[color=#777777]%02d:%02d[/color] %s\n" % [t.hour, t.minute, bbcode])
	if _chat.get_line_count() > CHAT_MAX_LINES:
		_chat.remove_paragraph(0)


func chat_system(bbcode: String) -> void:
	chat_line("[color=#b0b0c0]%s[/color]" % bbcode)


func _on_hit_resolved(target: Node3D, r: Dictionary) -> void:
	if not is_instance_valid(target):
		return
	var attacker: Node = r.get("attacker")
	var a_name := _short_name(attacker)
	var t_name := _short_name(target)
	var dtype := CombatRules.damage_type_name(r.get("damage_type", 0))
	var what: String = (" (%s)" % r.attack_name) if r.get("attack_name", "") != "" and attacker is PlayerCharacter else ""
	var line: String
	if r.has("heal"):
		chat_line("[color=#80e090]%s boit %s : +%d PV[/color]" % [t_name, r.get("attack_name", "une potion"), int(r.heal)])
		return
	if r.has("save_d20"):
		var verdict: String = "esquivée" if r.get("evaded", false) else ("ok" if r.save_success else "ratée")
		var cond_txt: String = "" if not r.has("condition") else " → %s" % Creature.CONDITION_NAMES.get(r.condition, r.condition)
		line = "%s%s → %s : sauv. %d vs DD %d %s → [b]%d[/b] %s%s" % [
			a_name, what, t_name, r.save_total, r.dc, verdict, r.damage, dtype, cond_txt]
	elif r.get("auto_hit", false):
		line = "%s%s → %s : [b]%d[/b] %s" % [a_name, what, t_name, r.damage, dtype]
	elif r.get("hit", false):
		var extra := ""
		if r.get("crit", false):
			extra += " [color=#ffa030]CRITIQUE[/color]"
		if r.get("blocked", false):
			extra += " [color=#99ccff]bloqué[/color]"
		if r.get("condition", "") == "restrained":
			extra += " [color=#e0e0b0]entravé[/color]"
		line = "%s%s → %s : %d (%d) vs CA %d → [b]%d[/b] %s%s" % [
			a_name, what, t_name, r.d20, r.total, r.ac, r.damage, dtype, extra]
	else:
		line = "[color=#8a8a8a]%s%s → %s : %d (%d) vs CA %d → %s[/color]" % [
			a_name, what, t_name, r.d20, r.total, r.ac, "bloqué" if r.get("blocked", false) else "raté"]
	# Couleur selon qui est touché : rouge = un joueur encaisse, jaune = un monstre.
	if r.get("hit", false) and r.get("damage", 0) > 0:
		line = ("[color=#ff8080]%s[/color]" if target.is_in_group("players") else "[color=#f0e0a0]%s[/color]") % line
	chat_line(line)


func _on_creature_died(c: Node3D) -> void:
	if c.has_node("StatBlock"):
		chat_line("[color=#ff6060]%s est mort.[/color]" % _short_name(c))


func _on_creature_downed(c: Node3D) -> void:
	if c is PlayerCharacter:
		chat_line("[color=#ff6060]%s est à terre ![/color]" % _short_name(c))


func _short_name(n: Node) -> String:
	if n == null or not is_instance_valid(n):
		return "?"
	if n is PlayerCharacter:
		return n.player_name if n.player_name != "" else n.stats.display_name
	if n.has_node("StatBlock"):
		return n.stats.display_name
	return n.name


# ============================================================ menu de commandes

## F / Entrée / Croix sans menu ouvert : selon la sélection — ennemi → menu de combat, PNJ → dialogue,
## autre joueur → menu du joueur (échanges), objet à portée → interagir ; sinon le menu de commandes.
func context_open() -> void:
	if player == null:
		return
	match player.context_kind():
		"talk":
			player.context_action()
		"player":
			open_player_menu(player.current_selection())
		"interact":
			player.request_action("interact")
		_:
			open_menu()


func open_menu() -> void:
	if player == null or not player.health.is_alive():
		return
	_menu_open = true
	_menu_level = ""
	_menu_index = 0
	_update_player_block()
	_rebuild_menu()
	_menu_panel.visible = true


func close_menu() -> void:
	_menu_open = false
	_menu_panel.visible = false
	_update_player_block(true)  # le menu de commandes se ferme souvent en lançant une action : déblocage direct


func _menu_back() -> void:
	if _menu_level == "":
		close_menu()
	else:
		_menu_level = ""
		_menu_index = 0
		_rebuild_menu()


func _menu_move(dir: int) -> void:
	if _menu_items.is_empty():
		return
	_menu_index = (_menu_index + dir + _menu_items.size()) % _menu_items.size()
	_paint_menu()


func _menu_confirm() -> void:
	if _menu_items.is_empty() or _menu_index >= _menu_items.size():
		return
	var item: Dictionary = _menu_items[_menu_index]
	if not item.get("enabled", true):
		chat_system(item.get("hint", "Indisponible."))
		return
	var action: String = item.action
	match action:
		"submenu:skills", "submenu:magic", "submenu:items":
			_menu_level = action.trim_prefix("submenu:")
			_menu_index = 0
			_rebuild_menu()
		"engage_or_pick":
			player.attack_shortcut()
			_menu_back_to_root()
		"flee", "disengage", "rest":
			player.request_action(action)
			close_menu()
		_:
			# Façon FFXI : le menu reste ouvert pendant le combat (Échap / Rond pour le fermer).
			player.request_action(action)
			_menu_back_to_root()


func _menu_back_to_root() -> void:
	_menu_level = ""
	_menu_index = 0
	_menu_refresh = 0.15  # laisse l'hôte confirmer (engagement, TP…) avant de redessiner
	_rebuild_menu()


func _rebuild_menu() -> void:
	_menu_items.clear()
	var cb: PlayerCombat = player.combat
	match _menu_level:
		"":
			_menu_title.text = "Commandes   (↑↓ · F/Entrée · Échap : fermer)"
			if cb.engaged:
				_menu_items.append({"label": "Cesser le combat", "action": "disengage"})
			else:
				_menu_items.append({"label": "Attaquer", "action": "engage_or_pick",
					"enabled": not player.target_candidates().is_empty(), "hint": "Aucun ennemi à portée."})
			_menu_items.append({"label": "Compétences", "action": "submenu:skills"})
			if player.spell_book.is_caster():
				_menu_items.append({"label": "Magie", "action": "submenu:magic"})
			_menu_items.append({"label": "Objets", "action": "submenu:items"})
			if player.resting:
				_menu_items.append({"label": "Se lever", "action": "rest"})
			elif not cb.engaged:
				_menu_items.append({"label": "Se reposer", "action": "rest"})
			_menu_items.append({"label": "Fuir", "action": "flee", "enabled": cb.cooldowns_left.get("flee", 0.0) <= 0.0,
				"hint": "Fuite : encore %d s." % ceili(float(cb.cooldowns_left.get("flee", 0.0)))})
		"skills":
			_menu_title.text = "Compétences   (retour : Échap)"
			var ws := cb.weapon_skill()
			if not ws.is_empty():
				var ready: bool = cb.tp >= PlayerCombat.TP_READY
				_menu_items.append({"label": "%s  [WS %d%%]" % [ws.get("name", "WS"), cb.tp], "action": "weapon_skill",
					"enabled": ready and cb.target_alive(), "hint": "Il faut 100 TP et une cible." if not ready else "Choisis une cible."})
			for a in cb.abilities():
				var left: float = float(cb.cooldowns_left.get(a.id, 0.0))
				var label: String = a.name
				if a.get("type") == "guard_toggle":
					label += "  [%s]" % ("levée" if player.is_blocking else "baissée")
				elif left > 0.0:
					label += "  (%d s)" % ceili(left)
				_menu_items.append({"label": label, "action": "ability:" + a.id, "enabled": left <= 0.0,
					"hint": "%s : encore %d s." % [a.name, ceili(left)]})
		"magic":
			_menu_title.text = "Magie   (retour : Échap)"
			var book := player.spell_book
			for sid in book.known:
				var spell := GameData.spell(sid)
				var lvl: int = spell.get("level", 0)
				var slot_txt := "∞"
				if lvl > 0:
					slot_txt = "%d/%d" % [int(book.slots.get(str(lvl), 0)), int(book.max_slots.get(str(lvl), 0))]
				var usable := book.can_cast(sid)
				_menu_items.append({"label": "%s  [%s · %.1f s]" % [spell.get("name", sid), slot_txt, float(spell.get("cast_time", 1.0))],
					"action": "cast:" + sid, "enabled": usable, "hint": "Plus d'emplacement pour ce sort."})
		"items":
			_menu_title.text = "Objets   (retour : Échap)"
			for i in player.inventory.items.size():
				var entry: Dictionary = player.inventory.items[i]
				var data := Inventory.item_data(entry)
				if data.get("type", "") == "consumable":
					_menu_items.append({"label": "%s ×%d" % [Inventory.display_name(entry), entry.get("qty", 1)], "action": "use:%d" % i})
			if _menu_items.is_empty():
				_menu_items.append({"label": "(sac vide)", "action": "noop", "enabled": false, "hint": "Rien à utiliser."})
	_menu_index = clampi(_menu_index, 0, maxi(_menu_items.size() - 1, 0))
	_paint_menu()


func _paint_menu() -> void:
	for c in _menu_box.get_children():
		c.queue_free()
	for i in _menu_items.size():
		var item: Dictionary = _menu_items[i]
		var row := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.3, 0.38, 0.6, 0.9) if i == _menu_index else Color(0, 0, 0, 0)
		sb.set_content_margin_all(4)
		sb.set_corner_radius_all(3)
		row.add_theme_stylebox_override("panel", sb)
		var lbl := _make_label(("▸ " if i == _menu_index else "   ") + item.label, FONT_NORMAL,
			Color.WHITE if item.get("enabled", true) else Color(0.55, 0.55, 0.6))
		row.add_child(lbl)
		var idx := i
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		row.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_menu_index = idx
				_menu_confirm())
		row.mouse_entered.connect(func():
			if _menu_index != idx:
				_menu_index = idx
				_paint_menu())
		_menu_box.add_child(row)


# ============================================================ menu système

func toggle_system_menu() -> void:
	if _sys_panel.visible:
		close_system_menu()
	else:
		open_system_menu()


func open_system_menu() -> void:
	if _menu_open:
		close_menu()
	_quit_armed = false
	_build_system_menu()
	_sys_panel.visible = true
	UiTheme.focus_first(_sys_body)
	_update_player_block()


func close_system_menu() -> void:
	_sys_panel.visible = false
	_update_player_block()


func _build_system_menu() -> void:
	_clear(_sys_body)
	_sys_body.add_child(_make_label("Menu", FONT_TITLE + 2, Color(0.95, 0.85, 0.6)))
	if not Net.is_solo:
		_sys_body.add_child(_make_label("Le jeu continue pendant que ce menu est ouvert.", FONT_SMALL, Color(0.7, 0.7, 0.75)))
	_sys_body.add_child(_button("Reprendre", close_system_menu))
	_sys_body.add_child(_button("Options", func():
		var m := OptionsMenu.open(self)
		_sys_panel.visible = false
		_update_player_block()
		m.closed.connect(func():
			# Retour au menu système (le focus y revient pour la manette).
			if is_inside_tree():
				open_system_menu())))
	_sys_body.add_child(_button("Aide des commandes (H)", _toggle_help))
	# Retour de test : la note part dans « Retour de test.txt » avec la zone, le job, la position…
	var note_row := HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 6)
	var note := LineEdit.new()
	note.placeholder_text = "Retour de test (ce qui ne va pas, ici)…"
	note.custom_minimum_size = Vector2(240, 0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var send := func():
		var saved := SessionLog.add_note(note.text)
		if saved != "":
			note.text = ""
			note.placeholder_text = "Noté ✔ — merci !"
			chat_system("Retour noté : " + saved)
	note.text_submitted.connect(func(_t: String): send.call())
	note_row.add_child(note)
	note_row.add_child(_button("Noter", send))
	_sys_body.add_child(note_row)
	var leave_txt := "Quitter vers le menu principal"
	if Net.is_host and not Net.is_solo:
		leave_txt = "Fermer la partie (le coéquipier est déconnecté)"
	elif not Net.is_host:
		leave_txt = "Quitter la partie"
	var leave := _button(leave_txt, func(): pass)
	leave.pressed.connect(func():
		if _quit_armed:
			Net.leave_to_menu()
		else:
			_quit_armed = true
			leave.text = "Confirmer : " + leave_txt.to_lower() + " ?")
	_sys_body.add_child(leave)
	var quit := _button("Quitter le jeu", func(): pass)
	quit.pressed.connect(func():
		if quit.text.begins_with("Confirmer"):
			Characters.quit_game()
		else:
			quit.text = "Confirmer : quitter le jeu ?")
	_sys_body.add_child(quit)
	_sys_body.add_child(_make_label("Échap / Rond : revenir au jeu", 10, Color(0.6, 0.6, 0.65)))


# ============================================================ inventaire

func toggle_inventory() -> void:
	_inv_panel.visible = not _inv_panel.visible
	if _inv_panel.visible:
		_refresh_inventory()
		if _pad_mode:
			UiTheme.focus_first(_inv_list)


func _on_item_picked(entry: Dictionary) -> void:
	var data := Inventory.item_data(entry)
	if data.get("type", "") == "currency":
		chat_line("[color=#f0d070]+%d pièces d'or[/color]" % int(entry.get("qty", 1)))
	else:
		var col := Inventory.rarity_color(entry).to_html(false)
		var qty := int(entry.get("qty", 1))
		chat_line("Ramassé : [color=#%s]%s[/color]%s" % [col, Inventory.display_name(entry), (" ×%d" % qty) if qty > 1 else ""])


func _refresh_inventory() -> void:
	if player == null:
		return
	var inv := player.inventory
	_gold_label.text = "%d po  ·  %d potion(s)" % [inv.gold, inv.count("potion_healing") + inv.count("potion_greater_healing")]
	if not _inv_panel.visible:
		return
	var focus_idx := _focus_index(_inv_list)
	_clear(_inv_list)
	_inv_title.text = "Inventaire — %d po" % inv.gold
	# Équipement
	_inv_list.add_child(_make_label("Équipé", FONT_SMALL, Color(0.8, 0.75, 0.6)))
	for slot in ["weapon", "armor", "shield"]:
		var row := HBoxContainer.new()
		var slot_name: String = {"weapon": "Arme", "armor": "Armure", "shield": "Bouclier"}[slot]
		if inv.equipped.has(slot):
			var e: Dictionary = inv.equipped[slot]
			var l := _make_label("%s : %s" % [slot_name, Inventory.display_name(e)], FONT_SMALL, Inventory.rarity_color(e))
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(l)
			var b := Button.new()
			b.text = "Retirer"
			b.add_theme_font_size_override("font_size", FONT_SMALL)
			b.pressed.connect(func(): player.request_action("unequip:" + slot))
			row.add_child(b)
		else:
			var l := _make_label("%s : —" % slot_name, FONT_SMALL, Color(0.55, 0.55, 0.6))
			row.add_child(l)
		_inv_list.add_child(row)
	# Sac
	_inv_list.add_child(_make_label("Sac (%d/%d)" % [inv.items.size(), Inventory.MAX_SLOTS], FONT_SMALL, Color(0.8, 0.75, 0.6)))
	if inv.items.is_empty():
		_inv_list.add_child(_make_label("(vide)", FONT_SMALL, Color(0.55, 0.55, 0.6)))
	for i in inv.items.size():
		var e: Dictionary = inv.items[i]
		var data := Inventory.item_data(e)
		var row := HBoxContainer.new()
		var qty := int(e.get("qty", 1))
		var txt := Inventory.display_name(e) + ((" ×%d" % qty) if qty > 1 else "")
		var t: String = data.get("type", "")
		if t == "weapon":
			txt += "  (%s %s)" % [data.get("damage", ""), CombatRules.damage_type_name(StatBlock.damage_type_from_string(data.get("damage_type", "bludgeoning")))]
		elif t == "armor":
			txt += "  (CA %d)" % int(data.get("base_ac", 10))
		elif t == "shield":
			txt += "  (+%d CA)" % int(data.get("ac_bonus", 0))
		var l := _make_label(txt, FONT_SMALL, Inventory.rarity_color(e))
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		if t in ["weapon", "armor", "shield"]:
			var b := Button.new()
			var wjob := PlayerCharacter.job_for_item(e)
			b.text = "Équiper" if wjob == "" or wjob == player.class_id else "Équiper → %s" % GameData.player_class(wjob).get("name", wjob)
			b.add_theme_font_size_override("font_size", FONT_SMALL)
			var idx := i
			b.pressed.connect(func(): player.request_action("equip:%d" % idx))
			row.add_child(b)
		elif t == "consumable":
			var b := Button.new()
			b.text = "Utiliser"
			b.add_theme_font_size_override("font_size", FONT_SMALL)
			var idx := i
			b.pressed.connect(func(): player.request_action("use:%d" % idx))
			row.add_child(b)
		_inv_list.add_child(row)
	_restore_focus(_inv_list, focus_idx)


# ============================================================ feuille de personnage

func toggle_character_sheet() -> void:
	_sheet_panel.visible = not _sheet_panel.visible
	if _sheet_panel.visible:
		_refresh_character_sheet()


func _sheet_row(label: String, value: String, color := Color.WHITE) -> void:
	var h := HBoxContainer.new()
	var l := _make_label(label, FONT_SMALL, Color(0.75, 0.75, 0.8))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	var v := _make_label(value, FONT_SMALL, color)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(v)
	_sheet_body.add_child(h)


func _refresh_character_sheet() -> void:
	for c in _sheet_body.get_children():
		c.queue_free()
	if player == null:
		return
	var st: StatBlock = player.stats
	var cls: Dictionary = GameData.player_class(player.class_id)
	_sheet_body.add_child(_make_label("Feuille de personnage   (C : fermer)", FONT_TITLE, Color(0.9, 0.85, 0.7)))
	_sheet_body.add_child(_make_label("%s — %s %s niveau %d" % [
		player.player_name if player.player_name != "" else st.display_name,
		GameData.race(player.race_id).get("name", ""), cls.get("name", ""), st.level], FONT_NORMAL))
	var nxt := Rules.xp_for_next_level(st.level)
	_sheet_row("Expérience", "%d / %s" % [st.xp, str(nxt) if nxt > 0 else "max"])
	# Jobs façon FFXI : le job suit l'arme équipée ; chaque job a son niveau.
	var job_txt: Array[String] = []
	for jid in GameData.classes:
		var lvl := int(player.jobs.get(jid, {}).get("level", 0))
		if jid == player.class_id:
			lvl = st.level
		job_txt.append("%s %s" % [GameData.player_class(jid).get("name", jid), str(lvl) if lvl > 0 else "—"])
	_sheet_row("Jobs", "  ·  ".join(job_txt), Color(0.8, 0.9, 1.0))
	_sheet_row("Origine", "%s (caractéristiques de départ)" % GameData.player_class(player.start_class).get("name", player.start_class), Color(0.7, 0.7, 0.75))
	var hind := player.combat.armor_hindrance()
	if hind != "":
		_sheet_row("⚠ Incantation", "impossible avec %s" % hind, Color(1.0, 0.6, 0.4))
	_sheet_body.add_child(HSeparator.new())
	var names := {"str": "Force", "dex": "Dextérité", "con": "Constitution", "int": "Intelligence", "wis": "Sagesse", "cha": "Charisme"}
	for a in ["str", "dex", "con", "int", "wis", "cha"]:
		var m := st.ability_mod(a)
		var prof: String = "  (sauv. +%d)" % st.save_bonus(a) if a in st.save_proficiencies else ""
		_sheet_row(names[a], "%d  (%s%d)%s" % [st.abilities.get(a, 10), "+" if m >= 0 else "", m, prof])
	_sheet_body.add_child(HSeparator.new())
	_sheet_row("Points de vie", "%d / %d" % [player.health.hp, player.health.max_hp], COLOR_HP)
	_sheet_row("Classe d'armure", str(st.armor_class()))
	_sheet_row("Bonus de maîtrise", "+%d" % st.proficiency())
	var w: Dictionary = player.weapon
	var w_ability: String = w.get("ability", "str")
	_sheet_row("Arme", "%s  (+%d, %s)" % [w.get("name", "—"), st.attack_bonus(w_ability, w.get("magic_bonus", 0)), w.get("damage", "")])
	_sheet_row("Vitesse", "%d pieds (%.1f m/s)" % [st.speed, st.move_speed_mps(true)])
	if player.spell_book and not player.spell_book.known.is_empty():
		_sheet_body.add_child(HSeparator.new())
		var sb: SpellBook = player.spell_book
		_sheet_row("Caractéristique de sort", names.get(sb.casting_ability, sb.casting_ability))
		_sheet_row("DD de sauvegarde", str(st.spell_save_dc(sb.casting_ability)))
		_sheet_row("Attaque de sort", "+%d" % st.spell_attack_bonus(sb.casting_ability))
		var slots_txt := ""
		for lvl in sb.max_slots:
			slots_txt += "N%s %d/%d  " % [str(lvl), sb.slots.get(lvl, 0), sb.max_slots[lvl]]
		_sheet_row("Emplacements", slots_txt.strip_edges())
		var known: Array = []
		for sid in sb.known:
			known.append(GameData.spell(sid).get("name", sid))
		_sheet_row("Sorts connus", ", ".join(known))
	var feats: Array = []
	if st.defense_style:
		feats.append("Style Défense")
	if st.mage_armor:
		feats.append("Armure du mage")
	for r in st.damage_resistances:
		feats.append("Résist. " + CombatRules.damage_type_name(r))
	if not feats.is_empty():
		_sheet_row("Traits", ", ".join(feats))


# ============================================================ écran de fin

func _show_end_screen(summary: Dictionary) -> void:
	for c in _end_panel.get_children():
		c.queue_free()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_end_panel.add_child(v)
	var title := _make_label("%s — terminé !" % summary.get("level_name", "Niveau"), 22, Color(0.95, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var dur: float = summary.get("duration", 0.0)
	var t := _make_label("Temps : %d min %02d s" % [int(dur) / 60, int(dur) % 60], FONT_NORMAL, Color(0.8, 0.8, 0.85))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	v.add_child(HSeparator.new())
	var grid := GridContainer.new()
	grid.columns = 1 + summary.get("players", []).size()
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 3)
	v.add_child(grid)
	var rows := [
		["", "name"], ["Classe", "class"], ["Niveau atteint", "level"], ["Monstres tués", "kills"],
		["Dégâts infligés", "damage_dealt"], ["Dégâts subis", "damage_taken"], ["Mises à terre", "downs"],
		["Potions bues", "potions"], ["Or", "gold"],
	]
	for row in rows:
		grid.add_child(_make_label(row[0], FONT_SMALL, Color(0.75, 0.75, 0.8)))
		for p in summary.get("players", []):
			var val = p.get(row[1], "")
			if row[1] == "class":
				val = "%s %s" % [p.get("race", ""), p.get("class", "")]
			var l := _make_label(str(val), FONT_NORMAL if row[1] == "name" else FONT_SMALL, Color(0.95, 0.9, 0.75) if row[1] == "name" else Color.WHITE)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			grid.add_child(l)
	v.add_child(HSeparator.new())
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	v.add_child(buttons)
	var cont := Button.new()
	cont.text = "Continuer à explorer"
	cont.pressed.connect(func(): _end_panel.visible = false)
	buttons.add_child(cont)
	var quit := Button.new()
	quit.text = "Retour au menu"
	quit.pressed.connect(func(): Net.leave_to_menu())
	buttons.add_child(quit)
	_end_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_status.text = ""


# ============================================================ zones, PNJ, quêtes

func _on_zone_entered(zone_name: String) -> void:
	_banner.text = zone_name
	_banner.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(2.5)
	tw.tween_property(_banner, "modulate:a", 0.0, 1.5)
	chat_system("Vous entrez dans [b]%s[/b]." % zone_name)


func _npc_data(npc_id: String) -> Dictionary:
	var game := get_tree().get_first_node_in_group("game")
	if game and game.level and game.level.has_method("npc_data"):
		return game.level.npc_data(npc_id)
	return {}


func _button(text: String, cb: Callable, enabled := true) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.add_theme_font_size_override("font_size", FONT_NORMAL)
	b.pressed.connect(cb)
	return b


func open_npc_dialog(npc_id: String) -> void:
	if _menu_open:
		close_menu()
	_dialog_npc = npc_id
	_dialog_mode = ""
	_dialog_panel.visible = true
	_refresh_dialog()
	UiTheme.focus_first(_dialog_body)
	_update_player_block()


func close_npc_dialog() -> void:
	_dialog_panel.visible = false
	_dialog_npc = ""
	_dialog_player = null
	_dialog_chest = false
	_update_player_block()


func _refresh_dialog() -> void:
	# On garde la position du focus (manette) quand la fenêtre se reconstruit après un achat, une vente…
	var focus_idx := _focus_index(_dialog_body)
	_clear(_dialog_body)
	_refresh_dialog_content()
	if focus_idx >= 0:
		_restore_focus(_dialog_body, focus_idx)
	elif _dialog_panel.visible and _pad_mode:
		UiTheme.focus_first(_dialog_body)


func _refresh_dialog_content() -> void:
	if _dialog_chest:
		_refresh_chest()
		return
	if _dialog_player != null:
		_refresh_player_menu()
		return
	var npc := _npc_data(_dialog_npc)
	if npc.is_empty() or player == null:
		return
	_dialog_body.add_child(_make_label(npc.get("name", "?"), FONT_TITLE, Color(0.95, 0.85, 0.6)))
	if _dialog_mode != "":
		_dialog_body.add_child(_make_label("Manette : croix ↑↓ choisir · Croix acheter/vendre · Rond retour", 10, Color(0.6, 0.6, 0.65)))
	match _dialog_mode:
		"":
			for line in npc.get("lines", []):
				var l := _make_label("« %s »" % line, FONT_NORMAL, Color(0.9, 0.9, 0.95))
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				_dialog_body.add_child(l)
			# Quêtes proposées / à rendre.
			for qid in npc.get("quests", []):
				var q := QuestLog.quest_data(qid)
				var ql: QuestLog = player.quest_log
				if ql.is_done(qid):
					continue
				if ql.is_active(qid):
					if ql.is_complete(qid, player.inventory):
						_dialog_body.add_child(_button("✔ Rendre : %s" % q.get("title", qid), func():
							player.request_action("quest_turnin:" + qid)
							_dialog_mode = ""
							get_tree().create_timer(0.2).timeout.connect(_refresh_dialog)))
					else:
						_dialog_body.add_child(_make_label("… %s (en cours)" % q.get("title", qid), FONT_SMALL, Color(0.7, 0.7, 0.75)))
				elif ql.can_accept(qid):
					var txt := _make_label(q.get("text", ""), FONT_SMALL, Color(0.8, 0.85, 0.8))
					txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
					_dialog_body.add_child(txt)
					_dialog_body.add_child(_button("Accepter : %s" % q.get("title", qid), func():
						player.request_action("quest_accept:" + qid)
						get_tree().create_timer(0.2).timeout.connect(_refresh_dialog)))
			if npc.get("role", "") == "merchant":
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 8)
				row.add_child(_button("Acheter", func():
					_dialog_mode = "shop_buy"
					_refresh_dialog_mode()))
				row.add_child(_button("Vendre", func():
					_dialog_mode = "shop_sell"
					_refresh_dialog_mode()))
				_dialog_body.add_child(row)
			_dialog_body.add_child(_button("Partir  (Échap)", close_npc_dialog))
		"shop_buy":
			_dialog_body.add_child(_make_label("Acheter — vous avez %d po" % player.inventory.gold, FONT_SMALL, Color(0.95, 0.85, 0.55)))
			for item_id in npc.get("shop", []):
				var data := GameData.item(item_id)
				var price := int(data.get("value", 10))
				_dialog_body.add_child(_button("%s — %d po" % [data.get("name", item_id), price], func():
					player.request_action("buy:" + item_id)
					get_tree().create_timer(0.2).timeout.connect(_refresh_dialog), player.inventory.gold >= price))
			_dialog_body.add_child(_button("Retour", func():
				_dialog_mode = ""
				_refresh_dialog_mode()))
		"shop_sell":
			_dialog_body.add_child(_make_label("Vendre (moitié prix) — vous avez %d po" % player.inventory.gold, FONT_SMALL, Color(0.95, 0.85, 0.55)))
			for i in player.inventory.items.size():
				var entry: Dictionary = player.inventory.items[i]
				var data := Inventory.item_data(entry)
				var price := maxi(1, int(data.get("value", 1)) / 2)
				var idx := i
				_dialog_body.add_child(_button("%s ×%d — %d po" % [Inventory.display_name(entry), int(entry.get("qty", 1)), price], func():
					player.request_action("sell:%d" % idx)
					get_tree().create_timer(0.2).timeout.connect(_refresh_dialog)))
			_dialog_body.add_child(_button("Retour", func():
				_dialog_mode = ""
				_refresh_dialog_mode()))


## Changement de page (boutique ↔ dialogue) : le focus repart du premier bouton.
func _refresh_dialog_mode() -> void:
	_clear(_dialog_body)
	_refresh_dialog_content()
	UiTheme.focus_first(_dialog_body)


# ============================================================ coffre partagé

func open_shared_chest() -> void:
	if _menu_open:
		close_menu()
	_dialog_npc = ""
	_dialog_player = null
	_dialog_chest = true
	_dialog_mode = ""
	_dialog_panel.visible = true
	_refresh_dialog_mode()
	_update_player_block()


func _on_chest_changed() -> void:
	if _dialog_chest and _dialog_panel.visible:
		_refresh_dialog()


func _refresh_chest() -> void:
	var c := Characters.chest()
	_dialog_body.add_child(_make_label("Coffre partagé", FONT_TITLE, Color(0.7, 0.85, 1.0)))
	var info := _make_label("Commun à tous tes personnages sur ce PC (en réseau : ton coffre, chez toi).", FONT_SMALL, Color(0.7, 0.7, 0.75))
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialog_body.add_child(info)
	var gold_chest := int(c.get("gold", 0))
	_dialog_body.add_child(_make_label("Or : %d po dans le coffre · %d po sur vous" % [gold_chest, player.inventory.gold], FONT_SMALL, Color(0.95, 0.85, 0.55)))
	var row_dep := HBoxContainer.new()
	row_dep.add_theme_constant_override("separation", 6)
	var row_wd := HBoxContainer.new()
	row_wd.add_theme_constant_override("separation", 6)
	for amount in [10, 50, 100]:
		var a: int = amount
		row_dep.add_child(_button("Déposer %d" % a, func():
			player.request_action("chest_deposit_gold:%d" % a), player.inventory.gold >= a))
		row_wd.add_child(_button("Retirer %d" % a, func():
			if int(Characters.chest().get("gold", 0)) >= a:
				Characters.chest_add_gold(-a)
				player.request_action("chest_withdraw_gold:%d" % a), gold_chest >= a))
	_dialog_body.add_child(row_dep)
	_dialog_body.add_child(row_wd)
	_dialog_body.add_child(_make_label("Dans le coffre (%d / %d)" % [c.items.size(), Characters.CHEST_SLOTS], FONT_NORMAL, Color(0.8, 0.75, 0.6)))
	if c.items.is_empty():
		_dialog_body.add_child(_make_label("(vide)", FONT_SMALL, Color(0.6, 0.6, 0.65)))
	for i: int in c.items.size():
		var entry: Dictionary = c.items[i]
		var idx: int = i
		var b := _button("Retirer : %s ×%d" % [Inventory.display_name(entry), int(entry.get("qty", 1))], func():
			var taken := Characters.chest_take(idx)
			if not taken.is_empty():
				player.request_action("chest_withdraw:" + JSON.stringify(taken)))
		b.add_theme_color_override("font_color", Inventory.rarity_color(entry))
		_dialog_body.add_child(b)
	_dialog_body.add_child(_make_label("Dans votre sac", FONT_NORMAL, Color(0.8, 0.75, 0.6)))
	if player.inventory.items.is_empty():
		_dialog_body.add_child(_make_label("(vide)", FONT_SMALL, Color(0.6, 0.6, 0.65)))
	for i in player.inventory.items.size():
		var entry: Dictionary = player.inventory.items[i]
		var idx: int = i
		var b := _button("Déposer : %s ×%d" % [Inventory.display_name(entry), int(entry.get("qty", 1))], func():
			player.request_action("chest_deposit:%d" % idx), not Characters.chest_is_full())
		b.add_theme_color_override("font_color", Inventory.rarity_color(entry))
		_dialog_body.add_child(b)
	_dialog_body.add_child(_button("Fermer  (Échap)", close_npc_dialog))


# ============================================================ menu d'un autre joueur (échanges)

func open_player_menu(other: Node) -> void:
	if not (other is PlayerCharacter) or other == player:
		return
	if _menu_open:
		close_menu()
	_dialog_npc = ""
	_dialog_player = other
	_dialog_mode = ""
	_dialog_panel.visible = true
	_refresh_dialog_mode()
	_update_player_block()


func _refresh_player_menu() -> void:
	var other := _dialog_player
	if not is_instance_valid(other):
		close_npc_dialog()
		return
	var path := str(other.get_path())
	var dist := player.global_position.distance_to(other.global_position)
	_dialog_body.add_child(_make_label(other.stats.display_name, FONT_TITLE, Color(0.6, 0.85, 1.0)))
	_dialog_body.add_child(_make_label("Niveau %d · PV %d / %d · à %.0f m" % [other.stats.level, other.health.hp, other.health.max_hp, dist],
		FONT_SMALL, Color(0.8, 0.8, 0.85)))
	match _dialog_mode:
		"":
			if other.health.is_downed:
				_dialog_body.add_child(_button("Relever", func():
					player.request_action("revive:" + path)
					close_npc_dialog()))
			_dialog_body.add_child(_button("Donner un objet", func():
				_dialog_mode = "give"
				_refresh_dialog_mode()))
			var gold_row := HBoxContainer.new()
			gold_row.add_theme_constant_override("separation", 6)
			for amount in [10, 50, 100]:
				var a: int = amount
				gold_row.add_child(_button("%d po" % a, func():
					player.request_action("give_gold:%d|%s" % [a, path])
					get_tree().create_timer(0.2).timeout.connect(_refresh_dialog), player.inventory.gold >= a))
			_dialog_body.add_child(_make_label("Donner de l'or (vous avez %d po) :" % player.inventory.gold, FONT_SMALL, Color(0.95, 0.85, 0.55)))
			_dialog_body.add_child(gold_row)
			_dialog_body.add_child(_button("Fermer  (Échap)", close_npc_dialog))
		"give":
			_dialog_body.add_child(_make_label("Donner à %s (à moins de %d m) :" % [other.player_name, int(PlayerCharacter.GIVE_RANGE)],
				FONT_SMALL, Color(0.95, 0.85, 0.55)))
			if player.inventory.items.is_empty():
				_dialog_body.add_child(_make_label("(sac vide)", FONT_SMALL, Color(0.6, 0.6, 0.65)))
			for i in player.inventory.items.size():
				var entry: Dictionary = player.inventory.items[i]
				var idx := i
				_dialog_body.add_child(_button("%s ×%d" % [Inventory.display_name(entry), int(entry.get("qty", 1))], func():
					player.request_action("give_item:%d|%s" % [idx, path])
					get_tree().create_timer(0.2).timeout.connect(_refresh_dialog)))
			_dialog_body.add_child(_button("Retour", func():
				_dialog_mode = ""
				_refresh_dialog_mode()))


func toggle_journal() -> void:
	_journal_panel.visible = not _journal_panel.visible
	if _journal_panel.visible:
		_refresh_journal()


func _refresh_journal() -> void:
	for c in _journal_body.get_children():
		c.queue_free()
	_journal_body.add_child(_make_label("Journal de quêtes   (J : fermer)", FONT_TITLE, Color(0.9, 0.85, 0.7)))
	if player == null:
		return
	var ql: QuestLog = player.quest_log
	var any := false
	for qid in ql.quests:
		var q := QuestLog.quest_data(qid)
		var obj: Dictionary = q.get("objective", {})
		var st: String = ql.state_of(qid)
		var progress := ""
		match obj.get("type", ""):
			"kill":
				progress = "%d / %d %s" % [ql.progress_of(qid), int(obj.get("count", 1)), GameData.monster(obj.get("monster", "")).get("name", "")]
			"collect":
				progress = "%d / %d %s" % [player.inventory.count(str(obj.get("item", ""))), int(obj.get("count", 1)), GameData.item(obj.get("item", "")).get("name", "")]
		var color := Color(0.6, 0.9, 0.6) if st == "done" else (Color(1, 0.95, 0.8) if ql.is_complete(qid, player.inventory) else Color.WHITE)
		_journal_body.add_child(_make_label("%s %s" % ["✔" if st == "done" else "▸", q.get("title", qid)], FONT_NORMAL, color))
		var txt := _make_label("%s%s" % [q.get("text", ""), ("\n→ " + progress) if progress != "" else ""], FONT_SMALL, Color(0.8, 0.8, 0.85))
		txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_journal_body.add_child(txt)
		any = true
	if not any:
		_journal_body.add_child(_make_label("Aucune quête. Parlez aux habitants de Brumeval (F).", FONT_SMALL, Color(0.75, 0.75, 0.8)))

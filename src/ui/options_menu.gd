class_name OptionsMenu
extends CanvasLayer
## Écran d'options (menu principal et menu système en jeu) : Affichage, Son, Souris & manette, Touches.
## Tout est construit en code. Navigation complète à la manette : croix directionnelle / stick pour se
## déplacer, Croix pour valider, gauche/droite sur les curseurs, L1/R1 pour changer d'onglet, Rond pour fermer.
## Les changements s'appliquent tout de suite et sont sauvegardés à la fermeture (les touches, immédiatement).

signal closed

const FONT := 14
const COLOR_PANEL := Color(0.06, 0.06, 0.08, 0.96)
const COLOR_BORDER := Color(0.45, 0.42, 0.34, 1.0)
const COLOR_LABEL := Color(0.88, 0.88, 0.92)
const COLOR_HEADER := Color(0.95, 0.85, 0.6)
const LISTEN_TIMEOUT := 6.0

static var _instance: OptionsMenu

var _tabs: TabContainer
var _status: Label
var _bind_buttons: Dictionary = {}   # "action|slot" -> Button
var _listen_action := ""
var _listen_slot := -1
var _listen_left := 0.0
var _res_option: OptionButton
var _last_sfx_test := 0


static func is_open() -> bool:
	return is_instance_valid(_instance)


## Ouvre l'écran d'options au-dessus de tout (un seul à la fois).
static func open(host: Node) -> OptionsMenu:
	if is_open():
		return _instance
	var m := OptionsMenu.new()
	host.get_tree().root.add_child(m)
	return m


func _ready() -> void:
	_instance = self
	layer = 80
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_focus_tab.call_deferred()


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


func close() -> void:
	Settings.save_settings()
	closed.emit()
	queue_free()


# ================================================================== construction

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.theme = UiTheme.get_theme()
	add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_PANEL
	sb.border_color = COLOR_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(780, 560)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	var title := _label("Options", 20, COLOR_HEADER)
	v.add_child(title)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_size_override("font_size", FONT)
	_tabs.tab_changed.connect(func(_t: int): _focus_tab.call_deferred())
	v.add_child(_tabs)
	_build_video_tab()
	_build_audio_tab()
	_build_controls_tab()
	_build_bindings_tab()

	_status = _label("", FONT - 1, Color(0.85, 0.85, 0.7))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	v.add_child(bottom)
	var hint := _label("Manette : L1 / R1 onglets · Croix valider · Rond fermer      Clavier : Tab / flèches · Entrée · Échap",
		FONT - 2, Color(0.6, 0.6, 0.66))
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(hint)
	var close_btn := Button.new()
	close_btn.text = "Fermer"
	close_btn.add_theme_font_size_override("font_size", FONT)
	close_btn.pressed.connect(close)
	bottom.add_child(close_btn)


func _new_tab(tab_name: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_tabs.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	scroll.add_child(margin)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)
	return box


func _label(text: String, size: int = FONT, color := COLOR_LABEL) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## Ligne « libellé | contrôle | valeur ». Le libellé s'illumine quand le contrôle a le focus.
func _row(parent: Control, text: String, control: Control, value_label: Label = null) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := _label(text)
	l.custom_minimum_size = Vector2(250, 0)
	row.add_child(l)
	control.custom_minimum_size.x = maxf(control.custom_minimum_size.x, 300)
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)
	if value_label:
		value_label.custom_minimum_size = Vector2(70, 0)
		row.add_child(value_label)
	parent.add_child(row)
	control.focus_entered.connect(func():
		l.add_theme_color_override("font_color", UiTheme.FOCUS_COLOR)
		l.text = "▸ " + text)
	control.focus_exited.connect(func():
		l.add_theme_color_override("font_color", COLOR_LABEL)
		l.text = text)


func _slider(parent: Control, text: String, min_v: float, max_v: float, step: float, value: float,
		fmt: Callable, on_change: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.focus_mode = Control.FOCUS_ALL
	var val := _label(fmt.call(value))
	s.value_changed.connect(func(x: float):
		val.text = fmt.call(x)
		on_change.call(x))
	_row(parent, text, s, val)
	return s


func _option(parent: Control, text: String, items: Array, selected: int, on_change: Callable) -> OptionButton:
	var o := OptionButton.new()
	o.add_theme_font_size_override("font_size", FONT)
	for it in items:
		o.add_item(str(it))
	o.selected = selected
	o.item_selected.connect(on_change)
	_row(parent, text, o)
	return o


func _check(parent: Control, text: String, value: bool, on_change: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.button_pressed = value
	c.toggled.connect(on_change)
	_row(parent, text, c)
	return c


static func _pct(x: float) -> String:
	return "%d %%" % roundi(x * 100.0)


# ------------------------------------------------------------------ onglets

func _build_video_tab() -> void:
	var box := _new_tab("Affichage")
	_option(box, "Mode d'affichage", Settings.WINDOW_MODES, Settings.window_mode, func(i: int):
		Settings.window_mode = i
		_res_option.disabled = i != 0
		Settings.apply_video())
	var res_items: Array = []
	var res_index := 0
	for i in Settings.RESOLUTIONS.size():
		var r: Vector2i = Settings.RESOLUTIONS[i]
		res_items.append("%d × %d" % [r.x, r.y])
		if r == Settings.resolution:
			res_index = i
	_res_option = _option(box, "Taille de la fenêtre", res_items, res_index, func(i: int):
		Settings.resolution = Settings.RESOLUTIONS[i]
		Settings.apply_video())
	_res_option.disabled = Settings.window_mode != 0
	_check(box, "Synchronisation verticale (V-Sync)", Settings.vsync, func(on: bool):
		Settings.vsync = on
		Settings.apply_video())
	var fps_items: Array = []
	for f in Settings.FPS_LIMITS:
		fps_items.append("Illimitée" if f == 0 else "%d i/s" % f)
	_option(box, "Limite d'images par seconde", fps_items, maxi(Settings.FPS_LIMITS.find(Settings.fps_limit), 0), func(i: int):
		Settings.fps_limit = Settings.FPS_LIMITS[i]
		Settings.apply_video(false))
	_slider(box, "Taille de l'interface", 0.75, 1.75, 0.05, Settings.ui_scale, _pct, func(x: float):
		Settings.ui_scale = x
		Settings.apply_video(false))
	_slider(box, "Résolution 3D", 0.5, 1.0, 0.05, Settings.render_scale, _pct, func(x: float):
		Settings.render_scale = x
		Settings.apply_video(false))
	_slider(box, "Champ de vision", 50.0, 100.0, 1.0, Settings.fov, func(x: float): return "%d°" % roundi(x), func(x: float):
		Settings.fov = x
		Settings.apply_video(false))
	var note := _label("La résolution 3D réduit le coût du rendu sans flouter l'interface. Ces réglages sont propres à ce PC.",
		FONT - 2, Color(0.6, 0.6, 0.66))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)


func _build_audio_tab() -> void:
	var box := _new_tab("Son")
	_slider(box, "Volume général", 0.0, 1.0, 0.05, Settings.vol_master, _pct, func(x: float):
		Settings.vol_master = x
		Settings.apply_audio()
		_test_sound())
	_slider(box, "Effets sonores", 0.0, 1.0, 0.05, Settings.vol_sfx, _pct, func(x: float):
		Settings.vol_sfx = x
		Settings.apply_audio()
		_test_sound())
	_slider(box, "Ambiance", 0.0, 1.0, 0.05, Settings.vol_ambient, _pct, func(x: float):
		Settings.vol_ambient = x
		Settings.apply_audio())


func _test_sound() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_sfx_test > 250:
		_last_sfx_test = now
		Sound.play_ui("hit")


func _build_controls_tab() -> void:
	var box := _new_tab("Souris & manette")
	_slider(box, "Sensibilité de la souris", 0.25, 3.0, 0.05, Settings.mouse_sensitivity, _pct, func(x: float):
		Settings.mouse_sensitivity = x)
	_slider(box, "Vitesse de la caméra (stick droit)", 0.25, 3.0, 0.05, Settings.stick_sensitivity, _pct, func(x: float):
		Settings.stick_sensitivity = x)
	_check(box, "Inverser l'axe vertical de la caméra", Settings.invert_y, func(on: bool):
		Settings.invert_y = on)
	_slider(box, "Zone morte des sticks", 0.05, 0.6, 0.01, Settings.stick_deadzone, _pct, func(x: float):
		Settings.stick_deadzone = x
		Settings.apply_controls())
	var note := _label("Zone morte : augmente-la si le personnage ou la caméra bouge tout seul (stick usé).",
		FONT - 2, Color(0.6, 0.6, 0.66))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)


func _build_bindings_tab() -> void:
	var box := _new_tab("Touches")
	var help := _label("Choisis une case puis appuie sur la nouvelle touche (ou le bouton de manette). Suppr : vider la case, Échap : annuler.",
		FONT - 1, Color(0.75, 0.75, 0.8))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)
	for h in ["Action", "Touche 1", "Touche 2", "Manette"]:
		grid.add_child(_label(h, FONT, COLOR_HEADER))
	for row in Settings.REBINDABLE:
		var action: String = row[0]
		if action == "#":
			grid.add_child(_label(row[1], FONT, Color(0.7, 0.75, 0.9)))
			for i in 3:
				grid.add_child(Control.new())
			continue
		if not InputMap.has_action(action):
			continue
		var name_label := _label(row[1])
		name_label.custom_minimum_size = Vector2(260, 0)
		grid.add_child(name_label)
		for slot in 3:
			var b := Button.new()
			b.custom_minimum_size = Vector2(140, 0)
			b.add_theme_font_size_override("font_size", FONT - 1)
			b.clip_text = true
			var a := action
			var sl := slot
			b.pressed.connect(func(): _start_listen(a, sl))
			b.focus_entered.connect(func(): name_label.add_theme_color_override("font_color", UiTheme.FOCUS_COLOR))
			b.focus_exited.connect(func(): name_label.add_theme_color_override("font_color", COLOR_LABEL))
			grid.add_child(b)
			_bind_buttons["%s|%d" % [action, slot]] = b
	var reset := Button.new()
	reset.text = "Rétablir toutes les touches par défaut"
	reset.add_theme_font_size_override("font_size", FONT)
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(func():
		Settings.reset_bindings()
		_refresh_bindings()
		_status.text = "Touches par défaut rétablies.")
	box.add_child(reset)
	_refresh_bindings()


func _refresh_bindings() -> void:
	for key in _bind_buttons:
		var parts: PackedStringArray = key.split("|")
		var action := parts[0]
		var slot := int(parts[1])
		var events := Settings.events_of(action, slot == 2)
		var idx := 0 if slot == 2 else slot
		var b: Button = _bind_buttons[key]
		b.text = Settings.event_label(events[idx]) if idx < events.size() else "—"


# ================================================================== saisie d'une touche

func _start_listen(action: String, slot: int) -> void:
	_listen_action = action
	_listen_slot = slot
	_listen_left = LISTEN_TIMEOUT
	var b: Button = _bind_buttons["%s|%d" % [action, slot]]
	b.text = "…"
	_status.text = ("Appuie sur un bouton de la manette (une touche du clavier annule)." if slot == 2
		else "Appuie sur une touche (ou un bouton de souris : molette, 4, 5). Un bouton de manette annule.")


func _stop_listen(message := "") -> void:
	_listen_action = ""
	_listen_slot = -1
	_refresh_bindings()
	_status.text = message


func _finish_listen(event: InputEvent) -> void:
	var action := _listen_action
	var slot := _listen_slot
	var others := Settings.conflicts(event, action) if event else ([] as Array[String])
	Settings.rebind(action, slot, event)
	var focus_btn: Button = _bind_buttons["%s|%d" % [action, slot]]
	_stop_listen()
	if event == null:
		_status.text = "Case vidée."
	elif others.is_empty():
		_status.text = "« %s » → %s" % [_action_label(action), Settings.event_label(event)]
	else:
		_status.text = "« %s » → %s.   ⚠ Aussi utilisée par : %s" % [_action_label(action), Settings.event_label(event), ", ".join(others)]
	# Le bouton garde le focus ; on ignore le relâchement de la touche qui vient d'être saisie.
	focus_btn.grab_focus.call_deferred()


func _action_label(action: String) -> String:
	for row in Settings.REBINDABLE:
		if row[0] == action:
			return row[1]
	return action


func _process(delta: float) -> void:
	if _listen_action != "":
		_listen_left -= delta
		if _listen_left <= 0.0:
			_stop_listen("Temps écoulé, touche inchangée.")


func _input(event: InputEvent) -> void:
	if _listen_action != "":
		_capture(event)
		return
	# Changement d'onglet : L1 / R1 (et Ctrl+Tab géré par le TabContainer).
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_LEFT_SHOULDER or event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			var d := -1 if event.button_index == JOY_BUTTON_LEFT_SHOULDER else 1
			_tabs.current_tab = wrapi(_tabs.current_tab + d, 0, _tabs.get_tab_count())
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("ui_cancel") and not _popup_open():
		get_viewport().set_input_as_handled()
		close()


func _popup_open() -> bool:
	for o in find_children("*", "OptionButton", true, false):
		if (o as OptionButton).get_popup().visible:
			return true
	return false


func _capture(event: InputEvent) -> void:
	var pad_slot := _listen_slot == 2
	if event is InputEventKey and event.pressed and not event.echo:
		get_viewport().set_input_as_handled()
		var code: int = event.keycode if event.keycode != 0 else Settings.physical_to_keycode(event.physical_keycode)
		if code == KEY_ESCAPE:
			_stop_listen("Annulé.")
		elif code == KEY_DELETE:
			_finish_listen(null)
		elif pad_slot:
			_stop_listen("Annulé (case manette : appuie sur un bouton de la manette).")
		else:
			var e := InputEventKey.new()
			e.keycode = code as Key
			_finish_listen(e)
	elif event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()
		if not pad_slot and event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			var e := InputEventMouseButton.new()
			e.button_index = event.button_index
			_finish_listen(e)
	elif event is InputEventJoypadButton and event.pressed:
		get_viewport().set_input_as_handled()
		if pad_slot:
			var e := InputEventJoypadButton.new()
			e.button_index = event.button_index
			_finish_listen(e)
		else:
			_stop_listen("Annulé.")
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.75:
		get_viewport().set_input_as_handled()
		if pad_slot:
			var e := InputEventJoypadMotion.new()
			e.axis = event.axis
			e.axis_value = 1.0 if event.axis_value > 0.0 else -1.0
			_finish_listen(e)
	elif event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()


# ================================================================== focus

func _focus_tab() -> void:
	var page := _tabs.get_current_tab_control()
	if page:
		UiTheme.focus_first(page)

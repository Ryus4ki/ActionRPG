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
var _spell_bar: HBoxContainer
var _status: Label
var _ally_refresh := 0.0


func _ready() -> void:
	_build_ui()
	EventBus.local_player_ready.connect(bind_player)
	EventBus.hit_resolved.connect(_on_hit_resolved)
	EventBus.creature_died.connect(_on_creature_died)
	EventBus.creature_downed.connect(_on_creature_downed)
	for p in get_tree().get_nodes_in_group("players"):
		if p is PlayerCharacter and p.is_local:
			bind_player(p)
			break
	chat_system("Bienvenue. Appuie sur H pour afficher ou masquer les commandes.")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_H:
		_help_panel.visible = not _help_panel.visible


# ============================================================ construction

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

	# --- Coéquipiers (sous le cadre) ---
	_allies_box = VBoxContainer.new()
	_allies_box.position = Vector2(12, 100)
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
	_help_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_help_panel.anchor_left = 1.0
	_help_panel.anchor_right = 1.0
	_help_panel.anchor_top = 1.0
	_help_panel.anchor_bottom = 1.0
	_help_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_help_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help_panel.offset_right = -12
	_help_panel.offset_bottom = -12
	_root.add_child(_help_panel)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 2)
	_help_panel.add_child(hv)
	hv.add_child(_make_label("Commandes   (H : masquer)", FONT_SMALL, Color(0.8, 0.75, 0.6)))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 1)
	hv.add_child(grid)
	for row in [
		["ZQSD / stick G", "Se déplacer"], ["Souris / stick D", "Caméra"],
		["Clic G / R2", "Attaquer"], ["Clic D / L2", "Garde (guerrier) · Sort (magicien)"],
		["Molette, 1-4 / L1 R1", "Choisir le sort"], ["Espace / Croix", "Esquiver"],
		["E / Rond", "Relever un allié"], ["Échap / Options", "Libérer la souris"],
		["Maj+Échap", "Retour au menu"], ["F1 · F2", "Debug : invulnérable · soin"],
	]:
		grid.add_child(_make_label(row[0], FONT_SMALL, Color(0.95, 0.9, 0.75)))
		grid.add_child(_make_label(row[1], FONT_SMALL, Color(0.8, 0.8, 0.85)))
	_help_panel.size = Vector2.ZERO  # laisse le conteneur se dimensionner

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


# ============================================================ liaison joueur

func bind_player(p: PlayerCharacter) -> void:
	if player == p:
		return
	player = p
	player.health.changed.connect(_on_hp_changed)
	player.health.downed.connect(func(): _status.text = "À TERRE — un allié peut vous relever (E)")
	player.health.revived.connect(func(): _status.text = "")
	player.stats.level_changed.connect(func(lvl: int):
		_refresh_identity()
		chat_system("[color=#ffd866]Niveau %d atteint ![/color]" % lvl))
	_refresh_identity()
	_on_hp_changed(player.health.hp, player.health.max_hp)
	if player.spell_book.is_caster():
		_build_spell_bar()
		player.spell_book.changed.connect(_refresh_spell_bar)
		_refresh_spell_bar()


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
	if r.has("save_d20"):
		line = "%s%s → %s : sauv. %d vs DD %d %s → [b]%d[/b] %s" % [
			a_name, what, t_name, r.save_total, r.dc, "ok" if r.save_success else "ratée", r.damage, dtype]
	elif r.get("auto_hit", false):
		line = "%s%s → %s : [b]%d[/b] %s" % [a_name, what, t_name, r.damage, dtype]
	elif r.get("hit", false):
		var extra := ""
		if r.get("crit", false):
			extra += " [color=#ffa030]CRITIQUE[/color]"
		if r.get("blocked", false):
			extra += " [color=#99ccff]bloqué[/color]"
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


# ============================================================ barre de sorts

func _build_spell_bar() -> void:
	if _spell_bar:
		return
	_spell_bar = HBoxContainer.new()
	_spell_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_spell_bar.anchor_left = 0.5
	_spell_bar.anchor_right = 0.5
	_spell_bar.anchor_top = 1.0
	_spell_bar.anchor_bottom = 1.0
	_spell_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_spell_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_spell_bar.offset_bottom = -16
	_spell_bar.add_theme_constant_override("separation", 6)
	_root.add_child(_spell_bar)


func _refresh_spell_bar() -> void:
	if _spell_bar == null or player == null:
		return
	for c in _spell_bar.get_children():
		c.queue_free()
	var book := player.spell_book
	for i in book.known.size():
		var sid: String = book.known[i]
		var spell := GameData.spell(sid)
		var panel := PanelContainer.new()
		var sb := _panel_style(5)
		var selected := i == book.selected
		if selected:
			sb.bg_color = Color(0.22, 0.3, 0.5, 0.9)
			sb.border_color = Color(0.7, 0.85, 1.0)
		panel.add_theme_stylebox_override("panel", sb)
		var lbl := Label.new()
		var lvl: int = spell.get("level", 0)
		var slot_txt := "∞"
		if lvl > 0:
			slot_txt = "%d/%d" % [int(book.slots.get(str(lvl), 0)), int(book.max_slots.get(str(lvl), 0))]
		lbl.text = "%d · %s\n%s" % [i + 1, spell.get("name", sid), slot_txt]
		lbl.add_theme_font_size_override("font_size", FONT_SMALL)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.custom_minimum_size = Vector2(110, 0)
		var usable := book.slot_level_for(spell) >= 0
		lbl.add_theme_color_override("font_color", Color(1, 1, 1) if usable else Color(0.5, 0.5, 0.5))
		panel.add_child(lbl)
		_spell_bar.add_child(panel)

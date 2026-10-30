extends CanvasLayer
## HUD du joueur local : nom/niveau, barre de PV, XP, journal de combat.

@onready var name_label: Label = %NameLabel
@onready var hp_bar: ProgressBar = %HpBar
@onready var hp_label: Label = %HpLabel
@onready var xp_label: Label = %XpLabel
@onready var log_label: RichTextLabel = %CombatLog
@onready var status_label: Label = %StatusLabel

var player: PlayerCharacter
var _log_lines: Array[String] = []
var _spell_bar: HBoxContainer


func _ready() -> void:
	EventBus.local_player_ready.connect(bind_player)
	EventBus.hit_resolved.connect(_on_hit_resolved)
	EventBus.creature_died.connect(_on_creature_died)
	status_label.text = ""
	# Si le joueur est entré dans l'arbre avant le HUD, on le récupère directement.
	for p in get_tree().get_nodes_in_group("players"):
		if p is PlayerCharacter and p.is_local:
			bind_player(p)
			break


func bind_player(p: PlayerCharacter) -> void:
	if player == p:
		return
	player = p
	player.health.changed.connect(_on_hp_changed)
	player.health.downed.connect(func(): status_label.text = "À TERRE — relevé automatique dans quelques secondes (solo)")
	player.health.revived.connect(func(): status_label.text = "")
	player.stats.level_changed.connect(func(lvl: int):
		_refresh_identity()
		_push_log("[color=#ffd866]Niveau %d atteint ![/color]" % lvl))
	_refresh_identity()
	_on_hp_changed(player.health.hp, player.health.max_hp)
	if player.spell_book.is_caster():
		_build_spell_bar()
		player.spell_book.changed.connect(_refresh_spell_bar)
		_refresh_spell_bar()


func _process(_delta: float) -> void:
	if player:
		var nxt := Rules.xp_for_next_level(player.stats.level)
		xp_label.text = "XP %d / %d" % [player.stats.xp, nxt] if nxt > 0 else "XP %d (max)" % player.stats.xp


func _refresh_identity() -> void:
	name_label.text = "%s — niveau %d   CA %d" % [player.stats.display_name, player.stats.level, player.stats.armor_class()]


func _on_hp_changed(hp: int, max_hp: int) -> void:
	hp_bar.max_value = max_hp
	hp_bar.value = hp
	hp_label.text = "%d / %d" % [hp, max_hp]


func _on_hit_resolved(target: Node3D, r: Dictionary) -> void:
	if not is_instance_valid(target):
		return
	var attacker: Node = r.get("attacker")
	var a_name: String = attacker.stats.display_name if attacker and attacker.has_node("StatBlock") else "?"
	var t_name: String = target.stats.display_name if target.has_node("StatBlock") else "?"
	var line: String
	var what: String = (" [%s]" % r.attack_name) if r.get("attack_name", "") != "" and attacker is PlayerCharacter else ""
	if r.has("save_d20"):
		line = "%s%s → %s : sauvegarde %d vs DD %d (%s), %d dégâts %s" % [
			a_name, what, t_name, r.save_total, r.dc, "réussie" if r.save_success else "ratée", r.damage, CombatRules.damage_type_name(r.damage_type)]
	elif r.get("auto_hit", false):
		line = "%s%s → %s : touche automatiquement → %d dégâts %s" % [a_name, what, t_name, r.damage, CombatRules.damage_type_name(r.damage_type)]
	elif r.get("hit", false):
		var crit := " [color=#ffa030]CRITIQUE[/color]" if r.get("crit") else ""
		if r.get("blocked", false):
			crit += " [color=#99ccff](bloqué : désavantage, dégâts ÷2)[/color]"
		line = "%s%s → %s : d20=%d (%d) vs CA %d → %d dégâts %s%s" % [
			a_name, what, t_name, r.d20, r.total, r.ac, r.damage, CombatRules.damage_type_name(r.damage_type), crit]
	else:
		line = "[color=#999999]%s%s → %s : d20=%d (%d) vs CA %d → %s[/color]" % [a_name, what, t_name, r.d20, r.total, r.ac, "bloqué" if r.get("blocked", false) else "raté"]
	_push_log(line)


func _on_creature_died(c: Node3D) -> void:
	if c.has_node("StatBlock"):
		_push_log("[color=#ff6060]%s est mort.[/color]" % c.stats.display_name)


func _push_log(line: String) -> void:
	_log_lines.append(line)
	if _log_lines.size() > 6:
		_log_lines.pop_front()
	log_label.text = "\n".join(_log_lines)


## Barre de sorts (lanceurs) : construite en code, en bas au centre.
func _build_spell_bar() -> void:
	if _spell_bar:
		return
	_spell_bar = HBoxContainer.new()
	_spell_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_spell_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_spell_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_spell_bar.position.y -= 190
	_spell_bar.add_theme_constant_override("separation", 8)
	$Root.add_child(_spell_bar)


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
		var lbl := Label.new()
		var lvl: int = spell.get("level", 0)
		var slot_txt := "tour de magie"
		if lvl > 0:
			slot_txt = "niv %d — %d/%d" % [lvl, int(book.slots.get(str(lvl), 0)), int(book.max_slots.get(str(lvl), 0))]
		lbl.text = "%d  %s\n%s" % [i + 1, spell.get("name", sid), slot_txt]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.custom_minimum_size = Vector2(150, 0)
		var usable := book.slot_level_for(spell) >= 0
		lbl.add_theme_color_override("font_color", Color(1, 1, 1) if usable else Color(0.55, 0.55, 0.55))
		if i == book.selected:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.25, 0.35, 0.6, 0.9)
			sb.border_color = Color(0.7, 0.85, 1.0)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			panel.add_theme_stylebox_override("panel", sb)
		panel.add_child(lbl)
		_spell_bar.add_child(panel)

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
	if r.has("save_d20"):
		line = "%s → %s : sauvegarde %d vs DD %d (%s), %d dégâts" % [
			a_name, t_name, r.save_total, r.dc, "réussie" if r.save_success else "ratée", r.damage]
	elif r.get("hit", false):
		var crit := " [color=#ffa030]CRITIQUE[/color]" if r.get("crit") else ""
		if r.get("blocked", false):
			crit += " [color=#99ccff](bloqué : désavantage, dégâts ÷2)[/color]"
		line = "%s → %s : d20=%d (%d) vs CA %d → %d dégâts %s%s" % [
			a_name, t_name, r.d20, r.total, r.ac, r.damage, CombatRules.damage_type_name(r.damage_type), crit]
	else:
		line = "[color=#999999]%s → %s : d20=%d (%d) vs CA %d → %s[/color]" % [a_name, t_name, r.d20, r.total, r.ac, "bloqué" if r.get("blocked", false) else "raté"]
	_push_log(line)


func _on_creature_died(c: Node3D) -> void:
	if c.has_node("StatBlock"):
		_push_log("[color=#ff6060]%s est mort.[/color]" % c.stats.display_name)


func _push_log(line: String) -> void:
	_log_lines.append(line)
	if _log_lines.size() > 6:
		_log_lines.pop_front()
	log_label.text = "\n".join(_log_lines)

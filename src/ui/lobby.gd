extends Control
## Lobby : choix de classe / race, état « prêt », lancement par l'hôte.

@onready var class_option: OptionButton = %ClassOption
@onready var race_option: OptionButton = %RaceOption
@onready var ready_check: CheckButton = %ReadyCheck
@onready var players_label: RichTextLabel = %Players
@onready var start_button: Button = %StartButton
@onready var info: Label = %Info
@onready var ip_row: HBoxContainer = %IpRow
@onready var ip_label: Label = %IpLabel
@onready var copy_button: Button = %CopyIpButton
@onready var level_row: HBoxContainer = %LevelRow
@onready var level_option: OptionButton = %LevelOption

var _class_ids: Array[String] = []
var _race_ids: Array[String] = []


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	theme = UiTheme.get_theme()
	for cid in GameData.classes:
		_class_ids.append(cid)
		class_option.add_item(GameData.classes[cid].get("name", cid))
	for rid in GameData.races:
		_race_ids.append(rid)
		race_option.add_item(GameData.races[rid].get("name", rid))
	class_option.item_selected.connect(func(_i): _send_choice())
	race_option.item_selected.connect(func(_i): _send_choice())
	ready_check.toggled.connect(func(_v): _send_choice())
	start_button.pressed.connect(func(): Net.start_game())
	%LeaveButton.pressed.connect(func(): Net.leave_to_menu())
	Net.players_changed.connect(_refresh)
	start_button.visible = Net.is_host
	level_row.visible = Net.is_host
	var level_paths: Array = Net.LEVELS.keys()
	# Personnage façon MMO : classe et race sont celles du personnage ; l'hôte reprend là où il s'était arrêté.
	if Characters.has_current():
		class_option.get_parent().visible = false
		race_option.get_parent().visible = false
		var resume: String = str(Characters.current.get("zone", ""))
		if not Net.LEVELS.has(resume):
			resume = level_paths[0]
		level_paths = [resume] + level_paths
		level_option.add_item("Reprendre — %s" % Net.LEVELS[resume])
		for lp in level_paths.slice(1):
			level_option.add_item(Net.LEVELS[lp])
		level_option.selected = 0
		Net.level_path = resume
	else:
		for lp in level_paths:
			level_option.add_item(Net.LEVELS[lp])
		level_option.selected = maxi(level_paths.find(Net.level_path), 0)
	level_option.item_selected.connect(func(i: int): Net.level_path = level_paths[i])
	if "--arena" in OS.get_cmdline_user_args():
		Net.level_path = "res://scenes/test_arena.tscn"
	info.text = "Solo : clique sur Lancer." if Net.is_solo else (
		"Tu héberges — en attente d'un coéquipier sur le LAN. Tu peux aussi lancer seul." if Net.is_host
		else "Connecté à l'hôte. Choisis ta classe et coche Prêt.")
	if Characters.has_current():
		info.text = "Personnage : %s\n%s" % [Characters.summary(Characters.current), info.text]
	_refresh(Net.players)
	_send_choice()
	# Manette : on démarre sur le choix de classe (croix ↓ pour race, Prêt, Lancer) — ou sur Prêt avec un personnage.
	(ready_check if Characters.has_current() else class_option).grab_focus.call_deferred()
	_show_host_ip()
	if Net.is_solo or "--autostart" in OS.get_cmdline_user_args():
		ready_check.button_pressed = true
		if Net.is_host:
			_autostart.call_deferred()


func _autostart() -> void:
	# Tests / solo : lance dès que tout le monde est prêt (ou tout de suite en solo).
	if Net.is_solo:
		Net.start_game()
		return
	var wanted := 2 if "--wait2" in OS.get_cmdline_user_args() else 1
	while Net.players.size() < wanted or not Net.all_ready():
		await get_tree().create_timer(0.2).timeout
	Net.start_game()


func _send_choice() -> void:
	if Characters.has_current():
		Net.set_my_character(ready_check.button_pressed)
		return
	var cid := _class_ids[class_option.selected] if class_option.selected >= 0 else "fighter"
	var rid := _race_ids[race_option.selected] if race_option.selected >= 0 else "human"
	Net.set_my_choice(cid, rid, ready_check.button_pressed)


func _refresh(players: Dictionary) -> void:
	var lines: Array[String] = []
	for id in players:
		var p: Dictionary = players[id]
		var job: String = str(p.get("state", {}).get("job", p.class_id))
		var cls: String = GameData.classes.get(job, {}).get("name", job)
		var race: String = GameData.races.get(p.race_id, {}).get("name", p.race_id)
		var tag := " (hôte)" if id == 1 else ""
		var ready_txt := "[color=#80e080]prêt[/color]" if p.ready else "[color=#e0a060]pas prêt[/color]"
		lines.append("• %s%s — %s %s niv. %d — %s" % [p.name, tag, race, cls, int(p.get("level", 1)), ready_txt])
	players_label.text = "\n".join(lines)
	start_button.disabled = not Net.all_ready()


func _show_host_ip() -> void:
	ip_row.visible = Net.is_host and not Net.is_solo
	if not ip_row.visible:
		return
	var ips := Net.local_ipv4_addresses()
	if ips.is_empty():
		ip_label.text = "Adresse IP introuvable (pas de réseau ?)"
		copy_button.disabled = true
		return
	ip_label.text = "Adresse IP de l'hôte : %s" % ips[0]
	if ips.size() > 1:
		ip_label.text += "   (autres : %s)" % ", ".join(ips.slice(1))
	ip_label.tooltip_text = "Port %d — à saisir dans « Ou adresse IP » sur l'autre PC." % Net.DEFAULT_PORT
	copy_button.pressed.connect(func():
		DisplayServer.clipboard_set(ips[0])
		copy_button.text = "Copié !"
		get_tree().create_timer(1.5).timeout.connect(func(): copy_button.text = "Copier"))

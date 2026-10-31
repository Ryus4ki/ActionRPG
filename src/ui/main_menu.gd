extends Control
## Menu principal : choix / création du personnage (façon MMO), puis Solo (reprise là où on s'était arrêté) /
## Héberger / Rejoindre (parties LAN détectées ou IP saisie) avec ce personnage.

@onready var name_edit: LineEdit = %NameEdit
@onready var game_name_edit: LineEdit = %GameNameEdit
@onready var ip_edit: LineEdit = %IpEdit
@onready var lan_list: ItemList = %LanList
@onready var status: Label = %Status

var _lan_ips: Array[String] = []
var _chars: Array = []
var _char_list: ItemList
var _create_box: VBoxContainer
var _create_name: LineEdit
var _create_class: OptionButton
var _create_race: OptionButton
var _delete_btn: Button
var _new_btn: Button
var _class_ids: Array[String] = []
var _race_ids: Array[String] = []


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	name_edit.text = Net.player_name
	game_name_edit.text = "Partie de " + Net.player_name
	Net.lan_games_changed.connect(_refresh_lan)
	Net.connection_failed.connect(func(reason: String): status.text = reason)
	Net.start_lan_discovery()
	%SoloButton.pressed.connect(_on_solo)
	%HostButton.pressed.connect(_on_host)
	%JoinButton.pressed.connect(_on_join_ip)
	%QuitButton.pressed.connect(func(): Characters.quit_game())
	_add_options_button()
	_build_character_section()
	theme = UiTheme.get_theme()
	%SoloButton.text = "Jouer en solo (reprendre l'aventure)"
	_refresh_characters()
	lan_list.item_activated.connect(_on_lan_activated)
	status.text = "Recherche de parties sur le réseau local…"
	_check_autostart()


# ------------------------------------------------------------------ personnages

## Section « Tes personnages » construite en code à la place du champ « Ton nom ».
func _build_character_section() -> void:
	var name_row: Control = name_edit.get_parent()
	var vbox: Container = name_row.get_parent()
	name_row.visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	vbox.add_child(box)
	vbox.move_child(box, name_row.get_index())
	var title := Label.new()
	title.text = "Tes personnages"
	box.add_child(title)
	_char_list = ItemList.new()
	_char_list.custom_minimum_size = Vector2(0, 120)
	_char_list.item_selected.connect(_on_char_selected)
	_char_list.item_activated.connect(func(_i: int): _on_solo())
	box.add_child(_char_list)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	_new_btn = Button.new()
	_new_btn.text = "Nouveau personnage"
	_new_btn.pressed.connect(_show_create)
	row.add_child(_new_btn)
	_delete_btn = Button.new()
	_delete_btn.text = "Supprimer"
	_delete_btn.pressed.connect(_on_delete)
	row.add_child(_delete_btn)
	# Création (masquée)
	_create_box = VBoxContainer.new()
	_create_box.visible = false
	_create_box.add_theme_constant_override("separation", 6)
	box.add_child(_create_box)
	var r1 := HBoxContainer.new()
	var l1 := Label.new()
	l1.text = "Nom"
	l1.custom_minimum_size = Vector2(120, 0)
	r1.add_child(l1)
	_create_name = LineEdit.new()
	_create_name.max_length = Characters.NAME_MAX
	_create_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_create_name.placeholder_text = "Nom du personnage"
	_create_name.text_submitted.connect(func(_t: String): _on_create())
	r1.add_child(_create_name)
	_create_box.add_child(r1)
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 8)
	_create_class = OptionButton.new()
	for cid in GameData.classes:
		_class_ids.append(cid)
		_create_class.add_item(GameData.classes[cid].get("name", cid))
	_create_race = OptionButton.new()
	for rid in GameData.races:
		_race_ids.append(rid)
		_create_race.add_item(GameData.races[rid].get("name", rid))
	var l2 := Label.new()
	l2.text = "Départ / race"
	l2.custom_minimum_size = Vector2(120, 0)
	r2.add_child(l2)
	r2.add_child(_create_class)
	r2.add_child(_create_race)
	_create_box.add_child(r2)
	var hint := Label.new()
	hint.text = "La classe de départ fixe tes caractéristiques et ton équipement de départ. Ensuite, ton job suit ton arme (épée, masse, hache → Guerrier ; bâton, dague → Magicien), chaque job avec son propre niveau."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(480, 0)
	hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	hint.add_theme_font_size_override("font_size", 12)
	_create_box.add_child(hint)
	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 8)
	var ok := Button.new()
	ok.text = "Créer"
	ok.pressed.connect(_on_create)
	r3.add_child(ok)
	var cancel := Button.new()
	cancel.text = "Annuler"
	cancel.pressed.connect(func():
		_create_box.visible = false
		_new_btn.grab_focus())
	r3.add_child(cancel)
	_create_box.add_child(r3)


func _refresh_characters(select_id := "") -> void:
	_chars = Characters.list()
	_char_list.clear()
	for ch in _chars:
		_char_list.add_item(Characters.summary(ch))
	if select_id == "" and Characters.has_current():
		select_id = str(Characters.current.get("id", ""))
	var idx := 0
	for i in _chars.size():
		if _chars[i].id == select_id:
			idx = i
	_delete_btn.disabled = _chars.is_empty()
	if _chars.is_empty():
		Characters.current = {}
		_show_create()
		status.text = "Bienvenue ! Crée ton premier personnage."
	else:
		_char_list.select(idx)
		_on_char_selected(idx)
		%SoloButton.grab_focus.call_deferred()


func _on_char_selected(index: int) -> void:
	if index < 0 or index >= _chars.size():
		return
	Characters.select(_chars[index].id)
	Net.player_name = str(_chars[index].get("name", "Aventurier"))
	game_name_edit.text = "Partie de " + Net.player_name
	_delete_btn.text = "Supprimer"


func _show_create() -> void:
	_create_box.visible = true
	_create_name.text = ""
	_create_name.grab_focus.call_deferred()


func _on_create() -> void:
	var ch := Characters.create(_create_name.text, _class_ids[maxi(_create_class.selected, 0)], _race_ids[maxi(_create_race.selected, 0)])
	if ch.is_empty():
		status.text = Characters.error
		return
	Characters.current = ch
	_create_box.visible = false
	status.text = "%s est prêt pour l'aventure. Il commencera au village de Brumeval." % ch.name
	_refresh_characters(ch.id)


## Suppression en deux temps (le bouton demande confirmation).
func _on_delete() -> void:
	var i := _char_list.get_selected_items()
	if i.is_empty():
		return
	var ch: Dictionary = _chars[i[0]]
	if _delete_btn.text.begins_with("Confirmer"):
		Characters.delete(ch.id)
		status.text = "%s a été supprimé." % ch.get("name", "?")
		_delete_btn.text = "Supprimer"
		_refresh_characters()
	else:
		_delete_btn.text = "Confirmer la suppression de %s ?" % ch.get("name", "?")


## Bouton « Options » ajouté juste avant « Quitter » (sans toucher à la scène).
func _add_options_button() -> void:
	var quit: Button = %QuitButton
	var b := Button.new()
	b.text = "Options"
	b.custom_minimum_size = quit.custom_minimum_size
	for prop in ["font_size"]:
		if quit.has_theme_font_size_override(prop):
			b.add_theme_font_size_override(prop, quit.get_theme_font_size(prop))
	quit.get_parent().add_child(b)
	quit.get_parent().move_child(b, quit.get_index())
	b.pressed.connect(func():
		var m := OptionsMenu.open(self)
		m.closed.connect(func(): if is_instance_valid(b): b.grab_focus()))


func _exit_tree() -> void:
	Net.stop_lan_discovery()


func _apply_names() -> void:
	if Characters.has_current():
		Net.player_name = str(Characters.current.get("name", Net.player_name))
	elif not name_edit.text.strip_edges().is_empty():
		Net.player_name = name_edit.text.strip_edges()
	if not game_name_edit.text.strip_edges().is_empty():
		Net.game_name = game_name_edit.text.strip_edges()


func _need_character() -> bool:
	if Characters.has_current() or _test_mode():
		return false
	status.text = "Choisis ou crée d'abord un personnage."
	return true


func _test_mode() -> bool:
	var args := OS.get_cmdline_user_args()
	return "--solo" in args or "--host" in args or "--join" in args


func _on_solo() -> void:
	if _need_character():
		return
	_apply_names()
	if Net.host(false) == OK:
		Net.set_my_character(true)
		get_tree().change_scene_to_file(Net.LOBBY_SCENE)


func _on_host() -> void:
	if _need_character():
		return
	_apply_names()
	if Net.host(true) == OK:
		get_tree().change_scene_to_file(Net.LOBBY_SCENE)


func _on_join_ip() -> void:
	if _need_character():
		return
	_apply_names()
	var ip := ip_edit.text.strip_edges()
	if ip.is_empty():
		status.text = "Saisis une adresse IP ou choisis une partie dans la liste."
		return
	status.text = "Connexion à %s…" % ip
	Net.join(ip)


func _on_lan_activated(index: int) -> void:
	if _need_character():
		return
	if index < _lan_ips.size():
		_apply_names()
		status.text = "Connexion à %s…" % _lan_ips[index]
		Net.join(_lan_ips[index], Net.lan_games[_lan_ips[index]].get("port", Net.DEFAULT_PORT))


func _refresh_lan(games: Dictionary) -> void:
	lan_list.clear()
	_lan_ips.clear()
	for ip in games:
		var g: Dictionary = games[ip]
		lan_list.add_item("%s — %s  (%d/%d)" % [g.get("name", "?"), ip, g.get("players", 0), g.get("max_players", 2)])
		_lan_ips.append(ip)
	if games.is_empty():
		status.text = "Aucune partie détectée pour l'instant (double-clic sur une partie pour la rejoindre)."
	else:
		status.text = "%d partie(s) trouvée(s) — double-clic pour rejoindre." % games.size()


## Arguments en ligne de commande pour les tests : `-- --host` ou `-- --join 127.0.0.1`.
func _check_autostart() -> void:
	var args := OS.get_cmdline_user_args()
	if "--solo" in args:
		_on_solo.call_deferred()
	elif "--host" in args:
		_on_host.call_deferred()
	elif "--join" in args:
		var i := args.find("--join")
		ip_edit.text = args[i + 1] if i + 1 < args.size() else "127.0.0.1"
		_on_join_ip.call_deferred()

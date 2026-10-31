extends Node
## Test réseau à deux instances headless.
##   Hôte   : godot --headless --path . res://tests/net_smoke.tscn -- --host
##   Client : godot --headless --path . res://tests/net_smoke.tscn -- --join 127.0.0.1
##   Boss   : godot --headless --path . res://tests/net_smoke.tscn -- --boss   (phases, renforts, archers, victoire)
##   Donjon : godot --headless --path . res://tests/net_smoke.tscn -- --dungeon (plan, pièges, leviers, porte, feu de camp, réapparition)
##   Monde  : godot --headless --path . res://tests/net_smoke.tscn -- --outdoor (village, PNJ, boutique, quêtes, lignes de zone, prairie)
##   Persos : godot --headless --path . res://tests/net_smoke.tscn -- --chars (création, sauvegarde, reprise, coffre partagé)
##   Équilibrage : godot --headless --path . res://tests/net_smoke.tscn -- --balance [--n 4] (combats simulés → logs/balance_*.txt)
##   Interface : godot --headless --path . res://tests/net_smoke.tscn -- --ui (options, touches, menu système, focus manette)
## Le nœud se détache de la scène courante pour survivre aux changements de scène.
## En solo (sans argument) : héberge sans annoncer et vérifie la boucle de combat.

const TIMEOUT := 40.0

var role := "solo"
var hits_seen := 0
var hits_on_enemies := 0
var hits_on_me := 0
var t0 := 0.0
var cleared := false
var summary: Dictionary = {}
var ws_hits := 0  # membre : les lambdas capturent les locales par valeur
var skills_announced: Array[String] = []
var zones_entered: Array[String] = []
var quest_msgs: Array[String] = []
var npc_opened: Array[String] = []
var skill_resolutions: Array[String] = []
var boss_phases: Array[int] = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--host" in args:
		role = "host"
	elif "--join" in args:
		role = "client"
	elif "--wizard" in args:
		role = "wizard"
	elif "--boss" in args:
		role = "boss"
	elif "--dungeon" in args:
		role = "dungeon"
	elif "--outdoor" in args:
		role = "outdoor"
	elif "--ui" in args:
		role = "ui"
	elif "--chars" in args:
		role = "chars"
	elif "--balance" in args:
		role = "balance"
	_detach.call_deferred()


func _detach() -> void:
	var tree := get_tree()
	get_parent().remove_child(self)
	tree.root.add_child(self)
	t0 = Time.get_ticks_msec() / 1000.0
	if not role in ["dungeon", "outdoor", "ui", "chars", "balance"]:
		Net.level_path = "res://scenes/test_arena.tscn"
	EventBus.level_cleared.connect(func(): cleared = true)
	EventBus.run_finished.connect(func(sm: Dictionary): summary = sm)
	EventBus.boss_phase.connect(func(_b: Node3D, ph: int): boss_phases.append(ph))
	EventBus.monster_skill.connect(func(_m: Node3D, n: String): skills_announced.append(n))
	EventBus.zone_entered.connect(func(n: String): zones_entered.append(n))
	EventBus.quest_updated.connect(func(t: String): quest_msgs.append(t))
	EventBus.npc_dialog.connect(func(id: String): npc_opened.append(id))
	EventBus.hit_resolved.connect(func(target: Node3D, r: Dictionary):
		hits_seen += 1
		if r.get("attacker") is Enemy and r.get("attack_name", "") != "" and target.is_in_group("players"):
			skill_resolutions.append(r.attack_name)
		if r.get("hit", false):
			if target.is_in_group("players"):
				hits_on_me += 1
			else:
				hits_on_enemies += 1
	)
	_run()


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - t0


func _fail(msg: String) -> void:
	print("=== NET %s ÉCHEC : %s ===" % [role.to_upper(), msg])
	get_tree().quit(1)


func _run() -> void:
	match role:
		"host":
			await _run_host()
		"client":
			await _run_client()
		"wizard":
			await _run_wizard()
		"boss":
			await _run_boss()
		"dungeon":
			await _run_dungeon()
		"outdoor":
			await _run_outdoor()
		"ui":
			await _run_ui()
		"chars":
			await _run_chars()
		"balance":
			await _run_balance()
		_:
			await _run_solo()


# ---------------------------------------------------------------- hôte

func _run_host() -> void:
	Net.player_name = "Hote"
	if Net.host(true) != OK:
		_fail("host() a échoué")
		return
	Net.set_my_choice("fighter", "human", true)
	print("[hôte] en attente d'un client…")
	while Net.players.size() < 2 or not Net.all_ready():
		if _elapsed() > TIMEOUT:
			_fail("aucun client prêt")
			return
		await get_tree().create_timer(0.1).timeout
	print("[hôte] client prêt : %s — lancement" % Net.players[Net.players.keys()[1]].name)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	# Échange : l'hôte donne de l'or et un objet au client (menu du joueur).
	var give_ok := false
	for _i in 50:
		await get_tree().create_timer(0.1).timeout
		var h: PlayerCharacter = game.get_node("Players").get_node_or_null("Player_1")
		var c: PlayerCharacter = null
		for p in game.get_node("Players").get_children():
			if p != h:
				c = p
		if h and c and c.health.max_hp > 0:
			h.global_position = c.global_position + Vector3(1.5, 0, 0)
			h.inventory.gold = 30
			var g0: int = c.inventory.gold
			var n0: int = c.inventory.items.size()
			var gave_gold := h.give_gold(10, str(c.get_path()))
			var gave_item := h.give_item(0, str(c.get_path()))
			give_ok = gave_gold and gave_item and c.inventory.gold == g0 + 10 and h.inventory.gold == 20 and c.inventory.items.size() >= n0
			print("[hôte] échange : or=%s objet=%s (or client %d→%d)" % [gave_gold, gave_item, g0, c.inventory.gold])
			break
	# Attendre que le client ait fini (il se déconnecte) ou le timeout.
	while Net.players.size() > 1 and _elapsed() < TIMEOUT:
		await get_tree().create_timer(0.2).timeout
	var players := game.get_node("Players").get_children()
	var enemies_alive := 0
	for e in game.get_node("Enemies").get_children():
		if e.health.is_alive():
			enemies_alive += 1
	print("[hôte] résolutions=%d touches ennemis=%d ; ennemis vivants=%d ; joueurs=%d" % [hits_seen, hits_on_enemies, enemies_alive, players.size()])
	var ok := hits_on_enemies > 0 and give_ok
	print("=== NET HOST %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- client

func _run_client() -> void:
	Net.player_name = "Client"
	var args := OS.get_cmdline_user_args()
	var ip := args[args.find("--join") + 1]
	print("[client] connexion à %s…" % ip)
	if Net.join(ip) != OK:
		_fail("join() a échoué")
		return
	while not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if _elapsed() > 15.0:
			_fail("connexion impossible")
			return
		await get_tree().create_timer(0.1).timeout
	await get_tree().create_timer(0.3).timeout  # laisser le lobby s'installer
	# Le client rejoint avec SON personnage (stocké chez lui), sauvegardé par l'hôte.
	Characters.use_test_storage("_client")
	Characters.current = Characters.create("Cliente", "wizard", "elf")
	Net.player_name = "Cliente"
	Net.set_my_character(true)
	print("[client] connecté, prêt (personnage Cliente, magicienne elfe)")
	var game := await _wait_game()
	if game == null:
		return
	# Attendre le spawn de notre joueur et des monstres.
	var me: PlayerCharacter = null
	while _elapsed() < TIMEOUT:
		me = game.get_node("Players").get_node_or_null("Player_%d" % multiplayer.get_unique_id())
		if me and game.get_node("Enemies").get_child_count() >= 7 and me.health.max_hp > 0:
			break
		await get_tree().create_timer(0.1).timeout
	if me == null:
		_fail("joueur local non spawné")
		return
	var enemies := game.get_node("Enemies").get_children()
	print("[client] je suis %s PV %d/%d CA %d ; %d ennemis visibles ; hôte visible : %s" % [
		me.stats.display_name, me.health.hp, me.health.max_hp, me.stats.armor_class(), enemies.size(),
		game.get_node("Players").get_node_or_null("Player_1") != null])
	if enemies.size() != 7 or me.health.max_hp <= 0:
		_fail("réplication initiale incomplète")
		return
	# On pilote le joueur « à la main » : désactiver la lecture clavier locale.
	me.is_local = false
	# Un magicien niveau 1 ne survit pas à trois monstres : on teste la réplication, pas l'équilibrage.
	me.request_action("debug_god")
	var target: Enemy = enemies[0]
	var p0 := me.global_position
	var attacks := 0
	var start_hp: int = target.health.hp
	while _elapsed() < TIMEOUT:
		await get_tree().physics_frame
		if not is_instance_valid(target) or target.health.is_dead:
			break
		var to := target.global_position - me.global_position
		to.y = 0.0
		var yaw := atan2(-to.x, -to.z)
		if to.length() > 1.6:
			# Avancer : input "avant" relatif à la caméra orientée vers la cible.
			me._rpc_input.rpc_id(1, Vector2(0, -1), yaw, 0.0, false)
		else:
			me._rpc_input.rpc_id(1, Vector2.ZERO, yaw, 0.0, false)
			if attacks == 0:
				# Cibler puis engager : l'auto-attaque fait le reste (délai de l'arme).
				me.request_action("target:" + str(target.get_path()))
				me.request_action("engage")
				attacks += 1
		if hits_on_enemies >= 2:
			break
	if not is_instance_valid(me):
		_fail("joueur local détruit en cours de test (déconnexion ?)")
		return
	var moved := me.global_position.distance_to(p0)
	var end_hp: int = target.health.hp if is_instance_valid(target) else 0
	print("[client] déplacé de %.1f m ; attaques demandées=%d ; résolutions reçues=%d ; touches ennemis=%d ; PV cible %d→%d" % [
		moved, attacks, hits_seen, hits_on_enemies, start_hp, end_hp])
	# Sauvegarde demandée à l'hôte : le fichier du personnage (chez le client) est mis à jour.
	await game.save_party_now()
	var file := Characters.find(str(Characters.current.get("id", "")))
	var save_ok: bool = not file.get("state", {}).is_empty() and file.get("zone", "") == Net.level_path and me.player_name == "Cliente" and me.class_id == "wizard"
	print("[client] sauvegarde distante : %s (zone %s, PV %s)" % [save_ok, file.get("zone"), file.get("state", {}).get("hp")])
	var ok := moved > 2.0 and hits_on_enemies > 0 and end_hp < start_hp and me.combat.engaged and save_ok
	print("[client] engagé=%s cible=%s TP=%d" % [me.combat.engaged, me.combat.target_path, me.combat.tp])
	print("=== NET CLIENT %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- solo

func _run_solo() -> void:
	Net.player_name = "Solo"
	Net.host(false)
	Net.set_my_choice("fighter", "human", true)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	var me: PlayerCharacter = null
	while _elapsed() < TIMEOUT:
		me = game.get_node("Players").get_node_or_null("Player_1")
		if me and game.get_node("Enemies").get_child_count() >= 7:
			break
		await get_tree().create_timer(0.1).timeout
	if me == null:
		_fail("joueur non spawné")
		return
	me.is_local = false
	var enemies := game.get_node("Enemies").get_children()
	var target: Enemy = enemies[0]
	var tc := -Vector3(target.global_position.x, 0, target.global_position.z).normalized()
	me.global_position = target.global_position + tc * 5.0 + Vector3(0, 0.1, 0)
	var attacks := 0
	var ws_used := false
	var tp_seen := false
	var ws_name: String = me.combat.weapon_skill().get("name", "")
	EventBus.hit_resolved.connect(func(_t: Node3D, r: Dictionary):
		if r.get("attack_name", "") == ws_name:
			ws_hits += 1)
	while _elapsed() < TIMEOUT:
		await get_tree().physics_frame
		var nearest: Enemy = null
		var nd := 999.0
		for e in game.get_node("Enemies").get_children():
			if e.health.is_alive():
				var d: float = e.global_position.distance_to(me.global_position)
				if d < nd:
					nd = d
					nearest = e
		if nearest and nd > 6.0:
			# Ennemi vivant hors de portée d'aggro : on s'en rapproche (téléportation de test).
			var tc2 := -Vector3(nearest.global_position.x, 0, nearest.global_position.z).normalized()
			me.global_position = nearest.global_position + tc2 * 4.0 + Vector3(0, 0.1, 0)
		elif nearest:
			if me.combat.target() != nearest:
				me.set_target_local(nearest)
			if not me.combat.engaged and me.health.is_alive() and not me.is_busy():
				me.request_action("engage")  # (ré)engagement, par ex. après s'être relevé
				attacks += 1
			# Weapon skill dès que les TP sont là.
			if me.combat.tp >= PlayerCombat.TP_READY and not ws_used:
				ws_used = me.combat.use_weapon_skill()
		if hits_on_me >= 1 and not me.health.invulnerable:
			me.health.invulnerable = true  # un coup encaissé suffit : on ne veut pas passer le test à terre
		if hits_on_enemies >= 3 and hits_on_me >= 1 and (ws_used or tp_seen):
			break
		if nearest == null:
			break
		tp_seen = tp_seen or me.combat.tp > 0
	print("[solo] engagements=%d résolutions=%d touches ennemis=%d touches sur moi=%d PV %d/%d ; TP=%d WS utilisée=%s (touches WS=%d) délai arme=%.1f s" % [
		attacks, hits_seen, hits_on_enemies, hits_on_me, me.health.hp, me.health.max_hp, me.combat.tp, ws_used, ws_hits, me.combat.weapon_delay()])
	# Archer : on doit pouvoir le rattraper à la course et le frapper (repli limité, pas de kiting).
	var archer: Enemy = null
	for e in game.get_node("Enemies").get_children():
		if e.monster_id == "goblin_archer" and e.health.is_alive():
			archer = e
	var archer_hit := false
	if archer:
		me.health.invulnerable = true
		var tca := -Vector3(archer.global_position.x, 0, archer.global_position.z).normalized()
		me.global_position = archer.global_position + tca * 6.0 + Vector3(0, 0.1, 0)
		await get_tree().physics_frame
		me.set_target_local(archer)
		me.request_action("engage")
		var t_a := _elapsed()
		var archer_hp0: int = archer.health.hp
		while _elapsed() - t_a < 12.0 and is_instance_valid(archer) and archer.health.is_alive():
			await get_tree().physics_frame
			var to_a := archer.global_position - me.global_position
			to_a.y = 0.0
			me._cam_yaw = atan2(-to_a.x, -to_a.z)
			me._input_dir = Vector2(0, -1) if to_a.length() > 1.6 else Vector2.ZERO
			if archer.health.hp < archer_hp0:
				archer_hit = true
				break
		me._input_dir = Vector2.ZERO
		archer_hit = archer_hit or not is_instance_valid(archer) or archer.health.is_dead
		print("[solo] archer rattrapé et touché=%s en %.1f s" % [archer_hit, _elapsed() - t_a])
	# Weapon skill forcée : 150 TP, cible vivante au contact → résolutions au nom de la WS.
	me.health.invulnerable = true
	me.combat.disengage()
	var tough: Enemy = null
	for e in game.get_node("Enemies").get_children():
		if e.health.is_alive() and (tough == null or e.health.hp > tough.health.hp):
			tough = e
	if tough:
		var tc3 := -Vector3(tough.global_position.x, 0, tough.global_position.z).normalized()
		me.global_position = tough.global_position + tc3 * 1.5 + Vector3(0, 0.1, 0)
		me.set_target_local(tough)
	await get_tree().physics_frame
	await get_tree().create_timer(0.5).timeout  # laisser passer un éventuel coup déjà programmé
	while me.is_busy():
		await get_tree().physics_frame
	me.combat.tp = 150
	ws_used = me.combat.use_weapon_skill()
	await get_tree().create_timer(1.2).timeout
	var tdbg := me.combat.target()
	print("[solo] WS %s : lancée=%s résolutions=%d TP après=%d cible=%s vivante=%s dist=%s" % [ws_name, ws_used, ws_hits, me.combat.tp,
		tdbg, tdbg.health.is_alive() if tdbg else "?", me.global_position.distance_to(tdbg.global_position) if tdbg else "?"])
	me.combat.disengage()
	# ---- Butin : tuer le reste, ramasser ce qui tombe, ouvrir le coffre, utiliser une potion.
	me.health.invulnerable = true
	for e in game.get_node("Enemies").get_children():
		if e.health.is_alive():
			e.health.take_damage(999, 0, false, me)
	await get_tree().physics_frame
	var loot_root := game.get_node("Loot")
	var drops := loot_root.get_child_count()
	var chest: Chest = null
	for c in get_tree().get_nodes_in_group("chests"):
		chest = c
	if chest:
		me.global_position = chest.global_position + Vector3(0, 0.1, 1.5)
		var t_chest := _elapsed()
		while _elapsed() - t_chest < 10.0 and (me.is_busy() or not me.try_interact()):
			await get_tree().physics_frame
		await get_tree().physics_frame
	var drops_after_chest := loot_root.get_child_count()
	var gold_before: int = me.inventory.gold
	var picked := 0
	for d in loot_root.get_children():
		if not is_instance_valid(d):
			continue
		me.global_position = d.global_position + Vector3(0, 0.1, 0)
		for _i in 3:
			await get_tree().physics_frame
		picked += 1
	var inv: Inventory = me.inventory
	for i in inv.items.size():
		if Inventory.item_data(inv.items[i]).get("type", "") == "weapon":
			inv.equip(i)
			break
	me.health.invulnerable = false
	me.health.invulnerable = false
	me.health.hp = me.health.max_hp
	me.health.take_damage(5, 0, false, null)
	var hp_before: int = me.health.hp
	var potion_ok := me.use_potion()
	print("[solo] butin : %d objets tombés des monstres, %d après le coffre (ouvert=%s), ramassés=%d, or %d→%d, sac=%d, arme=%s, potion=%s PV %d→%d" % [
		drops, drops_after_chest, chest.opened if chest else "?", picked, gold_before, inv.gold, inv.items.size(), me.weapon.get("name", ""), potion_ok, hp_before, me.health.hp])
	# Tous les monstres sont morts : le niveau doit être annoncé comme nettoyé.
	for _i in 5:
		await get_tree().physics_frame
	var chest_ok: bool = chest == null or chest.opened
	var loot_ok: bool = drops > 0 and chest_ok and inv.gold > gold_before and loot_root.get_child_count() == 0
	print("[solo] niveau nettoyé=%s" % cleared)
	var ok: bool = attacks > 0 and hits_on_enemies > 0 and loot_ok and potion_ok and cleared and tp_seen and ws_used and ws_hits >= 1 and archer_hit
	print("=== NET SOLO %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


func _wait_game() -> Node:
	while _elapsed() < TIMEOUT:
		var cur := get_tree().current_scene
		if cur and cur.name == "Game":
			return cur
		await get_tree().create_timer(0.1).timeout
	_fail("la scène de jeu n'a pas été chargée")
	return null


# ---------------------------------------------------------------- solo magicien (sorts)

func _run_wizard() -> void:
	Net.player_name = "Mage"
	Net.host(false)
	Net.set_my_choice("wizard", "elf", true)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	var me: PlayerCharacter = null
	while _elapsed() < TIMEOUT:
		me = game.get_node("Players").get_node_or_null("Player_1")
		if me and game.get_node("Enemies").get_child_count() >= 7:
			break
		await get_tree().create_timer(0.1).timeout
	if me == null:
		_fail("magicien non spawné")
		return
	me.is_local = false
	me.health.invulnerable = true
	var book: SpellBook = me.spell_book
	print("[mage] sorts connus : %s ; emplacements %s ; DD %d ; bonus d'attaque de sort +%d" % [
		book.known, book.slots, me.stats.spell_save_dc("int"), me.stats.spell_attack_bonus("int")])
	if book.known.size() < 4:
		_fail("liste de sorts incomplète")
		return
	var enemies := game.get_node("Enemies").get_children()
	var target: Enemy = enemies[1]  # le gobelin 2 : approche dégagée (pas de pilier sur le trajet)
	_place_near(me, target)
	var results := {}
	var cast_times: Array = []
	for sid in ["fire_bolt", "magic_missile", "burning_hands", "mage_armor", "fireball"]:
		if sid not in book.known and sid != "fireball":
			continue
		if sid == "fireball":
			# Niveau 5 requis : on donne l'XP, le livre de sorts doit se mettre à jour tout seul.
			me.stats.add_xp(6500)
			await get_tree().physics_frame
			print("[mage] niveau %d, sorts %s, emplacements %s, PV %d/%d" % [me.stats.level, book.known, book.slots, me.health.hp, me.health.max_hp])
			if "fireball" not in book.known:
				_fail("boule de feu absente au niveau 5")
				return
		var before := hits_seen
		var before_hp: int = target.health.hp if is_instance_valid(target) else 0
		var casts := 0
		var ac_before := me.stats.armor_class()
		for i in 60 * 6:
			await get_tree().physics_frame
			if not is_instance_valid(target) or target.health.is_dead:
				break
			var to := target.global_position - me.global_position
			me._cam_yaw = atan2(-to.x, -to.z)
			if me.combat.target() != target:
				me.set_target_local(target)
			if sid == "burning_hands" and to.length() > 3.5:
				me._input_dir = Vector2(0, -1)  # avancer au contact
			else:
				me._input_dir = Vector2.ZERO
				if not me.combat.is_casting() and book.can_cast(sid) and me.combat.start_cast(sid):
					casts += 1
					cast_times.append(me.combat.cast_total)
			if sid == "mage_armor":
				if me.stats.armor_class() != ac_before:
					break
			elif hits_seen - before >= 2 or (casts >= 1 and book.slot_level_for(GameData.spell(sid)) < 0 and i > 90):
				if hits_seen - before >= 1:
					break
		var after_hp: int = target.health.hp if is_instance_valid(target) else 0
		if sid == "mage_armor":
			results[sid] = "CA %d → %d" % [ac_before, me.stats.armor_class()]
		else:
			results[sid] = "%d lancers, %d résolutions, PV cible %d → %d" % [casts, hits_seen - before, before_hp, after_hp]
		print("[mage] %s : %s" % [sid, results[sid]])
		me._input_dir = Vector2.ZERO
		book.restore_all()
		# Nouvelle cible vivante si la précédente est morte.
		if not is_instance_valid(target) or target.health.is_dead:
			for e in game.get_node("Enemies").get_children():
				if e.health.is_alive():
					target = e
					break
			if is_instance_valid(target):
				_place_near(me, target)
	# Interruption : lancer un sort puis bouger → l'incantation doit être annulée.
	var interrupt_ok := false
	for e in game.get_node("Enemies").get_children():
		if e.health.is_alive():
			me.set_target_local(e)
			break
	book.restore_all()
	while me.is_busy() or me.combat.is_casting():
		await get_tree().physics_frame
	var started: bool = me.combat.start_cast("mage_armor")  # sans cible : toujours lançable
	if started:
		me._input_dir = Vector2(0, -1)
		for _i in 20:
			await get_tree().physics_frame
		interrupt_ok = not me.combat.is_casting() and book.slots.get("1", 0) == book.max_slots.get("1", 0)
		me._input_dir = Vector2.ZERO
	print("[mage] temps d'incantation vus : %s ; incantation démarrée=%s ; interruption par déplacement : %s" % [cast_times, started, interrupt_ok])
	var fireball_ok: bool = results.has("fireball") and not str(results["fireball"]).begins_with("0 lancers")
	var ok: bool = hits_seen >= 3 and me.stats.armor_class() == 13 + me.stats.ability_mod("dex") \
		and me.stats.level == 5 and fireball_ok and interrupt_ok and cast_times.size() > 0 and cast_times.max() >= 2.0
	print("=== NET WIZARD %s === (résolutions totales : %d)" % ["OK" if ok else "ÉCHEC", hits_seen])
	Net.stop()
	get_tree().quit(0 if ok else 1)


## Place le joueur à 8 m de la cible vers le centre de l'arène, en évitant les piliers de test_arena.
func _place_near(me: Node3D, target: Node3D) -> void:
	var tc := -Vector3(target.global_position.x, 0, target.global_position.z).normalized()
	var pos := target.global_position + tc * 8.0
	for pillar in [Vector3(5, 0, -5), Vector3(-5, 0, 5), Vector3(6, 0, 6)]:
		if Vector3(pos.x, 0, pos.z).distance_to(pillar) < 2.0:
			pos += tc.cross(Vector3.UP) * 2.5
	me.global_position = Vector3(pos.x, 0.1, pos.z)

# ---------------------------------------------------------------- boss

func _run_boss() -> void:
	Net.player_name = "Boss"
	Net.host(false)
	Net.set_my_choice("fighter", "dwarf", true)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	var me: PlayerCharacter = null
	while _elapsed() < TIMEOUT:
		me = game.get_node("Players").get_node_or_null("Player_1")
		if me and game.get_node("Enemies").get_child_count() >= 7:
			break
		await get_tree().create_timer(0.1).timeout
	if me == null:
		_fail("joueur non spawné")
		return
	me.is_local = false
	me.health.invulnerable = true
	var enemies_root := game.get_node("Enemies")
	var boss: Enemy = null
	var spider: Enemy = null
	for e in enemies_root.get_children():
		if e.monster_id == "goblin_boss":
			boss = e
		elif e.monster_id == "giant_spider":
			spider = e
	if boss == null:
		_fail("pas de boss dans l'arène")
		return
	var types := {}
	for e in enemies_root.get_children():
		types[e.monster_id] = types.get(e.monster_id, 0) + 1
	print("[boss] monstres : %s ; boss PV %d/%d (CA %d)" % [types, boss.health.hp, boss.health.max_hp, boss.stats.armor_class()])
	# Phase 1 : première blessure → 2 gobelins apparaissent.
	var before := enemies_root.get_child_count()
	me.global_position = boss.global_position + Vector3(0, 0.1, -3)
	boss.health.take_damage(int(boss.health.max_hp * 0.2), 0, false, me)
	for _i in 3:
		await get_tree().physics_frame
	var after1 := enemies_root.get_child_count()
	# Phase 2 : sous 50 % → 2 archers, attaque accélérée.
	boss.health.take_damage(int(boss.health.max_hp * 0.35), 0, false, me)
	for _i in 3:
		await get_tree().physics_frame
	var after2 := enemies_root.get_child_count()
	var archers := 0
	for e in enemies_root.get_children():
		if e.monster_id == "goblin_archer":
			archers += 1
	print("[boss] phases=%s ; ennemis %d → %d → %d ; archers=%d ; boss phase=%d cadence x%.2f" % [
		boss_phases, before, after1, after2, archers, boss.phase, 1.0 / boss._cooldown_mult])
	# Les archers tirent : on attend un projectile hostile puis une attaque à distance résolue sur moi.
	var hits_before := hits_on_me
	var projectiles_seen := 0
	var t_start := _elapsed()
	while _elapsed() - t_start < 12.0:
		await get_tree().physics_frame
		for p in game.get_node("Projectiles").get_children():
			if p is Projectile and p.hostile:
				projectiles_seen += 1
		if projectiles_seen > 0 and hits_seen > 0 and hits_on_me > hits_before:
			break
	print("[boss] projectiles hostiles vus=%d ; attaques subies=%d ; PV %d/%d (invulnérable)" % [
		projectiles_seen, hits_on_me - hits_before, me.health.hp, me.health.max_hp])
	# Provocation à distance : on attire un monstre inactif de loin, lui seul.
	var far: Enemy = null
	for e in enemies_root.get_children():
		if e.health.is_alive() and e.state == Enemy.State.IDLE and e.monster_id != "goblin_boss":
			far = e
			break
	var taunt_ok := false
	if far:
		var tcf := -Vector3(far.global_position.x, 0, far.global_position.z).normalized()
		me.global_position = far.global_position + tcf * 14.0 + Vector3(0, 0.1, 0)
		await get_tree().physics_frame
		me.set_target_local(far)
		var used: bool = me.combat.use_ability("provoke")
		await get_tree().physics_frame
		taunt_ok = used and far.target == me and far.state == Enemy.State.CHASE
		print("[boss] provocation à 14 m sur %s : utilisée=%s cible=moi:%s état=%s" % [far.monster_id, used, far.target == me, far.state])
	# Compétences de monstres : un gobelin à 100 TP doit annoncer puis lancer sa bombe (zone, sauvegarde DEX).
	var gob: Enemy = null
	for e in enemies_root.get_children():
		if e.monster_id == "goblin" and e.health.is_alive():
			gob = e
			break
	var skill_ok := false
	if gob:
		me.global_position = gob.global_position + Vector3(1.2, 0.1, 0)
		await get_tree().physics_frame
		gob.target = me
		gob.state = Enemy.State.ATTACK
		gob.gain_tp(100)
		var t_s := _elapsed()
		while _elapsed() - t_s < 6.0 and not ("Bombe gobeline" in skill_resolutions):
			await get_tree().physics_frame
		skill_ok = "Bombe gobeline" in skills_announced and "Bombe gobeline" in skill_resolutions
		print("[boss] compétence de monstre : annoncées=%s résolues=%s ; PV monstres ×%.1f (gobelin %d PV)" % [
			skills_announced, skill_resolutions, GameData.bal("monster_hp_mult"), gob.health.max_hp])
	# Toile d'araignée : on force la condition et on vérifie l'immobilisation.
	var web_ok := false
	if spider and spider.health.is_alive():
		me.global_position = Vector3(-20, 0.1, 20)  # loin de tout tireur de toile
		await get_tree().physics_frame
		me.conditions.clear()
		me.apply_condition("restrained", 1.0)
		web_ok = me.is_restrained()
		await get_tree().create_timer(1.1).timeout
		web_ok = web_ok and not me.is_restrained()
	# Fin : on tue tout, le niveau doit être nettoyé.
	for e in enemies_root.get_children():
		if e.health.is_alive():
			e.health.take_damage(9999, 0, false, me)
	for _i in 6:
		await get_tree().physics_frame
	print("[boss] boss mort=%s ; niveau nettoyé=%s ; entrave ok=%s ; niveau joueur=%d" % [
		boss.health.is_dead, cleared, web_ok, me.stats.level])
	var ok: bool = types.size() >= 5 and after1 == before + 2 and after2 == after1 + 2 and archers >= 2 \
		and boss_phases == [1, 2] and projectiles_seen > 0 and boss.health.is_dead and cleared and web_ok and skill_ok and taunt_ok
	print("=== NET BOSS %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- donjon

func _run_dungeon() -> void:
	Net.player_name = "Explorateur"
	Net.level_path = "res://scenes/dungeon_01.tscn"
	Net.host(false)
	Net.set_my_choice("fighter", "human", true)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	var me: PlayerCharacter = null
	while _elapsed() < TIMEOUT:
		me = game.get_node("Players").get_node_or_null("Player_1")
		if me and game.get_node("Enemies").get_child_count() >= 15:
			break
		await get_tree().create_timer(0.1).timeout
	if me == null:
		_fail("joueur non spawné")
		return
	me.is_local = false
	var level: Dungeon = game.level
	var enemies_root := game.get_node("Enemies")
	var walls := 0
	for n in level.geometry.get_children():
		if n.name.begins_with("Wall"):
			walls += 1
	var door: Door = get_tree().get_first_node_in_group("doors")
	var levers := get_tree().get_nodes_in_group("levers")
	var fire: Campfire = get_tree().get_first_node_in_group("campfires")
	var traps := get_tree().get_nodes_in_group("traps")
	var chests := get_tree().get_nodes_in_group("chests")
	print("[donjon] cellules=%s murs=%s torches=%s ennemis=%s porte=%s leviers=%s feux=%s pièges=%s coffres=%s spawn=%s" % [
		level.floor_cells.size(), walls, level._torch_lights.size(), enemies_root.get_child_count(),
		door != null, levers.size(), fire != null, traps.size(), chests.size(), me.global_position])
	# Les monstres du fond ne doivent pas être réveillés depuis l'entrée (pas de ligne de vue).
	await get_tree().create_timer(0.6).timeout
	var awake := 0
	for e in enemies_root.get_children():
		if e.state != Enemy.State.IDLE:
			awake += 1
	# Piège : on marche sur une plaque de pointes.
	var hits_before := hits_seen
	var spikes: Trap = null
	for t in traps:
		if t.kind == "spikes":
			spikes = t
			break
	me.global_position = spikes.global_position + Vector3(0, 0.1, 0)
	for _i in 6:
		await get_tree().physics_frame
	var trap_hits := hits_seen - hits_before
	var hp_after_trap: int = me.health.hp
	me.health.invulnerable = true  # l'araignée de la salle ouest ne doit pas nous mettre à terre
	# Énigme des runes (zone est) : mauvais ordre puis bon ordre → pointes désamorcées.
	var puzzle: RunePuzzle = null
	for pz in get_tree().get_nodes_in_group("puzzles"):
		if pz.zone == "east":
			puzzle = pz
	var puzzle_ok := false
	if puzzle:
		var runes := puzzle._runes
		puzzle.press(runes[puzzle.order[1]].rune_index, me)  # faux départ
		var reset_ok: bool = puzzle.progress == 0 and not puzzle.solved
		for idx in puzzle.order:
			me.global_position = runes[idx].global_position + Vector3(0, 0.1, 0) - runes[idx].global_transform.basis.z * 1.0
			await get_tree().physics_frame
			while me.is_busy():
				await get_tree().physics_frame
			me.try_interact()
			await get_tree().physics_frame
		await get_tree().physics_frame
		var before_disarm := hits_seen
		me.global_position = spikes.global_position + Vector3(0, 0.1, 0)
		for _i in 6:
			await get_tree().physics_frame
		puzzle_ok = reset_ok and puzzle.solved and spikes.disarmed and hits_seen == before_disarm
		print("[donjon] runes : reset=%s résolu=%s pointes désamorcées=%s (dégâts après=%d)" % [reset_ok, puzzle.solved, spikes.disarmed, hits_seen - before_disarm])
	# Leviers → porte.
	var door_before: bool = door.open
	me.global_position = door.global_position + Vector3(0, 0.1, 2.0)
	await get_tree().physics_frame
	while me.is_busy():
		await get_tree().physics_frame
	var feedback_ok: bool = me.try_interact()  # porte verrouillée : message seulement
	for l in levers:
		me.global_position = l.global_position + Vector3(0, 0.1, 1.0)
		await get_tree().physics_frame
		while me.is_busy():
			await get_tree().physics_frame
		var r: bool = me.try_interact()
		await get_tree().physics_frame
		print("[donjon] levier %s : interact=%s pulled=%s dist=%.2f busy=%s alive=%s" % [l.lever_id, r, l.pulled, me.global_position.distance_to(l.global_position), me.is_busy(), me.health.is_alive()])
	var door_after: bool = door.open
	# Feu de camp : repos (on repart avec tous ses PV pour que les 5 dégâts ne mettent pas à terre).
	me.health.invulnerable = false
	me.health.hp = me.health.max_hp
	me.health.take_damage(5, 0, false, null)
	var hp_before_rest: int = me.health.hp
	me.global_position = fire.global_position + Vector3(0, 0.1, 1.5)
	while me.is_busy():
		await get_tree().physics_frame
	fire.cooldown = 0.3
	var rest_ok: bool = me.try_interact()
	await get_tree().physics_frame
	var hp_after_rest: int = me.health.hp
	var max_at_rest: int = me.health.max_hp
	# Réutilisable après la recharge.
	await get_tree().create_timer(0.5).timeout
	while me.is_busy():
		await get_tree().physics_frame
	me.health.take_damage(3, 0, false, null)
	var rest_again: bool = me.try_interact() and me.health.hp == me.health.max_hp
	rest_ok = rest_ok and rest_again
	var checkpoint_moved: bool = game.checkpoint.distance_to(fire.global_position) < 3.0
	# Réapparition : le groupe entier à terre → retour au feu de camp.
	me.global_position = Vector3(6, 0.1, 6)
	await get_tree().physics_frame
	me.health.take_damage(999, 0, false, null)
	var downed: bool = me.health.is_downed
	var t_start := _elapsed()
	while _elapsed() - t_start < 8.0 and me.health.is_downed:
		await get_tree().physics_frame
	var respawned: bool = not me.health.is_downed and me.global_position.distance_to(game.checkpoint) < 3.0
	# Feuille de personnage (HUD) puis fin de partie : on tue tout, le résumé doit arriver.
	var hud: Node = game.get_node_or_null("HUD")
	var sheet_ok := false
	var menu_ok := false
	if hud:
		hud.toggle_character_sheet()
		sheet_ok = hud._sheet_panel.visible and hud._sheet_body.get_child_count() > 8
		hud.toggle_character_sheet()
		# Menu de commandes : d'abord via une vraie touche Entrée simulée (chaîne d'entrées complète)…
		# (loin de tout objet interactif : sinon Entrée = interagir, touche d'action contextuelle)
		me.selection = null
		me.global_position += Vector3(0, 40, 0)
		var key := InputEventKey.new()
		key.physical_keycode = KEY_ENTER
		key.keycode = KEY_ENTER
		key.pressed = true
		Input.parse_input_event(key)
		for _i in 3:
			await get_tree().process_frame
		var opened_by_key: bool = hud._menu_open
		var rect: Rect2 = _menu_rect(hud)
		print("[donjon] Entrée simulée → menu ouvert=%s ; rect=%s (fenêtre %s)" % [opened_by_key, rect, get_viewport().get_visible_rect().size])
		var key_up := InputEventKey.new()
		key_up.physical_keycode = KEY_ENTER
		key_up.keycode = KEY_ENTER
		key_up.pressed = false
		Input.parse_input_event(key_up)
		hud.close_menu()
		# …puis par l'API : racine → Compétences → retour → fermer.
		hud.open_menu()
		var root_n: int = hud._menu_items.size()
		hud._menu_move(1)
		hud._menu_confirm()
		var skills_n: int = hud._menu_items.size()
		var menu_level: String = hud._menu_level
		hud._menu_back()
		hud._menu_back()
		var vis: Rect2 = get_viewport().get_visible_rect()
		var help_rect: Rect2 = hud._help_panel.get_global_rect()
		var on_screen: bool = vis.encloses(rect) and vis.encloses(help_rect)
		print("[donjon] panneau d'aide rect=%s ; tout à l'écran=%s" % [help_rect, on_screen])
		menu_ok = root_n >= 4 and menu_level == "skills" and skills_n >= 3 and not hud._menu_open and not me.menu_open and opened_by_key and on_screen
		print("[donjon] menu : racine=%d entrées, compétences=%d entrées (%s), fermé=%s" % [root_n, skills_n, menu_level, not hud._menu_open])
	me.health.invulnerable = true
	me.global_position = Vector3(6, 0.1, 6)
	for e in enemies_root.get_children():
		if e.health.is_alive():
			e.health.take_damage(9999, 0, false, me)
	var t_end := _elapsed()
	while _elapsed() - t_end < 6.0 and summary.is_empty():
		await get_tree().physics_frame
	var stats_ok := false
	if not summary.is_empty():
		var p0: Dictionary = summary.players[0]
		stats_ok = p0.kills == 15 and p0.downs == 1 and p0.damage_taken > 0 and summary.duration > 1.0
		print("[donjon] résumé : %s en %.1f s ; %s" % [summary.level_name, summary.duration, p0])
	print("[donjon] éveillés au départ=%d ; piège : %d résolution(s), PV %d ; porte %s→%s (retour=%s) ; repos %d→%d (ok=%s, checkpoint=%s) ; à terre=%s réapparu=%s" % [
		awake, trap_hits, hp_after_trap, door_before, door_after, feedback_ok, hp_before_rest, hp_after_rest, rest_ok, checkpoint_moved, downed, respawned])
	var ok: bool = level.floor_cells.size() > 150 and walls > 100 and level._torch_lights.size() >= 20 \
		and enemies_root.get_child_count() == 15 and door != null and levers.size() == 2 and fire != null \
		and traps.size() == 3 and chests.size() == 2 and awake == 0 and trap_hits >= 1 \
		and not door_before and door_after and feedback_ok and rest_ok and hp_after_rest == max_at_rest \
		and checkpoint_moved and downed and respawned and sheet_ok and menu_ok and cleared and stats_ok and puzzle_ok
	print("[donjon] feuille=%s menu=%s nettoyé=%s stats=%s" % [sheet_ok, menu_ok, cleared, stats_ok])
	print("=== NET DUNGEON %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


func _menu_rect(hud: Node) -> Rect2:
	return (hud._menu_panel as Control).get_global_rect()


# ---------------------------------------------------------------- monde extérieur

func _await_player(game: Node, min_enemies: int) -> PlayerCharacter:
	var me: PlayerCharacter = null
	var t_w := _elapsed()
	while _elapsed() - t_w < 15.0:
		me = game.get_node("Players").get_node_or_null("Player_1")
		if me and game.get_node("Enemies").get_child_count() >= min_enemies and me.health.max_hp > 0:
			break
		await get_tree().create_timer(0.1).timeout
	return me


func _run_outdoor() -> void:
	Net.player_name = "Voyageur"
	Net.level_path = "res://scenes/outdoor_village.tscn"
	Net.host(false)
	Net.set_my_choice("fighter", "human", true)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	var me := await _await_player(game, 0)
	if me == null:
		_fail("joueur non spawné au village")
		return
	me.is_local = false
	me.health.invulnerable = true
	var level: Outdoor = game.level
	var npcs := get_tree().get_nodes_in_group("npcs")
	var lines := get_tree().get_nodes_in_group("zone_lines")
	var geo := level.geometry.get_child_count()
	print("[monde] %s : géométrie=%d PNJ=%d lignes de zone=%d feux=%d spawn=%s" % [
		level.zone_name, geo, npcs.size(), lines.size(), get_tree().get_nodes_in_group("campfires").size(), me.global_position])
	# PNJ : parler à l'ancienne → dialogue ouvert ; accepter la quête des lapins.
	var elder: Npc = null
	var smith: Npc = null
	for n in npcs:
		if n.npc_id == "elder":
			elder = n
		elif n.npc_id == "smith":
			smith = n
	me.global_position = elder.global_position + Vector3(0, 0.1, 1.5)
	await get_tree().physics_frame
	me.try_interact()
	await get_tree().physics_frame
	var dialog_ok: bool = "elder" in npc_opened
	me.request_action("quest_accept:q_rabbits")
	await get_tree().physics_frame
	var accepted: bool = me.quest_log.is_active("q_rabbits")
	# Boutique : acheter une masse chez le forgeron, la revendre.
	me.global_position = smith.global_position + Vector3(0, 0.1, 1.5)
	await get_tree().physics_frame
	me.inventory.gold = 100
	me.request_action("buy:mace")
	await get_tree().physics_frame
	var bought: bool = me.inventory.count("mace") == 1 and me.inventory.gold == 95
	var idx := me.inventory.find_index("mace")
	me.request_action("sell:%d" % idx)
	await get_tree().physics_frame
	var sold: bool = me.inventory.count("mace") == 0 and me.inventory.gold == 97
	var too_far_block := true
	me.global_position = Vector3(0, 0.1, 30)
	await get_tree().physics_frame
	me.request_action("buy:mace")
	await get_tree().physics_frame
	too_far_block = me.inventory.count("mace") == 0
	print("[monde] PNJ : dialogue=%s quête acceptée=%s ; boutique : achat=%s vente=%s refus à distance=%s ; messages=%s" % [
		dialog_ok, accepted, bought, sold, too_far_block, quest_msgs])
	# Ligne de zone vers la prairie : tout le groupe change de scène, l'état du personnage est conservé.
	me.stats.add_xp(300)  # niveau 2 pour vérifier la persistance
	var level_before: int = me.stats.level
	var gold_before: int = me.inventory.gold
	var east: ZoneLine = null
	for l in lines:
		if l.target_level.ends_with("outdoor_prairie.tscn"):
			east = l
	me.global_position = east.global_position + Vector3(-1.5, 0.1, 0)
	await get_tree().physics_frame
	me.global_position = east.global_position
	var t_z := _elapsed()
	while _elapsed() - t_z < 8.0 and (get_tree().current_scene == null or get_tree().current_scene == game or not is_instance_valid(game)):
		await get_tree().create_timer(0.1).timeout
		if not is_instance_valid(game):
			break
	await get_tree().create_timer(0.5).timeout
	var game2 := await _wait_game()
	var me2 := await _await_player(game2, 10)
	if me2 == null:
		_fail("joueur non spawné dans la prairie")
		return
	me2.is_local = false
	me2.health.invulnerable = true
	var level2: Outdoor = game2.level
	var persisted: bool = me2.stats.level == level_before and me2.inventory.gold == gold_before and me2.quest_log.is_active("q_rabbits")
	# Arrivée depuis le village (bord ouest) : on doit regarder vers l'est (+X), donc forward ≈ (1, 0, 0).
	var fwd := -me2.global_transform.basis.z
	var facing_ok: bool = fwd.x > 0.8 and absf(me2.camera_pivot.rotation.y - me2.rotation.y) < 0.05
	print("[monde] orientation à l'arrivée : avant=%s caméra alignée=%s" % [fwd, facing_ok])
	var enemies2 := game2.get_node("Enemies").get_children()
	var kinds := {}
	for e in enemies2:
		kinds[e.monster_id] = kinds.get(e.monster_id, 0) + 1
	print("[monde] %s : zones=%s ; persistance=%s (niv %d, %d po) ; monstres=%s ; spawn=%s" % [
		level2.zone_name, zones_entered, persisted, me2.stats.level, me2.inventory.gold, kinds, me2.global_position])
	# Après le changement de zone, un coup résolu doit s'afficher sans erreur (texte flottant, HUD).
	EventBus.hit_resolved.emit(me2, {"attacker": me2, "target": me2, "attack_name": "Test", "hit": true, "crit": false,
		"fumble": false, "blocked": false, "damage": 1, "damage_type": 0, "d20": 15, "total": 20, "ac": 10})
	await get_tree().physics_frame
	# Lapins : passifs (pas d'aggro), on en tue 5 → quête complète ; un lapin réapparaît.
	var rabbits: Array = []
	for e in enemies2:
		if e.monster_id == "rabbit":
			rabbits.append(e)
	await get_tree().create_timer(0.5).timeout
	var passive := true
	for r in rabbits:
		if r.state != Enemy.State.IDLE:
			passive = false
	var killed := 0
	for r in rabbits:
		if killed >= 5:
			break
		r.health.take_damage(999, 0, false, me2)
		killed += 1
	await get_tree().physics_frame
	await get_tree().physics_frame
	var quest_complete: bool = me2.quest_log.is_complete("q_rabbits", me2.inventory)
	var model_ok: bool = rabbits[0].model != null and rabbits[0].anim != null and rabbits[0].anim.has_animation("walk")
	# Rendre la quête à distance doit échouer (pas de PNJ) → on teste turn_in directement via l'hôte.
	var gold_q: int = me2.inventory.gold
	me2.request_action("quest_turnin:q_rabbits")
	await get_tree().physics_frame
	var turned: bool = me2.quest_log.is_done("q_rabbits") and me2.inventory.gold == gold_q + 30 and me2.inventory.count("potion_healing") >= 2
	print("[monde] lapins : passifs=%s tués=%d quête complète=%s rendue=%s modèle procédural=%s ; progression=%s" % [
		passive, killed, quest_complete, turned, model_ok, quest_msgs.slice(maxi(0, quest_msgs.size() - 3))])
	var ok: bool = geo > 50 and npcs.size() == 4 and lines.size() == 1 and dialog_ok and accepted and bought and sold and too_far_block \
		and zones_entered.size() >= 2 and persisted and kinds.get("rabbit", 0) == 8 and kinds.get("giant_bee", 0) == 4 \
		and passive and quest_complete and turned and model_ok and facing_ok
	print("=== NET OUTDOOR %s ===" % ("OK" if ok else "ÉCHEC"))
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- interface (options, manette)

func _key(code: Key, pressed := true) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = pressed
	Input.parse_input_event(k)
	for _i in 2:
		await get_tree().process_frame


func _tap(code: Key) -> void:
	await _key(code, true)
	await _key(code, false)


func _focus_in(root: Node) -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f != null and root.is_ancestor_of(f)


func _find_button(root: Node, prefix: String) -> Button:
	for b in root.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with(prefix) and (b as Button).is_visible_in_tree():
			return b
	return null


func _run_ui() -> void:
	var errors: Array[String] = []
	Settings.path = "user://settings_test.cfg"  # ne pas toucher aux réglages du joueur
	# 1) Touches : modification, sauvegarde, rechargement, réinitialisation.
	Settings.reset_bindings()
	var k := InputEventKey.new()
	k.keycode = KEY_K
	Settings.rebind("journal", 0, k)
	var cfg := ConfigFile.new()
	cfg.load(Settings.path)
	var saved: Array = cfg.get_value("bindings", "journal", [])
	var reload_ok := saved.size() >= 1 and saved[0] is InputEventKey and (saved[0] as InputEventKey).keycode == KEY_K
	var pad_kept := Settings.events_of("journal", true).size() == Settings.events_of("journal", true).size()
	InputMap.load_from_project_settings()
	Settings.load_settings()
	var applied := false
	for e in InputMap.action_get_events("journal"):
		if e is InputEventKey and (e as InputEventKey).keycode == KEY_K:
			applied = true
	var conflict := Settings.conflicts(k, "inventory")
	Settings.reset_bindings()
	var reset_ok := true
	for e in InputMap.action_get_events("journal"):
		if e is InputEventKey and (e as InputEventKey).keycode == KEY_K:
			reset_ok = false
	var labels := "%s / %s / %s" % [Settings.event_label(InputMap.action_get_events("move_forward")[1]),
		Settings.event_label(InputMap.action_get_events("attack")[0]), Settings.event_label(InputMap.action_get_events("dodge")[1])]
	print("[ui] touches : sauvegarde=%s rechargée=%s conflit=%s réinit=%s libellés=%s" % [reload_ok, applied, conflict, reset_ok, labels])
	if not (reload_ok and applied and reset_ok and pad_kept and "Journal de quêtes" in conflict):
		errors.append("touches")
	var pad_ui := false
	for e in InputMap.action_get_events("ui_accept"):
		if e is InputEventJoypadButton and e.button_index == JOY_BUTTON_A:
			pad_ui = true
	if not pad_ui:
		errors.append("ui_accept manette")

	# 2) Menu principal : bouton Options et focus de départ.
	var mm: Node = load("res://scenes/main_menu.tscn").instantiate()
	get_tree().root.add_child(mm)
	await get_tree().process_frame
	await get_tree().process_frame
	var opt_btn := _find_button(mm, "Options")
	var mm_focus := _focus_in(mm)
	opt_btn.pressed.emit()
	await get_tree().process_frame
	var om_main := OptionsMenu.is_open()
	await _tap(KEY_ESCAPE)
	var om_closed := not OptionsMenu.is_open()
	print("[ui] menu principal : bouton Options=%s focus=%s options ouvertes=%s fermées par Échap=%s" % [opt_btn != null, mm_focus, om_main, om_closed])
	if not (opt_btn and mm_focus and om_main and om_closed):
		errors.append("menu principal")
	mm.queue_free()
	await get_tree().process_frame

	# 3) En jeu (village) : dialogue PNJ au focus, boutique, menu système, options.
	Net.player_name = "Testeur"
	Net.level_path = "res://scenes/outdoor_village.tscn"
	Net.host(false)
	Net.set_my_choice("fighter", "human", true)
	Net.start_game()
	var game := await _wait_game()
	if game == null:
		return
	var me := await _await_player(game, 0)
	if me == null:
		_fail("joueur non spawné")
		return
	me.health.invulnerable = true
	var hud: Node = game.get_node("HUD")
	EventBus.npc_dialog.emit("elder")
	await get_tree().process_frame
	var dlg_focus := _focus_in(hud._dialog_body)
	var blocked: bool = me.menu_open
	await _tap(KEY_ENTER)  # bouton focalisé : pas de menu de commandes
	var no_cmd_menu: bool = not hud._menu_open
	if hud._dialog_panel.visible:
		await _tap(KEY_ESCAPE)
	var dlg_closed: bool = not hud._dialog_panel.visible
	await get_tree().create_timer(0.35).timeout
	var unblocked: bool = not me.menu_open
	print("[ui] dialogue : focus=%s bloqué=%s Entrée sans menu=%s fermé=%s débloqué=%s" % [dlg_focus, blocked, no_cmd_menu, dlg_closed, unblocked])
	if not (dlg_focus and blocked and no_cmd_menu and dlg_closed and unblocked):
		errors.append("dialogue")
	# Touche d'action contextuelle : PNJ sélectionné → dialogue ; Tab hors combat sélectionne aussi les PNJ.
	await get_tree().create_timer(0.3).timeout
	var elder_npc: Npc = null
	for n in get_tree().get_nodes_in_group("npcs"):
		if n.npc_id == "elder":
			elder_npc = n
	me.global_position = elder_npc.global_position + Vector3(0, 0.1, 2.0)
	await get_tree().physics_frame
	var cands: Array = me.selectable_candidates()
	me.select_node(elder_npc)
	var kind: String = me.context_kind()
	hud.context_open()
	await get_tree().physics_frame
	await get_tree().process_frame
	var talk_ok: bool = hud._dialog_panel.visible and hud._dialog_npc == "elder"
	hud.close_npc_dialog()
	await get_tree().create_timer(0.3).timeout
	me.select_node(null)
	# Menu de commandes persistant : après une action (objet), il reste ouvert à la racine et on peut bouger.
	hud.open_menu()
	hud._menu_level = "items"
	hud._rebuild_menu()
	hud._menu_index = 0
	hud._menu_confirm()
	await get_tree().physics_frame
	var persist_ok: bool = hud._menu_open and hud._menu_level == "" and me.menu_open and not me.ui_blocked
	hud.close_menu()
	print("[ui] action contextuelle : PNJ dans Tab=%s type=%s dialogue=%s ; menu persistant=%s" % [elder_npc in cands, kind, talk_ok, persist_ok])
	if not (elder_npc in cands and kind == "talk" and talk_ok and persist_ok):
		errors.append("action contextuelle / menu persistant")
	# Boutique du forgeron : « Acheter » → page boutique avec focus ; Échap → retour au dialogue.
	EventBus.npc_dialog.emit("smith")
	await get_tree().process_frame
	var buy := _find_button(hud._dialog_body, "Acheter")
	if buy:
		buy.grab_focus()
		await _tap(KEY_ENTER)
	var shop_mode: String = hud._dialog_mode
	var shop_focus := _focus_in(hud._dialog_body)
	await _tap(KEY_ESCAPE)
	var back_mode: String = hud._dialog_mode
	var still_open: bool = hud._dialog_panel.visible
	hud.close_npc_dialog()
	print("[ui] boutique : page=%s focus=%s retour=%s dialogue ouvert=%s" % [shop_mode, shop_focus, back_mode == "", still_open])
	if not (shop_mode == "shop_buy" and shop_focus and back_mode == "" and still_open):
		errors.append("boutique")
	# Menu système : Échap → menu, focus ; Options → écran d'options ; Échap → retour au menu ; Échap → jeu.
	await get_tree().create_timer(0.3).timeout
	await _tap(KEY_ESCAPE)
	var sys_open: bool = hud._sys_panel.visible
	var sys_focus := _focus_in(hud._sys_body)
	var options_btn := _find_button(hud._sys_body, "Options")
	options_btn.pressed.emit()
	await get_tree().process_frame
	var om: OptionsMenu = OptionsMenu._instance
	var tabs: int = om._tabs.get_tab_count() if om else 0
	var binds: int = om._bind_buttons.size() if om else 0
	var opt_focus := om != null and _focus_in(om)
	# Saisie d'une touche dans l'écran Touches.
	om._start_listen("journal", 0)
	await _tap(KEY_K)
	var bound := false
	for e in InputMap.action_get_events("journal"):
		if e is InputEventKey and (e as InputEventKey).keycode == KEY_K:
			bound = true
	var btn_txt: String = om._bind_buttons["journal|0"].text
	# Échelle d'interface.
	Settings.ui_scale = 1.25
	Settings.apply_video(false)
	var scale_ok := is_equal_approx(get_tree().root.content_scale_factor, 1.25)
	Settings.ui_scale = 1.0
	Settings.apply_video(false)
	# L1/R1 changent d'onglet.
	var pb := InputEventJoypadButton.new()
	pb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	pb.pressed = true
	Input.parse_input_event(pb)
	await get_tree().process_frame
	await get_tree().process_frame
	var tab_after: int = om._tabs.current_tab
	await _tap(KEY_ESCAPE)
	var back_to_sys: bool = not OptionsMenu.is_open() and hud._sys_panel.visible
	await _tap(KEY_ESCAPE)
	var sys_closed: bool = not hud._sys_panel.visible
	await get_tree().create_timer(0.35).timeout
	var free_again: bool = not me.menu_open
	Settings.reset_bindings()
	print("[ui] menu système : ouvert=%s focus=%s ; options : onglets=%d cases=%d focus=%s touche K=%s (%s) échelle=%s onglet R1=%d ; retour menu=%s fermé=%s libre=%s" % [
		sys_open, sys_focus, tabs, binds, opt_focus, bound, btn_txt, scale_ok, tab_after, back_to_sys, sys_closed, free_again])
	if not (sys_open and sys_focus and tabs == 4 and binds > 60 and opt_focus and bound and btn_txt == "K" and scale_ok
			and tab_after == 1 and back_to_sys and sys_closed and free_again):
		errors.append("menu système / options")
	# Liste des attaquants, sélection automatique, fermeture du menu en fin de combat.
	me.health.invulnerable = true
	game.spawn_enemy_at("wolf", me.global_position + Vector3(3, 0.5, 0))
	game.spawn_enemy_at("rabbit", me.global_position + Vector3(-3, 0.5, 0))
	await get_tree().create_timer(0.3).timeout
	var foes: Array = []
	for e in game.get_node("Enemies").get_children():
		if e.global_position.distance_to(me.global_position) < 6.0:
			e.taunt(me, 30.0)
			foes.append(e)
	await get_tree().create_timer(0.6).timeout
	var att: Array = hud.attackers()
	var auto_sel: bool = me.combat.target() in foes
	var panel_ok: bool = hud._aggro_panel.visible and hud._aggro_box.get_child_count() >= 3
	hud.open_menu()
	var first: Enemy = me.combat.target()
	first.health.invulnerable = false
	first.health.take_damage(99999)
	await get_tree().create_timer(0.3).timeout
	var switched: bool = me.combat.target() != first and me.combat.target() in foes and hud._menu_open
	var second: Enemy = me.combat.target()
	if second:
		second.health.invulnerable = false
		second.health.take_damage(99999)
	await get_tree().create_timer(0.3).timeout
	var closed_end: bool = not hud._menu_open
	print("[ui] attaquants=%d panneau=%s sélection auto=%s ; 1er mort → bascule=%s ; dernier mort → menu fermé=%s" % [
		att.size(), panel_ok, auto_sel, switched, closed_end])
	if not (att.size() == 2 and panel_ok and auto_sel and switched and closed_end):
		errors.append("attaquants / fin de combat")
	# Repos (/heal) : régénération par paliers, interrompu par un coup.
	me.health.invulnerable = false
	me.health.take_damage(int(me.health.max_hp * 0.6))
	var hp0: int = me.health.hp
	var started: bool = me.start_rest()
	await get_tree().create_timer(7.0).timeout
	var hp1: int = me.health.hp
	var still: bool = me.resting
	me.health.take_damage(1)
	var interrupted: bool = not me.resting
	var help_saved := true
	hud._help_panel.visible = true
	hud._toggle_help()
	help_saved = not Settings.show_help
	hud._toggle_help()
	print("[ui] repos : démarré=%s PV %d→%d (max %d) toujours assis=%s interrompu par un coup=%s ; aide mémorisée=%s" % [
		started, hp0, hp1, me.health.max_hp, still, interrupted, help_saved])
	if not (started and hp1 > hp0 and still and interrupted and help_saved):
		errors.append("repos / aide")
	var ok := errors.is_empty()
	print("=== NET UI %s ===%s" % ["OK" if ok else "ÉCHEC", "" if ok else " (" + ", ".join(errors) + ")"])
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- personnages, sauvegarde, coffre partagé

func _start_with_current() -> Node:
	Net.host(false)
	Net.set_my_character(true)
	Net.level_path = str(Characters.current.get("zone", "res://scenes/outdoor_village.tscn"))
	await get_tree().process_frame
	Net.start_game()
	return await _wait_game()


func _run_chars() -> void:
	var errors: Array[String] = []
	Settings.path = "user://settings_test.cfg"
	Characters.use_test_storage()
	var a := Characters.create("Aldo", "fighter", "dwarf")
	var dup := Characters.create("aldo", "wizard", "elf")
	var dup_err := Characters.error
	var b := Characters.create("Béa", "wizard", "elf")
	var listed := Characters.list().size()
	print("[persos] créés : %s / %s ; doublon refusé=%s (%s) ; liste=%d" % [a.get("id"), b.get("id"), dup.is_empty(), dup_err, listed])
	if a.is_empty() or b.is_empty() or not dup.is_empty() or listed != 2:
		errors.append("création")
	# Menu principal : la liste affiche les personnages.
	var mm: Node = load("res://scenes/main_menu.tscn").instantiate()
	get_tree().root.add_child(mm)
	await get_tree().process_frame
	var menu_items: int = mm._char_list.item_count
	mm.queue_free()
	await get_tree().process_frame
	if menu_items != 2:
		errors.append("menu personnages")
	# 1re session avec Aldo : on gagne de l'or, on bouge, on sauvegarde.
	Characters.select(a.id)
	Net.player_name = "Aldo"
	var game := await _start_with_current()
	if game == null:
		return
	var me := await _await_player(game, 0)
	if me == null:
		_fail("Aldo non spawné")
		return
	var spawned_ok: bool = me.class_id == "fighter" and me.race_id == "dwarf" and me.player_name == "Aldo"
	me.health.invulnerable = true
	me.inventory.gold = 123
	me.stats.add_xp(300)
	me.request_action("quest_accept:q_rabbits")
	# Jobs façon FFXI : prendre un bâton → Magicien niv. 1 ; reprendre l'épée → Guerrier niv. 2.
	var fighter_lvl: int = me.stats.level
	me.inventory.add({"id": "quarterstaff", "qty": 1, "rarity": "common"})
	me.request_action("equip:%d" % me.inventory.find_index("quarterstaff"))
	await get_tree().process_frame
	var as_wiz: bool = me.class_id == "wizard" and me.stats.level == 1 and me.spell_book.is_caster() and me.health.max_hp > 0
	var hind: String = me.combat.armor_hindrance()
	var cast_blocked: bool = hind != "" and not me.combat.start_cast("fire_bolt")
	me.request_action("equip:%d" % me.inventory.find_index("longsword"))
	await get_tree().process_frame
	var back: bool = me.class_id == "fighter" and me.stats.level == fighter_lvl and not me.spell_book.is_caster()
	# En combat : changement refusé.
	game.spawn_enemy_at("wolf", me.global_position + Vector3(4, 0.5, 0))
	await get_tree().create_timer(0.3).timeout
	for e in game.get_node("Enemies").get_children():
		if e.global_position.distance_to(me.global_position) < 8.0:
			e.taunt(me, 30.0)
	await get_tree().create_timer(0.3).timeout
	me.request_action("equip:%d" % me.inventory.find_index("quarterstaff"))
	await get_tree().process_frame
	var refused: bool = me.class_id == "fighter"
	for e in game.get_node("Enemies").get_children():
		if e.global_position.distance_to(me.global_position) < 10.0:
			e.health.invulnerable = false
			e.health.take_damage(99999)
	await get_tree().create_timer(0.3).timeout
	print("[persos] jobs : bâton → Magicien 1=%s (gêne : %s, sort bloqué=%s) ; épée → Guerrier %d=%s ; refus en combat=%s ; jobs=%s" % [
		as_wiz, hind, cast_blocked, fighter_lvl, back, refused, me.jobs])
	if not (as_wiz and cast_blocked and back and refused and me.jobs.has("wizard")):
		errors.append("jobs")
	# Coffre partagé : dépôt d'un objet et d'or, retrait, refus à distance.
	var sc: Node3D = get_tree().get_first_node_in_group("shared_chests")
	me.global_position = sc.global_position + Vector3(0, 0.1, 1.6)
	await get_tree().physics_frame
	var bag0: int = me.inventory.items.size()
	var first_id: String = me.inventory.items[0].id if bag0 > 0 else ""
	me.request_action("chest_deposit:0")
	me.request_action("chest_deposit_gold:20")
	await get_tree().process_frame
	var chest_after_dep: int = Characters.chest().items.size()
	var chest_gold: int = int(Characters.chest().gold)
	var taken := Characters.chest_take(0)
	me.request_action("chest_withdraw:" + JSON.stringify(taken))
	await get_tree().process_frame
	var withdrawn: bool = me.inventory.count(first_id) >= 1 and Characters.chest().items.is_empty()
	me.request_action("chest_deposit:0")
	await get_tree().process_frame
	# Ouverture par interaction (F) → fenêtre du coffre.
	var hud: Node = game.get_node("HUD")
	me.request_action("interact")
	await get_tree().process_frame
	var chest_ui: bool = hud._dialog_panel.visible and hud._dialog_chest
	hud.close_npc_dialog()
	var far_pos := sc.global_position + Vector3(20, 0.1, 0)
	me.global_position = far_pos
	await get_tree().physics_frame
	var t2 := Characters.chest_take(0)
	me.request_action("chest_withdraw:" + JSON.stringify(t2))
	await get_tree().process_frame
	var refused_far: bool = Characters.chest().items.size() == 1
	print("[persos] coffre : dépôt=%d objet(s) %d po ; retrait=%s ; fenêtre=%s ; refus à distance (rendu)=%s" % [chest_after_dep, chest_gold, withdrawn, chest_ui, refused_far])
	if not (chest_after_dep == 1 and chest_gold == 20 and withdrawn and chest_ui and refused_far):
		errors.append("coffre partagé")
	# Progression : celle de l'hôte décide.
	var gate_before: bool = game.world_has_progress("quest:test")
	me.add_progress("quest:test")
	var gate_after: bool = game.world_has_progress("quest:test")
	var zone_flag: bool = me.has_progress("zone:res://scenes/outdoor_village.tscn")
	# Sauvegarde puis retour au menu (sauvegarde automatique au départ).
	var saved_pos: Vector3 = me.global_position
	var gold_before: int = me.inventory.gold
	var lvl_before: int = me.stats.level
	await Net.leave_to_menu()
	await get_tree().process_frame
	var file := Characters.find(a.id)
	var st: Dictionary = file.get("state", {})
	var file_ok: bool = int(st.get("gold", -1)) == gold_before and int(file.get("level", 0)) == lvl_before \
		and file.get("zone", "") == "res://scenes/outdoor_village.tscn" and st.get("pos") is Array \
		and "quest:test" in file.get("progress", [])
	print("[persos] sauvegarde : or=%s niv=%s zone=%s pos=%s progression=%s ; portes : avant=%s après=%s zone vue=%s" % [
		st.get("gold"), file.get("level"), file.get("zone"), st.get("pos"), file.get("progress"), gate_before, gate_after, zone_flag])
	if not (spawned_ok and file_ok and not gate_before and gate_after and zone_flag):
		errors.append("sauvegarde / progression")
	# 2e session : reprise là où on était, avec le même or, niveau et quête.
	await get_tree().create_timer(0.3).timeout
	Characters.select(a.id)
	game = await _start_with_current()
	if game == null:
		return
	me = await _await_player(game, 0)
	await get_tree().physics_frame
	var resumed: bool = me.inventory.gold == gold_before and me.stats.level == lvl_before and me.jobs.has("wizard") \
		and me.quest_log.is_active("q_rabbits") and me.global_position.distance_to(saved_pos) < 2.0
	print("[persos] reprise : or=%d niv=%d quête=%s position=%s (attendu %s)" % [me.inventory.gold, me.stats.level,
		me.quest_log.is_active("q_rabbits"), me.global_position, saved_pos])
	if not resumed:
		errors.append("reprise")
	# Le magicien est un autre personnage, vierge, avec le même coffre.
	await Net.leave_to_menu()
	await get_tree().create_timer(0.3).timeout
	Characters.select(b.id)
	game = await _start_with_current()
	me = await _await_player(game, 0)
	var other_ok: bool = me.class_id == "wizard" and me.inventory.gold != gold_before and Characters.chest().items.size() == 1
	print("[persos] 2e personnage : classe=%s or=%d coffre partagé=%d objet(s)" % [me.class_id, me.inventory.gold, Characters.chest().items.size()])
	if not other_ok:
		errors.append("2e personnage")
	var ok := errors.is_empty()
	print("=== NET CHARS %s ===%s" % ["OK" if ok else "ÉCHEC", "" if ok else " (" + ", ".join(errors) + ")"])
	Net.stop()
	get_tree().quit(0 if ok else 1)


# ---------------------------------------------------------------- banc d'équilibrage (bots)
# Un bot joue de vrais combats (vraies règles, vrai serveur) : guerrier (engage, WS à 100 TP, Second souffle
# sous 40 %) et magicien (Armure du mage avant le combat, Projectile magique tant qu'il reste des emplacements,
# puis Trait de feu ; reste immobile). Résultat : durée, % de victoires, PV perdus.

var _game_time := 0.0


func _bal_wait(seconds: float) -> void:
	var end := _game_time + seconds
	while _game_time < end:
		await get_tree().physics_frame
		_game_time += Engine.time_scale / float(Engine.physics_ticks_per_second)


func _bal_reset(me: PlayerCharacter, game: Node) -> void:
	for e in game.get_node("Enemies").get_children():
		e.queue_free()
	if me.health.is_downed:
		me.health.revive(1.0)
	me.combat.disengage()
	me.combat.set_target(NodePath())
	me.health.heal(me.health.max_hp)
	me.spell_book.restore_all()
	me.combat.cooldowns_left = {}
	me.combat.tp = 0
	me.conditions = {}
	me._input_dir = Vector2.ZERO
	me.global_position = Vector3(0, 0.2, 0)
	me.velocity = Vector3.ZERO


func _bal_fight(me: PlayerCharacter, game: Node, monster_id: String, job: String) -> Dictionary:
	_bal_reset(me, game)
	await _bal_wait(0.3)
	game.spawn_enemy_at(monster_id, Vector3(0, 0.5, -10))
	await _bal_wait(0.3)
	var foe: Enemy = null
	for e in game.get_node("Enemies").get_children():
		if e is Enemy and e.health.is_alive():
			foe = e
	if foe == null:
		return {"ok": false}
	foe.taunt(me, 999.0)
	me.combat.set_target(foe.get_path())
	me.combat.engage()
	var t0 := _game_time
	var potions := 0
	var casts := 0
	var res0 := hits_seen
	var my_hits0 := hits_on_enemies
	while _game_time - t0 < 240.0:
		await get_tree().physics_frame
		_game_time += Engine.time_scale / float(Engine.physics_ticks_per_second)
		if not foe.health.is_alive() or not me.health.is_alive():
			break
		var to := foe.global_position - me.global_position
		to.y = 0.0
		me._cam_yaw = atan2(-to.x, -to.z)
		if job == "fighter":
			me._input_dir = Vector2(0, -1) if to.length() > 1.5 else Vector2.ZERO
			if me.combat.tp >= PlayerCombat.TP_READY:
				me.combat.use_weapon_skill()
			if me.health.hp < me.health.max_hp * 0.4 and me.combat.cooldown_left("second_wind") <= 0.0:
				me.combat.use_ability("second_wind")
		else:
			me._input_dir = Vector2.ZERO
			if not me.combat.is_casting() and not me.is_busy():
				if me.spell_book.can_cast("magic_missile"):
					casts += 1 if me.combat.start_cast("magic_missile") else 0
				elif me.spell_book.can_cast("fire_bolt"):
					casts += 1 if me.combat.start_cast("fire_bolt") else 0
	me._input_dir = Vector2.ZERO
	var win: bool = not foe.health.is_alive()
	var downed: bool = not me.health.is_alive()
	if "--verbose" in OS.get_cmdline_user_args():
		print("    [%s] %s : %.0f s, sorts lancés %d, résolutions %d, touches sur monstre %d, PV monstre %d/%d, dist %.1f" % [job, monster_id,
			_game_time - t0, casts, hits_seen - res0, hits_on_enemies - my_hits0, foe.health.hp, foe.health.max_hp, me.global_position.distance_to(foe.global_position)])
	return {"ok": true, "win": win, "downed": downed, "time": _game_time - t0, "lost": 100.0 if downed else 100.0 - 100.0 * me.health.hp / maxf(1, me.health.max_hp)}


func _run_balance() -> void:
	var args := OS.get_cmdline_user_args()
	var n := int(args[args.find("--n") + 1]) if "--n" in args else 4
	Engine.time_scale = 6.0
	Net.player_name = "Bot"
	var lines: Array[String] = []
	lines.append("BANC D'ÉQUILIBRAGE — %s — %d combats par duel, niveau 1, sans potion, reposé" % [Time.get_datetime_string_from_system(false, true), n])
	lines.append("balance.json : %s" % JSON.stringify(GameData.balance))
	var old_game: Node = null
	var jobs_list: Array = ["fighter", "wizard"]
	if "--job" in args:
		jobs_list = [args[args.find("--job") + 1]]
	for job in jobs_list:
		t0 = Time.get_ticks_msec() / 1000.0
		Net.host(false)
		Net.level_path = "res://scenes/test_arena.tscn"
		Net.set_my_choice(job, "human", true)
		await get_tree().process_frame
		Net.start_game()
		var game: Node = null
		while game == null or game == old_game or not is_instance_valid(game):
			await get_tree().process_frame
			var cur := get_tree().current_scene
			if cur and cur.name == "Game" and cur != old_game:
				game = cur
		old_game = game
		var me: PlayerCharacter = await _await_player(game, 0)
		me.is_local = false
		if job == "wizard":
			# Armure du mage avant le combat (puis emplacements rechargés : « reposé »).
			_bal_reset(me, game)
			me.combat.start_cast("mage_armor")
			await _bal_wait(2.5)
		lines.append("")
		lines.append("%s niv.1 — PV %d, CA %d, arme %s" % [GameData.player_class(job).get("name", job), me.health.max_hp, me.stats.armor_class(), me.weapon.get("name", "")])
		for mid in ["rabbit", "giant_bee", "boar", "wolf", "goblin"]:
			var wins := 0
			var downs := 0
			var tsum := 0.0
			var lost := 0.0
			var done := 0
			for i in n:
				var r: Dictionary = await _bal_fight(me, game, mid, job)
				if not r.get("ok", false):
					continue
				done += 1
				wins += 1 if r.win else 0
				downs += 1 if r.downed else 0
				tsum += r.time
				lost += r.lost
			var mhp := int(GameData.monster(mid).get("hp_fixed", 1) * GameData.bal("monster_hp_mult"))
			lines.append("  vs %-10s (PV %3d) : victoires %d/%d · à terre %d · %3.0f s · PV perdus %3.0f %%" % [mid, mhp, wins, done, downs, tsum / maxf(1, done), lost / maxf(1, done)])
			print(lines[-1])
		Net.stop()
		await get_tree().create_timer(0.3 * Engine.time_scale).timeout
	Engine.time_scale = 1.0
	var text := "\n".join(lines) + "\n"
	print(text)
	var dir := ProjectSettings.globalize_path("res://logs/")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir + "balance_dernier.txt", FileAccess.WRITE)
	if f:
		f.store_string(text)
	print("=== NET BALANCE OK ===")
	get_tree().quit(0)

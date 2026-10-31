extends Node
## Autoload « SessionLog » : journal de session pour l'équilibrage et le débogage.
## Chaque partie écrit, pour le joueur LOCAL (donc sur chaque PC, solo ou réseau) :
##   logs/session_AAAAMMJJ_HHMMSS.jsonl   un événement JSON par ligne (combats, morts, niveaux, zones, erreurs…)
##   logs/session_AAAAMMJJ_HHMMSS.txt     le résumé lisible, réécrit au fil de la partie
##   logs/derniere_session.txt            copie du dernier résumé
## Dans l'éditeur (cas de Grég et de jouer.bat), logs/ est dans le dossier du projet (ignoré par git et par Godot) ;
## dans un jeu exporté, dans user://logs/. Désactivable : Options → (variable Settings.session_log).

const FIGHT_IDLE_END := 4.0     # s sans coup ni attaquant → le combat est terminé
const SNAPSHOT_EVERY := 60.0

var enabled := true
var dir := ""
var _file: FileAccess
var _base := ""
var _t0 := 0
var _player: PlayerCharacter
var _zone := ""
var _fight: Dictionary = {}
var _fight_idle := 0.0
var _snapshot_left := SNAPSHOT_EVERY
var _fights: Array = []          # résumés des combats terminés
var _counters := {"downs": 0, "deaths": 0, "levels": 0, "job_changes": 0, "rests": 0, "rest_hp": 0, "errors": 0, "kills": 0}
var _errors: Array[String] = []
var _rest_start_hp := -1
var _logger: Object


func _ready() -> void:
	if "--no-session-log" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless" and not "--session-log" in OS.get_cmdline_user_args():
		enabled = false
		return
	dir = ProjectSettings.globalize_path("res://logs/") if OS.has_feature("editor") else ProjectSettings.globalize_path("user://logs/")
	EventBus.local_player_ready.connect(_on_player_ready)
	EventBus.hit_resolved.connect(_on_hit)
	EventBus.creature_died.connect(_on_died)
	EventBus.zone_entered.connect(_on_zone)
	EventBus.quest_updated.connect(func(t: String): event("message", {"text": t}))
	_install_error_logger()


# ------------------------------------------------------------------ fichiers

func _ensure_file() -> bool:
	if not enabled:
		return false
	if _file:
		return true
	DirAccess.make_dir_recursive_absolute(dir)
	# Godot ne doit pas importer ce dossier ; git l'ignore (voir .gitignore).
	if not FileAccess.file_exists(dir + ".gdignore"):
		var g := FileAccess.open(dir + ".gdignore", FileAccess.WRITE)
		if g:
			g.store_string("")
	_base = dir + "session_" + Time.get_datetime_string_from_system(false, true).replace("-", "").replace(":", "").replace(" ", "_")
	_file = FileAccess.open(_base + ".jsonl", FileAccess.WRITE)
	_t0 = Time.get_ticks_msec()
	return _file != null


func event(kind: String, data: Dictionary = {}) -> void:
	if not _ensure_file():
		return
	var d := data.duplicate()
	d["t"] = snappedf((Time.get_ticks_msec() - _t0) / 1000.0, 0.1)
	d["ev"] = kind
	_file.store_line(JSON.stringify(d))
	_file.flush()


func _now() -> float:
	return (Time.get_ticks_msec() - _t0) / 1000.0


# ------------------------------------------------------------------ joueur local

func _on_player_ready(p: Node3D) -> void:
	if not enabled or not (p is PlayerCharacter):
		return
	_player = p
	var first := _file == null
	_ensure_file()
	if first:
		event("session_start", {
			"version": ProjectSettings.get_setting("application/config/version", "dev"),
			"mode": "solo" if Net.is_solo else ("hôte" if Net.is_host else "client"),
			"players": Net.players.size(),
			"os": OS.get_name(), "gpu": RenderingServer.get_video_adapter_name(),
			"balance": GameData.balance,
		})
	event("player", _player_info())
	_player.stats.level_changed.connect(func(lvl: int):
		event("level", {"level": lvl, "job": _player.class_id})
		_counters.levels += 1)
	_player.job_changed.connect(func(job: String):
		event("job_change", {"job": job, "level": _player.stats.level})
		_counters.job_changes += 1)
	_player.health.downed.connect(func():
		_counters.downs += 1
		event("downed", {"zone": _zone, "fight": _fight.get("monsters", {})})
		_end_fight("à terre"))
	_player.health.died.connect(func():
		_counters.deaths += 1
		event("died", {"zone": _zone})
		_end_fight("mort"))


func _player_info() -> Dictionary:
	if not is_instance_valid(_player):
		return {}
	return {"name": _player.player_name, "job": _player.class_id, "start_class": _player.start_class,
		"race": _player.race_id, "level": _player.stats.level, "jobs": _player._jobs_with_current(),
		"hp": _player.health.hp, "max_hp": _player.health.max_hp, "ac": _player.stats.armor_class(),
		"weapon": _player.weapon.get("name", ""), "gold": _player.inventory.gold,
		"armor": Inventory.display_name(_player.inventory.equipped["armor"]) if _player.inventory.equipped.has("armor") else ""}


func _on_zone(zone_name: String) -> void:
	_zone = zone_name
	event("zone", {"zone": zone_name})


# ------------------------------------------------------------------ combats

func _is_me(n: Variant) -> bool:
	return is_instance_valid(_player) and n == _player


func _on_hit(target: Node3D, r: Dictionary) -> void:
	if not enabled or not is_instance_valid(_player):
		return
	var attacker: Variant = r.get("attacker")
	var mine := _is_me(attacker)
	var on_me := _is_me(target)
	if r.has("heal"):
		if on_me:
			_fight_add("heals", int(r.get("heal", 0)))
			if str(r.get("attack_name", "")).to_lower().contains("potion"):
				_fight_add("potions", 1)
		return
	if not (mine or on_me):
		return
	var other: Variant = target if mine else attacker
	if not (other is Enemy):
		return
	_start_fight_if_needed()
	var mid: String = (other as Enemy).monster_id
	var mons: Dictionary = _fight.monsters
	if not mons.has(mid):
		mons[mid] = 1
	var aname := str(r.get("attack_name", ""))
	if mine:
		_fight_add("my_attacks", 1)
		if r.get("hit", false):
			_fight_add("my_hits", 1)
			_fight_add("dmg_dealt", int(r.get("damage", 0)))
		if r.get("crit", false):
			_fight_add("crits", 1)
		if aname != "":
			var by: Dictionary = _fight.by_attack
			by[aname] = int(by.get(aname, 0)) + int(r.get("damage", 0))
	else:
		_fight_add("monster_attacks", 1)
		if r.get("hit", false):
			_fight_add("monster_hits", 1)
			_fight_add("dmg_taken", int(r.get("damage", 0)))
			if aname != "":
				var sk: Dictionary = _fight.monster_skills
				sk[aname] = int(sk.get(aname, 0)) + 1
	_fight_idle = 0.0
	_fight.hp_min_pct = minf(float(_fight.hp_min_pct), _hp_pct())


func _on_died(c: Node3D) -> void:
	if not _fight.is_empty() and c is Enemy:
		_fight_add("kills", 1)
		_counters.kills += 1


func _hp_pct() -> float:
	return 100.0 * _player.health.hp / maxf(1.0, _player.health.max_hp)


func _start_fight_if_needed() -> void:
	if not _fight.is_empty():
		return
	_fight = {"t": snappedf(_now(), 0.1), "zone": _zone, "job": _player.class_id, "level": _player.stats.level,
		"monsters": {}, "my_attacks": 0, "my_hits": 0, "crits": 0, "dmg_dealt": 0, "monster_attacks": 0,
		"monster_hits": 0, "dmg_taken": 0, "heals": 0, "potions": 0, "kills": 0, "by_attack": {}, "monster_skills": {},
		"hp_start_pct": snappedf(_hp_pct(), 1), "hp_min_pct": _hp_pct(), "slots_start": _player.spell_book.slots.duplicate(),
		"max_hp": _player.health.max_hp, "ac": _player.stats.armor_class()}
	_fight_idle = 0.0


func _fight_add(key: String, n: int) -> void:
	if _fight.is_empty():
		return
	_fight[key] = int(_fight.get(key, 0)) + n


func _attackers_count() -> int:
	var n := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if e is Enemy and e.target_peer == _player.peer_id and e.health.is_alive():
			n += 1
	return n


func _end_fight(outcome: String) -> void:
	if _fight.is_empty():
		return
	var f := _fight
	_fight = {}
	f["duration"] = snappedf(_now() - float(f.t), 0.1)
	f["outcome"] = outcome
	f["hp_end_pct"] = snappedf(_hp_pct(), 1) if is_instance_valid(_player) else 0
	f["hp_min_pct"] = snappedf(float(f.hp_min_pct), 1)
	f["slots_end"] = _player.spell_book.slots.duplicate() if is_instance_valid(_player) else {}
	event("fight", f)
	_fights.append(f)
	_write_summary()


func _process(delta: float) -> void:
	if not enabled or not is_instance_valid(_player):
		return
	if not _fight.is_empty():
		_fight.hp_min_pct = minf(float(_fight.hp_min_pct), _hp_pct())
		if _attackers_count() == 0 and not _player.combat.target_alive():
			_fight_idle += delta
			if _fight_idle >= FIGHT_IDLE_END:
				_end_fight("victoire" if int(_fight.kills) > 0 else "fin (fuite / laisse)")
		else:
			_fight_idle = 0.0
	# Repos
	if _player.resting and _rest_start_hp < 0:
		_rest_start_hp = _player.health.hp
	elif not _player.resting and _rest_start_hp >= 0:
		_counters.rests += 1
		_counters.rest_hp += maxi(0, _player.health.hp - _rest_start_hp)
		_rest_start_hp = -1
	_snapshot_left -= delta
	if _snapshot_left <= 0.0:
		_snapshot_left = SNAPSHOT_EVERY
		var snap := _player_info()
		snap["zone"] = _zone
		snap["fps"] = Engine.get_frames_per_second()
		event("snapshot", snap)
		_write_summary()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		finish()


## Fin de session (retour au menu, fermeture) : on clôt le combat en cours et on écrit le résumé.
func finish() -> void:
	if not enabled or _file == null:
		return
	_end_fight("interrompu")
	event("session_end", {"player": _player_info(), "counters": _counters})
	_write_summary()
	# La prochaine partie (après un retour au menu) ouvre un nouveau fichier.
	_file = null
	_base = ""
	_fights.clear()
	_errors.clear()
	for k in _counters:
		_counters[k] = 0
	_player = null


## Note de test saisie en jeu (menu système) : dans le journal ET à la fin de « Retour de test.txt » (projet),
## avec le contexte (heure, zone, job, niveau, PV, position) pour que Claude sache où regarder.
func add_note(text: String) -> String:
	text = text.strip_edges()
	if text.is_empty():
		return ""
	var ctx := ""
	if is_instance_valid(_player):
		var p := _player.global_position
		ctx = "%s · %s niv.%d · PV %d/%d · pos (%.0f, %.0f, %.0f)" % [_zone, _player.class_id, _player.stats.level,
			_player.health.hp, _player.health.max_hp, p.x, p.y, p.z]
	var line := "[%s] (%s) %s" % [Time.get_time_string_from_system().substr(0, 5), ctx, text]
	event("note", {"text": text, "context": ctx})
	var path := ProjectSettings.globalize_path("res://Retour de test.txt") if OS.has_feature("editor") else dir + "retours.txt"
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_string("\n\t\t" + line + "\n")
	return line


# ------------------------------------------------------------------ résumé lisible

func _write_summary() -> void:
	if _base == "":
		return
	var L: Array[String] = []
	L.append("RÉSUMÉ DE SESSION — %s" % Time.get_datetime_string_from_system(false, true))
	L.append("Durée : %d min · mode : %s" % [int(_now() / 60.0), "solo" if Net.is_solo else ("hôte" if Net.is_host else "client")])
	if is_instance_valid(_player):
		var p := _player_info()
		L.append("Personnage : %s — %s niv. %d (jobs : %s) · PV %d/%d · CA %d · arme %s" % [p.name, p.job, p.level,
			JSON.stringify(p.jobs), p.hp, p.max_hp, p.ac, p.weapon])
	L.append("Compteurs : %s" % JSON.stringify(_counters))
	L.append("")
	# Par monstre et par job : moyenne durée, PV perdus, taux de toucher.
	var agg := {}
	for f in _fights:
		var mons: Array = f.monsters.keys()
		mons.sort()
		var key := "%s niv.%d vs %s" % [f.job, int(f.level), "+".join(mons)]
		if not agg.has(key):
			agg[key] = {"n": 0, "dur": 0.0, "lost": 0.0, "minhp": 0.0, "down": 0, "my_hit": 0, "my_att": 0, "m_hit": 0, "m_att": 0, "pot": 0}
		var a: Dictionary = agg[key]
		a.n += 1
		a.dur += float(f.duration)
		a.lost += float(f.hp_start_pct) - float(f.hp_end_pct)
		a.minhp += float(f.hp_min_pct)
		a.down += 1 if f.outcome in ["à terre", "mort"] else 0
		a.my_hit += int(f.my_hits)
		a.my_att += int(f.my_attacks)
		a.m_hit += int(f.monster_hits)
		a.m_att += int(f.monster_attacks)
		a.pot += int(f.potions)
	L.append("COMBATS (%d) — moyenne par type de combat" % _fights.size())
	for key in agg:
		var a: Dictionary = agg[key]
		L.append("  %s : %d combat(s) · %.0f s · PV perdus %.0f %% · PV mini %.0f %% · à terre %d · toucher %d %% · subi %d %% · potions %d" % [
			key, a.n, a.dur / a.n, a.lost / a.n, a.minhp / a.n, a.down,
			roundi(100.0 * a.my_hit / maxf(1, a.my_att)), roundi(100.0 * a.m_hit / maxf(1, a.m_att)), a.pot])
	L.append("")
	L.append("DERNIERS COMBATS")
	for f in _fights.slice(maxi(0, _fights.size() - 15)):
		L.append("  [%s] %s niv.%d vs %s : %s en %.0f s · PV %d→%d %% (mini %d) · infligé %d · subi %d · coups %d/%d · par attaque %s" % [
			f.zone, f.job, int(f.level), JSON.stringify(f.monsters), f.outcome, float(f.duration), int(f.hp_start_pct),
			int(f.hp_end_pct), int(f.hp_min_pct), int(f.dmg_dealt), int(f.dmg_taken), int(f.my_hits), int(f.my_attacks),
			JSON.stringify(f.by_attack)])
	if not _errors.is_empty():
		L.append("")
		L.append("ERREURS (%d, 10 dernières)" % _errors.size())
		for e in _errors.slice(maxi(0, _errors.size() - 10)):
			L.append("  " + e)
	var text := "\n".join(L) + "\n"
	for path in [_base + ".txt", dir + "derniere_session.txt"]:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(text)


# ------------------------------------------------------------------ erreurs de script

func _install_error_logger() -> void:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return
	var script := GDScript.new()
	script.source_code = """extends Logger
var sink: Callable
func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	if sink.is_valid():
		sink.call_deferred("%s:%d %s %s" % [file.get_file(), line, code, rationale])
func _log_message(message: String, error: bool) -> void:
	pass
"""
	if script.reload() != OK:
		return
	_logger = script.new()
	_logger.set("sink", _on_engine_error)
	OS.call("add_logger", _logger)


func _on_engine_error(text: String) -> void:
	if _errors.size() < 500:
		_errors.append(text)
	_counters.errors += 1
	if _errors.size() <= 50:
		event("error", {"text": text})

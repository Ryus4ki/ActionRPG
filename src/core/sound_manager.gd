extends Node
## Autoload « Sound » : effets sonores placeholders (assets/sounds/*.wav) déclenchés par les
## signaux de l'EventBus et par les animations des créatures, plus l'ambiance de donjon en boucle.
## Les sons 3D sont joués à la position de l'événement avec un petit pool de lecteurs.

const SOUND_DIR := "res://assets/sounds/"
const POOL_SIZE := 16
const SFX_DB := -4.0
const AMBIENT_DB := -16.0

var streams: Dictionary = {}
var _pool: Array[AudioStreamPlayer3D] = []
var _pool_index := 0
var _ui: AudioStreamPlayer
var _ambient: AudioStreamPlayer
var _last_play: Dictionary = {}  # nom -> instant, pour éviter les rafales identiques


func _ready() -> void:
	for n in ["swing", "hit", "block", "miss", "cast", "explosion", "arrow", "hurt", "death", "potion",
			"pickup", "coins", "lever", "door", "trap", "flames", "rest", "levelup", "victory", "boss",
			"downed", "ambient"]:
		var path: String = SOUND_DIR + n + ".wav"
		if ResourceLoader.exists(path):
			streams[n] = load(path)
	for i in POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.volume_db = SFX_DB
		p.max_distance = 40.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.unit_size = 6.0
		p.bus = &"SFX"  # bus créé par l'autoload Settings (volume « Effets »)
		add_child(p)
		_pool.append(p)
	_ui = AudioStreamPlayer.new()
	_ui.volume_db = SFX_DB
	_ui.bus = &"SFX"
	add_child(_ui)
	_ambient = AudioStreamPlayer.new()
	_ambient.volume_db = AMBIENT_DB
	_ambient.bus = &"Ambiance"
	_ambient.finished.connect(func(): if _ambient.stream: _ambient.play())
	add_child(_ambient)

	EventBus.hit_resolved.connect(_on_hit_resolved)
	EventBus.creature_died.connect(func(c: Node3D): play_at("death", c.global_position))
	EventBus.creature_downed.connect(func(c: Node3D): play_at("downed", c.global_position))
	EventBus.item_picked.connect(func(entry: Dictionary):
		play_ui("coins" if Inventory.item_data(entry).get("type", "") == "currency" else "pickup"))
	EventBus.system_message.connect(_on_system_message)
	EventBus.boss_phase.connect(func(_b: Node3D, _p: int): play_ui("boss"))
	EventBus.monster_skill.connect(func(m: Node3D, _n: String): play_at("cast", m.global_position, 0.2))
	EventBus.level_cleared.connect(func(): play_ui("victory"))
	EventBus.local_player_ready.connect(func(p: Node3D):
		if p.has_node("StatBlock"):
			p.stats.level_changed.connect(func(_l: int): play_ui("levelup")))


## Son 3D à une position (rafales identiques limitées à une toutes les 40 ms).
func play_at(name: String, pos: Vector3, pitch_jitter := 0.08) -> void:
	if not streams.has(name):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_play.get(name, -1000)) < 40:
		return
	_last_play[name] = now
	var p := _pool[_pool_index]
	_pool_index = (_pool_index + 1) % POOL_SIZE
	p.stop()
	p.stream = streams[name]
	p.global_position = pos
	p.pitch_scale = randf_range(1.0 - pitch_jitter, 1.0 + pitch_jitter)
	p.play()


## Son d'interface (non spatialisé).
func play_ui(name: String) -> void:
	if not streams.has(name):
		return
	_ui.stream = streams[name]
	_ui.pitch_scale = 1.0
	_ui.play()


func start_ambient() -> void:
	if streams.has("ambient") and not _ambient.playing:
		_ambient.stream = streams["ambient"]
		_ambient.play()


func stop_ambient() -> void:
	_ambient.stop()
	_ambient.stream = null


## Appelé par Creature quand une animation démarre (hôte et clients).
func on_anim(creature: Node3D, anim_name: String) -> void:
	match anim_name:
		"attack":
			var ranged: bool = creature is Enemy and creature.melee_attacks.is_empty()
			play_at("arrow" if ranged else "swing", creature.global_position)
		"cast":
			play_at("cast", creature.global_position)


func _on_hit_resolved(target: Node3D, r: Dictionary) -> void:
	if not is_instance_valid(target):
		return
	var pos: Vector3 = target.global_position
	if r.has("heal"):
		play_at("potion", pos)
		return
	var what: String = r.get("attack_name", "")
	if what == "Pointes":
		play_at("trap", pos)
		return
	if what == "Jet de flammes":
		play_at("flames", pos)
		return
	if not r.get("hit", false):
		play_at("block" if r.get("blocked", false) else "miss", pos)
		return
	if r.get("blocked", false):
		play_at("block", pos)
	else:
		play_at("hit", pos)
	if target.is_in_group("players") and r.get("damage", 0) > 0:
		play_at("hurt", pos)


func _on_system_message(text: String) -> void:
	if "actionné" in text:
		play_ui("lever")
	elif "s'ouvre" in text:
		play_ui("door")
	elif "se repose" in text:
		play_ui("rest")

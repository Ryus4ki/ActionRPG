class_name Door
extends StaticBody3D
## Porte verrouillée par des leviers. `open` et `levers_pulled` sont répliqués ; la géométrie
## s'abaisse dans le sol à l'ouverture. Hôte : `check_levers()` est appelé par le donjon.

@export var door_id := "door"
@export var label_text := "Porte"
@export var required_levers: Array[String] = []

var open := false:
	set(v):
		var was := open
		open = v
		if v and not was:
			_animate_open()
		_refresh_label()
var levers_pulled := 0:
	set(v):
		levers_pulled = v
		_refresh_label()

@onready var label: Label3D = $Label
@onready var panel: MeshInstance3D = $Panel
@onready var shape: CollisionShape3D = $Shape


func _ready() -> void:
	add_to_group("doors")
	add_to_group("interactables")
	_refresh_label()
	if open:
		panel.position.y = -2.7
		shape.disabled = true


## Interaction joueur : juste un retour d'information (la porte s'ouvre par les leviers).
func interact(_by: Node) -> bool:
	if open:
		return false
	var game := get_tree().get_first_node_in_group("game")
	if game:
		game.system_message("%s : verrouillée — leviers %d/%d." % [label_text, levers_pulled, required_levers.size()])
	return true


## Hôte : met à jour le compte de leviers et ouvre si tous sont actionnés.
func check_levers(pulled_ids: Array) -> void:
	if not multiplayer.is_server() or open:
		return
	var n := 0
	for id in required_levers:
		if id in pulled_ids:
			n += 1
	levers_pulled = n
	if n >= required_levers.size():
		open = true
		var game := get_tree().get_first_node_in_group("game")
		if game:
			game.system_message("%s s'ouvre dans un grondement de pierre." % label_text)


func _animate_open() -> void:
	if not is_node_ready():
		return
	shape.disabled = true
	var tw := create_tween()
	tw.tween_property(panel, "position:y", -2.7, 1.5).set_trans(Tween.TRANS_SINE)
	label.visible = false


func _refresh_label() -> void:
	if not is_node_ready():
		return
	label.visible = not open
	label.text = "%s\nVerrouillée — leviers %d/%d" % [label_text, levers_pulled, required_levers.size()]

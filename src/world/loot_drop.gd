class_name LootDrop
extends Area3D
## Objet au sol. Ramassé par le premier joueur qui marche dessus (hôte). Modèle 3D + étiquette.

@export var item_id := "gold"
@export var qty := 1
@export var rarity := "common"

var _taken := false
var _t := 0.0

@onready var model_root: Node3D = $ModelRoot
@onready var label: Label3D = $Label


func _ready() -> void:
	var data := GameData.item(item_id)
	var model: String = data.get("model", "sm_coins")
	var scene: PackedScene = load("res://assets/models/%s.glb" % model)
	if scene:
		var inst: Node3D = scene.instantiate()
		model_root.add_child(inst)
		if data.has("tint"):
			for mi in inst.find_children("*", "MeshInstance3D", true, false):
				var mat := StandardMaterial3D.new()
				mat.albedo_color = Color(data["tint"])
				mi.material_override = mat
		# Les armes sont posées à plat ; les autres modèles ont déjà leur base au sol.
		if data.get("type", "") == "weapon":
			inst.rotation_degrees = Vector3(90, 0, 0)
			inst.position.y = 0.05
	var entry := {"id": item_id, "qty": qty, "rarity": rarity}
	label.text = Inventory.display_name(entry) + (" ×%d" % qty if qty > 1 and data.get("type", "") != "currency" else "")
	if data.get("type", "") == "currency":
		label.text = "%d po" % qty
	label.modulate = Inventory.rarity_color(entry)
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)
		# Durée de vie : disparaît après 2 minutes.
		get_tree().create_timer(120.0).timeout.connect(func(): if is_inside_tree(): queue_free())


func _process(delta: float) -> void:
	_t += delta
	model_root.rotation.y += delta * 1.2
	model_root.position.y = 0.05 + 0.04 * sin(_t * 2.0)


func _on_body_entered(body: Node) -> void:
	if _taken or not (body is PlayerCharacter) or not body.health.is_alive():
		return
	var inv: Inventory = body.inventory
	var entry := {"id": item_id, "qty": qty, "rarity": rarity}
	if inv.add(entry):
		_taken = true
		body.on_item_picked(entry)
		queue_free()

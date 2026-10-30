# -*- coding: utf-8 -*-
"""
gen_placeholders.py — génère les placeholders 3D du projet ActionRPG et les exporte en glTF.

Exécution (depuis la racine du projet) :
    blender --background --python tools/gen_placeholders.py
ou, dans Blender : Scripting → ouvrir ce fichier → Exécuter.

Sortie : assets/models/*.glb
    sk_humanoid.glb   humanoïde riggé + animations (idle, walk, run, attack, cast, hit, death, downed, block, block_walk, revive)
    sk_spider.glb     araignée (rig minimal) + idle/walk/attack
    sm_sword / sm_axe / sm_mace / sm_dagger / sm_staff / sm_shield   armes (origine = poignée)
    sm_floor / sm_wall / sm_wall_door / sm_pillar / sm_stairs / sm_torch / sm_chest / sm_altar
    sm_barrel / sm_crate / sm_potion / sm_coins

Conventions :
    - unités : mètres, Z haut dans Blender (glTF convertit en Y haut pour Godot).
    - 1 matériau par couleur plate, nommé mat_<couleur>.
    - os principaux : root, hips, spine, chest, neck, head, upper_arm.L/R, forearm.L/R, hand.L/R,
      thigh.L/R, shin.L/R, foot.L/R.  Socket arme : hand.R, bouclier : forearm.L.
"""
import math
import os
import sys

import bpy
from mathutils import Vector, Euler

# ---------------------------------------------------------------------------
# Chemins
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
if not os.path.exists(os.path.join(PROJECT_DIR, "project.godot")):
    PROJECT_DIR = os.getcwd()
OUT_DIR = os.path.join(PROJECT_DIR, "assets", "models")
os.makedirs(OUT_DIR, exist_ok=True)

FPS = 30

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
_materials = {}


def material(name, rgb):
    """Matériau plat (Principled) mis en cache."""
    key = name
    if key in _materials:
        return _materials[key]
    mat = bpy.data.materials.new("mat_" + name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.8
    mat.diffuse_color = (*rgb, 1.0)
    _materials[key] = mat
    return mat


COLORS = {
    "skin": (0.85, 0.65, 0.50),
    "cloth": (0.30, 0.35, 0.60),
    "leather": (0.40, 0.26, 0.14),
    "metal": (0.62, 0.64, 0.68),
    "dark_metal": (0.30, 0.31, 0.34),
    "wood": (0.45, 0.30, 0.16),
    "stone": (0.45, 0.45, 0.47),
    "stone_dark": (0.30, 0.30, 0.32),
    "gold": (0.90, 0.75, 0.25),
    "red": (0.80, 0.15, 0.15),
    "fire": (1.00, 0.55, 0.10),
    "black": (0.08, 0.08, 0.08),
    "glass": (0.70, 0.85, 0.95),
}


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _materials.clear()
    bpy.context.scene.render.fps = FPS


def box(name, size, loc=(0, 0, 0), color="stone", rot=(0, 0, 0)):
    """Boîte dont `size` = (x, y, z) et `loc` = centre."""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (size[0], size[1], size[2])
    ob.data.materials.append(material(color, COLORS[color]))
    return ob


def cylinder(name, radius, depth, loc=(0, 0, 0), color="wood", rot=(0, 0, 0), verts=12):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.name = name
    ob.data.materials.append(material(color, COLORS[color]))
    return ob


def sphere(name, radius, loc=(0, 0, 0), color="black", segments=12):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=max(6, segments // 2), radius=radius, location=loc)
    ob = bpy.context.active_object
    ob.name = name
    ob.data.materials.append(material(color, COLORS[color]))
    return ob


def cone(name, radius, depth, loc=(0, 0, 0), color="stone", rot=(0, 0, 0), verts=8):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=radius, radius2=0, depth=depth, location=loc, rotation=rot)
    ob = bpy.context.active_object
    ob.name = name
    ob.data.materials.append(material(color, COLORS[color]))
    return ob


def apply_transforms(objects):
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objects:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)


def join(objects, name):
    """Fusionne des objets en un seul mesh (scale/rotation appliqués)."""
    apply_transforms(objects)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objects:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    ob = bpy.context.active_object
    ob.name = name
    ob.data.name = name
    return ob


def export_glb(objects, filename):
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objects:
        ob.select_set(True)
        for child in ob.children_recursive:
            child.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    path = os.path.join(OUT_DIR, filename + ".glb")
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_nla_strips=True,
        export_skins=True,
        export_yup=True,
        export_materials="EXPORT",
    )
    print("  → " + os.path.relpath(path, PROJECT_DIR))


# ---------------------------------------------------------------------------
# Humanoïde riggé
# ---------------------------------------------------------------------------
# (nom, tête, queue, parent)  — Z haut, personnage face à -Y (convention Blender → glTF -Z… Godot regarde vers -Z)
HUMANOID_BONES = [
    ("root", (0, 0, 0.0), (0, 0, 0.2), None),
    ("hips", (0, 0, 0.95), (0, 0, 1.05), "root"),
    ("spine", (0, 0, 1.05), (0, 0, 1.25), "hips"),
    ("chest", (0, 0, 1.25), (0, 0, 1.50), "spine"),
    ("neck", (0, 0, 1.50), (0, 0, 1.58), "chest"),
    ("head", (0, 0, 1.58), (0, 0, 1.80), "neck"),
    ("upper_arm.L", (0.22, 0, 1.47), (0.22, 0, 1.18), "chest"),
    ("forearm.L", (0.22, 0, 1.18), (0.22, 0, 0.92), "upper_arm.L"),
    ("hand.L", (0.22, 0, 0.92), (0.22, 0, 0.82), "forearm.L"),
    ("upper_arm.R", (-0.22, 0, 1.47), (-0.22, 0, 1.18), "chest"),
    ("forearm.R", (-0.22, 0, 1.18), (-0.22, 0, 0.92), "upper_arm.R"),
    ("hand.R", (-0.22, 0, 0.92), (-0.22, 0, 0.82), "forearm.R"),
    ("thigh.L", (0.10, 0, 0.95), (0.10, 0, 0.50), "hips"),
    ("shin.L", (0.10, 0, 0.50), (0.10, 0, 0.08), "thigh.L"),
    ("foot.L", (0.10, 0, 0.08), (0.10, -0.15, 0.02), "shin.L"),
    ("thigh.R", (-0.10, 0, 0.95), (-0.10, 0, 0.50), "hips"),
    ("shin.R", (-0.10, 0, 0.50), (-0.10, 0, 0.08), "thigh.R"),
    ("foot.R", (-0.10, 0, 0.08), (-0.10, -0.15, 0.02), "shin.R"),
]

# Parties du corps : (nom, bone, taille, centre, couleur)
HUMANOID_PARTS = [
    ("pelvis", "hips", (0.32, 0.22, 0.14), (0, 0, 1.00), "leather"),
    ("torso", "chest", (0.36, 0.22, 0.42), (0, 0, 1.30), "cloth"),
    ("head_m", "head", (0.20, 0.22, 0.22), (0, 0, 1.70), "skin"),
    ("uarm_l", "upper_arm.L", (0.11, 0.11, 0.28), (0.22, 0, 1.33), "cloth"),
    ("farm_l", "forearm.L", (0.09, 0.09, 0.26), (0.22, 0, 1.05), "skin"),
    ("hand_l", "hand.L", (0.08, 0.06, 0.10), (0.22, 0, 0.87), "skin"),
    ("uarm_r", "upper_arm.R", (0.11, 0.11, 0.28), (-0.22, 0, 1.33), "cloth"),
    ("farm_r", "forearm.R", (0.09, 0.09, 0.26), (-0.22, 0, 1.05), "skin"),
    ("hand_r", "hand.R", (0.08, 0.06, 0.10), (-0.22, 0, 0.87), "skin"),
    ("thigh_l", "thigh.L", (0.14, 0.14, 0.44), (0.10, 0, 0.73), "leather"),
    ("shin_l", "shin.L", (0.12, 0.12, 0.40), (0.10, 0, 0.29), "leather"),
    ("foot_l", "foot.L", (0.11, 0.26, 0.08), (0.10, -0.06, 0.04), "black"),
    ("thigh_r", "thigh.R", (0.14, 0.14, 0.44), (-0.10, 0, 0.73), "leather"),
    ("shin_r", "shin.R", (0.12, 0.12, 0.40), (-0.10, 0, 0.29), "leather"),
    ("foot_r", "foot.R", (0.11, 0.26, 0.08), (-0.10, -0.06, 0.04), "black"),
]


def build_armature(name, bones):
    arm_data = bpy.data.armatures.new(name + "_arm")
    arm = bpy.data.objects.new(name, arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    created = {}
    for bname, head, tail, parent in bones:
        b = arm_data.edit_bones.new(bname)
        b.head = Vector(head)
        b.tail = Vector(tail)
        if parent:
            b.parent = created[parent]
        created[bname] = b
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


def build_skinned_mesh(name, arm, parts):
    objs = []
    for pname, bone, size, center, color in parts:
        ob = box(pname, size, center, color)
        objs.append(ob)
    # Assigner chaque partie à un seul os (poids rigide) AVANT la fusion.
    apply_transforms(objs)
    for ob, (pname, bone, *_rest) in zip(objs, parts):
        vg = ob.vertex_groups.new(name=bone)
        vg.add(list(range(len(ob.data.vertices))), 1.0, "REPLACE")
    mesh = join(objs, name + "_mesh")
    mesh.parent = arm
    mod = mesh.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    return mesh


# --- Animation -------------------------------------------------------------
def deg(x, y, z):
    return Euler((math.radians(x), math.radians(y), math.radians(z)), "XYZ")


def new_action(arm, name, length_frames, loop=True):
    """Crée une action, l'assigne à l'armature et prépare les pose bones."""
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = action
    # Blender ≥ 4.4 : actions à slots — s'assurer qu'un slot est assigné.
    if hasattr(action, "slots") and hasattr(arm.animation_data, "action_slot"):
        if len(action.slots) == 0:
            action.slots.new(id_type="OBJECT", name=arm.name)
        arm.animation_data.action_slot = action.slots[0]
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (0, 0, 0)
        pb.location = (0, 0, 0)
    action["loop"] = loop
    action.frame_range = (1, length_frames)
    action.use_frame_range = True
    return action


def key_pose(arm, frame, pose, root_loc=None):
    """pose = {bone: (rx, ry, rz) en degrés}. Les os absents sont remis à 0."""
    for pb in arm.pose.bones:
        pb.rotation_euler = deg(*pose.get(pb.name, (0, 0, 0)))
        pb.keyframe_insert("rotation_euler", frame=frame)
        if pb.name == "root":
            pb.location = Vector(root_loc) if root_loc else Vector((0, 0, 0))
            pb.keyframe_insert("location", frame=frame)


def push_to_nla(arm, action):
    """Pousse l'action en piste NLA pour que l'exporteur glTF les prenne toutes."""
    track = arm.animation_data.nla_tracks.new()
    track.name = action.name
    strip = track.strips.new(action.name, int(action.frame_range[0]), action)
    strip.name = action.name
    arm.animation_data.action = None


def humanoid_animations(arm):
    # Idle : respiration légère, 2 s
    a = new_action(arm, "idle", 60)
    key_pose(arm, 1, {"chest": (2, 0, 0), "upper_arm.L": (0, 0, -8), "upper_arm.R": (0, 0, 8)})
    key_pose(arm, 30, {"chest": (4, 0, 0), "upper_arm.L": (0, 0, -10), "upper_arm.R": (0, 0, 10)}, root_loc=(0, 0, -0.01))
    key_pose(arm, 60, {"chest": (2, 0, 0), "upper_arm.L": (0, 0, -8), "upper_arm.R": (0, 0, 8)})
    push_to_nla(arm, a)

    # Walk : cycle 1 s
    a = new_action(arm, "walk", 30)
    swing = 30
    for f, s in ((1, 1), (16, -1), (30, 1)):
        key_pose(arm, f, {
            "thigh.L": (s * swing, 0, 0), "thigh.R": (-s * swing, 0, 0),
            "shin.L": (-abs(swing) * 0.5 if s < 0 else 0, 0, 0), "shin.R": (-abs(swing) * 0.5 if s > 0 else 0, 0, 0),
            "upper_arm.L": (-s * swing * 0.8, 0, -8), "upper_arm.R": (s * swing * 0.8, 0, 8),
            "spine": (4, 0, 0),
        })
    push_to_nla(arm, a)

    # Run : cycle 0.66 s, amplitude plus forte, buste penché
    a = new_action(arm, "run", 20)
    swing = 50
    for f, s in ((1, 1), (11, -1), (20, 1)):
        key_pose(arm, f, {
            "thigh.L": (s * swing, 0, 0), "thigh.R": (-s * swing, 0, 0),
            "shin.L": (-70 if s < 0 else -10, 0, 0), "shin.R": (-70 if s > 0 else -10, 0, 0),
            "upper_arm.L": (-s * swing, 0, -8), "upper_arm.R": (s * swing, 0, 8),
            "forearm.L": (-60, 0, 0), "forearm.R": (-60, 0, 0),
            "spine": (12, 0, 0),
        }, root_loc=(0, 0, 0.03 if s > 0 else -0.02))
    push_to_nla(arm, a)

    # Attack : frappe de taille bras droit, 0.8 s (impact au frame 12)
    a = new_action(arm, "attack", 24, loop=False)
    key_pose(arm, 1, {"upper_arm.R": (-120, 0, 30), "forearm.R": (-40, 0, 0), "chest": (0, 0, -25), "upper_arm.L": (0, 0, -20)})
    key_pose(arm, 8, {"upper_arm.R": (-140, 0, 40), "forearm.R": (-50, 0, 0), "chest": (0, 0, -35), "upper_arm.L": (0, 0, -20)})
    key_pose(arm, 12, {"upper_arm.R": (-30, 0, -20), "forearm.R": (0, 0, 0), "chest": (10, 0, 25), "upper_arm.L": (0, 0, -20)})
    key_pose(arm, 24, {"upper_arm.R": (-10, 0, 8), "chest": (2, 0, 0), "upper_arm.L": (0, 0, -8)})
    push_to_nla(arm, a)

    # Cast : les deux mains vers l'avant, 0.8 s (sort libéré au frame 14)
    a = new_action(arm, "cast", 24, loop=False)
    key_pose(arm, 1, {"upper_arm.L": (-60, 0, -40), "upper_arm.R": (-60, 0, 40), "forearm.L": (-80, 0, 0), "forearm.R": (-80, 0, 0)})
    key_pose(arm, 14, {"upper_arm.L": (-95, 0, -5), "upper_arm.R": (-95, 0, 5), "forearm.L": (-10, 0, 0), "forearm.R": (-10, 0, 0), "chest": (8, 0, 0)})
    key_pose(arm, 24, {"upper_arm.L": (0, 0, -8), "upper_arm.R": (0, 0, 8)})
    push_to_nla(arm, a)

    # Hit : recul, 0.4 s
    a = new_action(arm, "hit", 12, loop=False)
    key_pose(arm, 1, {})
    key_pose(arm, 4, {"chest": (-18, 0, 0), "head": (-15, 0, 0), "upper_arm.L": (-30, 0, -20), "upper_arm.R": (-30, 0, 20)}, root_loc=(0, 0.08, 0))
    key_pose(arm, 12, {})
    push_to_nla(arm, a)

    # Death : chute en arrière, 1 s, reste au sol
    a = new_action(arm, "death", 30, loop=False)
    key_pose(arm, 1, {})
    key_pose(arm, 10, {"chest": (-20, 0, 0), "upper_arm.L": (-60, 0, -30), "upper_arm.R": (-60, 0, 30)})
    key_pose(arm, 30, {"hips": (-90, 0, 0), "thigh.L": (20, 0, 5), "thigh.R": (20, 0, -5), "upper_arm.L": (-30, 0, -70), "upper_arm.R": (-30, 0, 70), "head": (10, 0, 0)}, root_loc=(0, 0.3, -0.85))
    push_to_nla(arm, a)

    # Downed : à genoux, boucle (coop : en attente d'être relevé)
    a = new_action(arm, "downed", 60)
    kneel = {"thigh.L": (-90, 0, 0), "thigh.R": (-90, 0, 0), "shin.L": (-100, 0, 0), "shin.R": (-100, 0, 0),
             "spine": (25, 0, 0), "head": (20, 0, 0), "upper_arm.L": (-40, 0, -15), "upper_arm.R": (-40, 0, 15),
             "forearm.L": (-30, 0, 0), "forearm.R": (-30, 0, 0)}
    key_pose(arm, 1, kneel, root_loc=(0, 0, -0.55))
    key_pose(arm, 30, {**kneel, "spine": (30, 0, 0)}, root_loc=(0, 0, -0.57))
    key_pose(arm, 60, kneel, root_loc=(0, 0, -0.55))
    push_to_nla(arm, a)

    # Block : garde bouclier, bras gauche levé devant le torse, boucle (léger balancement)
    a = new_action(arm, "block", 40)
    guard = {"upper_arm.L": (-75, 0, -25), "forearm.L": (-70, 0, 0), "upper_arm.R": (-20, 0, 15), "forearm.R": (-40, 0, 0),
             "chest": (6, 0, 15), "head": (0, 0, -10)}
    key_pose(arm, 1, guard)
    key_pose(arm, 20, {**guard, "chest": (8, 0, 15)}, root_loc=(0, 0, -0.02))
    key_pose(arm, 40, guard)
    push_to_nla(arm, a)

    # Block_walk : marche lente avec la garde (haut du corps = block, jambes = walk)
    a = new_action(arm, "block_walk", 40)
    swing = 22
    for f, sg in ((1, 1), (21, -1), (40, 1)):
        key_pose(arm, f, {**guard,
            "thigh.L": (sg * swing, 0, 0), "thigh.R": (-sg * swing, 0, 0),
            "shin.L": (-abs(swing) * 0.5 if sg < 0 else 0, 0, 0), "shin.R": (-abs(swing) * 0.5 if sg > 0 else 0, 0, 0),
        })
    push_to_nla(arm, a)

    # Revive : du sol à debout, 1 s
    a = new_action(arm, "revive", 30, loop=False)
    key_pose(arm, 1, kneel, root_loc=(0, 0, -0.55))
    key_pose(arm, 30, {"chest": (2, 0, 0)})
    push_to_nla(arm, a)


def build_humanoid():
    print("sk_humanoid")
    clear_scene()
    arm = build_armature("sk_humanoid", HUMANOID_BONES)
    build_skinned_mesh("sk_humanoid", arm, HUMANOID_PARTS)
    humanoid_animations(arm)
    export_glb([arm], "sk_humanoid")


# ---------------------------------------------------------------------------
# Araignée (rig minimal : root + corps, pattes rigides sur le corps)
# ---------------------------------------------------------------------------
def build_spider():
    print("sk_spider")
    clear_scene()
    bones = [
        ("root", (0, 0, 0), (0, 0, 0.2), None),
        ("body", (0, 0, 0.5), (0, -0.4, 0.5), "root"),
        ("head", (0, -0.5, 0.5), (0, -0.8, 0.5), "body"),
    ]
    arm = build_armature("sk_spider", bones)
    parts = []
    abdomen = sphere("abdomen", 0.45, (0, 0.35, 0.55), "black")
    abdomen.scale = (1.0, 1.3, 0.9)
    thorax = sphere("thorax", 0.30, (0, -0.35, 0.5), "black")
    headm = sphere("head_m", 0.18, (0, -0.68, 0.48), "red")
    parts += [(abdomen, "body"), (thorax, "body"), (headm, "head")]
    for side in (1, -1):
        for i, (y, ang) in enumerate(((-0.55, 55), (-0.30, 20), (-0.05, -15), (0.20, -45))):
            leg = cylinder("leg_%d_%d" % (side, i), 0.035, 1.0, (side * 0.55, y, 0.45), "black",
                           rot=(math.radians(ang), math.radians(side * 60), 0), verts=6)
            parts.append((leg, "body"))
    objs = [p[0] for p in parts]
    apply_transforms(objs)
    for ob, bone in parts:
        vg = ob.vertex_groups.new(name=bone)
        vg.add(list(range(len(ob.data.vertices))), 1.0, "REPLACE")
    mesh = join(objs, "sk_spider_mesh")
    mesh.parent = arm
    mod = mesh.modifiers.new("Armature", "ARMATURE")
    mod.object = arm

    a = new_action(arm, "idle", 60)
    key_pose(arm, 1, {})
    key_pose(arm, 30, {"body": (3, 0, 0)}, root_loc=(0, 0, -0.03))
    key_pose(arm, 60, {})
    push_to_nla(arm, a)
    a = new_action(arm, "walk", 16)
    key_pose(arm, 1, {"body": (0, 4, 0)}, root_loc=(0, 0, 0.02))
    key_pose(arm, 8, {"body": (0, -4, 0)}, root_loc=(0, 0, -0.02))
    key_pose(arm, 16, {"body": (0, 4, 0)}, root_loc=(0, 0, 0.02))
    push_to_nla(arm, a)
    a = new_action(arm, "attack", 18, loop=False)
    key_pose(arm, 1, {})
    key_pose(arm, 6, {"body": (-20, 0, 0), "head": (-15, 0, 0)}, root_loc=(0, 0.15, 0.05))
    key_pose(arm, 10, {"body": (15, 0, 0), "head": (20, 0, 0)}, root_loc=(0, -0.25, -0.05))
    key_pose(arm, 18, {})
    push_to_nla(arm, a)
    a = new_action(arm, "death", 24, loop=False)
    key_pose(arm, 1, {})
    key_pose(arm, 24, {"body": (0, 180, 0)}, root_loc=(0, 0, -0.2))
    push_to_nla(arm, a)
    export_glb([arm], "sk_spider")


# ---------------------------------------------------------------------------
# Armes — origine à la poignée, lame vers +Z (Godot : attacher sur hand.R)
# ---------------------------------------------------------------------------
def build_weapons():
    print("armes")
    specs = {
        "sm_sword": lambda: [
            box("grip", (0.04, 0.04, 0.18), (0, 0, 0.09), "leather"),
            box("guard", (0.22, 0.04, 0.03), (0, 0, 0.19), "dark_metal"),
            box("blade", (0.06, 0.015, 0.75), (0, 0, 0.58), "metal"),
            sphere("pommel", 0.03, (0, 0, -0.01), "gold", 8),
        ],
        "sm_axe": lambda: [
            cylinder("haft", 0.025, 0.9, (0, 0, 0.45), "wood", verts=8),
            box("head", (0.30, 0.05, 0.25), (0.14, 0, 0.78), "metal"),
        ],
        "sm_mace": lambda: [
            cylinder("haft", 0.022, 0.6, (0, 0, 0.3), "wood", verts=8),
            sphere("head", 0.09, (0, 0, 0.64), "dark_metal", 8),
        ],
        "sm_dagger": lambda: [
            box("grip", (0.03, 0.03, 0.10), (0, 0, 0.05), "leather"),
            box("guard", (0.10, 0.03, 0.02), (0, 0, 0.11), "dark_metal"),
            box("blade", (0.04, 0.01, 0.28), (0, 0, 0.26), "metal"),
        ],
        "sm_staff": lambda: [
            cylinder("shaft", 0.025, 1.7, (0, 0, 0.55), "wood", verts=8),
            sphere("orb", 0.08, (0, 0, 1.45), "glass", 10),
        ],
        "sm_shield": lambda: [
            box("plate", (0.55, 0.06, 0.70), (0, 0.04, 0), "wood"),
            box("rim", (0.60, 0.03, 0.75), (0, 0.08, 0), "dark_metal"),
            sphere("boss", 0.08, (0, 0.11, 0), "metal", 8),
        ],
    }
    for name, make in specs.items():
        clear_scene()
        ob = join(make(), name)
        export_glb([ob], name)


# ---------------------------------------------------------------------------
# Kit de donjon (grille 4 m) et props
# ---------------------------------------------------------------------------
def build_dungeon_kit():
    print("kit donjon")
    T = 4.0  # taille d'une tuile
    H = 3.0  # hauteur des murs
    W = 0.3  # épaisseur des murs

    kit = {
        # Sol : centre à l'origine, surface à z=0
        "sm_floor": lambda: [box("floor", (T, T, 0.2), (0, 0, -0.1), "stone_dark")],
        # Mur : le long de l'axe X, centré, de z=0 à H ; face intérieure vers -Y
        "sm_wall": lambda: [box("wall", (T, W, H), (0, 0, H / 2), "stone")],
        "sm_wall_door": lambda: [
            box("left", (1.3, W, H), (-1.35, 0, H / 2), "stone"),
            box("right", (1.3, W, H), (1.35, 0, H / 2), "stone"),
            box("lintel", (1.4, W, 0.6), (0, 0, H - 0.3), "stone"),
            box("frame_l", (0.12, W + 0.1, 2.4), (-0.64, 0, 1.2), "wood"),
            box("frame_r", (0.12, W + 0.1, 2.4), (0.64, 0, 1.2), "wood"),
        ],
        "sm_pillar": lambda: [
            box("base", (0.7, 0.7, 0.3), (0, 0, 0.15), "stone"),
            cylinder("shaft", 0.25, H - 0.6, (0, 0, H / 2), "stone", verts=10),
            box("cap", (0.7, 0.7, 0.3), (0, 0, H - 0.15), "stone"),
        ],
        # Escalier : monte de 1,5 m sur une tuile, vers +Y
        "sm_stairs": lambda: [
            box("step%d" % i, (T, T / 6, 0.25 * (i + 1)), (0, -T / 2 + T / 12 + i * T / 6, 0.125 * (i + 1)), "stone")
            for i in range(6)
        ],
        "sm_torch": lambda: [
            box("bracket", (0.08, 0.12, 0.08), (0, 0.05, 1.6), "dark_metal"),
            cylinder("stick", 0.03, 0.45, (0, 0.12, 1.8), "wood", rot=(math.radians(-20), 0, 0), verts=6),
            sphere("flame", 0.09, (0, 0.2, 2.05), "fire", 8),
        ],
        "sm_chest": lambda: [
            box("body", (0.9, 0.55, 0.45), (0, 0, 0.225), "wood"),
            box("lid", (0.92, 0.57, 0.18), (0, 0, 0.54), "leather"),
            box("band1", (0.06, 0.6, 0.66), (-0.3, 0, 0.33), "dark_metal"),
            box("band2", (0.06, 0.6, 0.66), (0.3, 0, 0.33), "dark_metal"),
            box("lock", (0.1, 0.05, 0.12), (0, -0.3, 0.45), "gold"),
        ],
        "sm_altar": lambda: [
            box("base", (1.6, 0.9, 0.3), (0, 0, 0.15), "stone_dark"),
            box("top", (1.4, 0.7, 0.7), (0, 0, 0.65), "stone"),
            box("slab", (1.7, 1.0, 0.1), (0, 0, 1.05), "stone_dark"),
            sphere("gem", 0.1, (0, 0, 1.2), "red", 8),
        ],
        "sm_barrel": lambda: [
            cylinder("body", 0.35, 0.9, (0, 0, 0.45), "wood", verts=10),
            cylinder("hoop1", 0.37, 0.05, (0, 0, 0.2), "dark_metal", verts=10),
            cylinder("hoop2", 0.37, 0.05, (0, 0, 0.7), "dark_metal", verts=10),
        ],
        "sm_crate": lambda: [
            box("body", (0.8, 0.8, 0.8), (0, 0, 0.4), "wood"),
            box("x1", (0.84, 0.06, 0.84), (0, 0, 0.4), "leather"),
            box("x2", (0.06, 0.84, 0.84), (0, 0, 0.4), "leather"),
        ],
        "sm_potion": lambda: [
            sphere("flask", 0.08, (0, 0, 0.09), "red", 10),
            cylinder("neck", 0.03, 0.08, (0, 0, 0.19), "glass", verts=8),
            cylinder("cork", 0.035, 0.03, (0, 0, 0.24), "wood", verts=8),
        ],
        "sm_coins": lambda: [
            cylinder("c%d" % i, 0.06, 0.012, (dx, dy, 0.006 + 0.012 * k), "gold", verts=10)
            for i, (dx, dy, k) in enumerate(((0, 0, 0), (0.05, 0.03, 1), (-0.04, 0.05, 1), (0.01, -0.06, 0), (0.02, 0.01, 2)))
        ],
    }
    for name, make in kit.items():
        clear_scene()
        ob = join(make(), name)
        export_glb([ob], name)


# ---------------------------------------------------------------------------
def main():
    print("Génération des placeholders → " + OUT_DIR)
    build_humanoid()
    build_spider()
    build_weapons()
    build_dungeon_kit()
    print("Terminé.")


if __name__ == "__main__":
    main()

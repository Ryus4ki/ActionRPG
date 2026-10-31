class_name UiTheme
## Thème partagé : contour doré bien visible sur l'élément qui a le focus (navigation manette / clavier).
## Seuls les styles « focus » sont redéfinis ; le reste reprend le thème par défaut.

const FOCUS_COLOR := Color(1.0, 0.82, 0.35)

static var _theme: Theme


static func get_theme() -> Theme:
	if _theme == null:
		_theme = Theme.new()
		var sb := focus_style()
		for type in ["Button", "OptionButton", "CheckButton", "CheckBox", "LineEdit", "ItemList", "MenuButton", "TabContainer"]:
			_theme.set_stylebox("focus", type, sb)
		# Ligne de liste sélectionnée + focus (ItemList des parties LAN).
		_theme.set_stylebox("cursor", "ItemList", sb)
		_theme.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	return _theme


static func focus_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.border_color = FOCUS_COLOR
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	sb.expand_margin_left = 2
	sb.expand_margin_right = 2
	sb.expand_margin_top = 2
	sb.expand_margin_bottom = 2
	return sb


## Donne le focus au premier contrôle focalisable (visible, actif) sous `root`. Renvoie vrai si trouvé.
static func focus_first(root: Node) -> bool:
	var c := first_focusable(root)
	if c:
		c.grab_focus()
		return true
	return false


static func first_focusable(root: Node) -> Control:
	for child in root.get_children():
		if child is Control:
			var ctl := child as Control
			if not ctl.is_visible_in_tree():
				continue
			if ctl.focus_mode != Control.FOCUS_NONE and not (ctl is BaseButton and (ctl as BaseButton).disabled):
				return ctl
		var deeper := first_focusable(child)
		if deeper:
			return deeper
	return null


## Contrôles focalisables sous `root`, dans l'ordre de l'arbre.
static func focusables(root: Node, out: Array = []) -> Array:
	for child in root.get_children():
		if child is Control and (child as Control).is_visible_in_tree() and (child as Control).focus_mode != Control.FOCUS_NONE:
			out.append(child)
		focusables(child, out)
	return out

extends RefCounted
class_name WorldsmithTheme

# The look of the home screen and its sub-screens: a deep teal ground, chalk
# text, one brass action colour, and a serif face for the names of things.
# System fonts are used so nothing is bundled; each list ends in a face that
# exists on the headset.

const GROUND := Color("10262b")
const SURFACE := Color("183238")
const RAISED := Color("21434a")
const LINE := Color("2f5a61")
const CHALK := Color("eef1e6")
const MUTED := Color("9db2ae")
const FAINT := Color("5f7b7a")
const BRASS := Color("e3b04b")
const BRASS_BRIGHT := Color("f0c468")
const INK := Color("1a1405")
const MOSS := Color("8fd18a")
const CLAY := Color("e98b5d")
const SKY := Color("8db8f2")


static func serif(weight: int = 400) -> Font:
	return _system_font(["Iowan Old Style", "Charter", "Georgia", "Noto Serif", "serif"], weight)


static func sans(weight: int = 400) -> Font:
	return _system_font(["Avenir Next", "Avenir", "Roboto", "sans-serif"], weight)


static func _system_font(names: Array, weight: int) -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(names)
	font.font_weight = weight
	return font


static func box(fill: Color, radius: int = 6, border: Color = Color.TRANSPARENT, border_width: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_corner_radius_all(radius)
	style.border_color = border
	style.set_border_width_all(border_width)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 9
	style.content_margin_bottom = 9
	return style


static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font = sans()
	theme.default_font_size = 15
	theme.set_color("font_color", "Label", CHALK)
	_style_buttons(theme)
	_style_rows(theme)
	_style_fields(theme)
	_style_windows(theme)
	return theme


static func _style_buttons(theme: Theme) -> void:
	_button_states(theme, "Button", box(RAISED), box(LINE), box(SURFACE, 6, LINE, 1), CHALK)
	theme.set_stylebox("disabled", "Button", box(Color.TRANSPARENT, 6, LINE, 1))
	theme.set_color("font_disabled_color", "Button", FAINT)
	theme.set_type_variation("PrimaryButton", "Button")
	_button_states(theme, "PrimaryButton", box(BRASS), box(BRASS_BRIGHT), box(BRASS_BRIGHT), INK)
	theme.set_font("font", "PrimaryButton", sans(600))
	theme.set_font_size("font_size", "PrimaryButton", 17)
	theme.set_type_variation("TabButton", "Button")
	var selected_tab := box(Color.TRANSPARENT, 0, BRASS)
	selected_tab.border_width_bottom = 2
	_button_states(theme, "TabButton", box(Color.TRANSPARENT, 0), box(Color.TRANSPARENT, 0), selected_tab, MUTED)
	theme.set_color("font_pressed_color", "TabButton", CHALK)
	theme.set_color("font_hover_pressed_color", "TabButton", CHALK)
	theme.set_font_size("font_size", "TabButton", 17)


static func _button_states(theme: Theme, kind: String, normal: StyleBox, hover: StyleBox, pressed: StyleBox, text: Color) -> void:
	theme.set_stylebox("normal", kind, normal)
	theme.set_stylebox("hover", kind, hover)
	theme.set_stylebox("pressed", kind, pressed)
	theme.set_stylebox("hover_pressed", kind, pressed)
	theme.set_stylebox("focus", kind, box(Color.TRANSPARENT, 6, BRASS_BRIGHT, 2))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		theme.set_color(state, kind, text)


# A row in a list of scenes or assets: a hairline under each, brass edge on the chosen one.
static func _style_rows(theme: Theme) -> void:
	theme.set_type_variation("RowButton", "Button")
	var rest := box(Color.TRANSPARENT, 0, LINE)
	rest.border_width_bottom = 1
	var hover := box(SURFACE, 0, LINE)
	hover.border_width_bottom = 1
	var chosen := box(RAISED, 0, BRASS)
	chosen.border_width_left = 3
	_button_states(theme, "RowButton", rest, hover, chosen, CHALK)
	theme.set_stylebox("focus", "RowButton", StyleBoxEmpty.new())


static func _style_fields(theme: Theme) -> void:
	for kind in ["LineEdit", "TextEdit"]:
		theme.set_stylebox("normal", kind, box(SURFACE, 6, LINE, 1))
		theme.set_stylebox("focus", kind, box(SURFACE, 6, BRASS, 1))
		theme.set_stylebox("read_only", kind, box(SURFACE, 6, LINE, 1))
		theme.set_color("font_color", kind, CHALK)
		theme.set_color("font_placeholder_color", kind, FAINT)
	theme.set_stylebox("panel", "ItemList", box(SURFACE, 6, LINE, 1))
	theme.set_stylebox("hovered", "ItemList", box(RAISED, 4))
	theme.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	theme.set_color("font_color", "ItemList", CHALK)
	theme.set_constant("v_separation", "ItemList", 8)
	theme.set_stylebox("panel", "PanelContainer", box(SURFACE, 8))
	var grabber := box(LINE, 3)
	grabber.content_margin_left = 3
	grabber.content_margin_right = 3
	for state in ["grabber", "grabber_highlight", "grabber_pressed"]:
		theme.set_stylebox(state, "VScrollBar", grabber)
	theme.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())


static func _style_windows(theme: Theme) -> void:
	var frame := box(SURFACE, 8, LINE, 1)
	frame.expand_margin_top = 34
	theme.set_stylebox("embedded_border", "Window", frame)
	theme.set_stylebox("embedded_unfocused_border", "Window", frame)
	theme.set_color("title_color", "Window", CHALK)
	theme.set_stylebox("panel", "AcceptDialog", box(SURFACE, 0))
	theme.set_stylebox("panel", "PopupMenu", box(RAISED, 6, LINE, 1))
	theme.set_color("font_color", "PopupMenu", CHALK)


static func label(text: String, size: int, color: Color = CHALK, font: Font = null) -> Label:
	var made := Label.new()
	made.text = text
	made.add_theme_font_size_override("font_size", size)
	made.add_theme_color_override("font_color", color)
	if font != null:
		made.add_theme_font_override("font", font)
	return made

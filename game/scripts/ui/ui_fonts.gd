class_name UiFonts
## The game's two Japanese fonts (#134), both SIL OFL 1.1 (game/assets/fonts/OFL-*.txt):
##   body  : M PLUS Rounded 1c Bold, the project's default font (project.godot gui/theme/custom_font),
##           for explanations, settings, panels and small HUD text;
##   title : DotGothic16, a dot font that matches the pixel art, for titles, banners and the
##           big lines (StudyHud.label at TITLE_MIN_SIZE and above).

const BODY_PATH := "res://assets/fonts/MPLUSRounded1c-Bold.ttf"
const TITLE_PATH := "res://assets/fonts/DotGothic16-Regular.ttf"
## A label this big or bigger is a title / banner / big line.
const TITLE_MIN_SIZE := 28

static var _body: Font
static var _title: Font

static func body() -> Font:
	if _body == null:
		_body = load(BODY_PATH) as Font
		if _body == null:
			_body = ThemeDB.fallback_font
	return _body

static func title() -> Font:
	if _title == null:
		_title = load(TITLE_PATH) as Font
		if _title == null:
			_title = body()
	return _title

## The font for text of this size (pixels).
static func for_size(size: int) -> Font:
	return title() if size >= TITLE_MIN_SIZE else body()

## A Control's text in the title font (buttons and labels made outside StudyHud.label).
static func use_title(c: Control) -> void:
	c.add_theme_font_override("font", title())

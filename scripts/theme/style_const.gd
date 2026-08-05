# StyleConst — 项目全局颜色常量表
# 用法: const Style = preload("res://scripts/theme/style_const.gd"); Style.ATTACK_RED
extends RefCounted

# 移动端字号适配：窗口明显窄于 1920 视口基准时（手机竖屏等，内容被等比缩小），
# 字号放大补偿（上限 1.5 倍防溢出布局）。桌面/横屏大窗返回原字号。
# 用法: add_theme_font_size_override("font_size", Style.fs(30))
static func fs(size: int) -> int:
	var win = DisplayServer.window_get_size()
	if win.x > 0 and win.x < 1630:
		var k = clampf(1920.0 / win.x, 1.0, 1.5)
		return int(ceil(size * k))
	return size

# 场景节点字号适配：tscn 里写死的 font_size 无法用 Style.fs，在场景脚本 _ready 调用一次，
# 遍历子树把已有的字号 override 按移动端系数放大
static func scale_node_fonts(root: Node):
	for c in root.find_children("*", "Control", true, false):
		if c.has_theme_font_size_override("font_size"):
			c.add_theme_font_size_override("font_size", fs(c.get_theme_font_size("font_size")))

# ---- 主色调 ----
const BG_DARK       = Color(0.06, 0.08, 0.12)
const ATTACK_RED    = Color(1.0, 0.5, 0.4)
const MOVE_BLUE     = Color(0.4, 0.6, 1.0)
const FUNC_GREEN    = Color(0.3, 0.9, 0.6)
const FREE_YELLOW   = Color(1.0, 0.9, 0.3)

# ---- 玩家 ----
const ME_GREEN      = Color(0.3, 1.0, 0.3)
const OPP_RED       = Color(1.0, 0.4, 0.4)
const ME_INFO       = Color(0.5, 0.8, 1.0)
const OPP_INFO      = Color(1.0, 0.7, 0.5)

# ---- 棋盘 ----
const CELL_BG       = Color(0.12, 0.14, 0.2)
const CELL_BORDER   = Color(0.25, 0.25, 0.35)
const CELL_TEXT     = Color(0.5, 0.5, 0.6)

# ---- UI ----
const PHASE_GOLD    = Color(1.0, 0.85, 0.3)
const SELECTED_CYAN = Color(0.3, 1.0, 1.0)
const STATUS_GRAY   = Color(0.6, 0.6, 0.6)
const CARD_INFO     = Color(0.8, 0.8, 0.5)
const HAND_TITLE    = Color(0.7, 0.7, 0.7)
const DISCARD_RED   = Color(1.0, 0.4, 0.4)
const LOG_TEXT      = Color.WHITE
const POPUP_BG      = Color(0.0, 0.0, 0.0, 0.6)
const WEAPON_DESC   = Color(0.7, 0.7, 0.7)
const EMPTY_HAND    = Color(0.4, 0.4, 0.4)
const ERROR_RED     = Color(1.0, 0.3, 0.3)
const READY_YELLOW  = Color(1.0, 1.0, 0.3)
const WIN_GOLD      = Color(1.0, 0.85, 0.3)
const LOSE_RED      = Color(0.7, 0.3, 0.3)

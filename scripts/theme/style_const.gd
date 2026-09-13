# StyleConst — 项目全局颜色常量表
# 用法: const Style = preload("res://scripts/theme/style_const.gd"); Style.ATTACK_RED
extends RefCounted

# 移动端字号适配：窗口明显窄于 1920 视口基准时（手机竖屏等，内容被等比缩小），
# 字号放大补偿（上限 1.5 倍防溢出布局）。桌面/横屏大窗返回原字号。
# 用法: add_theme_font_size_override("font_size", Style.fs(30))
static func fs(size: int) -> int:
	var win = DisplayServer.window_get_size()
	if win.x > 0 and win.x < 1630:
		# 移动端：补偿视口缩小（上限 1.7 倍，越大越醒目）
		var k = clampf(1920.0 / win.x, 1.0, 1.7)
		return int(ceil(size * k))
	# 桌面/大窗：整体放大 10%（黑体 Bold/Black 字重下更醒目）
	return int(ceil(size * 1.1))

# 场景节点字号适配：tscn 里写死的 font_size 无法用 Style.fs，在场景脚本 _ready 调用一次，
# 遍历子树把已有的字号 override 按移动端系数放大
static func scale_node_fonts(root: Node):
	for c in root.find_children("*", "Control", true, false):
		if c.has_theme_font_size_override("font_size"):
			c.add_theme_font_size_override("font_size", fs(c.get_theme_font_size("font_size")))

# 中英混排断行修复：在"数字/拉丁字符 ↔ CJK 字符"交界插入 U+2060（WORD JOINER，UAX#14 WJ 类：禁止两侧断行）。
# 原因：AUTOWRAP_WORD_SMART 把数字/字母单词视为独立词，行尾放不下时会把数字整体甩到下一行，
# 造成"技能描述一遇数字就换行"的观感（如"长出1|层"）。插入 WJ 后数字与相邻中文粘合，断点移到自然位置。
# 注意：零宽字符，不影响排版宽度、搜索匹配与数据层断言。渲染含数字/字母的显示文本前调用。
# 用法: d.text = Style.wj("每回合限1次：弃1张攻击卡…")
static func wj(text: String) -> String:
	if text.is_empty():
		return text
	var out := ""
	var prev_latin := false
	for ch in text:
		var code := ch.unicode_at(0)
		var latin := (code >= 0x30 and code <= 0x39) or (code >= 0x41 and code <= 0x5A) \
			or (code >= 0x61 and code <= 0x7A) or code == 0x2D or code == 0x25 or code == 0x2E or code == 0x2B
		if latin != prev_latin and not out.is_empty():
			out += "\u2060"
		out += ch
		prev_latin = latin
	return out

# 中文段落首行缩进：对每个 \n\n 分隔的段落首行前加 2 个全角空格（U+3000，宽度=一个汉字）。
# 换行产生的后续行从最左开始（TextServer 断行会 trim 行首空白，仅首行保留缩进）。
# 用于正文/描述渲染，让段落边界清晰可辨。
# 用法: label.text = Style.indent("判定阶段开始时或位移后…\n\n蔓延：…")
static func indent(text: String) -> String:
	if text.is_empty():
		return text
	var parts := text.split("\n\n", false)
	for i in range(parts.size()):
		parts[i] = "　　" + parts[i]
	return "\n\n".join(parts)

# 刘海屏/挖孔屏/状态栏安全区适配：返回内容安全矩形（viewport 坐标，UI 布局直接用）。
# 无 inset（桌面/无遮挡）时返回全视口；Android 沉浸模式下窗口延伸到刘海/挖孔区域，
# 通过 DisplayServer.get_display_safe_area() 得到系统安全区，逆映射到 viewport 坐标。
# 用法: var safe = Style.safe_rect(get_viewport()); margin_top = 36 + int(safe.position.y)
static func safe_rect(vp: Viewport) -> Rect2:
	var view := vp.get_visible_rect()
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if safe.size.x <= 0 or safe.size.y <= 0 or (win.x > 0 and safe == Rect2i(0, 0, win.x, win.y)):
		return view
	var inv := vp.get_final_transform().affine_inverse()
	var tl := inv * Vector2(safe.position)
	var br := inv * Vector2(safe.position + safe.size)
	return Rect2(tl, br - tl)

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

# ---- 模式选择界面（mode_select）----
const MODE_CARD_BG       = Color(0.13, 0.16, 0.22)   # 模式卡片底（待美术替换）
const MODE_CARD_BORDER   = Color(0.30, 0.32, 0.40)   # 未选中边框
const MODE_SELECTED      = Color(1.0, 0.85, 0.3)     # 选中金边
const MODE_DISABLED      = Color(0.40, 0.40, 0.44)   # 禁用/占位卡
const MODE_TITLE         = Color(1.0, 0.85, 0.3)     # 模式名
const MODE_DESC          = Color(0.75, 0.78, 0.84)   # 模式简介
const MODE_FEATURE       = Color(0.55, 0.60, 0.68)   # 规则要点
const CONFIG_LABEL       = Color(0.85, 0.87, 0.92)   # 配置区标签
const CONFIG_VALUE       = Color(1.0, 0.9, 0.5)      # 配置数值

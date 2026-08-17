# wiki_ui.gd — 游戏百科界面（左侧分类导航 + 右侧内容区）
# 分类：基本规则 / 卡牌 / 特殊机制 / 角色；按钮常驻不消失，切换时清空内容并滚动回顶部
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

@onready var content = $MainHBox/Scroll/Margin/Content

# 角色技能（[类型, 技能名, 效果]）：主动技在前、被动技在后，每个技能独立一行；属性由角色数据自动渲染
const CHAR_SKILLS: Dictionary = {
	"fighter": [["被动技", "战利", "近战或重击攻击命中目标后，可选择：抽 1 张牌，或回复 2 点 HP。每回合限一次。"]],
	"sharpshooter": [["被动技", "先发", "每回合打出的第一张普通远程攻击卡不消耗攻击行动点（仅限\"远程\"卡，穿心不享受）。"]],
	"mage": [["主动技", "法术强化", "弃 1 张手牌，获得 2 点魔法强化——可无限叠加；打出魔法或吟唱攻击时，消耗全部强化层数，为本次攻击附加等量伤害。每回合限一次。"]],
	"paladin": [["被动技", "圣盾", "每回合第一次受到的伤害减少 2 点（最低为 0）。"]],
	"assassin": [["主动技", "暗影步", "每回合可免费向任意方向移动 1 格，不消耗位移行动点（不能推人）。"]],
	"priest": [
		["被动技", "治愈术精通", "使用回复卡时，回复量额外 +2。"],
		["被动技", "净化", "受到某类持续伤害（灼烧/中毒）后，清除自身该类持续伤害。"],
	],
	"berserker": [["被动技", "狂化", "受到直接攻击后，近战攻击伤害 +1，持续 3 回合，可叠加。"]],
	"warlock": [
		["被动技", "邪能", "功能行动点 +1（每回合 2 点）。"],
		["被动技", "虚空造物", "若本回合未打出任何功能卡，回合结束额外抽 1 张牌。"],
		["被动技", "枯萎", "自身受到的所有回血效果 −2（回复 +1/+2 时实际回复 0）。"],
	],
	"gunslinger": [["被动技", "双发扳机", "远程/穿心攻击固定消耗 2 攻击行动点，并造成两段伤害——每段 =（对应面板 − 距离）÷ 2 向下取整（最低 0）；穿心每段 =（远程面板 + 3 − 距离）÷ 2。两段各自独立结算：敌人需打出两张响应卡才能完全抵挡；圣骑士的首伤减免只对第一段生效，武器命中特效每段触发。"]],
	"hunter": [["主动技", "埋伏", "手牌持有远程攻击牌时可用。选择并丢弃一张「远程」攻击卡，消耗 1 攻击行动点，可放置 1 个捕兽夹；或选择并丢弃一张「穿心」攻击卡，消耗 2 攻击行动点，可放置 2 个捕兽夹。捕兽夹须放置于棋盘无单位空格，可重叠放置；首个到达该格的单位每个夹子受到 3 点伤害，触发后销毁。每回合限一次。"]],
	"tracker": [["被动技", "校准", "远程或法术攻击命中（造成伤害）后，获得 1 层校准状态——每层使远程攻击伤害 +1，永久持续、可无限叠加。若远程或法术攻击未能造成伤害（被闪避、格挡/牵制减至 0、护甲免疫、无法打出等），全部校准清空。"]],
	"wardsmith": [
		["主动技", "护甲注魔", "直接选择装备一件近战/远程/法术护甲，不消耗卡牌（整局限一次）。"],
		["主动技", "修复", "装备的护甲破损时可用：消耗 2 攻击行动点，并丢弃一张与护甲类型匹配的强化攻击卡（重击→近战防具、穿心→远程防具、吟唱→法术防具），修复 1 点护甲耐久。"],
		["被动技", "精铸", "装备的护甲耐久上限 +1（为 4 耐久）。"],
	],
	"spellblade": [["主动技", "魔力引导", "装备近战武器时可用。选择并丢弃一张「魔法」攻击卡，消耗 1 攻击行动点，视作打出「近战」攻击，无视距离限制；或选择并丢弃一张「吟唱」攻击卡，消耗 2 攻击行动点，视作打出「重击」攻击，无视距离限制。可被格挡响应。"]],
	"miko": [["被动技", "结界", "巫女的道具卡放置「鸟居」（同格仅 1 个，可被摧毁卡拆除）。巫女自己踩上：回复 2 点 HP，且近战/远程/魔法面板各永久 +1（可叠加）；敌方角色踩上：进入「神隐」——其下个回合被跳过。"]],
}

func _ready():
	Style.scale_node_fonts(self)  # 移动端字号适配（tscn 写死的字号）
	$MainHBox/Sidebar/BackBtn.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	$MainHBox/Sidebar/RulesBtn.pressed.connect(func(): _show_category("rules"))
	$MainHBox/Sidebar/CardsBtn.pressed.connect(func(): _show_category("cards"))
	$MainHBox/Sidebar/MechsBtn.pressed.connect(func(): _show_category("mechs"))
	$MainHBox/Sidebar/CharsBtn.pressed.connect(func(): _show_category("chars"))
	_show_category("rules")  # 默认显示基本规则

# 切换分类：清空内容 → 渲染该分类全部章节 → 滚动回顶部
func _show_category(cat: String):
	for c in content.get_children():
		content.remove_child(c)
		c.queue_free()
	match cat:
		"rules": _fill_rules()
		"cards": _fill_cards()
		"mechs": _fill_mechs()
		"chars": _fill_chars()
	# 触摸滚动修复：内容控件（PanelContainer 等）默认 mouse_filter=STOP 会拦截触摸，
	# 导致手机端点住内容无法拖动滚动——统一设为 PASS 让触摸穿透给 ScrollContainer
	for c in content.find_children("*", "Control", true, false):
		c.mouse_filter = Control.MOUSE_FILTER_PASS
	$MainHBox/Scroll.scroll_vertical = 0

# 添加一节内容（标题 + 正文）
func _add_section(title_text: String, body: String):
	var t = Label.new()
	t.text = title_text
	t.add_theme_font_size_override("font_size", Style.fs(42))
	t.add_theme_color_override("font_color", Style.WIN_GOLD)
	content.add_child(t)
	var b = Label.new()
	b.text = body
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_size_override("font_size", Style.fs(30))
	b.add_theme_constant_override("line_spacing", 10)
	b.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	content.add_child(b)
	content.add_child(_sep())

func _sep() -> HSeparator:
	var s = HSeparator.new()
	s.add_theme_constant_override("separation", 24)
	return s

# 分组小标题（如"基础攻击""强化攻击"）
func _add_group_label(text: String):
	var t = Label.new()
	t.text = text
	t.add_theme_font_size_override("font_size", Style.fs(36))
	t.add_theme_color_override("font_color", Color(1, 0.85, 0.3, 1))
	content.add_child(t)

# 单张卡牌块（名称行 + 描述行数组），独立面板与间距，避免内容冗杂
func _add_card_block(name_text: String, lines: Array):
	var p = PanelContainer.new()
	p.add_theme_constant_override("margin_left", 22)
	p.add_theme_constant_override("margin_right", 22)
	p.add_theme_constant_override("margin_top", 14)
	p.add_theme_constant_override("margin_bottom", 14)
	var vb = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	p.add_child(vb)
	var n = Label.new()
	n.text = name_text
	n.add_theme_font_size_override("font_size", Style.fs(32))
	n.add_theme_color_override("font_color", Style.SELECTED_CYAN)
	vb.add_child(n)
	for line in lines:
		var l = Label.new()
		l.text = line
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", Style.fs(26))
		l.add_theme_constant_override("line_spacing", 6)
		l.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
		vb.add_child(l)
	content.add_child(p)

# ==================== 基本规则 ====================
func _fill_rules():
	_add_section("游戏玩法",
		"《卡牌对决》目前是一款双人回合制战术卡牌对战游戏。双方各操控一名角色，在一条 11 格横线棋盘上，通过出牌、移动与响应博弈，率先将对方 HP 清空、并使其无法复活的一方获胜。未来将制作更复杂的棋盘地图，向 CCG+SRPG+DBG 形式前进。")
	_add_section("棋盘与位置",
		"棋盘为 11 格横线，两名角色初始分别站在靠近己方一侧的位置（先手侧第 4 格，后手侧第 7 格）。\n距离为两名角色所在格之间的格数差；两名角色位于相邻两格时即\"贴脸\"（距离为 0）。\n角色可在格子上移动；贴脸时向对方方向移动，可推着对方一起移动。")
	_add_section("游戏模式",
		"· 自我对战：本地轮流操控两名角色对战，适合熟悉规则与测试\n· 人机对战：与电脑对战，可选简单 / 普通 / 困难三档难度\n· 多人对战：联机对战，创建房间（填写服务器地址 + 房间号）或加入他人房间")
	_add_section("开局流程（BP 禁选）",
		"开局先随机决定禁选顺序，随后：\n1. 先手方（P1）禁用 1 名角色（双方都不可选）\n2. 后手方（P2）禁用 1 名角色\n3. P1 选择自己的角色\n4. P2 选择自己的角色\n5. 再随机确定本局先手，进入战斗")
	_add_section("牌堆与手牌",
		"双方共用一副 78 张的共享牌堆；每名玩家开局拥有 4 张初始卡牌，每回合摸牌阶段自动摸取 2 张。\n手牌上限 = 角色距己侧板边格数差 + 1；弃牌阶段玩家需要弃牌至不多于手牌上限。\n牌堆抽空时，弃牌堆自动洗回牌堆，可循环使用。")
	_add_section("回合与行动点",
		"每回合 4 个阶段：\n1. 判定阶段：结算持续伤害效果（灼烧、中毒等），并检查死亡与冻结状态\n2. 摸牌阶段：自动摸取 2 张牌\n3. 出牌阶段：自由打出卡牌（受行动点限制）——攻击、移动、功能卡等\n4. 弃牌阶段：手牌超上限时强制弃牌，也可主动弃牌\n\n行动点（每回合刷新，三种独立）：\n· 攻击 2 点：打出攻击类卡牌（部分强化攻击消耗 2 点）\n· 位移 1 点：移动\n· 功能 1 点：打出功能类卡牌（部分角色有额外加成）")
	_add_section("胜利条件与复活",
		"胜利：将敌人 HP 攻击至 0 或以下，且敌人无法通过复活回复 HP 值为正数。\n复活判定：HP 归零时，自动丢弃所有手牌 → 从牌堆摸取 4 张 → 自动使用其中所有回复卡：\n· HP 值能回复至正数 → 复活成功，继续战斗（可多次复活）\n· 否则 → 永久淘汰，本局失败")

# ==================== 卡牌 ====================
func _fill_cards():
	_add_section("攻击卡与伤害计算",
		"攻击卡分为三大基础类型与三种强化类型。每张攻击卡的伤害公式统一为\"命中造成伤害 =\"，实际数值再依次经过武器加成、Buff 加成、防具减伤、响应效果修正（见下方\"特殊规则\"）。")
	_add_group_label("基础攻击（各 8 张，共 24 张；消耗 1 攻击点）")
	_add_card_block("近战（×8）", [
		"使用条件：必须与对手贴脸（距离为 0）才能打出",
		"命中造成伤害 = 近战面板",
		"可交互：可被对方的格挡响应（伤害减半）；本卡也可用作格挡响应卡，抵挡近战/重击攻击",
	])
	_add_card_block("远程（×8）", [
		"使用条件：无距离限制（距离越近伤害越高）",
		"命中造成伤害 = 远程面板 − 距离（最低 0）",
		"可交互：可被对方的牵制（远程卡）或闪避（魔法卡）响应；本卡可用作牵制响应卡，牵制远程/穿心/魔法/吟唱攻击",
	])
	_add_card_block("魔法（×8）", [
		"使用条件：无视距离",
		"命中造成伤害 = 魔法面板",
		"可交互：可被对方的牵制（远程卡）或闪避（魔法卡）响应；本卡可用作闪避响应卡，可闪避任意攻击",
	])
	_add_group_label("强化攻击（各 3 张，共 9 张；消耗 2 攻击点）")
	_add_card_block("重击（×3）：强化近战攻击", [
		"使用条件：必须与对手贴脸（距离为 0）才能打出",
		"命中造成伤害 = 近战面板 + 3",
		"穿甲：命中防具时防具额外损失 2 点耐久（免疫/减半均触发，被闪避或减伤至 0 不触发）",
		"可交互：可被对方的格挡响应（伤害减半）",
	])
	_add_card_block("穿心（×3）：强化远程攻击", [
		"使用条件：若\"远程面板 − 距离 ≤ 0\"（距离过远）则无法打出（卡不消耗）",
		"命中造成伤害 = 远程面板 − 距离 + 3",
		"穿甲：命中防具时防具额外损失 2 点耐久（免疫/减半均触发，被闪避或减伤至 0 不触发）",
		"可交互：可被对方的牵制（远程卡）或闪避（魔法卡）响应",
	])
	_add_card_block("吟唱（×3）：强化魔法攻击", [
		"使用条件：无视距离",
		"命中造成伤害 = 魔法面板 + 3",
		"穿甲：命中防具时防具额外损失 2 点耐久（免疫/减半均触发，被闪避或减伤至 0 不触发）",
		"可交互：可被对方的牵制（远程卡）或闪避（魔法卡）响应",
	])
	_add_section("特殊规则",
		"快枪手双发：快枪手的远程/穿心攻击固定消耗 2 攻击点，且打出后分为两段伤害——每段 =（对应面板 − 距离）÷ 2 向下取整（最低 0），穿心每段 =（远程面板 + 3 − 距离）÷ 2。两段各自独立结算，各需一次响应。\n\n伤害修正顺序：命中造成伤害（基础值）→ 武器加成（武器类型须与攻击类型匹配）→ Buff 加成 → 防具减伤 → 响应效果 → 最终伤害（最低 0）。\n\n防具：3 耐久，首次命中完全免疫，之后减半（向下取整）；伤害最低 0。强化攻击（重击/穿心/吟唱）命中防具时额外损失 2 点耐久（不叠加正常消耗；满耐久 3 的防具需两次强化攻击命中才会碎裂）。（铸甲师被动可使防具耐久上限 +1，为 4 耐久。）")
	_add_section("响应系统",
		"当对方发动攻击时，你可以从手牌打出一张卡进行响应（一次攻击限一次）——猜对手的牌，是博弈的核心乐趣：\n\n· 格挡：用近战卡响应近战/重击 → 伤害减半（向下取整）\n· 牵制：用远程卡响应远程/穿心/魔法/吟唱 → 减免\"你的远程面板 − 距离\"点伤害（最低 0），连弩武器可额外 −2\n· 闪避：用魔法卡响应任意攻击 → 完全抵消伤害\n· 不响应 / 无牌可应：承受全额伤害\n\n注意：快枪手的双发攻击两段各需一次响应（各打一张卡）。\n响应有时间限制（20 秒），超时自动视为不响应。")
	_add_section("移动卡", "移动卡消耗 1 位移行动点，用于调整角色位置：")
	_add_card_block("移动（×7）", [
		"使用条件：目标格为空；或目标格有敌人且其身后为空（可推人）",
		"效果：向任意方向移动 1 格",
		"可交互：贴脸时向对方方向移动，可推着对方一起移动（对方被推到的格子若有陷阱会触发）；若本回合被限制移动（如霜咬命中），移动卡无法打出且不消耗；通过移动牌位移至贴脸时，触发突刺武器额外 +3",
	])
	_add_section("功能卡（消耗 1 功能行动点，共 11 张）", "")
	_add_card_block("冻结（×2）", [
		"效果：命中目标后，目标跳过下个出牌阶段（判定与摸牌阶段正常进行）",
		"可交互：可被魔法卡闪避响应（被闪避则本次冻结不生效）；冷却规则：同一玩家被冻结后隔一个完整回合才能再次被冻结（t1 被冻 → t2 不能冻 → t3 可冻），冷却期间打出冻结卡无效且不消耗；被冻结的角色复活时清除冻结状态",
	])
	_add_card_block("摧毁（×3）", [
		"效果：打出后三选一：① 盲丢手牌：随机丢弃对方 1 张手牌；② 摧毁装备：指定摧毁对方一件已装备的武器或防具（武器回到幻化池可再次生成，防具直接消失不回池）；③ 拆除道具：点击棋盘指定格子，同格所有可摧毁道具类型同时按各自规则拆除（默认类拆 1 个；可堆叠类如捕兽夹一次清空同格全部；免疫类跳过不影响其他类型）",
		"可交互：选择摧毁装备时，若对方未装备对应类型 → 卡不消耗；选择拆除道具时，若该格无道具 → 卡不消耗",
	])
	_add_card_block("夺取（×2）", [
		"效果：随机抽取对方 1 张手牌，加入自己手牌",
		"可交互：对方手牌为空时夺取失败（\"夺取空\"，卡仍消耗）",
	])
	_add_card_block("吸引（×2）", [
		"效果：强制将目标拉近 1 格",
		"可交互：目标在板边或目标格被占时无法吸引（卡不消耗）；目标被拉到的格子若有陷阱会触发；吸引后若双方贴脸，自己后退 1 格腾位",
	])
	_add_card_block("威慑（×2）", [
		"效果：强制将目标推远 1 格",
		"可交互：目标在板边时无法威慑（卡不消耗）；目标被推到的格子若有陷阱会触发",
	])
	_add_section("免费卡（不消耗行动点，共 27 张）", "")
	_add_card_block("回复+3（×3）/ 回复+5（×2）", [
		"效果：回复 3 / 5 点 HP（回复量不超过 HP 上限，多余回复无效）",
		"可交互：牧师使用回复卡时回复量额外 +2；邪术师自身受回血效果 −2（回复 +1/+2 时实际回复 0）；复活判定中会自动使用抽到的回复卡",
	])
	_add_card_block("天赐（×4）", [
		"效果：免费打出，抽 2 张牌",
		"可交互：每回合限用 1 张；复活判定中抽到天赐可自动打出并额外抽 2 张（仅一次）",
	])
	_add_card_block("数值强化（近战+1 / 远程+1 / 魔法+1，各 ×2）", [
		"效果：打出后对应面板永久 +1",
		"可交互：弃牌堆重洗后可再次抽到，可循环叠加；永久强化会提升所有对应类型攻击的\"命中造成伤害\"",
	])
	_add_card_block("陷阱（×3，道具卡）", [
		"使用条件：放置目标格必须为空（无单位）",
		"效果：打出后选择棋盘一个空格放置陷阱；第一个到达该格的单位受到 3 点伤害，触发后销毁",
		"可交互：同格仅能放 1 个；自己踩到也触发；被吸引/威慑/推人移动到该格同样触发；摧毁卡可拆除（默认一次拆 1 个）；猎人专属捕兽夹由技能生成，不在卡池",
	])
	_add_card_block("武器牌（近战/远程/法术武器牌，各 ×2）", [
		"效果：打出后从你的自定义武器幻化池中随机幻化一把该类型武器，确认后装备或丢弃",
		"可交互：武器只能装备一件，装备新武器时旧武器回到幻化池；被摧毁/丢弃的武器回到幻化池可再次生成；场上所有角色无法装备同一把武器（他人正在装备的武器不会幻化出来）；该类型武器均已被装备时，武器牌无效且不消耗",
		"自定义武器池：卡组编辑界面的「武器池编辑」可自定义每类型 4 把武器（未配置时默认为全部武器；点击或拖动金框/白框切换）",
		"武器一览（12 把，\"命中\" = 打出对应攻击类别的攻击卡且对目标造成伤害）：",
		"近战武器：",
		"· 斩铁：近战值+2",
		"· 霜咬：近战类攻击命中目标后，该目标下回合无法移动",
		"· 嗜血：近战类攻击命中目标且造成≥3点伤害时，回复2点HP",
		"· 突刺：近战值+1；通过移动牌位移至贴脸时，额外+3",
		"远程武器：",
		"· 长弓：远程值+1且距离衰减−1",
		"· 连弩：使用远程类攻击响应牵制时，额外扣除2点",
		"· 鹰眼：远程类攻击命中目标后，查看对方所有手牌",
		"· 毒牙：远程类攻击命中目标后，附加2层中毒（每回合−1HP，可叠加）",
		"法术武器：",
		"· 贤者之书：魔法值+2",
		"· 灼烧：魔法类攻击命中目标后，附加灼烧（每回合−2HP，持续2回合，再次命中刷新）",
		"· 时滞：魔法类攻击命中目标后，对方下回合攻击行动点−1",
		"· 共鸣：魔法类攻击命中目标后，减少对方护甲耐久2点",
	])
	_add_card_block("防具牌（近战/远程/法术防具，各 ×1）", [
		"效果：打出立即装备对应防具",
		"可交互：防具只能装备一件，装备新防具时旧防具直接消失；被摧毁后直接消失（不回池）；防具耐久规则：每次被对应类型攻击命中消耗 1 点耐久（满耐久首击完全免疫 → 之后减半 → 耗尽碎裂；被闪避或 0 伤害攻击不消耗；强化攻击命中额外 −2 耐久且不叠加正常消耗；铸甲师被动使耐久上限 +1 为 4）",
	])

# ==================== 特殊机制 ====================
func _fill_mechs():
	_add_section("移动推人",
		"贴脸时向对方方向移动，可推着对方一起移动（对方被推到的格子若放有陷阱会触发）。")
	_add_section("状态与 BUFF",
		"部分技能/武器会给角色附加状态效果，分持续回合型与永久型：\n\n· 狂化（狂战士被动）：受直接攻击后近战值+1，持续 3 回合，可叠加\n· 法师强化（法师技能）：弃 1 张手牌获得魔法强化+2，可叠加；打出魔法类攻击时消耗全部层数加伤\n· 校准（寻踪者被动）：远程/法术攻击命中叠 1 层，每层远程伤害+1，永久持续；若攻击未造成伤害则全部清空\n· 攻击行动点削减（时滞武器）：对方下回合攻击行动点 −1")
	_add_section("持续伤害（DoT）",
		"· 灼烧：每回合 −2HP，持续 2 回合，再次命中刷新时长\n· 中毒：每回合 −1HP，层数可叠加")

# ==================== 角色 ====================
func _fill_chars():
	var t = Label.new()
	t.text = "角色一览（12 名）"
	t.add_theme_font_size_override("font_size", Style.fs(42))
	t.add_theme_color_override("font_color", Style.WIN_GOLD)
	content.add_child(t)
	for char_id in Config.CHARACTER_IDS:
		var cd = Config.CHARACTER_DB[char_id]
		var p = PanelContainer.new()
		p.add_theme_constant_override("margin_left", 24)
		p.add_theme_constant_override("margin_right", 24)
		p.add_theme_constant_override("margin_top", 18)
		p.add_theme_constant_override("margin_bottom", 18)
		var vb = VBoxContainer.new()
		vb.add_theme_constant_override("separation", 10)
		p.add_child(vb)
		var head = Label.new()
		head.text = "%s　HP%d｜近战%d｜远程%d｜魔法%d" % [cd.name, cd.hp, cd.near, cd.range, cd.magic]
		head.add_theme_font_size_override("font_size", Style.fs(34))
		head.add_theme_color_override("font_color", Style.SELECTED_CYAN)
		vb.add_child(head)
		var skills = CHAR_SKILLS.get(char_id, [])
		if skills.is_empty():
			var d = Label.new()
			d.text = "技能：%s" % cd.skill_desc
			d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			d.add_theme_font_size_override("font_size", Style.fs(28))
			d.add_theme_constant_override("line_spacing", 8)
			d.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
			vb.add_child(d)
		else:
			for sk in skills:
				var l = Label.new()
				l.text = "%s %s：%s" % [sk[0], sk[1], sk[2]]
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				l.add_theme_font_size_override("font_size", Style.fs(28))
				l.add_theme_constant_override("line_spacing", 8)
				l.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
				vb.add_child(l)
		content.add_child(p)
	content.add_child(_sep())

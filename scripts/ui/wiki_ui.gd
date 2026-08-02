# wiki_ui.gd — 游戏百科界面（玩法/规则/伤害计算/角色面板）
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

@onready var content = $Scroll/Content

func _ready():
	$BackBtn.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	_fill()

# 填充百科内容：玩法/规则/伤害计算/特殊机制（静态文本）+ 角色面板（动态读取数据）
func _fill():
	_add_section("游戏玩法",
		"双人对战回合制卡牌游戏。双方各选一名角色，在 11 格横线棋盘上通过卡牌攻防博弈。\n先清空对方 HP 且对方无法复活者获胜。\n\n游戏模式：\n· 自我对战：本地双人轮流操作\n· 人机对战：简单/普通/困难三档 AI\n· 联机对战：创建房间（填服务器地址+房间号）或加入房间\n\n对战流程：BP 禁选（各禁 1 名角色 → 各选 1 名）→ 随机先手 → 战斗。")
	_add_section("回合与行动点",
		"每回合 4 个阶段：\n1. 判定阶段：结算 DoT（灼烧 -2HP/回合、中毒 -1HP/回合），检查死亡/冻结\n2. 摸牌阶段：自动抽 2 张牌\n3. 出牌阶段：自由出牌（受行动点限制）\n4. 弃牌阶段：手牌超上限必须弃到达标，也可主动弃牌\n\n行动点（每回合刷新，三种独立）：\n· 攻击 2 点（快枪手远程/穿心固定耗 2 点）\n· 位移 1 点\n· 功能 1 点（术士 +1）\n\n手牌上限 = 到己方板边距离 + 1；起手 4 张，每回合抽 2 张。")
	_add_section("伤害计算",
		"距离 = |位置差| - 1（相邻格 = 贴脸 = 0）。\n\n攻击类型伤害：\n· 近战：近战面板（必须贴脸，耗 1 攻击点）\n· 远程：远程面板 - 距离（耗 1 攻击点）\n· 魔法：魔法面板，无视距离（耗 1 攻击点）\n· 重击：近战 +3，必须贴脸（耗 2 攻击点）\n· 穿心：远程结算 +3（耗 2 攻击点；面板-距离≤0 时无法打出）\n· 吟唱：魔法 +3，无视距离（耗 2 攻击点）\n· 快枪手双发：远程/穿心固定耗 2 攻击点，造成两段伤害——\n  每段 = (面板 - 距离) / 2 向下取整（最小 0），两段各需一次响应\n\n伤害修正顺序：基础伤害 → 武器加成（类型须匹配）→ Buff 加成 → 防具减伤 → 响应效果。\n防具：3 耐久，首击完全免疫，之后减半（向下取整）。伤害最低 0。")
	_add_section("响应系统",
		"对方攻击时，你可打出一张卡响应（一次攻击限一次）：\n· 格挡：近战卡响应近战/重击 → 伤害减半\n· 牵制：远程卡响应远程/穿心/魔法/吟唱 → 扣除（你的远程面板-距离），连弩额外 -2\n· 闪避：魔法卡响应任意攻击 → 完全抵消\n· 不响应 / 无牌可应：承受全额伤害\n\n注意：快枪手双发攻击两段各需一次响应（各打一张卡）。\n响应超时（20 秒）自动视为不响应。")
	_add_section("防具与武器",
		"防具：3 类（近战/远程/法术）各 3 耐久。\n首击完全免疫 → 之后减半 → 碎裂。装备防具卡直接装上，旧防具消失。\n\n武器：3 类各 4 把，全局不重复。打出武器卡随机幻化一把未生成的武器，确认后装备或丢弃：\n· 近战：烈焰剑(近战+2)、霜咬(命中后对方下回合无法移动)、嗜血(近战≥3伤害回2HP)、突刺(近战+1，移动牌贴脸额外+3)\n· 远程：长弓(远程+1且距离衰减-1)、连弩(牵制额外-2)、鹰眼(命中后查看对方手牌)、毒牙(命中附加2层中毒可叠加)\n· 法术：贤者之书(魔法+2)、灼烧(命中后每回合-2持续2回合)、时滞(命中后对方下回合攻击行动点-1)、共鸣(本回合已出过其他攻击则+2)\n\n武器类型必须与攻击类型匹配才生效（近战武器配近战攻击等）。")
	_add_section("道具卡（通用道具）",
		"道具卡是一张通用卡：打出后选择棋盘空格放置一个道具，角色决定道具类型——\n大部分角色放「陷阱」，部分角色（如未来的猎人）放专属道具（捕兽夹等）。\n\n陷阱：踩上 -3HP 后销毁；同格仅放 1 个；自踩也生效。\n\n道具通用规则：\n· 只能放在没有单位的空格\n· 不同道具有各自的堆叠规则（如陷阱同格仅 1 个，其他类型由注册表配置）\n· 摧毁卡可点击棋盘指定格子拆除（默认一次拆 1 个；部分道具类型可声明一次清整格同类）\n· 踩上触发后道具消耗；道具伤害属于无来源伤害")
	_add_section("特殊机制",
		"· 复活：HP≤0 时弃光手牌 → 抽 4 张 → 自动使用回复卡；HP>0 复活否则永久淘汰（无限次）\n· 冻结：冻结卡命中后对方跳过下个出牌阶段（同一玩家不可连续被冻结）\n· 摧毁：盲丢对方 1 手牌 / 摧毁对方武器或防具 / 点击棋盘指定格子拆道具\n· 夺取：盲抽对方 1 张手牌\n· 移动推人：贴脸时向对方方向移动可推着对方一起走\n· 天赐：免费抽 2 张（每回合限 1 张）\n· 数值强化：近战/远程/魔法面板永久 +1（弃牌堆重洗后可循环叠加）\n· 吸引/威慑：强制对方位移 1 格（被吸引贴脸时你会后退腾位）\n· BP 禁选流程：先手禁 1 → 后手禁 1 → 先手选 → 后手选 → 随机先手开战")
	_add_characters()

# 添加一节内容（标题 + 正文）
func _add_section(title_text: String, body: String):
	var t = Label.new()
	t.text = title_text
	t.add_theme_font_size_override("font_size", 34)
	t.add_theme_color_override("font_color", Style.WIN_GOLD)
	content.add_child(t)
	var b = Label.new()
	b.text = body
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	content.add_child(b)
	content.add_child(_sep())

# 角色面板：动态读取 CHARACTER_DB，保证与游戏数据一致
func _add_characters():
	var t = Label.new()
	t.text = "角色一览"
	t.add_theme_font_size_override("font_size", 34)
	t.add_theme_color_override("font_color", Style.WIN_GOLD)
	content.add_child(t)
	for char_id in Config.CHARACTER_IDS:
		var cd = Config.CHARACTER_DB[char_id]
		var p = PanelContainer.new()
		var vb = VBoxContainer.new()
		p.add_child(vb)
		var head = Label.new()
		head.text = "%s　HP%d　近%d　远%d　魔%d" % [cd.name, cd.hp, cd.near, cd.range, cd.magic]
		head.add_theme_font_size_override("font_size", 26)
		head.add_theme_color_override("font_color", Style.SELECTED_CYAN)
		vb.add_child(head)
		var desc = Label.new()
		desc.text = "技能：%s" % cd.skill_desc
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_font_size_override("font_size", 22)
		desc.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
		vb.add_child(desc)
		content.add_child(p)
	content.add_child(_sep())

func _sep() -> HSeparator:
	var s = HSeparator.new()
	s.add_theme_constant_override("separation", 8)
	return s

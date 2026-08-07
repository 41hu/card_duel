# tutorial_manager.gd — 新手教程控制器（交互式教学关卡）
# 继承 StepRunner（通用步骤驱动：帧循环/pending 闸门/对手脚本/操作限制），
# 本类只负责教程数据（步骤剧本）与教学 UI（引导横幅/跳过/分段选择）。
# 复用真实对战（MatchState 全规则），脚本化 10 步教学：
#   刺客段 10 步：移动→暗影步→远程衰减→狂化/防具→狂战士回合(格挡)→装备突刺→
#                 突刺爆发→连击后撤→复活机制→反杀
#   猎人段 3 步：捕兽夹堆叠→摧毁演示→推人 combo
extends "res://scripts/ui/step_runner.gd"

const Style = preload("res://scripts/theme/style_const.gd")

var _guide_label: Label = null
var _skip_btn: Button = null
var _hunter_steps: Array = []
var _hunter_done: bool = false
var _burst_hp_base: int = 0  # 第7步突刺爆发：记录对手进入步骤时 HP
var _combo_hp_base: int = 0  # 第8步连击后撤：记录对手进入步骤时 HP
var _combo_pos_base: int = 0  # 第8步连击后撤：记录玩家进入步骤时位置（必须实际后撤）

func _ready():
	_build_guide_ui()
	_build_steps()
	_build_hunter_steps()
	super._ready()  # StepRunner._ready：启动第 1 步（子类 _ready 会覆盖父类，需显式调用）

# ---------------- 子类钩子 ----------------
func _set_guide_text(text: String):
	if _guide_label != null:
		_guide_label.text = text

func _on_steps_finished():
	# 猎人段（进阶）完成后不再弹分段选择，直接回主菜单
	if _hunter_done:
		_exit_tutorial()
		return
	# 分段选择：继续看进阶道具（猎人段）或返回主菜单
	_set_guide_text("刺客基础教学完成！")
	var c := Control.new()
	c.name = "SegmentChoice"
	c.z_index = 20
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.offset_left = -300; vb.offset_right = 300
	vb.offset_top = -180; vb.offset_bottom = 180
	vb.add_theme_constant_override("separation", 16)
	c.add_child(vb)
	var t := Label.new()
	t.text = "要不要继续观看进阶玩法？\n（猎人捕兽夹 · 道具堆叠 · 推人 combo）"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", Style.fs(30))
	t.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	vb.add_child(t)
	var cont := Button.new()
	cont.text = "继续观看进阶道具"
	cont.add_theme_font_size_override("font_size", Style.fs(28))
	cont.pressed.connect(func():
		c.queue_free()
		_skip_btn.text = "跳过教程"
		_enter_hunter_segment()
	)
	vb.add_child(cont)
	var back := Button.new()
	back.text = "返回主菜单"
	back.add_theme_font_size_override("font_size", Style.fs(28))
	back.pressed.connect(func():
		c.queue_free()
		_exit_tutorial()
	)
	vb.add_child(back)
	get_tree().root.add_child(c)

# ---------------- 引导 UI ----------------
func _build_guide_ui():
	_guide_label = Label.new()
	_guide_label.name = "TutorialGuide"
	_guide_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_guide_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_guide_label.add_theme_font_size_override("font_size", Style.fs(28))
	_guide_label.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_guide_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_guide_label.add_theme_constant_override("outline_size", Style.fs(4))
	# 右上角（避开棋盘/手牌/PhaseLabel 居中区域）
	_guide_label.anchor_left = 1.0; _guide_label.anchor_right = 1.0
	_guide_label.offset_left = -560; _guide_label.offset_right = -24
	_guide_label.offset_top = 24; _guide_label.offset_bottom = 300
	get_tree().root.add_child(_guide_label)

	_skip_btn = Button.new()
	_skip_btn.text = "跳过教程"
	_skip_btn.add_theme_font_size_override("font_size", Style.fs(24))
	# 左上角（不与右上角引导横幅重叠）
	_skip_btn.anchor_left = 0.0; _skip_btn.anchor_right = 0.0
	_skip_btn.offset_left = 24; _skip_btn.offset_right = Style.fs(200)
	_skip_btn.offset_top = 24; _skip_btn.offset_bottom = Style.fs(94)
	_skip_btn.pressed.connect(func(): _exit_tutorial())
	get_tree().root.add_child(_skip_btn)

func _exit_tutorial():
	_cleanup()
	if LocalGame.game != null:
		LocalGame.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _cleanup():
	if _guide_label != null and is_instance_valid(_guide_label):
		_guide_label.queue_free()
	if _skip_btn != null and is_instance_valid(_skip_btn):
		_skip_btn.queue_free()
	LocalGame.tutorial_mode = false

func _enter_hunter_segment():
	_hunter_done = true
	_finish_called = false  # 猎人段完成时允许再次收尾（直接退出）
	# 清理可能残留的分段弹窗（防叠屏挡点击）
	for old in get_tree().root.get_children():
		if old.name == "SegmentChoice":
			old.queue_free()
	_steps = _hunter_steps
	_start_step(0)

# ---------------- 刺客段 10 步剧本 ----------------
func _build_steps():
	_steps = [
		# ---- 第1步 移动（回合1）：刺客 vs 狂战士 ----
		{
			"guide": "第 1 步 —— 移动与距离\n点击手牌中的「移动」卡，向对手方向移动 1 格（其他牌本回合不能使用）。\n棋盘共 11 格，两人之间隔的格数就是距离；紧挨着（相邻两格）视为贴脸，距离为 0，此时近战才能打出。\n顶部角色面板的圆圈是行动点：攻 2 点、移 1 点、功 1 点——出牌消耗对应点数，回合开始重置。「移动」耗 1 位移点。",
			"enter": func():
				g.players[0].position = Vector2i(3, 0)
				g.players[1].position = Vector2i(7, 0)
				# 初始手牌（用户配置）
				deal_hand(0, ["move", "range_armor", "near", "range", "near", "near"])
				deal_hand(1, ["attract", "near", "range", "near_weapon"])
				# 狂战士武器池只留斩铁
				g.used_weapon_ids = ["frost_bite", "bloodthirst", "lunge"]
				battle_state_refresh(),
			"check": func():
				return g.players[0].position.x >= 4,
			"allow_cards": ["move"],
			"allow_skills": [],
			"allow_end_turn": false,
			"move_dirs": [1],
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- 第2步 暗影步（同一回合）----
		{
			"guide": "第 2 步 —— 暗影步技能\n刺客的被动技：每回合可免费移动 1 格（不消耗位移点）。\n点击左侧技能栏的「暗影步」向对手方向移动。注意：暗影步不能推人。",
			"enter": func():
				battle_state_refresh(),
			"check": func():
				return g.players[0].position.x >= 5,
			"allow_cards": [],
			"allow_skills": ["assassin_move"],
			"allow_end_turn": false,
			"move_dirs": [1],
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- 第3步 远程攻击（同一回合）----
		{
			"guide": "第 3 步 —— 远程攻击与距离衰减\n远程伤害 = 远程面板 − 距离（最低 0）。\n你现在距对手 1 格，打出「远程」：耗 1 攻击点，伤害 = 4 − 1 = 3。越近伤害越高，贴脸（距离 0）最高。",
			"enter": func():
				battle_state_refresh(),
			"check": func():
				return g.players[1].hp < 28,
			"allow_cards": ["range"],
			"allow_skills": [],
			"allow_end_turn": false,
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- 第4步 狂化讲解 + 远程防具（同一回合）----
		{
			"guide": "第 4 步 —— 狂战士的狂化与远程防具\n你刚才的远程命中了狂战士——他的被动「狂化」触发了（近战+1，可叠加，越打越强）。\n点击对手名字（面板顶部）可查看他的技能描述。\n然后装备手牌中的「远程防具」：满耐久可完全免疫一次远程攻击，之后减半。",
			"enter": func():
				battle_state_refresh(),
			"check": func():
				return not g.players[0].armor.is_empty(),
			"allow_cards": ["range_armor"],
			"allow_skills": [],
			"allow_end_turn": false,
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- 第5步 结束回合 → 狂战士回合（玩家格挡教学）----
		{
			"guide": "第 5 步 —— 狂战士回合\n点击「结束出牌」——先到弃牌阶段：手牌上限 = 你离己方板边的格数 + 1（顶部面板「手:当前/上限」），超上限必须弃到上限，再点「确认弃牌」。\n轮到狂战士行动：远程攻击（你的「远程防具」满耐久挡掉，看下方战斗日志）、吸引你、装备「斩铁」、近战攻击。\n近战攻击时请用「近战」卡格挡（伤害减半）。",
			"enter": func():
				deal_hand(1, ["near", "near", "attract", "range", "near_weapon"])
				g.players[1].ap_attack = 2
				g.players[1].ap_function = 1  # 武器卡免费（ap=0），吸引耗 1 功能点
				battle_state_refresh(),
			"check": func():
				# 玩家完成格挡响应（跨玩家结束回合 + 狂战士脚本回合）
				return g.stats[0].get("responses", 0) > 0,
			"allow_cards": [],
			"allow_skills": [],
			"allow_end_turn": true,
			"wait_turn_end": true,
			"force_response": true,
			"manual_discard": true,  # 本步弃牌阶段玩家手动点「确认弃牌」（教学弃牌阶段）
			"opp_actions": func():
				return [
					{"action": "play_card", "card_uid": 9003},  # 远程（打防具免伤）
					{"action": "play_card", "card_uid": 9002},  # 吸引
					{"action": "play_card", "card_uid": 9004},  # 装备斩铁
					{"action": "play_card", "card_uid": 9000},  # 近战（引导玩家格挡）
				],
		},
		# ---- 第6步 刺客装备突刺 ----
		{
			"guide": "第 6 步 —— 装备突刺武器\n点击手牌中的武器卡装备「突刺」（近战+1；本回合通过移动贴脸后额外+3）。\n装备后进入下一步。",
			"enter": func():
				# 回合开始一次性补发武器+移动（装备后直接移动爆发，不再用一张发一张）
				add_cards(0, ["near_weapon", "move"])
				# 武器池锁定突刺（排除其他近战）
				g.used_weapon_ids = ["iron_cutter", "frost_bite", "bloodthirst"]
				battle_state_refresh(),
			"check": func():
				return not g.players[0].weapon.is_empty(),
			"allow_cards": ["near_weapon"],
			"allow_skills": [],
			"allow_end_turn": false,
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- 第7步 移动贴脸 + 突刺近战爆发 ----
		{
			"guide": "第 7 步 —— 突刺爆发\n先使用「移动」贴脸（本回合移动贴脸会触发突刺额外+3），再打出「近战」：\n伤害 = 7（近战）+ 1（突刺）+ 3（移动贴脸）= 11 爆发伤害！",
			"enter": func():
				_burst_hp_base = g.players[1].hp
				battle_state_refresh(),
			"check": func():
				return g.players[1].hp < _burst_hp_base,
			"allow_cards": ["move", "near"],
			"allow_skills": [],
			"allow_end_turn": false,
			"move_dirs": [1],
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- 第8步 连击后撤 → 结束回合 → 狂战士两刀复活 ----
		{
			"guide": "第 8 步 —— 连击与后撤\n再打一张「近战」命中（突刺加成下伤害可观），然后用「暗影步」向后撤（远离对手），点击「结束出牌」。\n轮到狂战士：他会吸引你并连打两刀近战——你手里没有能格挡的卡，只能点「无法响应（跳过）」。挨下两刀后 HP 归零——看下方战斗日志的复活流程。",
			"enter": func():
				_combo_hp_base = g.players[1].hp
				_combo_pos_base = g.players[0].position.x
				# 狂战士脚本牌（吸引 + 两刀近战，打死触发复活）
				deal_hand(1, ["attract", "near", "near"])
				g.players[1].ap_attack = 2
				g.players[1].ap_function = 1
				# 复活牌堆：清空共享牌堆只放确定牌，保证玩家复活抽到 2 张回复卡（+10 起死回生），
				# 否则从随机牌堆抽 4 张可能无回复卡 → 复活失败淘汰 → 教程卡死
				g.card_systems[0].deck.clear()
				g.card_systems[0].deck.append({"uid": 5000, "type_id": "heal_5"})
				g.card_systems[0].deck.append({"uid": 5001, "type_id": "heal_5"})
				g.card_systems[0].deck.append({"uid": 5002, "type_id": "near"})
				g.card_systems[0].deck.append({"uid": 5003, "type_id": "near"})
				battle_state_refresh(),
			"check": func():
				# 玩家必须完成近战命中 + 暗影步后撤（贴脸位置不算后撤，未后撤不能结束回合）
				return g.players[1].hp < _combo_hp_base \
					and g.players[0].position.x < _combo_pos_base,
			"allow_cards": ["near"],
			"allow_skills": ["assassin_move"],
			"allow_end_turn": false,
			"move_dirs": [-1],
			"wait_turn_end": true,
			"opp_actions": func():
				return [
					{"action": "play_card", "card_uid": 9000},  # 吸引
					{"action": "play_card", "card_uid": 9001},  # 近战1
					{"action": "play_card", "card_uid": 9002},  # 近战2
				],
		},
		# ---- 第9步 复活检测（狂战士两刀后，等玩家复活完成）----
		{
			"guide": "第 9 步 —— 复活机制\nHP 归零 → 自动弃光手牌 → 抽 4 张 → 自动使用回复卡 → HP 为正则复活（否则淘汰）。\n看下方战斗日志了解你倒下后发生了什么。",
			"enter": func():
				battle_state_refresh(),
			"check": func():
				return g.stats[0].get("resurrected", 0) > 0,
			"allow_cards": [],
			"allow_skills": [],
			"allow_end_turn": true,
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- 第10步 玩家近战反杀 ----
		{
			"guide": "第 10 步 —— 反杀！\n复活成功！狂战士只剩少量 HP——用「近战」反杀他（突刺加成下伤害远超他的血量）。",
			"enter": func():
				add_cards(0, ["near"])
				# 清空狂战士牌堆（保证反杀后复活失败淘汰）
				g.card_systems[1].deck.clear()
				battle_state_refresh(),
			"check": func():
				return g.phase == Config.Phase.GAME_OVER and g.game_result.get("winner", -1) == 0,
			"allow_cards": ["near"],
			"allow_skills": [],
			"allow_end_turn": false,
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
	]

func _build_hunter_steps():
	_hunter_steps = [
		# ---- 进阶1 捕兽夹堆叠（切猎人，回合1）----
		{
			"guide": "进阶 1/3 —— 道具与堆叠（猎人）\n现在你是猎人，道具卡放的是「捕兽夹」（踩上 -3HP，可无限堆叠）。\n先点技能「埋伏」选「穿心」：连点 4、5 两格放 2 个夹子；\n再点手牌「陷阱」卡，叠放到 4 或 5 格（同格叠放：一张摧毁卡会拆掉整格全部夹子）。",
			"enter": func():
				_switch_to_hunter_segment()
				_allowed_trap_pos = [Vector2i(4, 0), Vector2i(5, 0)],
			"check": func():
				return _count_snares() >= 3,
			"allow_cards": ["trap"],
			"allow_skills": ["hunter_ambush"],
			"wait_turn_end": true,
			"opp_actions": func(): return [],
		},
		# ---- 进阶2 摧毁演示（观察）----
		{
			"guide": "进阶 2/3 —— 摧毁卡可以拆除道具\n点击「结束出牌」，对手会打出「摧毁」卡拆掉你叠放的夹子。\n注意：一张摧毁卡会拆掉目标格的全部堆叠——这就是堆叠的风险与道具的反制手段。",
			"enter": func():
				_allowed_trap_pos = []
				deal_hand(0, [])
				deal_hand(1, ["destroy"])
				g.players[1].ap_function = 3  # 摧毁卡耗 3 功能点
				battle_state_refresh(),
			"check": func():
				return _count_snares() < 3,
			"allow_cards": [],
			"allow_skills": [],
			"allow_end_turn": true,
			"wait_turn_end": true,
			"opp_actions": func():
				# 拆堆叠最多的格子（教学引导说"拆掉叠放的夹子"）
				var best_pos = null
				var best_count = 0
				var counts = {}
				for it in g.items:
					if it.item_type != "snare": continue
					var key = g.movement.geometry.to_dict(it.position)
					counts[key] = counts.get(key, 0) + 1
					if counts[key] > best_count:
						best_count = counts[key]
						best_pos = key
				if best_pos != null:
					return [{"action": "play_card", "card_uid": 9000,
						"extra": {"destroy_target": "trap", "trap_pos": best_pos}}]
				return [],
		},
		# ---- 进阶3 推人 combo（回合3）----
		{
			"guide": "进阶 3/3 —— 推人 combo（最终演示）\n先点「陷阱」把捕兽夹放在对手身后那一格（第 7 格，威慑会把他推去那里），\n再点「威慑」把他推进夹子：-3HP。这就是道具 + 推人的 combo。",
			"enter": func():
				_allowed_trap_pos = [Vector2i(7, 0)]
				deal_hand(0, ["trap", "deter"])
				deal_hand(1, [])
				g.players[0].ap_function = 3  # 威慑卡耗 3 功能点（基础只有 1）
				g.players[1].position = Vector2i(6, 0)
				battle_state_refresh(),
			"check": func():
				return g.players[1].hp < 26,
			"allow_cards": ["trap", "deter"],
			"allow_skills": [],
			"allow_end_turn": true,
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
	]

func _switch_to_hunter_segment():
	g.init_match("hunter", "fighter", 0)
	g._start_game()
	g.players[0].position = Vector2i(3, 0)
	g.players[1].position = Vector2i(8, 0)
	deal_hand(0, ["pierce", "trap", "trap"])
	deal_hand(1, [])
	battle_state_refresh()

func _count_snares() -> int:
	var n = 0
	for it in g.items:
		if it.item_type == "snare": n += 1
	return n

# tutorial_manager.gd — 新手教程控制器（交互式教学关卡）
# 复用真实对战（MatchState 全规则），脚本化 9 步教学，每步 = 一个完整回合：
#   刺客段 6 步：①移动 ②暗影步 ③远程伤害计算 ④突刺武器 ⑤防具与响应 ⑥复活反杀
#   猎人段 3 步：⑦捕兽夹堆叠 ⑧摧毁演示 ⑨推人 combo
# 每步手牌只发当前步骤需要的牌；对手永不响应；玩家按引导操作（乱点被限制）
extends Node

const Style = preload("res://scripts/theme/style_const.gd")

var battle: Control = null
var g = null
var player_idx: int = 0
var opp_idx: int = 1

var _step: int = -1
var _steps: Array = []
var _hunter_steps: Array = []
var _pending_step: int = -1   # 等待完整回合结束后的下一步
var _pending_turn: int = -1    # 设置 pending 时的回合号（等新回合才触发）
var _guide_label: Label = null
var _skip_btn: Button = null
var _opp_actions: Array = []
var _opp_turn_handled: bool = false
var _revive_hint_shown: bool = false
var _opp_attack_count: int = 0
var _discard_base: int = 0
var _weapon_flag: bool = false
var _weapon_discard_base: int = 0
var _step9_hp_base: int = 0
var _step9_pos_base: int = 0
var _step7_hp_base: int = 0
var _hunter_done: bool = false
var _finish_called: bool = false  # 防重入：GAME_OVER 后步骤9 check 每帧满足，只允许弹一次分段窗

func _ready():
	_build_guide_ui()
	_build_steps()
	_build_hunter_steps()
	_start_step(0)

func _process(_delta):
	if g == null: return
	if _step < 0 or _step >= _steps.size(): return
	# 教程自动通过弃牌阶段（不弹手动弃牌，避免玩家乱弃破坏教学流程）；
	# 步骤⑤（索引4）玩家手动点击"确认弃牌"除外；对手弃牌始终自动确认（否则回合卡死）。
	# 注意：手牌超上限时 confirm_discard 会拒绝（必须先弃），这里自动弃掉超限的牌
	if g.waiting_for_discard:
		var cur = g.current_player
		var auto = (cur == opp_idx) or (cur == player_idx and _step != 4)
		if auto:
			var cs = g.card_systems[cur]
			var limit = g.movement.get_hand_limit(cur)
			var need = cs.hand.size() - limit
			var uids: Array = []
			if need > 0:
				for i in range(min(need, cs.hand.size())):
					uids.append(cs.hand[i].uid)
			g.confirm_discard(cur, uids)
			return
	# 步骤④ 顺序要求：装备武器后记录弃牌基准（之后打出重击才算）
	if _step == 3 and not g.players[0].weapon.is_empty() and not _weapon_flag:
		_weapon_flag = true
		_weapon_discard_base = g.card_systems[0].discard.size()
	# 等待完整回合：步骤已完成，玩家结束回合后（新回合 ACTION）进入下一步
	# 注意：pending 时对手回合仍需执行脚本（不能 return 跳过，否则卡死）
	if _pending_step >= 0:
		# 只有进入新回合（玩家 ACTION）才触发下一步，否则刚设置 pending 的同一回合
		# 就会立即切换步骤，导致对手脚本回合被跳过（"一直在循环"问题）
		if g.phase == Config.Phase.PLAYER_TURN and g.current_player == player_idx \
				and g.turn_phase == Config.TurnPhase.ACTION \
				and g.turn_number > _pending_turn:
			var n = _pending_step
			_pending_step = -1
			_start_step(n)
			return
		if g.phase == Config.Phase.PLAYER_TURN and g.current_player == player_idx:
			_guide_label.text = "做得对！点击「结束出牌」进入下一步"
			return
		if g.phase == Config.Phase.PLAYER_TURN and g.current_player == opp_idx:
			_guide_label.text = "本回合完成，等待对手行动…"
	# 对手回合：按脚本行动（pending 与非 pending 都执行；必须到出牌阶段 ACTION 才执行，
	# 否则判定/抽牌阶段提前触发会失败并标记 handled 导致不行动）
	if g.phase == Config.Phase.PLAYER_TURN and g.current_player == opp_idx \
			and g.turn_phase == Config.TurnPhase.ACTION:
		if not _opp_turn_handled:
			_opp_turn_handled = true
			_run_opp_actions()
		elif not _opp_actions.is_empty() and not g.response_pending:
			_run_opp_actions()  # 响应结算后继续执行剩余脚本动作
		elif _opp_actions.is_empty() and not g.response_pending:
			_try_end_opp_turn()  # 脚本执行完且无响应等待 → 结束回合
	if g.current_player != opp_idx:
		_opp_turn_handled = false
	# 步骤⑥ 特殊：玩家被打死后（复活完成）才提示复活机制
	if _step == 5 and g.stats[0].get("resurrected", 0) > 0 and not _revive_hint_shown:
		_revive_hint_shown = true
		_guide_label.text = "复活成功！刚才你倒下时发生了什么？看右侧战斗日志：\nHP 归零 → 自动弃光手牌 → 抽 4 张 → 自动使用回复卡 → HP 为正则复活（否则淘汰）。\n现在对手变成木桩不会还手，用你的手牌反杀他！"
	# 当前步骤完成检测
	var s: Dictionary = _steps[_step]
	if s.get("check", Callable()).call():
		if s.get("wait_turn_end", false):
			_pending_step = _step + 1
			_pending_turn = g.turn_number  # 记录当前回合，等玩家结束回合后（新回合）触发
			_guide_label.text = "做得对！点击「结束出牌」进入下一步"
		else:
			_start_step(_step + 1)

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

# ---------------- 步骤系统 ----------------
func _start_step(i: int):
	if i >= _steps.size():
		_finish_tutorial()
		return
	_step = i
	var s: Dictionary = _steps[i]
	_guide_label.text = s.get("guide", "")
	if s.has("enter"):
		s["enter"].call()
	_opp_actions = []
	_opp_turn_handled = false
	if s.has("opp_actions"):
		_opp_actions = s["opp_actions"].call()

func _finish_tutorial():
	if _finish_called: return  # 防重入：GAME_OVER 后 check 每帧满足，重复弹窗会叠屏挡住点击
	_finish_called = true
	# 猎人段（进阶）完成后不再弹分段选择，直接回主菜单
	if _hunter_done:
		_exit_tutorial()
		return
	# 分段选择：继续看进阶道具（猎人段）或返回主菜单
	_guide_label.text = "刺客基础教学完成！"
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

func _enter_hunter_segment():
	_hunter_done = true
	_finish_called = false  # 猎人段完成时允许再次进入 _finish_tutorial（直接退出）
	# 清理可能残留的分段弹窗（防叠屏挡点击）
	for old in get_tree().root.get_children():
		if old.name == "SegmentChoice":
			old.queue_free()
	_steps = _hunter_steps
	_start_step(0)

func _run_opp_actions():
	# 同一对手回合执行完所有脚本动作（如 ⑤ 的两刀）
	print("[TUT] opp turn start, actions=%s" % str(_opp_actions))
	while not _opp_actions.is_empty() and g.current_player == opp_idx \
			and not g.response_pending and not g.waiting_for_discard:
		var act = _opp_actions[0]
		_opp_actions.remove_at(0)
		var r = g.process_action(opp_idx, act)
		print("[TUT] opp act %s -> %s" % [JSON.stringify(act), JSON.stringify(r)])
		if not r.get("success", false):
			break
	_try_end_opp_turn()

func _try_end_opp_turn():
	if g.current_player == opp_idx and not g.waiting_for_discard:
		g.process_action(opp_idx, {"action": "end_turn"})

# ---------------- 操作限制 ----------------
# allow_cards/allow_skills：["*"]=不限制；[]=禁止一切；其他=只允许列出的类型
func allow_card_click(uid: int, type_id: String) -> bool:
	if _step < 0 or _step >= _steps.size(): return false
	var allow: Array = _steps[_step].get("allow_cards", ["*"])
	if allow.is_empty(): return false
	if "*" in allow: return true
	return type_id in allow

func allow_skill(sk_id: String) -> bool:
	if _step < 0 or _step >= _steps.size(): return false
	var allow: Array = _steps[_step].get("allow_skills", ["*"])
	if allow.is_empty(): return false
	if "*" in allow: return true
	return sk_id in allow

func allow_end_turn() -> bool:
	if _pending_step >= 0: return true  # 步骤已完成，允许结束回合进入下一步
	if _step < 0 or _step >= _steps.size(): return false
	return bool(_steps[_step].get("allow_end_turn", false))  # 默认完成步骤前不能结束

func allowed_move_dirs() -> Array:
	if _step < 0 or _step >= _steps.size(): return [1, -1]
	var dirs: Array = _steps[_step].get("move_dirs", [])
	if dirs.is_empty(): return [1, -1]
	return dirs

func force_response() -> bool:
	if _step < 0 or _step >= _steps.size(): return false
	return bool(_steps[_step].get("force_response", false))

# 响应接管：返回 true 表示教程已自动处理（不弹响应窗口）
# 规则：对手永不响应；玩家被攻击正常弹窗（含复活步骤的"无法响应"教学）
func handle_response_needed() -> bool:
	if g == null: return false
	if g._response_attacker < 0: return false
	var defender = 1 - g._response_attacker
	if defender == opp_idx:
		g.process_response(opp_idx, false)  # 对手被攻击：自动不响应
		return true
	return false

# ---------------- 教学工具 ----------------
func deal_hand(idx: int, types: Array):
	var cs = g.card_systems[idx]
	cs.hand.clear()
	for i in range(types.size()):
		cs.hand.append({"uid": 9000 + i, "type_id": types[i]})

# 补发卡到手牌（不清空，保留初始手牌贯穿教学）
func add_cards(idx: int, types: Array):
	var cs = g.card_systems[idx]
	var base = 9000
	for c in cs.hand:
		if c.uid >= base: base = c.uid + 1
	for i in range(types.size()):
		cs.hand.append({"uid": base + i, "type_id": types[i]})

func battle_state_refresh():
	if battle != null and battle.has_method("_refresh_all"):
		battle._refresh_all(g.get_full_state())

# ---------------- 9 步剧本（每步=一个完整回合） ----------------
func _build_steps():
	_steps = [
		# ---- ①移动（回合1）：刺客 vs 狂战士 ----
		{
			"guide": "第 1 步 —— 移动与距离\n点击手牌中的「移动」卡，向对手方向移动 1 格（其他牌本回合不能使用）。\n棋盘共 11 格，两人之间隔的格数就是距离；紧挨着（相邻两格）视为贴脸，距离为 0，此时近战才能打出。",
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
		# ---- ②暗影步（同一回合）----
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
		# ---- ③远程攻击（同一回合）----
		{
			"guide": "第 3 步 —— 远程攻击与距离衰减\n远程伤害 = 远程面板 − 距离（最低 0）。\n你现在距对手 1 格，打出「远程」：伤害 = 4 − 1 = 3。越近伤害越高，贴脸（距离 0）最高。",
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
		# ---- ④狂化讲解 + 远程防具（同一回合）----
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
		# ---- ⑤结束回合 → 狂战士回合格挡（合并：t1 玩家结束后狂战士立即行动）----
		{
			"guide": "第 5 步 —— 狂战士回合\n点击「结束出牌」（弃牌阶段点「确认弃牌」）——轮到狂战士行动：远程攻击（你的「远程防具」满耐久挡掉，看右侧日志）、吸引你、装备「斩铁」、近战攻击。\n近战攻击时请用「近战」卡格挡（伤害减半）。",
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
			"opp_actions": func():
				return [
					{"action": "play_card", "card_uid": 9003},  # 远程（打防具免伤）
					{"action": "play_card", "card_uid": 9002},  # 吸引
					{"action": "play_card", "card_uid": 9004},  # 装备斩铁
					{"action": "play_card", "card_uid": 9000},  # 近战（引导玩家格挡）
				],
		},
		# ---- ⑦刺客装备突刺 ----
		{
			"guide": "第 7 步 —— 装备突刺武器\n点击手牌中的武器卡装备「突刺」（近战+1；本回合通过移动贴脸后额外+3）。\n装备后进入下一步。",
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
		# ---- ⑧移动贴脸 + 突刺近战爆发 ----
		{
			"guide": "第 8 步 —— 突刺爆发\n先使用「移动」贴脸（本回合移动贴脸会触发突刺额外+3），再打出「近战」：\n伤害 = 7（近战）+ 1（突刺）+ 3（移动贴脸）= 11 爆发伤害！",
			"enter": func():
				_step7_hp_base = g.players[1].hp
				battle_state_refresh(),
			"check": func():
				return g.players[1].hp < _step7_hp_base,
			"allow_cards": ["move", "near"],
			"allow_skills": [],
			"allow_end_turn": false,
			"move_dirs": [1],
			"wait_turn_end": false,
			"opp_actions": func(): return [],
		},
		# ---- ⑨连击后撤 → 结束回合 → 狂战士两刀复活 ----
		{
			"guide": "第 9 步 —— 连击与后撤\n再打一张「近战」命中（突刺加成下伤害可观），然后用「暗影步」向后撤（远离对手），点击「结束出牌」。\n轮到狂战士：他会吸引你并连打两刀近战——你手里没有能格挡的卡，只能点「无法响应（跳过）」。挨下两刀后 HP 归零——看右侧日志的复活流程。",
			"enter": func():
				_step9_hp_base = g.players[1].hp
				_step9_pos_base = g.players[0].position.x
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
				return g.players[1].hp < _step9_hp_base \
					and g.players[0].position.x < _step9_pos_base,
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
		# ---- ⑩复活检测（狂战士两刀后，等玩家复活完成）----
		{
			"guide": "第 10 步 —— 复活机制\nHP 归零 → 自动弃光手牌 → 抽 4 张 → 自动使用回复卡 → HP 为正则复活（否则淘汰）。\n看右侧战斗日志了解你倒下后发生了什么。",
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
		# ---- ⑪玩家近战反杀 ----
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
		# ---- ⑦捕兽夹堆叠（切猎人，回合1）----
		{
			"guide": "进阶 1/3 —— 道具与堆叠（猎人）\n现在你是猎人，道具卡放的是「捕兽夹」（踩上 -3HP，可堆叠放置）。\n先用「穿心」埋伏（耗2攻击点放 2 个夹子），再用手牌的道具卡同格叠放 1 个。",
			"enter": func():
				_switch_to_hunter_segment(),
			"check": func():
				return _count_snares() >= 3,
			"allow_cards": ["trap"],
			"allow_skills": ["hunter_ambush"],
			"wait_turn_end": true,
			"opp_actions": func(): return [],
		},
		# ---- ⑧摧毁演示（观察）----
		{
			"guide": "进阶 2/3 —— 摧毁卡可以拆除道具\n点击「结束出牌」，对手会打出「摧毁」卡。\n注意：堆叠的捕兽夹会被一张摧毁卡全部拆掉——这就是堆叠的风险与道具的反制手段。",
			"enter": func():
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
				for it in g.items:
					if it.item_type == "snare":
						return [{"action": "play_card", "card_uid": 9000,
							"extra": {"destroy_target": "trap", "trap_pos": g.movement.geometry.to_dict(it.position)}}]
				return [],
		},
		# ---- ⑨推人 combo（回合3）----
		{
			"guide": "进阶 3/3 —— 推人 combo（最终演示）\n先点「陷阱」把捕兽夹放在对手身后一格（他被推去的方向），\n再点「威慑」把他推进夹子：-3HP。这就是道具 + 推人的 combo。",
			"enter": func():
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

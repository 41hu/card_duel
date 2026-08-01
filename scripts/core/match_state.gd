# ============================================================
# match_state.gd — 对局状态机（服务端权威，唯一真实数据源）
# ============================================================
extends RefCounted

const CombatSys = preload("res://scripts/core/combat_system.gd")
const MovementSys = preload("res://scripts/core/movement_system.gd")
const EquipmentSys = preload("res://scripts/core/equipment_system.gd")
const StatusSys = preload("res://scripts/core/status_system.gd")
const BPSys = preload("res://scripts/core/bp_system.gd")
const CardSys = preload("res://scripts/core/card_system.gd")

const ACTION_TIME = 60
const DISCARD_TIME = 30

var card_systems: Array = []
var combat
var movement
var equipment
var status
var bp

var players: Array = []
var phase: int = Config.Phase.MAIN_MENU
var turn_phase: int = Config.TurnPhase.JUDGMENT
var current_player: int = 0
var turn_number: int = 0
var first_player: int = 0
var used_weapon_ids: Array = []
var items: Array = []  # 地格道具（原 traps，泛化为道具系统；结构 {item_type, position, owner}）
var action_log: Array = []
var waiting_for_weapon_choice: int = -1
var pending_weapon_id: String = ""
var response_pending: bool = false
var attacker_last_damage: int = 0
var attacker_last_type: int = 0
var pending_attack_card: String = ""
var pending_attack_uid: int = -1
var pending_attack_segment: int = 0      # 多段攻击：当前段（1 起）
var pending_attack_segments: int = 1     # 多段攻击：总段数（1 = 单段，现有行为）
var game_result: Dictionary = {}
# 对战统计（结算页展示 + 称号判定）：每玩家一个字典
var stats: Array = []
# 本回合是否通过移动牌位移到贴脸（突刺武器额外+3 的判定标记）
var _moved_to_adjacent_this_turn: bool = false
# 本次攻击防具是否生效（实际造成伤害时消耗耐久，闪避/0伤害不消耗）
var _armor_hit: bool = false
# 调试发牌的 uid 计数器（保证唯一，与正常卡 uid 0-77 隔离）
var _cheat_uid_counter: int = -1000
var char_skills
var card_effects
var item_system
var waiting_for_discard: bool = false
var discard_count: int = 0
var _reveal_to: int = -1
var _reveal_from: int = -1
var _pending_formula: String = ""

var _action_deadline: int = 0
var _discard_deadline: int = 0
const RESPONSE_TIME = 20  # 响应窗口超时秒数（超时默认不响应）

signal state_changed(data: Dictionary)
signal weapon_prompt(player_idx: int, weapon: Dictionary)
signal response_needed(defender_idx: int, attack_info: Dictionary)
signal game_ended(result: Dictionary)
signal bp_state_changed(bp_state: Dictionary)

func _init():
	combat = CombatSys.new(self)
	movement = MovementSys.new(self)
	equipment = EquipmentSys.new(self)
	status = StatusSys.new(self)
	bp = BPSys.new(self)
	item_system = preload("res://scripts/core/item_system.gd").new(self)
	char_skills = preload("res://scripts/core/character_skills.gd").new(self)
	card_effects = preload("res://scripts/core/card_effects.gd").new(self)

func init_match(p1_char_id: String, p2_char_id: String, bp_first: int = -1):
	var p1_char = Config.CHARACTER_DB[p1_char_id]
	var p2_char = Config.CHARACTER_DB[p2_char_id]
	players = [
		_create_player(0, p1_char_id, p1_char),
		_create_player(1, p2_char_id, p2_char),
	]
	var shared_deck = Config.build_initial_deck()
	shared_deck.shuffle()
	var shared_discard = []
	card_systems = [
		CardSys.new(shared_deck, shared_discard),
		CardSys.new(shared_deck, shared_discard),
	]
	used_weapon_ids.clear()
	items.clear()
	action_log.clear()
	turn_number = 0
	waiting_for_weapon_choice = -1
	response_pending = false
	waiting_for_discard = false
	discard_count = 0
	game_result = {}
	stats = [
		{"damage_dealt": 0, "damage_taken": 0, "damage_from_attack": 0, "damage_from_trap": 0, "damage_from_dot": 0, "heal_total": 0, "moves": 0, "responses": 0, "resurrected": 0, "cards_played": {}, "card_total": 0},
		{"damage_dealt": 0, "damage_taken": 0, "damage_from_attack": 0, "damage_from_trap": 0, "damage_from_dot": 0, "heal_total": 0, "moves": 0, "responses": 0, "resurrected": 0, "cards_played": {}, "card_total": 0},
	]
	_action_deadline = 0
	_discard_deadline = 0
	_moved_to_adjacent_this_turn = false
	_cheat_uid_counter = -1000
	first_player = bp_first if bp_first >= 0 else randi() % 2
	current_player = first_player
	phase = Config.Phase.BP_PHASE
	bp.reset()
	for i in range(2):
		card_systems[i].draw_cards(4)

func _create_player(idx: int, char_id: String, char_data: Dictionary) -> Dictionary:
	return {
		index=idx, char_id=char_id,
		hp=char_data.hp, max_hp=char_data.hp,
		near_power=char_data.near, range_power=char_data.range, magic_power=char_data.magic,
		position=(3 if idx == 0 else 7),
		weapon={}, armor={}, buffs=[], dots=[],
		frozen=false, frozen_lockout=false, frozen_move=false,
		damage_reduction_used=false, skill_used_this_turn=false, free_move_used=false,
		damage_bonus={},
		combo_attacks_this_turn=[],
		upgrades={},
		skill_counts={},
		skills_used=[],
		used_function_card=false,
		pending_swordsman_skill=false,
	}

func get_player(idx: int): return players[idx]
func get_items() -> Array: return items

func do_bp_action(player_idx: int, action: String, char_id: String) -> bool:
	var ok = bp.execute_action(player_idx, action, char_id)
	if ok and bp.is_done():
		var chars = bp.picked_chars
		init_match(chars[0], chars[1], bp._bp_first)
		_start_game()
	return ok

func _start_game():
	phase = Config.Phase.PLAYER_TURN
	turn_phase = Config.TurnPhase.JUDGMENT
	turn_number = 1
	current_player = first_player
	_judgment_phase()

func _judgment_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.JUDGMENT
	var player = players[current_player]
	if player.dots.size() > 0:
		# 先快照本回合将造成伤害的 DoT 类型（牧师净化用）
		var dot_types: Array = []
		for dot in player.dots:
			if not dot.type in dot_types:
				dot_types.append(dot.type)
		var dd = combat.apply_dot_damage(current_player)
		if dd.damage > 0:
			player.hp -= dd.damage
			# 伤害来源统计：DoT 计入受到伤害；施放者（source）计入造成伤害
			stats[current_player]["damage_taken"] += dd.damage
			stats[current_player]["damage_from_dot"] += dd.damage
			for ds in dd.dot_stats:
				if ds.source >= 0:
					stats[ds.source]["damage_dealt"] += ds.damage
			var detail_str = "、".join(dd.details)
			add_log(current_player, "%s共%d点伤害" % [detail_str, dd.damage])
			# 角色被动：受到 DoT 伤害后的处理（牧师清除对应 DoT）
			char_skills.on_dot_damage(current_player, dot_types)
			if player.hp <= 0:
				_handle_death(current_player)
				if phase == Config.Phase.GAME_OVER: return
	status.on_turn_start(current_player)
	char_skills.on_opponent_turn_start(current_player)
	_draw_phase()

func _draw_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.DRAW
	card_systems[current_player].draw_cards(char_skills.draw_count(current_player))
	add_log(current_player, "抽了2张牌")
	_action_phase()

func _action_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.ACTION
	_moved_to_adjacent_this_turn = false  # 每回合重置突刺贴脸标记
	var player = players[current_player]
	if player.frozen:
		add_log(current_player, "被冻结，跳过出牌阶段")
		status.clear_freeze(current_player)
		player.frozen_lockout = false  # 冻结已生效一次，解锁允许之后再次被冻结
		_discard_phase()
		return
	char_skills.on_turn_start(current_player)
	_action_deadline = Time.get_ticks_msec() + ACTION_TIME * 1000
	state_changed.emit(get_full_state())

func process_action(player_idx: int, action_data: Dictionary) -> Dictionary:
	if player_idx != current_player: return {success=false, msg="不是你的回合"}
	if waiting_for_discard:
		var act = action_data.get("action", "")
		if act == "discard_one": return {success=discard_one(player_idx, int(action_data.get("card_uid", -1)))}
		if act == "confirm_discard": confirm_discard(player_idx, _int_array(action_data.get("card_uids", []))); return {success=true}
		return {success=false, msg="弃牌阶段请先弃牌或确认结束"}
	if phase != Config.Phase.PLAYER_TURN or turn_phase != Config.TurnPhase.ACTION:
		return {success=false, msg="当前不在出牌阶段"}
	var action = action_data.get("action", "")
	match action:
		"play_card": return _do_play_card(player_idx, action_data)
		"end_turn": _discard_phase(); return {success=true, msg="结束出牌"}
		"use_skill":
			if action_data.get("skill", "") == "_cheat": return _cheat_card(player_idx, action_data.get("type_id", ""))
			if action_data.get("skill", "") == "_debug_end": return _debug_end(player_idx, action_data.get("win", true))
			return _handle_skill(player_idx, action_data.get("skill", ""), action_data)
		"swordsman_choice": return _handle_swordsman_choice(player_idx, action_data)
	return {success=false, msg="未知行动"}

func _do_play_card(player_idx: int, data: Dictionary) -> Dictionary:
	var card_uid = int(data.get("card_uid", -1))
	var extra = data.get("extra", {})
	var from_idx = player_idx
	if extra.has("from_opponent") and extra.from_opponent:
		from_idx = 1 - player_idx
	var card_sys = card_systems[from_idx]
	if not card_sys.has_card(card_uid): return {success=false, msg="手牌中没有此卡"}
	var card = {}
	for c in card_sys.hand:
		if c.uid == card_uid: card = c.duplicate(); break
	for key in extra: card[key] = extra[key]
	if extra.has("as_type"):
		if not Config.CARD_DB.has(extra.as_type):
			return {success=false, msg="无效卡牌类型"}
		card.type_id = extra.as_type
	var type_id = card.type_id
	var player = players[player_idx]
	var cd = Config.CARD_DB[type_id]
	# 角色专属消耗覆盖（如快枪手远程 2AP）；-1 = 用卡牌默认消耗
	var cost = char_skills.get_attack_cost(player_idx, type_id)
	if cost < 0: cost = cd.cost
	var ap_ok = false
	match cd.ap:
		Config.APType.ATTACK: ap_ok = (player.ap_attack >= cost)
		Config.APType.MOVE: ap_ok = (player.ap_move >= cost)
		Config.APType.FUNCTION: ap_ok = (player.ap_function >= cost)
		Config.APType.NONE: ap_ok = true
	if not ap_ok: return {success=false, msg="行动点不足"}
	var free_archer = char_skills.can_attack_free(player_idx, type_id)
	if type_id == "blessing":
		if player.free_move_used: return {success=false, msg="本回合已使用过天赐"}
		player.free_move_used = true
	if not free_archer and cd.ap != Config.APType.NONE:
		match cd.ap:
			Config.APType.ATTACK: player.ap_attack -= cost
			Config.APType.MOVE: player.ap_move -= cost
			Config.APType.FUNCTION: player.ap_function -= cost
	var result = _execute_card_effect(player_idx, card)
	if not result.get("success", false) and result.get("phase") != "choose":
		if not free_archer and cd.ap != Config.APType.NONE:
			match cd.ap:
				Config.APType.ATTACK: player.ap_attack += cost
				Config.APType.MOVE: player.ap_move += cost
				Config.APType.FUNCTION: player.ap_function += cost
		return result
	if free_archer: player.skill_used_this_turn = true
	if cd.ap == Config.APType.FUNCTION: player.used_function_card = true
	state_changed.emit(get_full_state())
	return result

func _execute_card_effect(player_idx: int, card: Dictionary) -> Dictionary:
	return card_effects.execute(player_idx, card)

func _handle_skill(player_idx: int, skill: String, params: Dictionary = {}) -> Dictionary:
	var r = char_skills.use_skill(player_idx, skill, params)
	if r.get("success", false):
		state_changed.emit(get_full_state())
	return r

func _cheat_card(player_idx: int, type_id: String) -> Dictionary:
	if not Config.CARD_DB.has(type_id): return {success=false, msg="未知卡牌类型"}
	# uid 用递减计数器保证唯一（随机 uid 可能重复导致出牌选错卡）
	var card = {"uid": _cheat_uid_counter, "type_id": type_id}
	_cheat_uid_counter -= 1
	card_systems[player_idx].add_to_hand(card)
	add_log(player_idx, "[DEV]+%s" % type_id)
	state_changed.emit(get_full_state())
	return {success=true}

# 调试：立即结束对局（win=true 自己获胜，false 自己败北）
func _debug_end(player_idx: int, win: bool) -> Dictionary:
	var loser = 1 - player_idx if win else player_idx
	players[loser].hp = 0
	_check_permanent_death(loser)
	return {success=true}

func _handle_swordsman_choice(player_idx: int, data: Dictionary) -> Dictionary:
	var p = players[player_idx]
	if not p.get("pending_swordsman_skill", false): return {success=false, msg="无可用技能"}
	if p.skill_used_this_turn: return {success=false, msg="本回合已使用过"}
	var choice = data.get("choice", "")
	if choice == "heal":
		var before = p.hp
		p.hp = min(p.max_hp, p.hp + 2)
		stats[player_idx]["heal_total"] += p.hp - before  # 技能回血计入统计
		add_log(player_idx, "剑士+2HP")
	elif choice == "draw":
		card_systems[player_idx].draw_cards(1)
		add_log(player_idx, "剑士抽1张")
	else:
		return {success=false, msg="无效选择"}
	p.skill_used_this_turn = true
	p.pending_swordsman_skill = false
	state_changed.emit(get_full_state())
	return {success=true}

func _int_array(arr: Array) -> Array:
	var out = []
	for v in arr: out.append(int(v))
	return out

func _use_card(player_idx: int, card: Dictionary):
	card_systems[player_idx].play_card(card.uid)
	# 对战统计：打出牌数
	var s = stats[player_idx]
	var tid = card.get("type_id", "?")
	s["cards_played"][tid] = s["cards_played"].get(tid, 0) + 1
	s["card_total"] += 1

func _handle_respondable_card(player_idx: int, card: Dictionary, kind: String) -> Dictionary:
	var opp = 1 - player_idx
	pending_attack_card = kind
	pending_attack_uid = card.uid
	attacker_last_damage = 1
	phase = Config.Phase.RESPONSE_WINDOW
	response_pending = true
	response_needed.emit(opp, {attacker=player_idx, card=kind, damage=0, distance=0})
	return {success=true, phase="response"}

func _handle_attack_card(player_idx: int, card: Dictionary) -> Dictionary:
	var type_id = card.type_id
	if type_id in ["near", "heavy"] and movement.get_distance() != 0:
		return {success=false, msg="必须贴脸"}
	pending_attack_card = type_id
	pending_attack_uid = card.uid
	# 多段攻击：总段数由角色钩子决定（默认 1 = 单段，现有行为）
	pending_attack_segments = char_skills.get_attack_hit_count(player_idx, type_id)
	pending_attack_segment = 0
	return _begin_attack_segment(player_idx)

# 开始攻击的一段：计算伤害 → 进入响应窗口；段间推进由 process_response 处理
func _begin_attack_segment(player_idx: int) -> Dictionary:
	pending_attack_segment += 1
	var type_id = pending_attack_card
	var opp = 1 - player_idx
	var distance = movement.get_distance()
	var player = players[player_idx]
	attacker_last_damage = 0
	attacker_last_type = Config.get_damage_type(type_id)
	var calc = combat.calculate_attack(player_idx, opp, type_id)
	attacker_last_damage = calc.damage
	attacker_last_damage += char_skills.on_attack_cast(player_idx, type_id)
	_pending_formula = calc.get("formula", "")
	_armor_hit = calc.get("armor_hit", false)
	# 防具完全免疫优先于伤害加成判定（技能加成不能穿透满耐久防具）
	if calc.get("blocked", false):
		if calc.get("reason", "") == "distance":
			# 距离不够（穿心）：攻击无效，不消耗卡
			return {success=false, msg=calc.get("msg", "距离不够")}
		combat.consume_armor(opp)  # 防具生效消耗耐久（免疫也算一次命中）
		add_log(player_idx, "被防具挡下")
		# 多段攻击：本段被免疫则继续下一段（防具耐久已消耗，下一段按减半结算）
		if pending_attack_segment < pending_attack_segments:
			return _begin_attack_segment(player_idx)
		_use_card(player_idx, {uid=pending_attack_uid, type_id=pending_attack_card})
		state_changed.emit(get_full_state())
		return {success=true, msg="被防具挡下"}
	if attacker_last_damage <= 0:
		# 本段 0 伤害：跳过本段响应，直接尝试下一段；末段仍 0 则整卡无效
		if pending_attack_segment < pending_attack_segments:
			return _begin_attack_segment(player_idx)
		return {success=false, msg="无法造成伤害"}
	# 有效攻击才计入连击（失败的穿心不算）；多段攻击整卡只计一次连击
	if pending_attack_segment == 1:
		player.combo_attacks_this_turn.append(type_id)
	# 记录攻击声明（谁打出了什么），便于复盘验证
	add_log(player_idx, "%s打出%s" % [Config.char_name(players[player_idx].char_id), Config.card_name(type_id)])
	phase = Config.Phase.RESPONSE_WINDOW
	response_pending = true
	_action_deadline = Time.get_ticks_msec() + RESPONSE_TIME * 1000  # 响应窗口独立计时
	response_needed.emit(opp, {attacker=player_idx, card=type_id, damage=calc.damage, distance=distance, segment=pending_attack_segment, segments=pending_attack_segments})
	return {success=true, phase="response", damage=calc.damage}

func process_response(defender_idx: int, respond: bool, card_uid: int = -1):
	if not response_pending: return
	var attacker_idx = 1 - defender_idx
	response_pending = false
	phase = Config.Phase.PLAYER_TURN
	var final_damage = attacker_last_damage
	var formula = _pending_formula
	_pending_formula = ""
	if respond and card_uid >= 0:
		var rr = combat.process_response(attacker_idx, defender_idx, pending_attack_card, card_uid)
		if rr.success:
			stats[defender_idx]["responses"] += 1
			var rname = Config.card_name(rr.get("response_card", ""))
			match rr.effect:
				"block": final_damage = floori(final_damage / 2.0); formula += "/2"; add_log(defender_idx, "用%s格挡" % rname)
				"restrain": final_damage = max(0, final_damage - rr.value); formula += "-%d" % rr.value; add_log(defender_idx, "用%s牵制(-%d)" % [rname, rr.value])
				"dodge": final_damage = 0; add_log(defender_idx, "用%s闪避" % rname)
		else:
			if respond: add_log(defender_idx, "无法响应")
	if pending_attack_card == "freeze":
		# 冻结为单段攻击：结算后直接消耗卡结束
		_use_card(attacker_idx, {uid=pending_attack_uid, type_id=pending_attack_card})
		if final_damage == 0:
			add_log(attacker_idx, "冻结被闪避")
		else:
			status.freeze_player(defender_idx)
			add_log(attacker_idx, "冻结")
		state_changed.emit(get_full_state())
		return
	if final_damage > 0:
		if _armor_hit:
			combat.consume_armor(defender_idx)  # 防具耐久在实际伤害时消耗（被闪避后为0不消耗）
		_armor_hit = false
		var before_skill = final_damage
		final_damage = char_skills.on_taking_damage(defender_idx, attacker_idx, final_damage)
		if final_damage != before_skill:
			formula += "-%d" % (before_skill - final_damage)
		players[defender_idx].hp -= final_damage
		# 对战统计：伤害（来源=攻击）
		stats[attacker_idx]["damage_dealt"] += final_damage
		stats[defender_idx]["damage_taken"] += final_damage
		stats[defender_idx]["damage_from_attack"] += final_damage
		var attacker_name = Config.char_name(players[attacker_idx].char_id)
		var defender_name = Config.char_name(players[defender_idx].char_id)
		var card_name = Config.card_name(pending_attack_card)
		add_log(attacker_idx, "%s使用%s对%s造成：%s=%d点伤害" % [attacker_name, card_name, defender_name, formula, final_damage])
		combat.apply_on_hit_effects(attacker_idx, defender_idx, final_damage, attacker_last_type)
		char_skills.on_attack_hit(attacker_idx, defender_idx, final_damage, attacker_last_type)
	else:
		# 0 伤害（被闪避/格挡到0等）：补充攻击方记录
		add_log(attacker_idx, "%s使用%s攻击未造成伤害" % [Config.char_name(players[attacker_idx].char_id), Config.card_name(pending_attack_card)])
	if players[defender_idx].hp <= 0: _handle_death(defender_idx)
	if phase == Config.Phase.GAME_OVER: return
	# 多段攻击：还有段则进入下一段响应窗口（每段独立结算；末段才消耗卡）
	# 注意：_begin_attack_segment 内部会自增段号，这里不能重复自增
	if pending_attack_segment < pending_attack_segments:
		_begin_attack_segment(attacker_idx)
		state_changed.emit(get_full_state())
		return
	_use_card(attacker_idx, {uid=pending_attack_uid, type_id=pending_attack_card})
	turn_phase = Config.TurnPhase.ACTION
	var st = get_full_state()
	if _reveal_to >= 0:
		st["revealed_hand"] = card_systems[_reveal_from].get_hand_type_ids()
		st["revealed_to"] = _reveal_to
		_reveal_to = -1; _reveal_from = -1
	state_changed.emit(st)

func skip_response(defender_idx: int): process_response(defender_idx, false)

func _handle_move_card(player_idx: int, card: Dictionary) -> Dictionary:
	var direction = int(card.get("direction", 0))
	var steps = int(card.get("steps", 1))
	if direction != -1 and direction != 1: return {success=false, msg="无效移动方向"}
	if not char_skills.move_distances(player_idx).has(steps):
		return {success=false, msg="不支持%d步移动" % steps}
	if status.get_move_modifier(player_idx) < 0:
		# 流程检查：禁移动时移动卡不消耗（movement.move_player 另有兜底检查）
		return {success=false, msg="本回合无法移动"}
	for _s in range(steps):
		if not movement.move_player(player_idx, direction): break
		stats[player_idx]["moves"] += 1  # 对战统计：移动步数
	_use_card(player_idx, card)
	add_log(player_idx, "移动到%d" % players[player_idx].position)
	if movement.get_distance() == 0:
		_moved_to_adjacent_this_turn = true  # 突刺武器：移动贴脸后额外+3
	var td = item_system.trigger_on_step(player_idx)
	if td > 0:
		_check_any_death()  # 移动者或被推的对方都可能踩道具致死（内部已扣血）
	return {success=true}

func _handle_destroy(player_idx: int, card: Dictionary) -> Dictionary:
	var opp = 1 - player_idx
	var target = card.get("destroy_target", "hand")
	if target == "hand":
		card_systems[opp].random_discard(1); _use_card(player_idx, card); add_log(player_idx, "摧毁手牌"); return {success=true}
	if target == "trap":
		# 摧毁必须指定格子（客户端走棋盘选格；无位置参数视为操作错误）
		var pos = int(card.get("trap_pos", -1))
		if pos < 0:
			return {success=false, msg="请选择要摧毁的格子"}
		if item_system.destroy_item_at(pos):
			_use_card(player_idx, card); add_log(player_idx, "摧毁%d格道具" % pos); return {success=true}
		return {success=false, msg="该格没有道具"}
	var et = card.get("equip_type", "weapon")
	if et != "weapon" and et != "armor": return {success=false, msg="无效装备类型"}
	var msg = equipment.destroy_equipment(opp, et); _use_card(player_idx, card); add_log(player_idx, msg); return {success=true}

func _handle_seize(player_idx: int, card: Dictionary) -> Dictionary:
	var opp = 1 - player_idx
	var taken = card_systems[opp].random_take(); _use_card(player_idx, card)
	if taken.is_empty(): add_log(player_idx, "夺取空"); return {success=true}
	card_systems[player_idx].add_to_hand(taken); add_log(player_idx, "夺取1张"); return {success=true}

func _handle_heal(player_idx: int, card: Dictionary, amount: int) -> Dictionary:
	var player = players[player_idx]
	amount = char_skills.on_heal(player_idx, amount)
	var before = player.hp
	player.hp = min(player.max_hp, player.hp + amount); _use_card(player_idx, card)
	stats[player_idx]["heal_total"] += player.hp - before  # 对战统计：实际回复量
	add_log(player_idx, "+%dHP" % amount); return {success=true}

func _handle_weapon_card(player_idx: int, card: Dictionary, weapon_type: String) -> Dictionary:
	var result = equipment.process_weapon_card(player_idx, weapon_type)
	if result.phase == "done": return result
	_use_card(player_idx, card)
	waiting_for_weapon_choice = player_idx; pending_weapon_id = result.weapon.id
	weapon_prompt.emit(player_idx, result.weapon)
	return {success=true, phase="weapon_choose", weapon=result.weapon}

func confirm_weapon(player_idx: int, accept: bool):
	if waiting_for_weapon_choice != player_idx: return
	waiting_for_weapon_choice = -1
	if accept: equipment.equip_weapon(player_idx, pending_weapon_id); add_log(player_idx, "装备武器")
	else: equipment.discard_weapon_offer(pending_weapon_id); add_log(player_idx, "放弃武器")
	pending_weapon_id = ""; state_changed.emit(get_full_state())

func _discard_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.DISCARD
	_action_deadline = 0
	waiting_for_discard = true
	_discard_deadline = Time.get_ticks_msec() + DISCARD_TIME * 1000
	state_changed.emit(get_full_state())

func discard_one(player_idx: int, card_uid: int):
	if not waiting_for_discard or player_idx != current_player: return false
	if not card_systems[current_player].has_card(card_uid): return false
	card_systems[current_player].discard_card(card_uid)
	add_log(current_player, "弃1张")
	state_changed.emit(get_full_state())
	return true

func confirm_discard(player_idx: int, card_uids: Array = []):
	if not waiting_for_discard or player_idx != current_player: return
	for uid in card_uids:
		card_systems[current_player].discard_card(uid)
	state_changed.emit(get_full_state())
	var limit = movement.get_hand_limit(current_player)
	if card_systems[current_player].hand.size() > limit: return
	waiting_for_discard = false
	_discard_deadline = 0
	_finish_discard()

func _finish_discard():
	_discard_deadline = 0
	char_skills.on_turn_end(current_player)
	status.on_turn_end(current_player)
	_advance_to_next_player()

func _advance_to_next_player():
	if phase == Config.Phase.GAME_OVER: return
	current_player = 1 - current_player
	if current_player == first_player: turn_number += 1
	_judgment_phase()
	state_changed.emit(get_full_state())

# 位移/陷阱类效果后检查双方死亡（吸引/威慑可能让任一方踩陷阱）
func _check_any_death():
	for i in range(2):
		if players[i].hp <= 0:
			_handle_death(i)
			return

func _handle_death(player_idx: int):
	add_log(player_idx, "HP归零，复活...")
	phase = Config.Phase.RESURRECTING
	_action_deadline = 0
	_discard_deadline = 0
	card_systems[player_idx].discard_all()
	var drawn = card_systems[player_idx].draw_cards(4)
	if drawn.is_empty(): _check_permanent_death(player_idx); return
	for c in drawn:
		if c.type_id == "blessing":
			card_systems[player_idx].play_card(c.uid); card_systems[player_idx].draw_cards(2); break
	while card_systems[player_idx].has_heal_card() and players[player_idx].hp <= 0:
		_use_heal_in_resurrection(player_idx)
	if players[player_idx].hp > 0:
		add_log(player_idx, "复活成功")
		stats[player_idx]["resurrected"] += 1  # 对战统计：复活次数
		players[player_idx].frozen = false; players[player_idx].frozen_lockout = false
		phase = Config.Phase.PLAYER_TURN; response_pending = false
		state_changed.emit(get_full_state())
	else: _check_permanent_death(player_idx)

func _use_heal_in_resurrection(player_idx: int):
	var card = card_systems[player_idx].use_heal_card()
	if card.is_empty(): return
	var amount = 3 if card.type_id == "heal_3" else 5
	amount = char_skills.on_heal(player_idx, amount)
	var before = players[player_idx].hp
	players[player_idx].hp = min(players[player_idx].max_hp, players[player_idx].hp + amount)
	stats[player_idx]["heal_total"] += players[player_idx].hp - before  # 对战统计：复活回复也算

func _check_permanent_death(player_idx: int):
	if players[player_idx].hp <= 0:
		phase = Config.Phase.GAME_OVER
		var winner = 1 - player_idx
		game_result = {
			winner=winner, loser=player_idx, reason="permanent_death",
			stats=stats.duplicate(),
			names=[Config.char_name(players[0].char_id), Config.char_name(players[1].char_id)],
			title=_calc_title(winner),
		}
		add_log(player_idx, "淘汰")
		state_changed.emit(get_full_state())
		game_ended.emit(game_result)

# 获胜者称号：根据对战统计判定
func _calc_title(winner_idx: int) -> String:
	var w = stats[winner_idx]
	var l = stats[1 - winner_idx]
	if w["damage_taken"] == 0: return "无伤传说"
	if w["damage_dealt"] >= 25: return "毁灭之王"
	if l["damage_dealt"] == 0: return "绝对防御"
	if w["heal_total"] >= 10: return "圣光使者"
	if w["resurrected"] > 0: return "不死凤凰"
	if w["card_total"] >= 15: return "出牌大师"
	return "征服者"

func check_timers():
	var now = Time.get_ticks_msec()
	if phase == Config.Phase.BP_PHASE:
		var before = bp.bp_phase
		bp.check_bp_timer()
		if bp.bp_phase != before:
			# 超时自动操作后广播，让客户端 UI 刷新并推进流程
			bp_state_changed.emit(bp.get_bp_state())
		return
	if _action_deadline > 0 and now >= _action_deadline:
		_action_deadline = 0
		if response_pending:
			# 响应窗口超时：默认不响应，结算后攻击者继续出牌（避免软锁）
			skip_response(1 - current_player)
			if phase == Config.Phase.PLAYER_TURN and turn_phase == Config.TurnPhase.ACTION:
				_action_deadline = Time.get_ticks_msec() + ACTION_TIME * 1000
			return
		add_log(current_player, "回合超时")
		if waiting_for_weapon_choice >= 0:
			confirm_weapon(waiting_for_weapon_choice, false)  # 武器选择超时默认放弃
		_discard_phase()
	if _discard_deadline > 0 and now >= _discard_deadline:
		_discard_deadline = 0
		_auto_discard()

func _auto_discard():
	if not waiting_for_discard: return
	var cs = card_systems[current_player]
	var limit = movement.get_hand_limit(current_player)
	var excess = cs.hand.size() - limit
	if excess > 0:
		cs.random_discard(excess)
		add_log(current_player, "超时自动弃%d张" % excess)
	waiting_for_discard = false
	state_changed.emit(get_full_state())
	_finish_discard()

func add_log(player_idx: int, msg: String):
	action_log.append({turn=turn_number, player=player_idx, player_name=Config.char_name(players[player_idx].char_id), msg=msg})

func steal_card(player_idx: int, target_uid: int) -> int:
	var opp = 1 - player_idx
	if not card_systems[opp].has_card(target_uid): return -1
	var card = card_systems[opp].play_card(target_uid)
	if card.is_empty(): return -1
	card_systems[player_idx].add_to_hand(card)
	add_log(player_idx, "取走对方1张牌")
	return card.uid

func return_card(player_idx: int, card_uid: int) -> bool:
	var opp = 1 - player_idx
	if not card_systems[player_idx].has_card(card_uid): return false
	var card = card_systems[player_idx].play_card(card_uid)
	if card.is_empty(): return false
	card_systems[opp].add_to_hand(card)
	return true

func reveal_opponent_hand(asking_player_idx: int) -> Array:
	var opp = 1 - asking_player_idx
	return card_systems[opp].get_hand_type_ids()

func _skill_list(player_idx: int) -> Array:
	var out = []
	for sk in char_skills.has_active_skills(player_idx):
		out.append({"id": sk, "name": char_skills.skill_button_name(sk)})
	return out

func get_full_state(full: bool = false) -> Dictionary:
	var now = Time.get_ticks_msec()
	var atl = -1
	if _action_deadline > 0:
		atl = max(0, int((_action_deadline - now) / 1000.0))
	var dtl = -1
	if _discard_deadline > 0:
		dtl = max(0, int((_discard_deadline - now) / 1000.0))
	var state = {
		phase=phase, turn_phase=turn_phase, current_player=current_player,
		turn_number=turn_number, first_player=first_player,
		response_pending=response_pending, pending_attack_card=pending_attack_card,
		pending_attack_segment=pending_attack_segment, pending_attack_segments=pending_attack_segments,
		waiting_for_discard=waiting_for_discard, discard_count=discard_count,
		action_time_left=atl, discard_time_left=dtl,
		deck_size=card_systems[0].deck.size(), discard_size=card_systems[0].discard.size(),
		players=[], items=items.duplicate(), action_log=action_log.duplicate(),
		distance=movement.get_distance(),
	}
	for i in range(2):
		var p = players[i]; var cs = card_systems[i]
		state.players.append({
			index=i, char_id=p.char_id, char_name=Config.char_name(p.char_id),
			hp=p.hp, max_hp=p.max_hp,
			near_power=p.near_power, range_power=p.range_power, magic_power=p.magic_power,
			position=p.position, weapon=p.weapon, armor=p.armor,
			buffs=p.buffs.duplicate(), dots=p.dots.duplicate(), frozen=p.frozen,
			ap_attack=p.get("ap_attack",0), ap_move=p.get("ap_move",0), ap_function=p.get("ap_function",0),
			hand_size=cs.hand.size(), deck_size=cs.deck.size(),
			hand=cs.hand.duplicate(), hand_limit=movement.get_hand_limit(i),
			active_skills=_skill_list(i),
			pending_swordsman_skill=p.get("pending_swordsman_skill", false),
			# 角色道具类型（一张通用道具卡，卡面/说明按角色道具显示）
			item_type=char_skills.get_item_type(i),
			item_type_name=item_system.get_item_type(char_skills.get_item_type(i)).get("name", "道具"),
			item_type_desc=item_system.get_item_type(char_skills.get_item_type(i)).get("desc", ""),
		})
	if full: state.bp_state = bp.get_bp_state()
	return state

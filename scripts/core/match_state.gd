# ============================================================
# match_state.gd — 对局状态机（服务端权威，唯一真实数据源）
# ============================================================
extends RefCounted

const MapGeometry = preload("res://scripts/core/map_geometry.gd")
const CombatSys = preload("res://scripts/core/combat_system.gd")
const MovementSys = preload("res://scripts/core/movement_system.gd")
const EquipmentSys = preload("res://scripts/core/equipment_system.gd")
const StatusSys = preload("res://scripts/core/status_system.gd")
const BPSys = preload("res://scripts/core/bp_system.gd")
const CardSys = preload("res://scripts/core/card_system.gd")
const DeckData = preload("res://scripts/data/deck_data.gd")

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
var weapon_pools: Array = []  # 每玩家自定义武器幻化池 [{near:[],range:[],magic:[]}]（默认=武器库全部）
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
var _response_attacker: int = -1         # 响应等待的攻击者（process_response 身份校验用）
var _pending_target: int = -1            # 当前攻击/技能的目标玩家（多人局显式指定；2 人局 -1）
var game_result: Dictionary = {}
# 对战统计（结算页展示 + 称号判定）：每玩家一个字典
var stats: Array = []
# 本回合是否通过移动牌位移到贴脸（突刺武器额外+3 的判定标记）
var _moved_to_adjacent_this_turn: bool = false
# 本次攻击防具是否生效（实际造成伤害时消耗耐久，闪避/0伤害不消耗）
var _armor_hit: bool = false
# 本次攻击是否触发穿甲（强化攻击 heavy/pierce/chant 命中防具时额外-2耐久）
var _armor_pierce: bool = false
# 满耐久防具完全免疫：攻击进入响应窗口（玩家可闪避保甲），结算时防具免疫才生效
var _pending_blocked: bool = false
# 本次响应效果（block/restrain/dodge/""）：0 伤害结算时判断是否闪避保住防具
var _resp_effect: String = ""
var _ignore_distance: bool = false  # 魔力引导等技能：本次攻击无视贴脸距离限制
# 重锤武器：命中后对方护甲额外-1耐久（伤害归0时（闪避/格挡）不触发）
var _hammer_pierce: bool = false
# 共鸣武器：法术攻击被完全抵挡时额外造成2点伤害（穿透反震）
var _resonance_rebound: bool = false
# 风神弓：穿心命中后控制对方移动1格（方向自由，待攻击者选择方向）
var _wind_bow_pending: bool = false
var _wind_bow_target: int = -1
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

# 倒计时开关（由启动方设置，联机保持默认全开）：
#   disable_timeout = true → 全部关闭（自我对战：双方不限时，含 BP）
#   no_timeout_for >= 0    → 仅该玩家不限时（人机对战：人类 P0 不限时）
var disable_timeout: bool = false
var no_timeout_for: int = -1

# ---- 对局记录（本地/联机共用：每回合双方手牌/血量/位置/AP/牌堆，结算导出分析） ----
var battle_record: Array = []
var _last_rec_key: String = ""

# AI 难度（人机对战由 local_game 设置；-1 = 无 AI 特权，联机/自我对战不受影响）
# 地狱难度：P1（AI）复活高概率且不污染牌库（牌堆检索回复卡，无卡时概率复苏）
var ai_difficulty: int = -1

func _timeout_enabled(player_idx: int) -> bool:
	if disable_timeout: return false
	if no_timeout_for >= 0 and player_idx == no_timeout_for: return false
	return true

# BP 阶段计时是否生效（本地模式 BP 也关闭：AI 自动操作不需要计时）
func bp_timer_active() -> bool:
	return not (disable_timeout or no_timeout_for >= 0)

signal state_changed(data: Dictionary)
signal weapon_prompt(player_idx: int, weapon: Dictionary)
signal wind_bow_prompt(attacker_idx: int, target_idx: int)  # 风神弓：穿心命中后控制对方移动（方向自由）
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

func init_match(p1_char_id: String, p2_char_id: String, bp_first: int = -1, custom_decks: Array = [], independent_decks: bool = false, weapon_pools: Array = []):
	_setup_match([p1_char_id, p2_char_id], bp_first, custom_decks, independent_decks, weapon_pools)

# 多人（4 人）混战开局：不走 BP 直接开战；默认独立牌堆（每角色各一副）
func init_match_multi(char_ids: Array, custom_decks: Array = [], independent_decks: bool = true, weapon_pools: Array = []):
	_setup_match(char_ids, randi() % char_ids.size(), custom_decks, independent_decks, weapon_pools)

func _setup_match(char_ids: Array, bp_first: int, custom_decks: Array, independent_decks: bool, wp_in: Array = []):
	var n = char_ids.size()
	# 地图模式：2 人局线性、多人局六边形。以后新增布局只改 map_geometry.gd
	# （见该文件头注释"以后修改地图布局"），此处按人数切换即可
	movement.geometry.set_mode(MapGeometry.MODE_HEX if n > 2 else MapGeometry.MODE_LINEAR)
	players = []
	for i in range(n):
		var cd = Config.CHARACTER_DB[char_ids[i]]
		players.append(_create_player(i, char_ids[i], cd))
	# 默认共享牌堆（人机/联机原行为）；independent_decks=true（PVE/多人）每名玩家各自一副，
	# custom_decks[idx] = 自定义 type_id 列表（PVE 构筑）
	self.independent_decks = independent_decks
	# 自定义房间规则：不勾「共享牌堆」→ 强制各自独立牌堆（即使调用方未传 independent）
	if not game_config.is_empty() and not bool(game_config.get("shared_deck", true)):
		self.independent_decks = true
	if self.independent_decks:
		card_systems = []
		for i in range(n):
			card_systems.append(_build_card_system(i, custom_decks))
	else:
		var shared_deck = Config.build_initial_deck()
		shared_deck.shuffle()
		var shared_discard = []
		card_systems = []
		for i in range(n):
			card_systems.append(CardSys.new(shared_deck, shared_discard))
	# 武器幻化池：每玩家独立（自定义卡组随卡组上报；非法/缺失 → 默认池=武器库全部）
	self.weapon_pools = []
	for i in range(n):
		if wp_in.size() > i and DeckData.validate_weapon_pool(wp_in[i]):
			self.weapon_pools.append(wp_in[i].duplicate(true))
		else:
			self.weapon_pools.append(DeckData.default_weapon_pool())
	items.clear()
	action_log.clear()
	battle_record.clear(); _last_rec_key = ""  # 对局记录（本地/联机共用，结算导出）
	turn_number = 0
	waiting_for_weapon_choice = -1
	response_pending = false
	waiting_for_discard = false
	discard_count = 0
	game_result = {}
	stats = []
	for i in range(n):
		stats.append({"damage_dealt": 0, "damage_taken": 0, "damage_from_attack": 0, "damage_from_trap": 0, "damage_from_dot": 0, "heal_total": 0, "moves": 0, "responses": 0, "resurrected": 0, "cards_played": {}, "card_total": 0, "blocked_dmg": 0, "weapons_used": {}, "max_hit": 0})
	_action_deadline = 0
	_discard_deadline = 0
	_moved_to_adjacent_this_turn = false
	_cheat_uid_counter = -1000
	first_player = bp_first if bp_first >= 0 else randi() % n
	current_player = first_player
	phase = Config.Phase.BP_PHASE
	bp.reset()
	for i in range(n):
		card_systems[i].draw_cards(4)

# 玩家数（2 人标准 / 4 人多人混战）
func player_count() -> int:
	return players.size()

# 目标解析：target >= 0 显式指定（多人局点选）；2 人局自动返回唯一对手
func get_opponent(player_idx: int, target: int = -1) -> int:
	if target >= 0 and target < players.size() and target != player_idx:
		return target
	if players.size() == 2:
		return 1 - player_idx
	return -1

# 目标玩家名（日志显示用）：指定索引，无效时兜底"对手"
func _target_name(target: int) -> String:
	if target >= 0 and target < players.size():
		return Config.char_name(players[target].char_id)
	return "对手"

# 最近的存活对手（多人局距离显示/默认目标）
func _nearest_alive_opponent(player_idx: int) -> int:
	var best = -1
	var best_d = 999999
	for i in range(players.size()):
		if i == player_idx or players[i].get("eliminated", false): continue
		var d = movement.geometry.distance(players[player_idx].position, players[i].position)
		if d < best_d:
			best_d = d
			best = i
	return best

func _create_player(idx: int, char_id: String, char_data: Dictionary) -> Dictionary:
	# 饲甲人开局自带活铠（魔甲）：耐久上限 2，全类型减半，无完全免疫，不碎裂
	var init_armor = {}
	if char_id == "armor_feeder":
		init_armor = {id="demon_armor", data=Config.ARMOR_DB["demon_armor"], durability=2, max_durability=2}
	return {
		index=idx, char_id=char_id,
		hp=char_data.hp, max_hp=char_data.hp,
		near_power=char_data.near, range_power=char_data.range, magic_power=char_data.magic,
		position=movement.geometry.initial_position(idx),
		weapon={}, armor=init_armor, buffs=[], dots=[],
		eliminated=false,  # 多人混战：淘汰标记（2 人局不使用）
		frozen=false, frozen_lockout=0, frozen_move=false,
		damage_reduction_used=false, skill_used_this_turn=false, free_move_used=false,
		combo_attacks_this_turn=[],
		upgrades={},
		skill_counts={},
		skills_used=[],
		used_function_card=false,
		pending_fighter_skill=false,
	}

# 牌堆模式：false = 共享牌堆（默认，人机/联机）；true = 独立牌堆（PVE 构筑）
var independent_decks: bool = false

# 教程模式：抑制回合自然抽牌（手牌由教程管理器完全控制）
var draw_suppressed: bool = false

# 快速模式：出牌不消耗行动点（无限出牌）、天赐不限次数、冻结无冷却（可连续冻结）
var rapid_mode: bool = false

# ---- 自定义房间规则（客户端配置下发，服务端权威生效）----
# 规则字段（与 mode_data.CONFIG_DEFAULTS 一致）：
#   shared_deck / infinite_play / freeze_no_cooldown / blessing_unlimited / hand_limit / hand_min / resurrect_limit
var game_config: Dictionary = {}
var infinite_play: bool = false          # 无限出牌（不消耗行动点）
var freeze_no_cooldown: bool = false     # 冻结无冷却（可连续冻结）
var blessing_unlimited: bool = false     # 天赐不限次数
var hand_limit_override: int = -1        # 手牌上限（-1 = 默认动态：距板边距离+1）
var hand_min_override: int = 0           # 手牌下限（弃牌阶段不能低于此数）
var resurrect_limit_override: int = -1   # 复活次数上限（-1 = 无限）

# 应用自定义房间规则（对局创建后调用；服务器/本地共用）
func _apply_game_config(cfg: Dictionary):
	game_config = cfg.duplicate()
	infinite_play = bool(cfg.get("infinite_play", false))
	freeze_no_cooldown = bool(cfg.get("freeze_no_cooldown", false))
	blessing_unlimited = bool(cfg.get("blessing_unlimited", false))
	hand_limit_override = int(cfg.get("hand_limit", -1))
	hand_min_override = int(cfg.get("hand_min", 0))
	resurrect_limit_override = int(cfg.get("resurrect_limit", -1))
	# rapid_mode 兼容旧检查点（任一快速规则开启即视为快速模式）
	rapid_mode = infinite_play or freeze_no_cooldown or blessing_unlimited

# 构建一副卡组（默认初始构成；custom_decks[idx] 为自定义 type_id 数组时用自定义）
func _build_card_system(idx: int, custom_decks: Array) -> CardSys:
	var deck: Array = []
	if custom_decks.size() > idx and custom_decks[idx] is Array and not custom_decks[idx].is_empty():
		# uid 全局唯一：每名玩家独立牌堆加偏移（P1:0-39, P2:1000-1039, P3:2000-...）。
		# 否则双方 uid 都从 0 起，夺取/偷牌跨玩家转移后同 uid 撞车，
		# 出牌/弃牌/格挡按 uid 查找会选错卡、污染双方牌堆。
		# 与教程发牌(9000+)、作弊发牌(-1000 递减)、经典共享牌堆(0-77)均不冲突。
		for i in range(custom_decks[idx].size()):
			deck.append({"uid": idx * 1000 + i, "type_id": str(custom_decks[idx][i])})
	else:
		deck = Config.build_initial_deck()
	return CardSys.new(deck)

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
	# 回合开始钩子（判定阶段最前，DoT 之前）：活铠献祭等
	char_skills.on_judgment_start(current_player)
	if phase == Config.Phase.GAME_OVER: return  # 献祭扣血致死淘汰
	var player = players[current_player]
	if player.dots.size() > 0:
		# 先快照本回合将造成伤害的 DoT 类型（牧师净化用）
		var dot_types: Array = []
		for dot in player.dots:
			if not dot.type in dot_types:
				dot_types.append(dot.type)
		var dd = combat.apply_dot_damage(current_player)
		if dd.damage > 0:
			# 伤害来源统计：DoT 计入受到伤害；施放者（source）计入造成伤害
			stats[current_player]["damage_taken"] += dd.damage
			stats[current_player]["damage_from_dot"] += dd.damage
			for ds in dd.dot_stats:
				if ds.source >= 0:
					stats[ds.source]["damage_dealt"] += ds.damage
			var detail_str = "、".join(dd.details)
			add_log(current_player, "%s共%d点伤害" % [detail_str, dd.damage])
			_damage_player(current_player, dd.damage)  # 统一伤害入口（内部含死亡判定）
			# 角色被动：受到 DoT 伤害后的处理（牧师清除对应 DoT）
			char_skills.on_dot_damage(current_player, dot_types)
			if phase == Config.Phase.GAME_OVER: return
	status.on_turn_start(current_player)
	char_skills.on_opponent_turn_start(current_player)
	# 神隐（巫女鸟居）：判定阶段 DoT 已结算，清除神隐并跳过本回合
	# （不抽牌/不出牌/不弃牌，直接切换玩家；被神隐期间 buff 不衰减）
	if status.has_buff(current_player, "神隐"):
		status.clear_buff(current_player, "神隐")
		add_log(current_player, "神隐：跳过本回合")
		_advance_to_next_player()  # 内部已 emit 状态
		return
	_draw_phase()

func _draw_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.DRAW
	# 教程模式抑制自然抽牌（手牌由教程完全控制，避免混入随机牌）
	if not draw_suppressed:
		card_systems[current_player].draw_cards(char_skills.draw_count(current_player))
		add_log(current_player, "抽了2张牌")
	_action_phase()

func _action_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.ACTION
	_moved_to_adjacent_this_turn = false  # 每回合重置突刺贴脸标记
	var player = players[current_player]
	# 冻结冷却：每经过一个出牌阶段递减，到 0 后才可再次被冻结（不能连续冻结）
	if player.frozen_lockout > 0:
		player.frozen_lockout -= 1
	if player.frozen:
		add_log(current_player, "被冻结，跳过出牌阶段")
		status.clear_freeze(current_player)
		_discard_phase()
		return
	char_skills.on_turn_start(current_player)
	_action_deadline = Time.get_ticks_msec() + ACTION_TIME * 1000
	state_changed.emit(get_full_state())

func process_action(player_idx: int, action_data: Dictionary) -> Dictionary:
	# 风神弓方向选择：攻击结算后的独立交互，不受阶段限制（放在回合校验前）
	if action_data.get("action", "") == "wind_bow_move":
		return _handle_wind_bow_move(player_idx, action_data)
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
		"fighter_choice": return _handle_fighter_choice(player_idx, action_data)
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
	var ap_ok = rapid_mode or infinite_play  # 快速模式/自定义「无限出牌」：不检查/不消耗行动点
	if not ap_ok:
		match cd.ap:
			Config.APType.ATTACK: ap_ok = (player.ap_attack >= cost)
			Config.APType.MOVE: ap_ok = (player.ap_move >= cost)
			Config.APType.FUNCTION: ap_ok = (player.ap_function >= cost)
			Config.APType.NONE: ap_ok = true
	if not ap_ok: return {success=false, msg="行动点不足"}
	var free_sharpshooter = char_skills.can_attack_free(player_idx, type_id)
	if type_id == "blessing" and not (rapid_mode or blessing_unlimited):  # 快速/自定义「天赐不限」：抽牌效果保留
		if player.free_move_used: return {success=false, msg="本回合已使用过天赐"}
		player.free_move_used = true
	if not (rapid_mode or infinite_play) and not free_sharpshooter and cd.ap != Config.APType.NONE:
		match cd.ap:
			Config.APType.ATTACK: player.ap_attack -= cost
			Config.APType.MOVE: player.ap_move -= cost
			Config.APType.FUNCTION: player.ap_function -= cost
	var result = _execute_card_effect(player_idx, card)
	if not result.get("success", false) and result.get("phase") != "choose":
		if not (rapid_mode or infinite_play) and not free_sharpshooter and cd.ap != Config.APType.NONE:
			match cd.ap:
				Config.APType.ATTACK: player.ap_attack += cost
				Config.APType.MOVE: player.ap_move += cost
				Config.APType.FUNCTION: player.ap_function += cost
		return result
	if free_sharpshooter: player.skill_used_this_turn = true
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
	if players.size() > 2:
		# 多人混战：调试胜利 = 其余全部淘汰自己获胜（走多人结算，每人称号齐全）；
		# 调试失败 = 自己淘汰，对局继续（最后存活者胜，符合多人规则语义）
		for i in range(players.size()):
			if (win and i != player_idx) or (not win and i == player_idx):
				players[i].hp = 0
				players[i].eliminated = true
		add_log(player_idx, "调试: 立即胜利" if win else "调试: 立即淘汰")
		_check_multi_winner()
		return {success=true}
	var loser = 1 - player_idx if win else player_idx
	players[loser].hp = 0
	_check_permanent_death(loser)
	return {success=true}

func _handle_fighter_choice(player_idx: int, data: Dictionary) -> Dictionary:
	var p = players[player_idx]
	if not p.get("pending_fighter_skill", false): return {success=false, msg="无可用技能"}
	if p.skill_used_this_turn: return {success=false, msg="本回合已使用过"}
	var choice = data.get("choice", "")
	if choice == "heal":
		var before = p.hp
		# 走 on_heal 钩子（邪术师回血效果-1 覆盖剑士技能回血）
		var heal_amt = char_skills.on_heal(player_idx, 2)
		p.hp = min(p.max_hp, p.hp + heal_amt)
		stats[player_idx]["heal_total"] += p.hp - before  # 技能回血计入统计
		add_log(player_idx, "斗士+%dHP" % heal_amt)
	elif choice == "draw":
		card_systems[player_idx].draw_cards(1)
		add_log(player_idx, "斗士抽1张")
	else:
		return {success=false, msg="无效选择"}
	p.skill_used_this_turn = true
	p.pending_fighter_skill = false
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

# 真言（牧师）：回复卡等值法术伤害，无视护甲，只能魔法响应（闪避），无卡消耗
func _begin_priest_chant(player_idx: int, card: Dictionary, target_idx: int) -> Dictionary:
	var opp = get_opponent(player_idx, target_idx)
	if opp < 0: return {success=false, msg="请选择目标"}
	var dmg = 3 if card.type_id == "heal_3" else 5
	_pending_target = opp
	pending_attack_card = "priest_chant"
	pending_attack_uid = -1  # 无卡消耗标记（_use_card 检查手牌持有再消耗）
	_response_attacker = player_idx
	pending_attack_segments = 1
	pending_attack_segment = 0
	attacker_last_damage = dmg
	attacker_last_type = Config.DamageType.MAGICAL
	_pending_formula = "真言(%s)" % Config.card_name(card.type_id)
	# 无视护甲（不计算防具）；重置武器/共鸣/风神弓标记防残留
	_armor_hit = false
	_armor_pierce = false
	_hammer_pierce = false
	_resonance_rebound = false
	_wind_bow_pending = false
	_wind_bow_target = -1
	_pending_blocked = false
	add_log(player_idx, "%s咏唱真言: 弃%s，对%s造成%d点法术伤害" % [
		Config.char_name(players[player_idx].char_id), Config.card_name(card.type_id),
		_target_name(opp), dmg])
	phase = Config.Phase.RESPONSE_WINDOW
	response_pending = true
	_action_deadline = Time.get_ticks_msec() + RESPONSE_TIME * 1000
	response_needed.emit(opp, {attacker=player_idx, card="priest_chant", damage=dmg,
		distance=movement.get_distance(opp), segment=1, segments=1})
	return {success=true, phase="response", damage=dmg}

func _handle_respondable_card(player_idx: int, card: Dictionary, kind: String) -> Dictionary:
	var opp = get_opponent(player_idx, int(card.get("target", -1)))
	if opp < 0: return {success=false, msg="请选择目标"}
	_pending_target = opp
	pending_attack_card = kind
	pending_attack_uid = card.uid
	_response_attacker = player_idx
	attacker_last_damage = 1
	# 冻结为单段攻击：显式重置段号，防止沿用上一攻击（如快枪手双发）残留的段数
	# 导致响应弹窗误显示"第2/2段"（battle_ui 从 get_full_state 读取段号）
	pending_attack_segments = 1
	pending_attack_segment = 1
	phase = Config.Phase.RESPONSE_WINDOW
	response_pending = true
	response_needed.emit(opp, {attacker=player_idx, card=kind, damage=0, distance=0, target=opp, segment=1, segments=1})
	return {success=true, phase="response"}

func _handle_attack_card(player_idx: int, card: Dictionary) -> Dictionary:
	var type_id = card.type_id
	_pending_target = get_opponent(player_idx, int(card.get("target", -1)))
	if _pending_target < 0: return {success=false, msg="请选择目标"}
	# ignore_distance（魔力引导等技能）：近战/重击无视距离限制打出
	if type_id in ["near", "heavy"] and movement.get_distance(_pending_target) != 0 and not card.get("ignore_distance", false):
		return {success=false, msg="必须贴脸"}
	pending_attack_card = type_id
	pending_attack_uid = card.uid
	_ignore_distance = card.get("ignore_distance", false)  # 魔力引导等技能：近战/重击无视距离
	# 多段攻击：总段数由角色钩子决定（默认 1 = 单段，现有行为）
	pending_attack_segments = char_skills.get_attack_hit_count(player_idx, type_id)
	pending_attack_segment = 0
	_response_attacker = player_idx
	return _begin_attack_segment(player_idx)

# 开始攻击的一段：计算伤害 → 进入响应窗口；段间推进由 process_response 处理
func _begin_attack_segment(player_idx: int) -> Dictionary:
	pending_attack_segment += 1
	_pending_blocked = false  # 每段独立判定（防上一段免疫标记残留）
	var type_id = pending_attack_card
	var opp = _pending_target
	var distance = movement.get_distance(opp)
	var player = players[player_idx]
	attacker_last_damage = 0
	attacker_last_type = Config.get_damage_type(type_id)
	var calc = combat.calculate_attack(player_idx, opp, type_id, _ignore_distance)
	attacker_last_damage = calc.damage
	# 技能伤害加成（法师强化等）计入实际伤害，公式同步显示（避免"8=10"）
	var skill_bonus = char_skills.on_attack_cast(player_idx, type_id)
	if skill_bonus != 0:
		attacker_last_damage += skill_bonus
	_pending_formula = calc.get("formula", "")
	if skill_bonus != 0:
		_pending_formula += ("+%d" if skill_bonus > 0 else "%d") % skill_bonus
	_armor_hit = calc.get("armor_hit", false)
	# 穿甲标记：强化攻击（heavy/pierce/chant）命中防具时额外-2耐久
	_armor_pierce = _armor_hit and type_id in ["heavy", "pierce", "chant"]
	# 重锤标记：攻击者装备重锤时，命中后对方护甲额外-1耐久（伤害归0不触发）
	_hammer_pierce = not player.weapon.is_empty() and player.weapon.id == "hammer"
	# 共鸣标记：装备共鸣且打出法术攻击时，被完全抵挡则额外造成2点伤害
	_resonance_rebound = not player.weapon.is_empty() and player.weapon.id == "resonance" \
			and type_id in ["magic", "chant"]
	# 幻影（法师）：50%概率闪避本段攻击——先判定幻影，成功则本段无效（不进响应窗口、护甲不消耗）；
	# 多段攻击每段独立判定（每段消耗一层机会）
	if status.try_phantom_dodge(opp):
		char_skills.on_attack_failed_no_damage(player_idx, attacker_last_type)
		add_log(opp, "幻影闪避: 攻击落空")
		if pending_attack_segment < pending_attack_segments:
			state_changed.emit(get_full_state())
			return _begin_attack_segment(player_idx)
		if pending_attack_uid >= 0 or card_systems[player_idx].has_card(pending_attack_uid):
			_use_card(player_idx, {uid=pending_attack_uid, type_id=pending_attack_card})
		state_changed.emit(get_full_state())
		return {success=true, msg="被幻影闪避"}
	# 防具完全免疫优先于伤害加成判定（技能加成不能穿透满耐久防具）
	if calc.get("blocked", false):
		char_skills.on_attack_failed_no_damage(player_idx, attacker_last_type)
		if calc.get("reason", "") == "distance":
			# 距离不够（穿心）：攻击无效，不消耗卡
			return {success=false, msg=calc.get("msg", "距离不够")}
		# 满耐久防具免疫：进入响应窗口——玩家可用魔法卡闪避躲开攻击、保住防具耐久；
		# 不响应/格挡/牵制则防具免疫生效（消耗耐久，强化攻击附带穿甲）
		_pending_blocked = true
		add_log(player_idx, "%s打出%s" % [Config.char_name(players[player_idx].char_id), Config.card_name(type_id)])
		phase = Config.Phase.RESPONSE_WINDOW
		response_pending = true
		_action_deadline = Time.get_ticks_msec() + RESPONSE_TIME * 1000
		response_needed.emit(opp, {attacker=player_idx, card=type_id, damage=0, distance=distance, segment=pending_attack_segment, segments=pending_attack_segments})
		return {success=true, phase="response", damage=0}
	if attacker_last_damage <= 0:
		# 防具把伤害减半到 0：防具本次已生效（armor_hit=true），照常消耗耐久，
		# 否则 1 伤害攻击可以无限白嫖防具减半；同时清空穿甲标记防残留
		if _armor_hit:
			combat.consume_armor(_pending_target)
			add_log(player_idx, "防具减免伤害至0")
			# 重锤：护甲把伤害减到0 也算命中护甲，额外-1耐久
			if _hammer_pierce:
				combat.pierce_armor(_pending_target, 1)
				add_log(player_idx, "重锤: 护甲耐久-1")
			# 共鸣：护甲把伤害减到0 = 被完全抵挡 → 额外造成2点伤害
			_apply_resonance_rebound(player_idx, _pending_target)
		_armor_hit = false
		_armor_pierce = false
		char_skills.on_attack_failed_no_damage(player_idx, attacker_last_type)
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
	# 身份校验：只有被攻击方（攻击者的目标）可以响应，防止攻击方对自己"响应"
	if _response_attacker < 0 or defender_idx != _pending_target:
		return
	var attacker_idx = _response_attacker
	response_pending = false
	phase = Config.Phase.PLAYER_TURN
	var final_damage = attacker_last_damage
	var formula = _pending_formula
	_pending_formula = ""
	_resp_effect = ""
	if respond and card_uid >= 0:
		var rr = combat.process_response(attacker_idx, defender_idx, pending_attack_card, card_uid)
		if rr.success:
			stats[defender_idx]["responses"] += 1
			var rname = Config.card_name(rr.get("response_card", ""))
			_resp_effect = str(rr.effect)
			match rr.effect:
				"block": final_damage = floori(final_damage / 2.0); formula += "/2"; add_log(defender_idx, "用%s格挡" % rname)
				"restrain":
					final_damage = max(0, final_damage - rr.value); formula += "-%d" % rr.value; add_log(defender_idx, "用%s牵制(-%d)" % [rname, rr.value])
					# 牵制完全抵挡（归零）：计入"完全抵挡"统计（战术大师称号）
					if final_damage == 0:
						stats[defender_idx]["blocked_dmg"] += attacker_last_damage
				"dodge":
					final_damage = 0; add_log(defender_idx, "用%s闪避" % rname)
					# 闪避完全抵挡：计入"完全抵挡"统计（战术大师称号）
					stats[defender_idx]["blocked_dmg"] += attacker_last_damage
		else:
			if respond: add_log(defender_idx, "无法响应")
	if pending_attack_card == "freeze":
		# 冻结为单段攻击：结算后直接消耗卡结束
		_use_card(attacker_idx, {uid=pending_attack_uid, type_id=pending_attack_card})
		if final_damage == 0:
			add_log(attacker_idx, "冻结被闪避")
		else:
			status.freeze_player(defender_idx)
			add_log(attacker_idx, "冻结: %s" % _target_name(defender_idx))
		state_changed.emit(get_full_state())
		return
	if final_damage > 0:
		# 强化攻击命中防具：只掉 2 点耐久（穿甲），不叠加正常消耗 -1（玩家要求）
		if _armor_hit and _armor_pierce:
			combat.pierce_armor(defender_idx)
			add_log(attacker_idx, "穿甲: 防具耐久-2")
		elif _armor_hit:
			combat.consume_armor(defender_idx)  # 普通攻击：防具耐久在实际伤害时消耗（被闪避后为0不消耗）
		_armor_hit = false
		_armor_pierce = false
		# 重锤：响应后仍有伤害（格挡减半后 >0）则触发额外-1耐久；被闪避/格挡至0不触发
		if _hammer_pierce:
			combat.pierce_armor(defender_idx, 1)
			add_log(attacker_idx, "重锤: 护甲耐久-1")
		var before_skill = final_damage
		final_damage = char_skills.on_taking_damage(defender_idx, attacker_idx, final_damage)
		if final_damage != before_skill:
			formula += "-%d" % (before_skill - final_damage)
		# 对战统计：伤害（来源=攻击）
		stats[attacker_idx]["damage_dealt"] += final_damage
		# 单次最大伤害（致命一击称号判定）
		if final_damage > stats[attacker_idx]["max_hit"]:
			stats[attacker_idx]["max_hit"] = final_damage
		stats[defender_idx]["damage_taken"] += final_damage
		stats[defender_idx]["damage_from_attack"] += final_damage
		var attacker_name = Config.char_name(players[attacker_idx].char_id)
		var defender_name = Config.char_name(players[defender_idx].char_id)
		# 真言为技能攻击：战报显示中文名（card_name 对无卡池条目返回英文 id）
		var card_name = "真言" if pending_attack_card == "priest_chant" else Config.card_name(pending_attack_card)
		add_log(attacker_idx, "%s使用%s对%s造成：%s=%d点伤害" % [attacker_name, card_name, defender_name, formula, final_damage])
		# 命中特效在死亡判定前（与重构前顺序一致：统计→日志→特效→判定）
		# 真言为技能攻击：不触发武器命中效果（毒牙/灼烧等）
		if pending_attack_card != "priest_chant":
			combat.apply_on_hit_effects(attacker_idx, defender_idx, final_damage, attacker_last_type)
		char_skills.on_attack_hit(attacker_idx, defender_idx, final_damage, attacker_last_type)
		# 风神弓：穿心命中并造成伤害后，控制对方移动1格（方向自由；多段攻击只触发一次）
		if not _wind_bow_pending and not players[attacker_idx].weapon.is_empty() \
				and players[attacker_idx].weapon.id == "wind_god_bow" and pending_attack_card == "pierce":
			_wind_bow_pending = true
			_wind_bow_target = defender_idx
			wind_bow_prompt.emit(attacker_idx, defender_idx)
		_damage_player(defender_idx, final_damage)  # 统一伤害入口（内部含死亡判定）
	else:
		# 0 伤害：闪避 / 格挡牵制到 0 / 满耐久防具免疫
		var was_blocked = _pending_blocked
		if was_blocked and _resp_effect != "dodge":
			# 防具免疫生效：消耗耐久（强化攻击只穿甲-2，不叠加正常消耗——玩家要求）
			if _armor_pierce:
				combat.pierce_armor(defender_idx)
				add_log(attacker_idx, "穿甲: 防具耐久-2")
			else:
				combat.consume_armor(defender_idx)
			# 重锤：被护甲挡下也算命中，额外-1耐久（强化攻击穿甲-2 与之叠加，满耐久护甲可一次碎裂）
			if _hammer_pierce:
				combat.pierce_armor(defender_idx, 1)
				add_log(attacker_idx, "重锤: 护甲耐久-1")
			stats[defender_idx]["blocked_dmg"] += attacker_last_damage
			add_log(attacker_idx, "被防具挡下")
		elif was_blocked and _resp_effect == "dodge":
			pass  # 闪避躲开：防具不消耗耐久（保甲成功，日志已在响应块记录"用X闪避"）
		_pending_blocked = false
		_armor_hit = false
		_armor_pierce = false
		char_skills.on_attack_failed_no_damage(attacker_idx, attacker_last_type)
		if _resp_effect == "" and not was_blocked:
			# 无任何响应且非防具免疫（纯 0 伤害攻击）：补充记录
			add_log(attacker_idx, "%s使用%s攻击未造成伤害" % [Config.char_name(players[attacker_idx].char_id),
				"真言" if pending_attack_card == "priest_chant" else Config.card_name(pending_attack_card)])
		# 共鸣：法术攻击被完全抵挡（护甲免疫生效/闪避/牵制归零）→ 额外造成2点伤害。
		# 0 伤害分支必然是完全抵挡（免疫挡下或响应归零），统一在此触发一次
		_apply_resonance_rebound(attacker_idx, defender_idx)
	if phase == Config.Phase.GAME_OVER: return  # 死亡判定已由 _damage_player 统一处理
	# 多段攻击：还有段则进入下一段响应窗口（每段独立结算；末段才消耗卡）
	# 注意：_begin_attack_segment 内部会自增段号，这里不能重复自增
	if pending_attack_segment < pending_attack_segments:
		_begin_attack_segment(attacker_idx)
		state_changed.emit(get_full_state())
		return
	# 无卡消耗标记（真言 -1）或卡已不在手牌时跳过；调试卡（负 uid）在手牌中照常消耗
	if pending_attack_uid >= 0 or card_systems[attacker_idx].has_card(pending_attack_uid):
		_use_card(attacker_idx, {uid=pending_attack_uid, type_id=pending_attack_card})
	turn_phase = Config.TurnPhase.ACTION
	# 响应方不限时清掉 deadline 后，攻击方（若限时）恢复出牌计时
	if _action_deadline == 0 and _timeout_enabled(attacker_idx):
		_action_deadline = Time.get_ticks_msec() + ACTION_TIME * 1000
	# 鹰眼等查看手牌由 get_full_state 统一带出并重置（防止提前 return 路径残留）
	state_changed.emit(get_full_state())

func skip_response(defender_idx: int): process_response(defender_idx, false)

# 风神弓：控制对方移动1格（方向自由；无方向/取消 = 放弃；无法移动 = 效果无效）
func _handle_wind_bow_move(player_idx: int, data: Dictionary) -> Dictionary:
	if not _wind_bow_pending: return {success=false, msg="无待决的风神弓控制"}
	if player_idx != _response_attacker: return {success=false, msg="不是你的控制权"}
	var target = _wind_bow_target
	_wind_bow_pending = false
	_wind_bow_target = -1
	if target < 0 or target >= players.size(): return {success=false, msg="目标无效"}
	var dir = movement.geometry.from_dict(data.get("direction", {}))
	if data.get("cancel", false) or dir == Vector2i.ZERO:
		add_log(player_idx, "风神弓: 放弃控制移动")
		state_changed.emit(get_full_state())
		return {success=true}
	var before = players[target].position
	# 冻结/神隐等无法移动、边界、位置被占 → move_player 失败或未位移 → 效果无效
	if not movement.move_player(target, dir, false) or players[target].position == before:
		add_log(player_idx, "风神弓: 对方无法移动")
		state_changed.emit(get_full_state())
		return {success=true}
	add_log(player_idx, "风神弓: 控制%s移动1格" % _target_name(target))
	_check_any_death()  # 位移可能踩陷阱致死
	state_changed.emit(get_full_state())
	return {success=true}

# 共鸣：法术攻击被完全抵挡时额外造成2点伤害（穿透反震，不再受响应/防具影响）
func _apply_resonance_rebound(attacker_idx: int, defender_idx: int):
	if not _resonance_rebound: return
	_damage_player(defender_idx, 2)
	stats[attacker_idx]["damage_dealt"] += 2
	stats[defender_idx]["damage_taken"] += 2
	stats[defender_idx]["damage_from_attack"] += 2
	add_log(attacker_idx, "共鸣: 被完全抵挡，反震2点伤害")

func _handle_move_card(player_idx: int, card: Dictionary) -> Dictionary:
	var direction: Vector2i = movement.geometry.from_dict(card.get("direction", {}))
	var steps = int(card.get("steps", 1))
	# 方向校验：线性只认左右；六边形（多人局）认 6 个轴向方向。
	# 以后加新布局：把该布局的方向表加入 HEX_DIRS 同级的常量并在校验里引用
	var geo = movement.geometry
	if geo._mode == MapGeometry.MODE_HEX:
		if not direction in geo.HEX_DIRS:
			return {success=false, msg="无效移动方向"}
	else:
		if direction != geo.DIR_LEFT and direction != geo.DIR_RIGHT:
			return {success=false, msg="无效移动方向"}
	if not char_skills.move_distances(player_idx).has(steps):
		return {success=false, msg="不支持%d步移动" % steps}
	if status.get_move_modifier(player_idx) < 0:
		# 流程检查：禁移动时移动卡不消耗（movement.move_player 另有兜底检查）
		return {success=false, msg="本回合无法移动"}
	for _s in range(steps):
		if not movement.move_player(player_idx, direction): break
		if phase == Config.Phase.GAME_OVER: break  # 踩陷阱致死淘汰：停止后续移动
		# 位移统计（moves）由 movement.move_player 内部统一更新（含推人/吸引/威慑/暗影步）
	_use_card(player_idx, card)
	add_log(player_idx, "移动到%s" % movement.geometry.to_text(players[player_idx].position))
	if movement.get_distance() == 0:
		_moved_to_adjacent_this_turn = true  # 突刺武器：移动贴脸后额外+3
	item_system.trigger_on_step(player_idx)  # 死亡判定由 _damage_player 统一处理
	return {success=true}

func _handle_destroy(player_idx: int, card: Dictionary) -> Dictionary:
	var opp = get_opponent(player_idx, int(card.get("target", -1)))
	if opp < 0: return {success=false, msg="请选择目标"}
	var target = card.get("destroy_target", "hand")
	if target == "hand":
		card_systems[opp].random_discard(1); _use_card(player_idx, card); add_log(player_idx, "摧毁手牌: %s" % _target_name(opp)); return {success=true}
	if target == "trap":
		# 摧毁必须指定格子（客户端走棋盘选格；无位置参数视为操作错误）
		var pos: Vector2i = movement.geometry.from_dict(card.get("trap_pos", {}))
		if not movement.geometry.is_valid(pos):
			return {success=false, msg="请选择要摧毁的格子"}
		if item_system.destroy_item_at(pos):
			_use_card(player_idx, card); add_log(player_idx, "摧毁%s格道具" % movement.geometry.to_text(pos)); return {success=true}
		return {success=false, msg="该格没有道具"}
	var et = card.get("equip_type", "weapon")
	if et != "weapon" and et != "armor": return {success=false, msg="无效装备类型"}
	var msg = equipment.destroy_equipment(opp, et)
	if "没有" in msg or "免疫" in msg:
		return {success=false, msg=msg}  # 目标不存在/免疫摧毁（活铠）：卡不消耗
	_use_card(player_idx, card); add_log(player_idx, msg); return {success=true}

func _handle_seize(player_idx: int, card: Dictionary) -> Dictionary:
	var opp = get_opponent(player_idx, int(card.get("target", -1)))
	if opp < 0: return {success=false, msg="请选择目标"}
	var taken = card_systems[opp].random_take(); _use_card(player_idx, card)
	if taken.is_empty(): add_log(player_idx, "夺取空"); return {success=true}
	card_systems[player_idx].add_to_hand(taken)
	add_log(player_idx, "夺取%s的：%s" % [_target_name(opp), Config.card_name(taken.type_id)])
	return {success=true}

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
	# 自定义房间「手牌下限」：手牌已 ≤ 下限 → 无需弃牌，直接进入下一玩家
	if hand_min_override > 0 and card_systems[current_player].hand.size() <= hand_min_override:
		waiting_for_discard = false
		_finish_discard()
		return
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
	var n = players.size()
	var next = (current_player + 1) % n
	var guard = 0
	while players[next].get("eliminated", false) and guard < n:
		next = (next + 1) % n
		guard += 1
	current_player = next
	if current_player == first_player: turn_number += 1
	_judgment_phase()
	state_changed.emit(get_full_state())

# 位移/陷阱类效果后检查死亡（吸引/威慑可能让任一方踩陷阱）
func _check_any_death():
	for i in range(players.size()):
		if players[i].hp <= 0 and not players[i].get("eliminated", false):
			_handle_death(i)
			return

# 统一伤害入口：所有伤害来源（攻击/DoT/陷阱等）走这里扣血，
# 扣血后自动判定死亡（防重入：复活/结束阶段不重复判定）。
# 彻底杜绝"新增伤害来源漏掉死亡判定"类 bug。
func _damage_player(player_idx: int, amount: int):
	var p = players[player_idx]
	p.hp -= amount
	if p.hp <= 0 and phase != Config.Phase.RESURRECTING and phase != Config.Phase.GAME_OVER:
		_check_any_death()

func _handle_death(player_idx: int):
	# 多人（4 人）混战：死亡直接淘汰（无复活），最后存活者胜
	if players.size() > 2:
		players[player_idx].eliminated = true
		players[player_idx].hp = 0
		discard_count = 0
		add_log(player_idx, "淘汰")
		_check_multi_winner()
		if phase != Config.Phase.GAME_OVER:
			state_changed.emit(get_full_state())  # 淘汰也要广播（UI 显示"已淘汰"）
		return
	add_log(player_idx, "HP归零，复活...")
	# 自定义房间「复活次数上限」：达到上限直接淘汰（不再进入复活流程）
	if resurrect_limit_override >= 0 and stats[player_idx]["resurrected"] >= resurrect_limit_override:
		_check_permanent_death(player_idx)
		return
	phase = Config.Phase.RESURRECTING
	_action_deadline = 0
	_discard_deadline = 0
	card_systems[player_idx].discard_all()
	# 地狱难度 AI（人机 P1）：不污染牌库——不抽 4 张（会大幅扰动共享牌堆/记牌），
	# 改为牌堆检索回复卡（仅拿走一张），检索不到则正常淘汰
	if ai_difficulty >= Config.AI_DIFF_HELL and player_idx == 1:
		_hell_resurrect(player_idx)
		return
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
		players[player_idx].frozen = false; players[player_idx].frozen_lockout = 0
		phase = Config.Phase.PLAYER_TURN; response_pending = false
		state_changed.emit(get_full_state())
	else: _check_permanent_death(player_idx)

# 地狱难度 AI 复活：牌堆检索一张回复卡使用（不抽 4 张，牌库只少一张、零额外扰动）；
# 检索不到或回复量不足 → 淘汰（与普通规则一致，不做概率复活）
func _hell_resurrect(player_idx: int):
	# 地狱 AI 检索复活限 2 次（超过直接淘汰，避免无限复苏拖长对局）
	if stats[player_idx]["resurrected"] >= 2:
		_check_permanent_death(player_idx)
		return
	var cs = card_systems[player_idx]
	var heal = {}
	for i in range(cs.deck.size() - 1, -1, -1):
		if cs.deck[i].type_id in ["heal_3", "heal_5"]:
			heal = cs.deck.pop_at(i)
			break
	if not heal.is_empty():
		cs.add_to_hand(heal)
		while cs.has_heal_card() and players[player_idx].hp <= 0:
			_use_heal_in_resurrection(player_idx)
	if players[player_idx].hp <= 0:
		_check_permanent_death(player_idx)
		return
	add_log(player_idx, "地狱AI复苏成功")
	stats[player_idx]["resurrected"] += 1  # 对战统计：复活次数
	players[player_idx].frozen = false; players[player_idx].frozen_lockout = 0
	phase = Config.Phase.PLAYER_TURN; response_pending = false
	state_changed.emit(get_full_state())

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
			turn_number=turn_number,  # 结算显示总回合数
			stats=stats.duplicate(),
			names=_player_names(),
			titles=_calc_titles(winner, true),
			titles_loser=_calc_titles(player_idx, false),
			# 每名玩家的称号（结算界面统计卡片"查看称号"展开用；自己视角只看顶部自己的）
			player_titles=[_calc_titles(0, winner == 0), _calc_titles(1, winner == 1)],
			eliminated=[players[0].get("eliminated", false), players[1].get("eliminated", false)],
			end_players=_end_player_snapshot(),  # 结束时各方面板（结算界面查看成长）
			battle_record=battle_record.duplicate(),
			action_log=action_log.duplicate(),
		}
		add_log(player_idx, "淘汰")
		state_changed.emit(get_full_state())
		game_ended.emit(game_result)

# 多人混战：每淘汰一人检查存活数，只剩 1 人时结束对局
func _check_multi_winner():
	var alive: Array = []
	for i in range(players.size()):
		if not players[i].get("eliminated", false): alive.append(i)
	if alive.size() <= 1:
		var winner = alive[0] if alive.size() == 1 else -1
		phase = Config.Phase.GAME_OVER
		response_pending = false
		var pts: Array = []
		var eli: Array = []
		for i in range(players.size()):
			pts.append(_calc_titles(i, i == winner, winner))
			eli.append(players[i].get("eliminated", false))
		game_result = {
			winner=winner, loser=-1, reason="last_alive",
			turn_number=turn_number,  # 结算显示总回合数
			stats=stats.duplicate(),
			names=_player_names(),
			titles=_calc_titles(winner, true) if winner >= 0 else [],
			titles_loser=[],
			player_titles=pts,
			eliminated=eli,
			end_players=_end_player_snapshot(),  # 结束时各方面板（结算界面查看成长）
			battle_record=battle_record.duplicate(),
			action_log=action_log.duplicate(),
		}
		state_changed.emit(get_full_state())
		game_ended.emit(game_result)

# 对局结束时的玩家面板快照（结算界面显示"成长"：结束时 vs 初始 CHARCTER_DB）
func _end_player_snapshot() -> Array:
	var out: Array = []
	for p in players:
		out.append({
			char_id=p.char_id, name=Config.char_name(p.char_id),
			hp=p.hp, max_hp=p.max_hp,
			near=p.near_power, range=p.range_power, magic=p.magic_power,
		})
	return out

func _player_names() -> Array:
	var names: Array = []
	for p in players:
		names.append(Config.char_name(p.char_id))
	return names

# 称号难度分级（UI 徽章颜色）：gold=金色大框（最难）blue=蓝色框 white=白色框（最易）
const TITLE_TIERS := {
	"完美击杀": "gold", "毁灭之王": "gold", "耐杀王": "gold", "不死鸟": "gold",
	"出师不利": "gold", "负隅顽抗": "gold", "虽败犹荣": "gold",
	"武器专家": "gold", "战术大师": "gold",
	"致命一击": "gold", "完美形态": "gold",
	"险胜": "blue", "伤痕累累": "blue", "苦战": "blue",
	"坚守阵地": "blue", "马拉松冠军": "blue", "火力压制": "blue",
	"征服者": "white",
}

# 称号判定（is_winner: 胜者/败者归属），可同时获得多个
# 同条件类型互斥：同组内按定义顺序只保留第一个（定义顺序=条件更苛刻的优先），
# 例如胜者达成毁灭之王（伤害>50）则不再给火力压制（伤害>30）
# 主称号 = 难度最高档（gold > blue > white），同档保持判定顺序
func _calc_titles(player_idx: int, is_winner: bool, winner_idx: int = -1) -> Array:
	var w = stats[player_idx]
	var groups := {
		"dmg": [], "taken": [], "resurrect": [], "moves": [],
		"responses": [], "hp_self": [], "turns": [],
		"weapons": [], "blocked": [], "max_hit": [], "perfect": [],
	}
	if is_winner:
		# 胜者专属
		if w["damage_taken"] == 0: groups["taken"].append("完美击杀")
		if w["damage_dealt"] > 50: groups["dmg"].append("毁灭之王")
		if w["damage_taken"] > 55: groups["taken"].append("耐杀王")
		if w["resurrected"] >= 2: groups["resurrect"].append("不死鸟")
		if players[player_idx].hp < 5: groups["hp_self"].append("险胜")
	else:
		# 败者专属
		if w["damage_dealt"] == 0: groups["dmg"].append("出师不利")
		if w["resurrected"] >= 2: groups["resurrect"].append("负隅顽抗")
		# 虽败犹荣：败者伤害高于胜者（2 人局=唯一对手；多人局=最终胜者；平局无对比对象不判）
		var cmp = winner_idx if winner_idx >= 0 else 1 - player_idx
		if cmp >= 0 and cmp < players.size() and w["damage_dealt"] > stats[cmp]["damage_dealt"]:
			groups["dmg"].append("虽败犹荣")
		if w["damage_taken"] > 55: groups["taken"].append("伤痕累累")
		if turn_number > 20: groups["turns"].append("苦战")
	# 通用（不论胜负）
	if w["weapons_used"].size() >= 6: groups["weapons"].append("武器专家")
	if w["blocked_dmg"] > 60: groups["blocked"].append("战术大师")
	if w["responses"] >= 15: groups["responses"].append("坚守阵地")
	if w["moves"] > 10: groups["moves"].append("马拉松冠军")
	if w["damage_dealt"] > 30: groups["dmg"].append("火力压制")
	if w["max_hit"] > 15: groups["max_hit"].append("致命一击")
	# 完美形态：游戏结束时三项数值面板均 > 6
	var pp = players[player_idx]
	if pp.near_power > 6 and pp.range_power > 6 and pp.magic_power > 6:
		groups["perfect"].append("完美形态")
	var titles: Array = []
	for g in groups:
		if not groups[g].is_empty():
			titles.append(groups[g][0])
	# 主称号 = 最难档优先（gold > blue > white），同档保持判定顺序
	var rank := {"gold": 0, "blue": 1, "white": 2}
	titles.sort_custom(func(a: String, b: String) -> bool:
		return rank[TITLE_TIERS.get(a, "blue")] < rank[TITLE_TIERS.get(b, "blue")])
	# 征服者：胜利必得（放最后，白色档最易）
	if is_winner:
		titles.append("征服者")
	return titles

func check_timers():
	var now = Time.get_ticks_msec()
	if phase == Config.Phase.BP_PHASE:
		if not bp_timer_active(): return  # 本地模式 BP 不限时（AI 自动操作不依赖计时）
		var before = bp.bp_phase
		bp.check_bp_timer()
		if bp.bp_phase != before:
			# 超时自动操作后广播，让客户端 UI 刷新并推进流程
			bp_state_changed.emit(bp.get_bp_state())
		return
	if _action_deadline > 0 and now >= _action_deadline:
		# 超时对象：响应窗口是被攻击方（_pending_target），出牌阶段是当前玩家
		var timed_player = (_pending_target if response_pending else current_player)
		_action_deadline = 0
		if _timeout_enabled(timed_player):
			if response_pending:
				# 响应窗口超时：默认不响应，结算后攻击者继续出牌（避免软锁）
				skip_response(_pending_target)
				if phase == Config.Phase.PLAYER_TURN and turn_phase == Config.TurnPhase.ACTION:
					_action_deadline = Time.get_ticks_msec() + ACTION_TIME * 1000
				return
			add_log(current_player, "回合超时")
			if waiting_for_weapon_choice >= 0:
				confirm_weapon(waiting_for_weapon_choice, false)  # 武器选择超时默认放弃
			_discard_phase()
	if _discard_deadline > 0 and now >= _discard_deadline:
		_discard_deadline = 0
		if _timeout_enabled(current_player):
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
	var desc = Config.CHARACTER_DB.get(players[player_idx].char_id, {}).get("skill_desc", "")
	for sk in char_skills.has_active_skills(player_idx):
		out.append({"id": sk, "name": char_skills.skill_button_name(sk), "desc": desc})
	return out

func get_full_state(full: bool = false) -> Dictionary:
	var now = Time.get_ticks_msec()
	var atl = -1
	if _action_deadline > 0:
		var timed_player = (_pending_target if response_pending else current_player)
		if _timeout_enabled(timed_player):
			atl = max(0, int((_action_deadline - now) / 1000.0))
	var dtl = -1
	if _discard_deadline > 0 and _timeout_enabled(current_player):
		dtl = max(0, int((_discard_deadline - now) / 1000.0))
	var state = {
		phase=phase, turn_phase=turn_phase, current_player=current_player,
		turn_number=turn_number, first_player=first_player,
		response_pending=response_pending, pending_attack_card=pending_attack_card,
		pending_attack_segment=pending_attack_segment, pending_attack_segments=pending_attack_segments,
		pending_target=_pending_target,  # 当前攻击/技能的目标（多人局响应弹窗用）
		waiting_for_discard=waiting_for_discard, discard_count=discard_count,
		action_time_left=atl, discard_time_left=dtl,
		deck_size=card_systems[0].deck.size(), discard_size=card_systems[0].discard.size(),
		independent_decks=independent_decks,  # 独立牌堆标记（UI 决定显示单方/双方牌堆）
		players=[], items=_serialize_items(), action_log=action_log.duplicate(),
		distance=movement.get_distance(_nearest_alive_opponent(current_player)),
	}
	for i in range(players.size()):
		var p = players[i]; var cs = card_systems[i]
		state.players.append({
			index=i, char_id=p.char_id, char_name=Config.char_name(p.char_id),
			hp=p.hp, max_hp=p.max_hp,
			near_power=p.near_power, range_power=p.range_power, magic_power=p.magic_power,
			position=movement.geometry.to_dict(p.position), weapon=p.weapon, armor=p.armor,
			buffs=p.buffs.duplicate(), dots=p.dots.duplicate(), frozen=p.frozen,
			eliminated=p.get("eliminated", false),
			ap_attack=p.get("ap_attack",0), ap_move=p.get("ap_move",0), ap_function=p.get("ap_function",0),
			hand_size=cs.hand.size(), deck_size=cs.deck.size(), discard_size=cs.discard.size(),
			hand=cs.hand.duplicate(), hand_limit=movement.get_hand_limit(i),
			active_skills=_skill_list(i),
			pending_fighter_skill=p.get("pending_fighter_skill", false),
			# 角色道具类型（一张通用道具卡，卡面/说明按角色道具显示）
			item_type=char_skills.get_item_type(i),
			item_type_name=item_system.get_item_type(char_skills.get_item_type(i)).get("name", "道具"),
			item_type_desc=item_system.get_item_type(char_skills.get_item_type(i)).get("desc", ""),
		})
	if full: state.bp_state = bp.get_bp_state()
	# 鹰眼等查看手牌效果：快照统一带出 revealed 并立即重置。
	# 放在 get_full_state 内部可防止 process_response 提前 return 路径漏重置
	# （残留的 _reveal_to 会让后续任意状态刷新误弹"查看手牌"）
	if _reveal_to >= 0:
		state["revealed_hand"] = card_systems[_reveal_from].get_hand_type_ids()
		state["revealed_to"] = _reveal_to
		state["revealed_from"] = _reveal_from  # 被查看手牌的目标玩家（弹窗显示"谁"）
		_reveal_to = -1; _reveal_from = -1
	_record_snapshot(state)
	return state

# 道具序列化（position Vector2i → {x,y}，协议/JSON 传输用）
func _serialize_items() -> Array:
	var out = []
	for it in items:
		var d = it.duplicate()
		d["position"] = movement.geometry.to_dict(it.position)
		out.append(d)
	return out

# 对局快照：每玩家每回合的出牌/弃牌阶段各记一次（手牌内容/血量/位置/AP/牌堆）
func _record_snapshot(st: Dictionary):
	var tp = st.get("turn_phase", -1)
	if tp != 2 and tp != 3: return  # 只记录出牌/弃牌阶段
	var cur = st.get("current_player", -1)
	var turn = st.get("turn_number", 0)
	var key = "%d_%d_%d" % [turn, cur, tp]
	if key == _last_rec_key: return
	_last_rec_key = key
	var rec := {turn=turn, player=cur, phase=tp}
	for p in st.get("players", []):
		var hand_names := []
		for c in p.get("hand", []):
			hand_names.append(Config.card_name(c.type_id))
		rec["p%d" % p.get("index", -1)] = {
			hp=p.get("hp", 0), max_hp=p.get("max_hp", 1), pos=p.get("position", 0),
			hand=hand_names, ap=[p.get("ap_attack", 0), p.get("ap_move", 0), p.get("ap_function", 0)],
		}
	# 独立卡组：记录当前行动玩家自己的牌堆/弃牌数（原共享牌堆时两者一致）
	var cur_p = {}
	for p in st.get("players", []):
		if p.get("index", -1) == cur:
			cur_p = p
			break
	rec.deck = cur_p.get("deck_size", st.get("deck_size", 0))
	rec.discard = cur_p.get("discard_size", st.get("discard_size", 0))
	battle_record.append(rec)

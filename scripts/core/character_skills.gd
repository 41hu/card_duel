# ============================================================
# character_skills.gd — 角色技能钩子系统
#
# 【架构说明】：所有角色技能逻辑集中在本文件，match_state.gd 通过钩子调用。
# 每个钩子接收 player_idx，内部用 match char_id 分发到具体技能实现。
#
# 【加新角色步骤】：
#   1. config.gd 的 CHARACTER_DB 加一行角色数据
#   2. 在对应钩子方法里加 match 分支
#   3. 写技能实现函数（_xxx 前缀的私有方法）
#
# 【钩子列表】：
#   on_turn_start        — 回合开始时调用（重置AP、状态）
#   on_turn_end          — 回合结束时调用（术士抽牌等）
#   on_opponent_turn_start — 对方回合开始时调用
#   can_attack_free      — 判断某次攻击是否免费（返回bool）
#   on_attack_cast       — 攻击牌打出时，返回额外伤害加成
#   on_attack_hit        — 攻击命中后触发（剑士回血等）
#   on_taking_damage     — 即将受伤时，返回修正后的伤害值
#   on_heal              — 回复时，返回修正后的回复量
#   has_active_skill     — 是否有主动技能可用（返回技能名或空字符串）
#   use_skill            — 执行主动技能（返回{success, msg}）
#   draw_count           — 每回合抽牌数（默认2）
#   can_upgrade_skill    — 是否可升级技能
#   upgrade_skill        — 升级技能（弃N张牌永久增强）
#   is_immune            — 是否免疫某效果（freeze/dot_xxx/force_move）
#   modify_max_hp        — 修改生命上限
#   armor_durability_bonus — 防具额外耐久
#
# 【玩家数据字典】：每个玩家是一个 Dictionary，包含：
#   char_id, hp, max_hp, near_power, range_power, magic_power,
#   position, weapon, armor, buffs, dots, frozen, frozen_lockout,
#   frozen_move, damage_reduction_used, skill_used_this_turn,
#   free_move_used, mage_buffed, combo_attacks_this_turn,
#   ap_attack, ap_move, ap_function, upgrades
# ============================================================
extends RefCounted

# _ms = MatchState 实例引用，通过它访问 players[], card_systems[], status 等子系统
var _ms

func _init(ms):
	_ms = ms

# ---------- 钩子入口 ----------
func on_attack_hit(attacker_idx: int, _defender_idx: int, _damage: int, damage_type: int):
	var p = _ms.players[attacker_idx]
	match p.char_id:
		"swordsman": _swordsman_hit(attacker_idx, damage_type)

func on_taking_damage(defender_idx: int, _attacker_idx: int, base_damage: int) -> int:
	var p = _ms.players[defender_idx]
	match p.char_id:
		"paladin": return _paladin_reduce(defender_idx, base_damage)
		"berserker": _berserker_rage(defender_idx)
	return base_damage

func on_heal(player_idx: int, amount: int) -> int:
	var p = _ms.players[player_idx]
	# 每回合回复上限（-1无限制）
	var limit = _heal_limit(player_idx)
	if limit > 0:
		var healed = p.get("healed_this_turn", 0)
		var allowed = limit - healed
		if allowed <= 0: return 0
		amount = min(amount, allowed)
		p.healed_this_turn = healed + amount
	if p.char_id == "priest": amount += 2
	return amount

func _heal_limit(player_idx: int) -> int:
	match _ms.players[player_idx].char_id:
		_: return -1

func on_turn_start(player_idx: int):
	var p = _ms.players[player_idx]
	p.skill_used_this_turn = false
	p.free_move_used = false
	p.damage_bonus = {}
	p.healed_this_turn = 0
	p.damage_reduction_used = false
	p.pending_swordsman_skill = false
	p.combo_attacks_this_turn = []
	match p.char_id:
		"warlock": p.ap_function = 2
		_: p.ap_function = 1
	p.ap_attack = 2
	p.ap_move = 1

func on_turn_end(player_idx: int):
	var p = _ms.players[player_idx]
	if p.char_id == "warlock" and p.ap_function >= 1:
		_ms.card_systems[player_idx].draw_cards(1)
		_ms.add_log(player_idx, "术士+1抽")

func can_attack_free(player_idx: int, card_type: String) -> bool:
	var p = _ms.players[player_idx]
	if p.char_id == "archer" and card_type == "range" and not p.skill_used_this_turn:
		return true
	return false

# 增伤标记（任何技能都可以设置，下次攻击时自动消耗）
func set_damage_bonus(player_idx: int, types: Array, amount: int, label: String):
	var p = _ms.players[player_idx]
	p.damage_bonus = {"types": types, "amount": amount, "label": label}

func on_attack_cast(player_idx: int, type_id: String) -> int:
	var p = _ms.players[player_idx]
	var opp = 1 - player_idx
	var db = p.get("damage_bonus", {})
	# 目标免疫技能增伤
	if not db.is_empty() and _ms.char_skills.is_immune(opp, "skill_damage"):
		p.damage_bonus = {}
		return 0
	if db.is_empty(): return 0
	if type_id in db.types:
		p.damage_bonus = {}
		_ms.add_log(player_idx, "%s: +%d伤害" % [db.label, db.amount])
		return db.amount
	return 0

func on_opponent_turn_start(current_player_idx: int):
	var opp = 1 - current_player_idx
	match _ms.players[opp].char_id:
		_: pass  # 加新角色在这里

# ---------- 手牌条件注册表 ----------
var _hand_conditions: Dictionary = {}

func _init_conditions():
	if not _hand_conditions.is_empty(): return
	#=== 全局条件注册表 ===
	# 添加方式: _hand_conditions["条件名"] = func(idx): return 布尔表达式
	# 可访问: _ms.players[idx].hp, _ms.card_systems[idx].hand 等
	_hand_conditions["has_attack"]   = func(idx): return _count_type(idx, Config.ATTACK_CARD_TYPES) > 0
	_hand_conditions["no_attack"]    = func(idx): return _count_type(idx, Config.ATTACK_CARD_TYPES) == 0
	_hand_conditions["hp_below_50"]  = func(idx): return _ms.players[idx].hp < _ms.players[idx].max_hp * 0.5
	_hand_conditions["hp_below_25"]  = func(idx): return _ms.players[idx].hp < _ms.players[idx].max_hp * 0.25
	# 自定义示例:
	# "hp_below_10" = func(idx): return _ms.players[idx].hp < 10

func check_hand_condition(player_idx: int, condition: String) -> bool:
	_init_conditions()
	var fn = _hand_conditions.get(condition, null)
	if fn: return fn.call(player_idx)
	return true

func _count_type(player_idx: int, types: Array) -> int:
	var n = 0
	for c in _ms.card_systems[player_idx].hand:
		if c.type_id in types: n += 1
	return n

# 返回可用技能名（空字符串=不可用）
# 新角色示例: "xxx": return "skill_xxx" if check_hand_condition(idx, "has_attack") else ""
func has_active_skill(player_idx: int) -> String:
	var p = _ms.players[player_idx]
	if p.skill_used_this_turn: return ""
	match p.char_id:
		"mage": return "mage_discard" if p.damage_bonus.is_empty() else ""
		"assassin": return "assassin_move"
	return ""

# 整局技能次数上限（-1表示无限制）
func skill_game_limit(skill: String) -> int:
	match skill:
		_: return -1  # 默认不限制

func use_skill(player_idx: int, skill: String, params: Dictionary) -> Dictionary:
	var p = _ms.players[player_idx]
	if p.skill_used_this_turn: return {success=false, msg="本回合已使用过"}
	var limit = skill_game_limit(skill)
	if limit > 0:
		var used = p.skill_counts.get(skill, 0)
		if used >= limit: return {success=false, msg="整局已达上限(%d次)" % limit}
		p.skill_counts[skill] = used + 1
	p.skill_used_this_turn = true
	match skill:
		"mage_discard": return _mage_discard(player_idx, params)
		"assassin_move": return _assassin_move(player_idx, params)
	return {success=false, msg="未知技能"}

# 技能升级：弃N张牌永久增强技能效果。加新角色写在这里
# 移动步数选项（返回可选的步数数组，默认[1]）
# 手牌上限修正（在基础值上加减，基础=到板边距离+1）
func hand_limit_bonus(player_idx: int) -> int:
	match _ms.players[player_idx].char_id:
		_: return 0

func move_distances(player_idx: int) -> Array:
	match _ms.players[player_idx].char_id:
		_: return [1]

func draw_count(player_idx: int) -> int:
	match _ms.players[player_idx].char_id:
		_: return 2

func can_upgrade_skill(player_idx: int) -> String:
	match _ms.players[player_idx].char_id:
		_: return ""  # 默认不可升级

func upgrade_skill(player_idx: int, discarded_count: int) -> Dictionary:
	var p = _ms.players[player_idx]
	var key = str("up_", p.char_id)
	p.upgrades[key] = p.upgrades.get(key, 0) + discarded_count
	_ms.add_log(player_idx, "技能永久增强! (+%d级)" % discarded_count)
	return {success=true}

# 免疫检测：加新角色在这里
# 免疫: 返回true则免疫该效果
# 效果类型: "freeze" "dot_poison" "dot_burn" "force_move" "skill_damage"
# 示例: "新角色": return effect in ["freeze", "dot_poison"]
func is_immune(player_idx: int, _effect: String) -> bool:
	match _ms.players[player_idx].char_id:
		_: return false

# 修改生命上限（保底1）
# 修改面板值（正加负减，下限0）
func modify_stat(player_idx: int, stat: String, delta: int):
	var p = _ms.players[player_idx]
	match stat:
		"near": p.near_power = max(0, p.near_power + delta)
		"range": p.range_power = max(0, p.range_power + delta)
		"magic": p.magic_power = max(0, p.magic_power + delta)
	_ms.add_log(player_idx, "%s面板%+d" % [stat, delta])

func modify_max_hp(player_idx: int, delta: int):
	var p = _ms.players[player_idx]
	p.max_hp = max(1, p.max_hp + delta)
	p.hp = min(p.hp, p.max_hp)
	_ms.add_log(player_idx, "生命上限%+d" % delta)
	if delta > 0: p.hp = min(p.hp + delta, p.max_hp)

# 是否能装备（返回空=可以，否则返回拒绝原因）
func can_equip(player_idx: int, _equip_type: String) -> String:
	match _ms.players[player_idx].char_id:
		# "新角色": return "无法装备" + equip_type  # 禁止某类装备
		_: return ""

func armor_durability_bonus(player_idx: int) -> int:
	if _ms.players[player_idx].char_id == "paladin": return 1
	return 0

# ---------- 各角色技能实现 ----------
func _swordsman_hit(player_idx: int, damage_type: int):
	var p = _ms.players[player_idx]
	if damage_type == Config.DamageType.PHYSICAL and not p.skill_used_this_turn:
		p.pending_swordsman_skill = true

func _paladin_reduce(player_idx: int, base: int) -> int:
	var p = _ms.players[player_idx]
	if not p.damage_reduction_used:
		p.damage_reduction_used = true
		return max(0, base - 2)
	return base

func _berserker_rage(player_idx: int):
	_ms.status.add_buff(player_idx, "attack_up", 1, 2)
	_ms.add_log(player_idx, "狂战士+1近战")

func _mage_discard(player_idx: int, params: Dictionary) -> Dictionary:
	var uid = int(params.get("card_uid", -1))
	var cs = _ms.card_systems[player_idx]
	if not cs.has_card(uid): return {success=false, msg="没有此牌"}
	cs.discard_card(uid)
	set_damage_bonus(player_idx, ["magic", "chant"], 2, "法师强化")
	_ms.add_log(player_idx, "弃牌强化:下次魔法+2")
	return {success=true}

func _assassin_move(player_idx: int, params: Dictionary) -> Dictionary:
	var dir = params.get("direction", 0)
	if dir == 0: return {success=false, msg="请选择方向"}
	if not _ms.movement.move_player(player_idx, dir): return {success=false, msg="无法移动"}
	var td = _ms.movement.check_trap_trigger(player_idx)
	if td > 0: _ms.players[player_idx].hp -= td
	_ms.add_log(player_idx, "暗影步")
	return {success=true}

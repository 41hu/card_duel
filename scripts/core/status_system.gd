# status_system.gd — 状态系统（Buff、DoT、冻结、被动技能标记）
extends RefCounted

var match_ref

# Buff 修正注册表：新增影响攻击/移动的 buff 只需在这里注册一个 handler，
# 无需改 get_attack_modifier / get_move_modifier 等消费点（开闭原则）
# handler 签名：func(buff: Dictionary, aspect: String, damage_type: int) -> int
var _modifier_handlers: Dictionary = {
	# 通用攻击加成（所有伤害类型）
	"attack_up": func(buff, aspect, _damage_type):
		return buff.value if aspect == "attack" else 0,
	# 通用攻击弱化（value 为负）
	"attack_down": func(buff, aspect, _damage_type):
		return buff.value if aspect == "attack" else 0,
	# 近战限定加成（狂战士）：仅物理类伤害（近战/重击）生效
	"near_up": func(buff, aspect, damage_type):
		return buff.value if (aspect == "attack" and damage_type == Config.DamageType.PHYSICAL) else 0,
	# 校准（寻踪者）：仅远程伤害生效，每层+1，无限叠加、永久持续（duration=-2）
	"calibration": func(buff, aspect, damage_type):
		return buff.value if (aspect == "attack" and damage_type == Config.DamageType.RANGED) else 0,
	# 攻击行动点削减（时滞）：回合开始设置攻击点时应用
	"ap_attack_down": func(buff, aspect, _damage_type):
		return buff.value if aspect == "ap_attack" else 0,
}

# Buff 叠加规则（触发次数开关）：max_stacks = N 同类型最多 N 层（达上限命中只刷新时长）；-1 无限叠加（默认）
# 例：时滞 ap_attack_down 设为 1 = 永不叠加（刷新），调大 = 允许多层，-1 = 无限
var _stack_rules: Dictionary = {
	"ap_attack_down": {"max_stacks": 1},
	# 神隐（巫女鸟居）：不可叠加（已有神隐再踩只保持跳过一回合）
	"神隐": {"max_stacks": 1},
	# 凋零（虚空魔典）：回复量-1，再次命中只刷新时长（不叠加）
	"wither_weapon": {"max_stacks": 1},
}

func _init(match):
	match_ref = match

# 添加Buff {type, value, duration}
# duration: >0 = 每回合衰减；-1 = 回合结束清除；-2 = 永久持续（on_turn_end 天然跳过）
# 按 _stack_rules 的 max_stacks 控制叠加：达上限时只刷新时长（不叠加）
func add_buff(player_idx: int, buff_type: String, value: int, duration: int):
	var player = match_ref.get_player(player_idx)
	var max_stacks = int(_stack_rules.get(buff_type, {}).get("max_stacks", -1))
	if max_stacks >= 0:
		var stacks = 0
		for b in player.buffs:
			if b.type == buff_type: stacks += 1
		if stacks >= max_stacks:
			# 达上限：刷新已有层的时长（duration -1 表示回合结束清除，保持原语义）
			for b in player.buffs:
				if b.type == buff_type:
					b.duration = max(b.duration, duration)
					return
			return
	player.buffs.append({type=buff_type, value=value, duration=duration})

# 幻影（法师）：50% 概率闪避一次攻击，成功消耗 1 层（失败保留）；无幻影返回 false
func try_phantom_dodge(player_idx: int) -> bool:
	var player = match_ref.get_player(player_idx)
	for i in range(player.buffs.size() - 1, -1, -1):
		if player.buffs[i].type == "mage_phantom" and player.buffs[i].value > 0:
			if randf() < 0.5:
				player.buffs[i].value -= 1
				if player.buffs[i].value <= 0:
					player.buffs.remove_at(i)
				return true
			return false
	return false

# 添加凋零（虚空魔典）：持续2回合，回复量-1；再次命中只刷新持续时间为2回合（不叠加层数）
func add_wither(player_idx: int):
	add_buff(player_idx, "wither_weapon", -1, 2)

# 凋零回复削减：返回当前凋零效果值（0 = 无凋零）
func get_heal_reduction(player_idx: int) -> int:
	var total := 0
	for b in match_ref.get_player(player_idx).buffs:
		if b.type == "wither_weapon":
			total += int(b.value)
	return total

# 添加灼烧：持续2回合，每回合-2HP，再次命中刷新持续时间为2回合（不叠加层数）
# source：施放者索引（用于伤害来源统计，-1=无来源）
func add_burn(player_idx: int, source: int = -1):
	if match_ref.char_skills.is_immune(player_idx, "dot_burn"): return
	var player = match_ref.get_player(player_idx)
	for dot in player.dots:
		if dot.type == "burn":
			dot.duration = 2  # 刷新持续时间
			return
	player.dots.append({type="burn", damage=2, duration=2, source=source})

# 添加中毒：每回合-1HP，再次命中+2层，层数每回合-1，可无限叠加
# source：施放者索引（用于伤害来源统计，-1=无来源）
func add_poison(player_idx: int, stacks: int = 2, source: int = -1):
	if match_ref.char_skills.is_immune(player_idx, "dot_poison"): return
	var player = match_ref.get_player(player_idx)
	for dot in player.dots:
		if dot.type == "poison":
			dot.duration += stacks  # 叠加层数
			return
	player.dots.append({type="poison", damage=1, duration=stacks, source=source})

# 冻结玩家
# 规则：冻结后隔一个完整回合才能再次冻结（t1 冻结→对方跳回合→t2 不能冻→t3 可冻）
func freeze_player(player_idx: int) -> bool:
	var player = match_ref.get_player(player_idx)
	if match_ref.char_skills.is_immune(player_idx, "freeze"): return false
	if match_ref.rapid_mode or match_ref.freeze_no_cooldown:
		# 快速模式/自定义「冻结无冷却」：可连续冻结
		player.frozen = true
		return true
	if player.frozen_lockout > 0:
		return false  # 冻结冷却中
	player.frozen = true
	player.frozen_lockout = 2  # 冷却 2 个出牌阶段（被冻回合 + 下一回合）
	return true

# 清除冻结（冷却计数由 _action_phase 每回合递减，不在此清除）
func clear_freeze(player_idx: int):
	var player = match_ref.get_player(player_idx)
	player.frozen = false

# 回合开始处理
func on_turn_start(_player_idx: int):
	pass  # 冻结锁在 match_state._action_phase 的冻结分支中解锁（仅正常回合）

# 回合结束处理
func on_turn_end(player_idx: int):
	var player = match_ref.get_player(player_idx)

	# 处理有限持续时间的buff
	for i in range(player.buffs.size() - 1, -1, -1):
		if player.buffs[i].duration > 0:
			player.buffs[i].duration -= 1
			if player.buffs[i].duration <= 0:
				player.buffs.remove_at(i)

	# 清理回合性buff（duration=-1，每回合结束时清除）
	for i in range(player.buffs.size() - 1, -1, -1):
		if player.buffs[i].duration == -1:
			player.buffs.remove_at(i)

	# 清除冻结移动限制
	player.frozen_move = false

	# 重置圣骑士被动
	player.damage_reduction_used = false

	# 清除技能使用标记
	player.skill_used_this_turn = false

# 统一 buff 修正查询入口（注册表模式）
# aspect: "attack"(攻击伤害) / "move"(移动)；damage_type: Config.DamageType（-1=不区分）
func query_modifier(player_idx: int, aspect: String, damage_type: int = -1) -> int:
	var player = match_ref.get_player(player_idx)
	var mod = 0
	for buff in player.buffs:
		var handler = _modifier_handlers.get(buff.type)
		if handler != null:
			mod += handler.call(buff, aspect, damage_type)
	return mod

# 获取攻击力修正（damage_type: Config.DamageType，用于区分近战限定加成）
func get_attack_modifier(player_idx: int, damage_type: int) -> int:
	return query_modifier(player_idx, "attack", damage_type)

# 是否持有指定 buff（神隐等一次性标记用）
func has_buff(player_idx: int, buff_type: String) -> bool:
	for b in match_ref.get_player(player_idx).buffs:
		if b.type == buff_type:
			return true
	return false

# 清除指定 buff（全部层）
func clear_buff(player_idx: int, buff_type: String):
	var p = match_ref.get_player(player_idx)
	for i in range(p.buffs.size() - 1, -1, -1):
		if p.buffs[i].type == buff_type:
			p.buffs.remove_at(i)

# 获取移动修正（霜咬效果等）
func get_move_modifier(player_idx: int) -> int:
	if match_ref.get_player(player_idx).frozen_move:
		return -999  # 位移=0
	return query_modifier(player_idx, "move")

# status_system.gd — 状态系统（Buff、DoT、冻结、被动技能标记）
extends RefCounted

var match_ref

# Buff 修正注册表：新增影响攻击/移动的 buff 只需在这里注册一个 handler，
# 无需改 get_attack_modifier / get_move_modifier 等消费点（开闭原则）
# handler 签名：func(buff: Dictionary, aspect: String, damage_type: int) -> int
var _modifier_handlers: Dictionary = {
	# 通用攻击加成（所有伤害类型）
	"attack_up": func(buff, aspect, damage_type):
		return buff.value if aspect == "attack" else 0,
	# 通用攻击弱化（value 为负）
	"attack_down": func(buff, aspect, damage_type):
		return buff.value if aspect == "attack" else 0,
	# 近战限定加成（狂战士）：仅物理类伤害（近战/重击）生效
	"near_up": func(buff, aspect, damage_type):
		return buff.value if (aspect == "attack" and damage_type == Config.DamageType.PHYSICAL) else 0,
}

func _init(match):
	match_ref = match

# 添加Buff {type, value, duration} duration=-1表示回合结束清除
func add_buff(player_idx: int, buff_type: String, value: int, duration: int):
	var player = match_ref.get_player(player_idx)
	player.buffs.append({type=buff_type, value=value, duration=duration})

# 添加灼烧：持续2回合，每回合-2HP，再次命中刷新持续时间为2回合（不叠加层数）
func add_burn(player_idx: int):
	if match_ref.char_skills.is_immune(player_idx, "dot_burn"): return
	var player = match_ref.get_player(player_idx)
	for dot in player.dots:
		if dot.type == "burn":
			dot.duration = 2  # 刷新持续时间
			return
	player.dots.append({type="burn", damage=2, duration=2})

# 添加中毒：每回合-1HP，再次命中+2层，层数每回合-1，可无限叠加
func add_poison(player_idx: int, stacks: int = 2):
	if match_ref.char_skills.is_immune(player_idx, "dot_poison"): return
	var player = match_ref.get_player(player_idx)
	for dot in player.dots:
		if dot.type == "poison":
			dot.duration += stacks  # 叠加层数
			return
	player.dots.append({type="poison", damage=1, duration=stacks})

# 冻结玩家
func freeze_player(player_idx: int) -> bool:
	var player = match_ref.get_player(player_idx)
	# 不能连续冻结
	if match_ref.char_skills.is_immune(player_idx, "freeze"): return false
	if player.frozen_lockout:
		return false
	player.frozen = true
	player.frozen_lockout = true
	return true

# 清除冻结
func clear_freeze(player_idx: int):
	var player = match_ref.get_player(player_idx)
	player.frozen = false
	player.frozen_lockout = true  # 本回合不能被再次冻结

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

# 获取移动修正（霜咬效果等）
func get_move_modifier(player_idx: int) -> int:
	if match_ref.get_player(player_idx).frozen_move:
		return -999  # 位移=0
	return query_modifier(player_idx, "move")

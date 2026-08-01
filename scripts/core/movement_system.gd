# movement_system.gd — 移动系统（棋盘位置、距离计算、推人、吸引/威慑）
extends RefCounted

var match_ref

func _init(match):
	match_ref = match

# 获取双方距离
func get_distance() -> int:
	var p1 = match_ref.get_player(0)
	var p2 = match_ref.get_player(1)
	return max(0, abs(p1.position - p2.position) - 1)

# 是否贴脸
func is_adjacent() -> bool:
	return get_distance() == 0

# 移动玩家（统一位移入口：移动卡/暗影步都走这里）
func move_player(player_idx: int, direction: int) -> bool:
	# 禁移动（霜咬 frozen_move 等）统一在此兜底，所有位移路径自动受限
	if match_ref.status.get_move_modifier(player_idx) < 0:
		return false
	var player = match_ref.get_player(player_idx)
	var other_player = match_ref.get_player(1 - player_idx)
	var new_pos = Config.clamp_position(player.position + direction)

	# 贴脸时向对方方向移动可推人（先判断推人，再判断阻挡）
	var moving_toward = (direction == (1 if player_idx == 0 else -1))
	if moving_toward and new_pos == other_player.position:
		if not _can_push(player_idx):
			return false
		_push_opponent(player_idx)
		player.position = new_pos
		return true

	# 不能移动到对方所在格（非推人情况）
	if new_pos == other_player.position:
		return false

	player.position = new_pos
	return true

# 获取到己方板边的距离（用于手牌上限计算）
func distance_to_own_edge(player_idx: int) -> int:
	var player = match_ref.get_player(player_idx)
	if player_idx == 0:  # P1在左边
		return player.position
	else:  # P2在右边
		return 10 - player.position

# 手牌上限
func get_hand_limit(player_idx: int) -> int:
	return distance_to_own_edge(player_idx) + 1 + match_ref.char_skills.hand_limit_bonus(player_idx)

# 推人逻辑
func _can_push(player_idx: int) -> bool:
	if not is_adjacent():
		return false
	var other = match_ref.get_player(1 - player_idx)
	var direction = 1 if player_idx == 0 else -1
	var new_pos = Config.clamp_position(other.position + direction)
	var my_pos = match_ref.get_player(player_idx).position
	# 不能推到和推动者重合
	return new_pos != my_pos

func _push_opponent(player_idx: int):
	var other = match_ref.get_player(1 - player_idx)
	var direction = 1 if player_idx == 0 else -1
	other.position = Config.clamp_position(other.position + direction)
	_trigger_items_on_step(1 - player_idx)

# 吸引：将对方拉向自己1格
func attract(player_idx: int) -> bool:
	var other = match_ref.get_player(1 - player_idx)
	if match_ref.char_skills.is_immune(1 - player_idx, "force_move"): return false
	var player = match_ref.get_player(player_idx)
	var my_pos = player.position
	var direction = 1 if other.position < my_pos else -1
	var new_pos = Config.clamp_position(other.position + direction)
	if new_pos == my_pos:
		# 贴脸：对方被吸引到我的位置，我沿对方方向后退一格腾出空间
		var my_new = Config.clamp_position(my_pos + direction)
		if my_new == other.position: return false
		other.position = my_pos
		_trigger_items_on_step(1 - player_idx)
		player.position = my_new
		_trigger_items_on_step(player_idx)
		return true
	other.position = new_pos
	_trigger_items_on_step(1 - player_idx)
	return true

# 威慑：将对方推远1格
func deter(player_idx: int) -> bool:
	var other = match_ref.get_player(1 - player_idx)
	if match_ref.char_skills.is_immune(1 - player_idx, "force_move"): return false
	var my_pos = match_ref.get_player(player_idx).position
	var direction = 1 if other.position > my_pos else -1
	var new_pos = Config.clamp_position(other.position + direction)
	if new_pos == my_pos:
		return false
	other.position = new_pos
	_trigger_items_on_step(1 - player_idx)
	return true

# 移动/位移后触发地格道具（原陷阱逻辑已迁移至 item_system.trigger_on_step）
func _trigger_items_on_step(player_idx: int):
	match_ref.item_system.trigger_on_step(player_idx)

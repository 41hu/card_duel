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

# 移动玩家
func move_player(player_idx: int, direction: int) -> bool:
	var player = match_ref.get_player(player_idx)
	var other_player = match_ref.get_player(1 - player_idx)
	var new_pos = Config.clamp_position(player.position + direction)

	# 不能移动到对方所在格
	if new_pos == other_player.position:
		return false

	# 贴脸时向对方方向移动可推人
	if direction == (1 if player_idx == 0 else -1):
		# 向对方方向移动
		if _can_push(player_idx):
			_push_opponent(player_idx)

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
	check_trap_trigger(1 - player_idx)

# 吸引：将对方拉向自己1格
func attract(player_idx: int) -> bool:
	var other = match_ref.get_player(1 - player_idx)
	if match_ref.char_skills.is_immune(1 - player_idx, "force_move"): return false
	var player = match_ref.get_player(player_idx)
	var my_pos = player.position
	var direction = 1 if other.position < my_pos else -1
	var new_pos = Config.clamp_position(other.position + direction)
	if new_pos == my_pos:
		# 贴脸时推自己后退
		var back_dir = 1 if player_idx == 1 else -1
		var my_new = Config.clamp_position(my_pos + back_dir)
		if my_new == other.position: return false
		player.position = my_new
		check_trap_trigger(player_idx)
		return true
	other.position = new_pos
	check_trap_trigger(1 - player_idx)
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
	check_trap_trigger(1 - player_idx)
	return true

# 检查陷阱触发
func check_trap_trigger(player_idx: int) -> int:
	var player = match_ref.get_player(player_idx)
	var traps = match_ref.get_traps()
	var damage = 0

	for i in range(traps.size() - 1, -1, -1):
		if traps[i].position == player.position:
			damage += 3
			traps.remove_at(i)

	if damage > 0:
		player.hp -= damage
		match_ref.add_log(player_idx, "踩陷阱-%dHP" % damage)
	return damage

# 放置陷阱
func place_trap(player_idx: int, pos: int) -> bool:
	var traps = match_ref.get_traps()
	var p1 = match_ref.get_player(0)
	var p2 = match_ref.get_player(1)

	# 不能在玩家所在格放置
	if pos == p1.position or pos == p2.position:
		return false

	traps.append({position=pos, owner=player_idx})
	return true

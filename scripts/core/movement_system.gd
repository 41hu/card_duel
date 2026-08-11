# movement_system.gd — 移动系统（所有位置运算委托 map_geometry 抽象层）
# 位置 = Vector2i（当前线性地图 Vector2i(x,0)；未来六边形轴向坐标，只换 geometry 实现）
extends RefCounted

var match_ref
var geometry: RefCounted  # BoardGeometry 实例

func _init(match):
	match_ref = match
	geometry = load("res://scripts/core/map_geometry.gd").new()

# 双方格距（贴脸 = 0）；target_idx >= 0 指定目标，否则取最近存活对手
func get_distance(target_idx: int = -1) -> int:
	var player = match_ref.get_player(match_ref.current_player)
	if target_idx < 0:
		target_idx = match_ref._nearest_alive_opponent(match_ref.current_player)
		if target_idx < 0: return 0
	var other = match_ref.get_player(target_idx)
	return geometry.distance(player.position, other.position)

func is_adjacent() -> bool:
	return get_distance() == 0

# 沿方向移动一格（dir: Vector2i 方向向量；禁移动在此兜底，所有位移路径自动受限）
# allow_push=false：该位移不能推人（暗影步等免费位移——避免免费位移附带推人收益过强）
func move_player(player_idx: int, dir: Vector2i, allow_push: bool = true) -> bool:
	if match_ref.status.get_move_modifier(player_idx) < 0:
		return false
	var player = match_ref.get_player(player_idx)
	var new_pos = geometry.clamp_position(geometry.step(player.position, dir))

	# 贴脸时朝对手方向移动可推人（先判断推人，再判断阻挡；多人局取该方向上的对手）
	var push_idx = _opponent_in_dir(player_idx, dir)
	if push_idx >= 0 and new_pos == match_ref.get_player(push_idx).position:
		if not allow_push:
			return false  # 不允许推人的位移（暗影步）：贴脸朝对方移动直接失败
		if not _can_push(player_idx, push_idx):
			return false
		_push_opponent(player_idx, push_idx)
		player.position = new_pos
		_add_move_stat(player_idx)
		return true

	# 不能移动到任何存活玩家所在格（非推人情况）
	for i in range(match_ref.players.size()):
		if i != player_idx and not match_ref.players[i].get("eliminated", false) \
				and match_ref.players[i].position == new_pos:
			return false

	player.position = new_pos
	_add_move_stat(player_idx)
	return true

# 该方向上的贴脸存活对手（多人局可能有多个方向的对手）
func _opponent_in_dir(player_idx: int, dir: Vector2i) -> int:
	var player = match_ref.get_player(player_idx)
	for i in range(match_ref.players.size()):
		if i == player_idx or match_ref.players[i].get("eliminated", false): continue
		var other = match_ref.get_player(i)
		if geometry.direction_between(player.position, other.position) == dir \
				and geometry.distance(player.position, other.position) == 0:
			return i
	return -1

# 获取到己方板边的距离（用于手牌上限计算）
func distance_to_own_edge(player_idx: int) -> int:
	return geometry.edge_distance(player_idx, match_ref.get_player(player_idx).position)

# 手牌上限：多人（4 人）局固定 5 + 角色加成（六边形地图无"板边"概念）
func get_hand_limit(player_idx: int) -> int:
	if match_ref.players.size() > 2:
		return 5 + match_ref.char_skills.hand_limit_bonus(player_idx)
	return geometry.hand_limit(player_idx, match_ref.get_player(player_idx).position) + match_ref.char_skills.hand_limit_bonus(player_idx)

# 位移统计（马拉松冠军称号判定）：任何角色位置移动一格 +1（主动移动/推人/被推/吸引/威慑）
func _add_move_stat(player_idx: int):
	match_ref.stats[player_idx]["moves"] += 1

# 推人逻辑
func _can_push(player_idx: int, push_idx: int) -> bool:
	var other = match_ref.get_player(push_idx)
	var dir = geometry.direction_between(match_ref.get_player(player_idx).position, other.position)
	var new_pos = geometry.clamp_position(geometry.step(other.position, dir))
	var my_pos = match_ref.get_player(player_idx).position
	# 被推者必须能实际移动（板边 clamp 不动 = 推不动，避免推上去造成人物重叠）
	if new_pos == other.position:
		return false
	# 不能推到和推动者重合
	return new_pos != my_pos

func _push_opponent(player_idx: int, push_idx: int):
	var other = match_ref.get_player(push_idx)
	var dir = geometry.direction_between(match_ref.get_player(player_idx).position, other.position)
	other.position = geometry.clamp_position(geometry.step(other.position, dir))
	_add_move_stat(push_idx)  # 被推者也位移了一格
	_trigger_items_on_step(push_idx)

# 吸引：将对方拉向自己1格（target 指定目标；2 人局自动）
func attract(player_idx: int, target: int = -1) -> bool:
	var opp = match_ref.get_opponent(player_idx, target)
	if opp < 0: return false
	var other = match_ref.get_player(opp)
	if match_ref.char_skills.is_immune(opp, "force_move"): return false
	var player = match_ref.get_player(player_idx)
	var my_pos = player.position
	var dir = geometry.direction_between(other.position, my_pos)  # 对方朝我方向
	var new_pos = geometry.clamp_position(geometry.step(other.position, dir))
	if new_pos == my_pos:
		# 贴脸：对方被吸引到我的位置，我沿对方方向后退一格腾出空间
		var my_new = geometry.clamp_position(geometry.step(my_pos, dir))
		# 我无法实际后退（板边 clamp 不动 / 位置被占）→ 吸引失败，不位移（卡不消耗）
		if my_new == other.position or my_new == my_pos:
			return false
		other.position = my_pos
		_add_move_stat(opp)
		_trigger_items_on_step(opp)
		player.position = my_new
		_add_move_stat(player_idx)
		_trigger_items_on_step(player_idx)
		return true
	other.position = new_pos
	_add_move_stat(opp)
	_trigger_items_on_step(opp)
	return true

# 威慑：将对方推远1格（target 指定目标；2 人局自动）
func deter(player_idx: int, target: int = -1) -> bool:
	var opp = match_ref.get_opponent(player_idx, target)
	if opp < 0: return false
	var other = match_ref.get_player(opp)
	if match_ref.char_skills.is_immune(opp, "force_move"): return false
	var my_pos = match_ref.get_player(player_idx).position
	var dir = -geometry.direction_between(other.position, my_pos)  # 对方朝我方向的反向 = 推远
	var new_pos = geometry.clamp_position(geometry.step(other.position, dir))
	if new_pos == my_pos:
		return false
	# 对方在板边推不动（clamp 后原地不动）→ 威慑失败，不位移（卡不消耗）
	if new_pos == other.position:
		return false
	other.position = new_pos
	_add_move_stat(opp)  # 被威慑推远的位移
	_trigger_items_on_step(opp)
	return true

# 移动/位移后触发地格道具（原陷阱逻辑已迁移至 item_system.trigger_on_step）
func _trigger_items_on_step(player_idx: int):
	match_ref.item_system.trigger_on_step(player_idx)

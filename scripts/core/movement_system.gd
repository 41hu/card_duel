# movement_system.gd — 移动系统（所有位置运算委托 map_geometry 抽象层）
# 位置 = Vector2i（当前线性地图 Vector2i(x,0)；未来六边形轴向坐标，只换 geometry 实现）
extends RefCounted

var match_ref
var geometry: RefCounted  # BoardGeometry 实例

func _init(match):
	match_ref = match
	geometry = load("res://scripts/core/map_geometry.gd").new()

# 双方格距（贴脸 = 0）
func get_distance() -> int:
	var p0 = match_ref.get_player(0)
	var p1 = match_ref.get_player(1)
	return geometry.distance(p0.position, p1.position)

func is_adjacent() -> bool:
	return get_distance() == 0

# 沿方向移动一格（dir: Vector2i 方向向量；禁移动在此兜底，所有位移路径自动受限）
func move_player(player_idx: int, dir: Vector2i) -> bool:
	if match_ref.status.get_move_modifier(player_idx) < 0:
		return false
	var player = match_ref.get_player(player_idx)
	var other_player = match_ref.get_player(1 - player_idx)
	var new_pos = geometry.clamp_position(geometry.step(player.position, dir))

	# 贴脸时向对方方向移动可推人（先判断推人，再判断阻挡）
	var moving_toward = (geometry.direction_between(player.position, other_player.position) == dir and dir != Vector2i.ZERO)
	if moving_toward and new_pos == other_player.position:
		if not _can_push(player_idx):
			return false
		_push_opponent(player_idx)
		player.position = new_pos
		_add_move_stat(player_idx)
		return true

	# 不能移动到对方所在格（非推人情况）
	if new_pos == other_player.position:
		return false

	player.position = new_pos
	_add_move_stat(player_idx)
	return true

# 获取到己方板边的距离（用于手牌上限计算）
func distance_to_own_edge(player_idx: int) -> int:
	return geometry.edge_distance(player_idx, match_ref.get_player(player_idx).position)

# 手牌上限
func get_hand_limit(player_idx: int) -> int:
	return geometry.hand_limit(player_idx, match_ref.get_player(player_idx).position) + match_ref.char_skills.hand_limit_bonus(player_idx)

# 位移统计（马拉松冠军称号判定）：任何角色位置移动一格 +1（主动移动/推人/被推/吸引/威慑）
func _add_move_stat(player_idx: int):
	match_ref.stats[player_idx]["moves"] += 1

# 推人逻辑
func _can_push(player_idx: int) -> bool:
	if not is_adjacent():
		return false
	var other = match_ref.get_player(1 - player_idx)
	var dir = geometry.direction_between(match_ref.get_player(player_idx).position, other.position)
	var new_pos = geometry.clamp_position(geometry.step(other.position, dir))
	var my_pos = match_ref.get_player(player_idx).position
	# 被推者必须能实际移动（板边 clamp 不动 = 推不动，避免推上去造成人物重叠）
	if new_pos == other.position:
		return false
	# 不能推到和推动者重合
	return new_pos != my_pos

func _push_opponent(player_idx: int):
	var other = match_ref.get_player(1 - player_idx)
	var dir = geometry.direction_between(match_ref.get_player(player_idx).position, other.position)
	other.position = geometry.clamp_position(geometry.step(other.position, dir))
	_add_move_stat(1 - player_idx)  # 被推者也位移了一格
	_trigger_items_on_step(1 - player_idx)

# 吸引：将对方拉向自己1格
func attract(player_idx: int) -> bool:
	var other = match_ref.get_player(1 - player_idx)
	if match_ref.char_skills.is_immune(1 - player_idx, "force_move"): return false
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
		_add_move_stat(1 - player_idx)
		_trigger_items_on_step(1 - player_idx)
		player.position = my_new
		_add_move_stat(player_idx)
		_trigger_items_on_step(player_idx)
		return true
	other.position = new_pos
	_add_move_stat(1 - player_idx)
	_trigger_items_on_step(1 - player_idx)
	return true

# 威慑：将对方推远1格
func deter(player_idx: int) -> bool:
	var other = match_ref.get_player(1 - player_idx)
	if match_ref.char_skills.is_immune(1 - player_idx, "force_move"): return false
	var my_pos = match_ref.get_player(player_idx).position
	var dir = -geometry.direction_between(other.position, my_pos)  # 对方朝我方向的反向 = 推远
	var new_pos = geometry.clamp_position(geometry.step(other.position, dir))
	if new_pos == my_pos:
		return false
	# 对方在板边推不动（clamp 后原地不动）→ 威慑失败，不位移（卡不消耗）
	if new_pos == other.position:
		return false
	other.position = new_pos
	_add_move_stat(1 - player_idx)  # 被威慑推远的位移
	_trigger_items_on_step(1 - player_idx)
	return true

# 移动/位移后触发地格道具（原陷阱逻辑已迁移至 item_system.trigger_on_step）
func _trigger_items_on_step(player_idx: int):
	match_ref.item_system.trigger_on_step(player_idx)

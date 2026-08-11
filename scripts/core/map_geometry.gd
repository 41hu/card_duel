# map_geometry.gd — 地图几何抽象层
#
# 所有位置/方向/边界/距离/邻接/到边距离运算集中于此，上层逻辑（movement/combat/
# card_effects/UI）只调接口，不直接做坐标算术。
#
# ============================ 支持的布局 ============================
# LINEAR：11 格线性地图（2 人局默认）。位置 = Vector2i(x, 0)，x ∈ 0..10，
#         P0 初始 3、P1 初始 7；方向 = 左右两向；手牌上限 = 到己方板边距离 + 1。
# HEX：六边形蜂窝地图（4 人局）。位置 = Vector2i(q, r) 轴向坐标，半径 R=3
#       （中心 + 3 层，共 37 格）；6 方向；4 个对称初始点。
#
# ==================== 以后修改地图布局（加新模式）====================
# 1. 在文件顶部常量区新增模式常量（如 MODE_XXX）和该模式的参数
#    （尺寸/初始点/方向表）。
# 2. 在 set_mode 里接受新模式（_mode 赋值）。
# 3. 为每个几何接口（is_valid/clamp_position/direction_between/distance/
#    edge_distance/hand_limit/initial_position）增加模式分发分支。
#    ——所有上层代码零改动（它们只调这些接口）。
# 4. 易踩的坑（务必注意）：
#    a) distance() 的语义是"相邻两格 = 0（贴脸）"——线性是 |dx|-1，
#       六边形是 hex_dist-1；新布局必须保持"相邻 = 0"，否则贴脸判定全错。
#    b) clamp_position 必须保证收敛（不能死循环）：收缩式实现每次至少
#       向中心移动一步，且终止条件覆盖所有越界形态。
#    c) direction_between 在六边形里是"最接近的 6 方向"（近似方向）——
#       只用于"朝对方/远离对方"这类语义（推人/吸引/威慑），不保证严格对准；
#       移动方向由玩家显式选择（不经过此函数）。
#    d) 改尺寸（半径/宽度）或初始点时：初始点必须在地图内（is_valid 为真）
#       且彼此不重合；4 人局初始点建议保持对称（公平性）。
#    e) edge_distance/hand_limit 只对 LINEAR 有意义（手牌上限规则）；
#       HEX 的手牌上限由 movement.get_hand_limit 固定处理（5 + 加成），
#       这里返回兜底值即可，不要再在别处实现"到边距离"逻辑。
#
# ====================================================================
extends RefCounted

# ---- 布局模式 ----
const MODE_LINEAR := 0  # 11 格线性（2 人局）
const MODE_HEX := 1     # 六边形蜂窝（4 人局）

# ---- LINEAR 参数 ----
const WIDTH := 11

# ---- HEX 参数 ----
const HEX_RADIUS := 3  # 六边形半径（层数）：中心 + 3 层 = 37 格

var _mode: int = MODE_LINEAR

# 方向常量
# LINEAR：左右两向
const DIR_LEFT := Vector2i(-1, 0)
const DIR_RIGHT := Vector2i(1, 0)
# HEX：轴向 6 方向（q, r）。命名与渲染坐标对应关系（尖顶朝上，屏幕 y 向下）：
#   x = 86*(q + r*0.5)，y = 74*r
#   (1,0)→右、(-1,0)→左、(1,-1)→右上、(0,-1)→左上、(-1,1)→左下、(0,1)→右下
# 注意：六边形没有正北/正南方向（尖顶朝上时仅 6 个邻居）。
# 集合不可增删（direction_between 点积逻辑依赖这 6 个方向覆盖全平面）
const HEX_DIRS: Array = [
	Vector2i(1, 0),    # 东
	Vector2i(1, -1),   # 东北
	Vector2i(0, -1),   # 西北
	Vector2i(-1, 0),   # 西
	Vector2i(-1, 1),   # 西南
	Vector2i(0, 1),    # 东南
]

func set_mode(mode: int):
	_mode = mode

# 位置是否在地图内
func is_valid(pos: Vector2i) -> bool:
	if _mode == MODE_HEX:
		return _hex_valid(pos.x, pos.y)
	return pos.y == 0 and pos.x >= 0 and pos.x < WIDTH

func _hex_valid(q: int, r: int) -> bool:
	# 轴向坐标合法条件：|q|、|r|、|q+r| 均 <= 半径（第三坐标 s = -q-r）
	return abs(q) <= HEX_RADIUS and abs(r) <= HEX_RADIUS and abs(q + r) <= HEX_RADIUS

# 边界收敛（越界收敛到边界内最近格；必须保证收敛，见文件头注释 b）
func clamp_position(pos: Vector2i) -> Vector2i:
	if _mode == MODE_HEX:
		return _clamp_hex(pos)
	return Vector2i(clampi(pos.x, 0, WIDTH - 1), 0)

func _clamp_hex(pos: Vector2i) -> Vector2i:
	# 两步收敛（保证终止）：
	# 1. 先把 q、r 各自夹到 [-R, R]（轴向越界）
	# 2. 再处理对角线越界（|q+r| > R）：把 |q+r| 较大的一侧坐标朝中心
	#    收缩 1 步；每次迭代 |q+r| 严格减少，最多 R 次后必然合法
	var q = clampi(pos.x, -HEX_RADIUS, HEX_RADIUS)
	var r = clampi(pos.y, -HEX_RADIUS, HEX_RADIUS)
	while abs(q + r) > HEX_RADIUS:
		if q + r > HEX_RADIUS:
			if q > r: q -= 1
			else: r -= 1
		else:
			if q < r: q += 1
			else: r += 1
	return Vector2i(q, r)

# 从 from 朝 to 的方向向量（同格返回 ZERO）
func direction_between(from: Vector2i, to: Vector2i) -> Vector2i:
	if _mode == MODE_HEX:
		var dq = to.x - from.x
		var dr = to.y - from.y
		if dq == 0 and dr == 0: return Vector2i.ZERO
		# 六边形下选"最接近"的 6 方向（夹角最小）。
		# 注意：方向向量长度不同（对角线 (1,-1) 等长 √2），必须用
		# 归一化点积（dot / |d|）比较夹角，否则会误匹配（如目标 (0,1)
		# 会被 (-1,1) 的点积打平并因遍历顺序而错误选中）。
		# 这是近似方向：只用于"朝对方/远离"语义（推人/吸引/威慑）。
		var best = HEX_DIRS[0]
		var best_cos = -2.0
		for d in HEX_DIRS:
			var cos_val = float(d.x * dq + d.y * dr) / d.length()
			if cos_val > best_cos:
				best_cos = cos_val
				best = d
		return best
	if to.x > from.x: return DIR_RIGHT
	if to.x < from.x: return DIR_LEFT
	return Vector2i.ZERO

# 沿方向走一格（不做边界收敛，由调用方决定）
func step(pos: Vector2i, dir: Vector2i) -> Vector2i:
	return pos + dir

# 格距（相邻两格 = 0，即"贴脸"）——语义约定，见文件头注释 a
func distance(a: Vector2i, b: Vector2i) -> int:
	if _mode == MODE_HEX:
		return max(0, _hex_dist(a, b) - 1)
	return max(0, abs(a.x - b.x) - 1)

func _hex_dist(a: Vector2i, b: Vector2i) -> int:
	# 轴向六边形距离 = 三个坐标差绝对值的最大值
	var dq = abs(a.x - b.x)
	var dr = abs(a.y - b.y)
	var ds = abs((a.x + a.y) - (b.x + b.y))
	return max(dq, max(dr, ds))

func is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return distance(a, b) == 0

# 到己方板边的距离（手牌上限规则：上限 = 到边距离 + 1 + 加成）
# 只对 LINEAR 有意义；HEX 手牌上限由 movement.get_hand_limit 固定处理，
# 这里返回 0 兜底（调用方不应在 HEX 下依赖此值，见文件头注释 e）
func edge_distance(player_idx: int, pos: Vector2i) -> int:
	if _mode == MODE_HEX:
		return 0
	return pos.x if player_idx == 0 else WIDTH - 1 - pos.x

# 手牌上限（LINEAR：到边距离 + 1 + 加成；HEX：固定 5 + 加成兜底，
# 实际由 movement.get_hand_limit 统一处理，此值仅防御性）
func hand_limit(player_idx: int, pos: Vector2i, bonus: int = 0) -> int:
	if _mode == MODE_HEX:
		return 5 + bonus
	return edge_distance(player_idx, pos) + 1 + bonus

# 初始位置
# LINEAR：P0 左侧第 4 格、P1 右侧第 8 格
# HEX：半径 3 六边形的 4 个对称顶点（东/西/北/南），玩家 0-3 按序分配。
# 以后改初始点：保证 is_valid 为真、互不重合、对称（公平性），见文件头注释 d
func initial_position(player_idx: int) -> Vector2i:
	if _mode == MODE_HEX:
		var spots: Array = [
			Vector2i(3, 0),   # 东
			Vector2i(-3, 0),  # 西
			Vector2i(0, 3),   # 北
			Vector2i(0, -3),  # 南
		]
		return spots[player_idx % spots.size()]
	return Vector2i(3 if player_idx == 0 else 7, 0)

# ---- 协议/存档序列化（get_full_state / battle_record / 网络字段）----
func to_dict(pos: Vector2i) -> Dictionary:
	return {"x": pos.x, "y": pos.y}

func from_dict(d) -> Vector2i:
	if d is Vector2i: return d
	if d is Dictionary:
		return Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	if d is int:
		return Vector2i(int(d), 0)  # 兼容旧 int 位置
	return Vector2i.ZERO

# 可读文本（日志/导出）
func to_text(pos: Vector2i) -> String:
	return "%d,%d" % [pos.x, pos.y]

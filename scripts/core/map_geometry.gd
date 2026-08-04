# map_geometry.gd — 地图几何抽象层
#
# 所有位置/方向/边界/距离/邻接/到边距离运算集中于此，上层逻辑只调接口，
# 不直接做算术（加减乘除坐标）。未来切换六边形蜂窝地图：只替换本文件内部实现
# （位置 Vector2i 即轴向坐标 q,r），上层零改动。
#
# 当前实现：11 格线性地图。位置 = Vector2i(x, 0)，x ∈ 0..10（P0 初始 3，P1 初始 7）。
# 方向 = 左右两向（DIR_LEFT/DIR_RIGHT）；贴脸 = 格距 0。
# 手牌上限 = 到己方板边距离 + 1 + 角色加成。
extends RefCounted

const WIDTH := 11

# 方向常量（六边形未来扩展 6 方向）
const DIR_LEFT := Vector2i(-1, 0)
const DIR_RIGHT := Vector2i(1, 0)

# 位置是否在地图内
func is_valid(pos: Vector2i) -> bool:
	return pos.y == 0 and pos.x >= 0 and pos.x < WIDTH

# 边界收敛（越界 clamp 到边界格）
func clamp_position(pos: Vector2i) -> Vector2i:
	return Vector2i(clampi(pos.x, 0, WIDTH - 1), 0)

# 从 from 朝 to 的方向向量（同格返回 ZERO）
func direction_between(from: Vector2i, to: Vector2i) -> Vector2i:
	if to.x > from.x: return DIR_RIGHT
	if to.x < from.x: return DIR_LEFT
	return Vector2i.ZERO

# 沿方向走一格（不做边界收敛，由调用方决定）
func step(pos: Vector2i, dir: Vector2i) -> Vector2i:
	return pos + dir

# 格距（相邻两格 = 0，即"贴脸"）
func distance(a: Vector2i, b: Vector2i) -> int:
	return max(0, abs(a.x - b.x) - 1)

func is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return distance(a, b) == 0

# 到己方板边的距离（手牌上限规则：上限 = 到边距离 + 1 + 加成）
func edge_distance(player_idx: int, pos: Vector2i) -> int:
	return pos.x if player_idx == 0 else WIDTH - 1 - pos.x

# 手牌上限
func hand_limit(player_idx: int, pos: Vector2i, bonus: int = 0) -> int:
	return edge_distance(player_idx, pos) + 1 + bonus

# 初始位置（P0 左侧第 4 格、P1 右侧第 8 格）
func initial_position(player_idx: int) -> Vector2i:
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

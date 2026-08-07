# step_runner.gd — 通用步骤驱动系统（新手教程 / 关卡 / 挑战模式复用）
# 数据驱动：每步 = Dictionary，字段：
#   guide          引导文字（由 _set_guide_text 钩子输出）
#   enter          进入步骤时回调
#   check          完成检测（每帧调用，true 则推进）
#   allow_cards    本步可点的卡类型（["*"]=不限；[]=禁止）
#   allow_skills   本步可用技能（同上）
#   allow_end_turn 本步是否允许结束回合
#   move_dirs      本步允许的移动方向（空=不限）
#   wait_turn_end  true=check 满足后等玩家结束回合（新回合 ACTION）才进下一步
#   opp_actions    对手本回合脚本动作（每次执行一个，间隔 OPP_STEP_DELAY_MS）
#   manual_discard true=弃牌阶段玩家手动确认（默认自动确认）
# 子类钩子：_set_guide_text()、_on_steps_finished()
class_name StepRunner
extends Node

var battle: Control = null  # battle_ui（刷新 UI 用）
var g = null                # MatchState 实例
var player_idx: int = 0
var opp_idx: int = 1

var _step: int = -1
var _steps: Array = []
var _pending_step: int = -1   # 等待完整回合结束后的下一步
var _pending_turn: int = -1   # 设置 pending 时的回合号（等新回合才触发）
var _opp_actions: Array = []
var _opp_turn_handled: bool = false
var _opp_next_act_time: int = 0
var _allowed_trap_pos: Array = []  # 当前步骤允许放夹子的格子（空 = 不限制）
var _finish_called: bool = false   # 防重入：GAME_OVER 后 check 每帧满足，只允许收尾一次
const OPP_STEP_DELAY_MS = 700      # 对手每步出牌间隔（帧驱动逐步行动，玩家能看清出牌过程）

func _ready():
	# 子类 _ready 先执行（先构建 _steps），这里再启动第一步
	_start_step(0)

func _process(_delta):
	if g == null: return
	if _step < 0 or _step >= _steps.size(): return
	# 自动通过弃牌阶段（不弹手动弃牌，避免破坏流程）；
	# manual_discard 步骤玩家手动确认除外；对手弃牌始终自动确认（否则回合卡死）。
	# 注意：手牌超上限时 confirm_discard 会拒绝（必须先弃），这里自动弃掉超限的牌
	if g.waiting_for_discard:
		var cur = g.current_player
		var auto = (cur == opp_idx) or (cur == player_idx and not _steps[_step].get("manual_discard", false))
		if auto:
			var cs = g.card_systems[cur]
			var limit = g.movement.get_hand_limit(cur)
			var need = cs.hand.size() - limit
			var uids: Array = []
			if need > 0:
				for i in range(min(need, cs.hand.size())):
					uids.append(cs.hand[i].uid)
			g.confirm_discard(cur, uids)
			return
	# 等待完整回合：步骤已完成，玩家结束回合后（新回合 ACTION）进入下一步
	# 注意：pending 时对手回合仍需执行脚本（不能 return 跳过，否则卡死）
	if _pending_step >= 0:
		# 只有进入新回合（玩家 ACTION）才触发下一步，否则刚设置 pending 的同一回合
		# 就会立即切换步骤，导致对手脚本回合被跳过
		if g.phase == Config.Phase.PLAYER_TURN and g.current_player == player_idx \
				and g.turn_phase == Config.TurnPhase.ACTION \
				and g.turn_number > _pending_turn:
			var n = _pending_step
			_pending_step = -1
			_start_step(n)
			return
		if g.phase == Config.Phase.PLAYER_TURN and g.current_player == player_idx:
			_set_guide_text("做得对！点击「结束出牌」进入下一步")
			return
		if g.phase == Config.Phase.PLAYER_TURN and g.current_player == opp_idx:
			_set_guide_text("本回合完成，等待对手行动…")
	# 对手回合：按脚本行动（pending 与非 pending 都执行；必须到出牌阶段 ACTION 才执行，
	# 否则判定/抽牌阶段提前触发会失败并标记 handled 导致不行动）
	if g.phase == Config.Phase.PLAYER_TURN and g.current_player == opp_idx \
			and g.turn_phase == Config.TurnPhase.ACTION:
		if not _opp_turn_handled:
			_opp_turn_handled = true
			_opp_next_act_time = Time.get_ticks_msec() + OPP_STEP_DELAY_MS
		elif not _opp_actions.is_empty() and not g.response_pending \
				and Time.get_ticks_msec() >= _opp_next_act_time:
			_run_opp_actions()  # 每步间隔出牌（响应结算后同样走间隔），玩家能看清过程
		elif _opp_actions.is_empty() and not g.response_pending:
			_try_end_opp_turn()  # 脚本执行完且无响应等待 → 结束回合
	if g.current_player != opp_idx:
		_opp_turn_handled = false
	# 当前步骤完成检测
	var s: Dictionary = _steps[_step]
	if s.get("check", Callable()).call():
		if s.get("wait_turn_end", false):
			_pending_step = _step + 1
			_pending_turn = g.turn_number  # 记录当前回合，等玩家结束回合后（新回合）触发
			_set_guide_text("做得对！点击「结束出牌」进入下一步")
		else:
			_start_step(_step + 1)

# ---------------- 步骤系统 ----------------
func _start_step(i: int):
	if i >= _steps.size():
		_finish_tutorial()
		return
	_step = i
	var s: Dictionary = _steps[i]
	_set_guide_text(s.get("guide", ""))
	if s.has("enter"):
		s["enter"].call()
	_opp_actions = []
	_opp_turn_handled = false
	if s.has("opp_actions"):
		_opp_actions = s["opp_actions"].call()

func _finish_tutorial():
	if _finish_called: return  # 防重入：GAME_OVER 后 check 每帧满足，重复收尾会叠屏挡点击
	_finish_called = true
	_on_steps_finished()

# ---------------- 子类钩子 ----------------
func _set_guide_text(_text: String):
	pass

func _on_steps_finished():
	pass

# ---------------- 对手脚本 ----------------
func _run_opp_actions():
	# 每次只执行一个脚本动作（帧驱动逐步出牌，玩家能看清过程；同帧全执行体验差）
	if _opp_actions.is_empty() or g.current_player != opp_idx \
			or g.response_pending or g.waiting_for_discard:
		return
	var act = _opp_actions[0]
	_opp_actions.remove_at(0)
	var r = g.process_action(opp_idx, act)
	_opp_next_act_time = Time.get_ticks_msec() + OPP_STEP_DELAY_MS
	if not r.get("success", false):
		_try_end_opp_turn()

func _try_end_opp_turn():
	if g.current_player == opp_idx and not g.waiting_for_discard:
		g.process_action(opp_idx, {"action": "end_turn"})

# ---------------- 操作限制（battle_ui 集成） ----------------
# allow_cards/allow_skills：["*"]=不限制；[]=禁止一切；其他=只允许列出的类型
func allow_card_click(_uid: int, type_id: String) -> bool:
	if _step < 0 or _step >= _steps.size(): return false
	var allow: Array = _steps[_step].get("allow_cards", ["*"])
	if allow.is_empty(): return false
	if "*" in allow: return true
	return type_id in allow

func allow_skill(sk_id: String) -> bool:
	if _step < 0 or _step >= _steps.size(): return false
	var allow: Array = _steps[_step].get("allow_skills", ["*"])
	if allow.is_empty(): return false
	if "*" in allow: return true
	return sk_id in allow

func allow_end_turn() -> bool:
	if _pending_step >= 0: return true  # 步骤已完成，允许结束回合进入下一步
	if _step < 0 or _step >= _steps.size(): return false
	return bool(_steps[_step].get("allow_end_turn", false))  # 默认完成步骤前不能结束

func allowed_trap_positions() -> Array:
	return _allowed_trap_pos

func allowed_move_dirs() -> Array:
	if _step < 0 or _step >= _steps.size(): return [1, -1]
	var dirs: Array = _steps[_step].get("move_dirs", [])
	if dirs.is_empty(): return [1, -1]
	return dirs

func force_response() -> bool:
	if _step < 0 or _step >= _steps.size(): return false
	return bool(_steps[_step].get("force_response", false))

# 响应接管：返回 true 表示已自动处理（不弹响应窗口）
# 规则：对手永不响应；玩家被攻击正常弹窗
func handle_response_needed() -> bool:
	if g == null: return false
	if g._response_attacker < 0: return false
	var defender = 1 - g._response_attacker
	if defender == opp_idx:
		g.process_response(opp_idx, false)  # 对手被攻击：自动不响应
		return true
	return false

# ---------------- 教学工具 ----------------
func deal_hand(idx: int, types: Array):
	var cs = g.card_systems[idx]
	cs.hand.clear()
	for i in range(types.size()):
		cs.hand.append({"uid": 9000 + i, "type_id": types[i]})

# 补发卡到手牌（不清空，保留初始手牌贯穿教学）
func add_cards(idx: int, types: Array):
	var cs = g.card_systems[idx]
	var base = 9000
	for c in cs.hand:
		if c.uid >= base: base = c.uid + 1
	for i in range(types.size()):
		cs.hand.append({"uid": base + i, "type_id": types[i]})

func battle_state_refresh():
	if battle != null and battle.has_method("_refresh_all"):
		# 同步 _game_state：deal_hand/add_cards 直接改手牌不发 state_changed 信号，
		# 否则弹窗（选穿心/选卡）读的是旧手牌，看不到发的卡
		var full = g.get_full_state()
		battle._game_state = full
		battle._refresh_all(full)

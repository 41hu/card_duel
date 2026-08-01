# 卡牌对决 — API 参考与开发规范

> 给 AI 协作开发者的**方法级参考文档**。改代码前先查本文件，按"效果实现规范"章节的标准流程实现，可以最大限度避免 bug。
> 优先级：本文件（方法/实现规范） → WORKFLOW.md（架构/流程/已知问题） → GAME_RULES.md / RESPONSE_RULES.md（规则）

---

## 一、架构分层

```
autoload/  Config(静态数据)  Network(WebSocket客户端)  LocalGame(本地对战，模拟Network接口)
core/      MatchState(服务端权威状态机，唯一真相) + 7个系统组件(全部 RefCounted)
server/    ServerMain(TCPServer, 独立进程跑同一套 MatchState)
data/      纯数据(卡牌/角色/装备表)
ui/        客户端界面(纯渲染+转发，不做判定)
```

**数据流**：UI 操作 → `Network.send_*`（或 LocalGame.send_* 直调）→ MatchState 处理 → `state_changed` 信号 → UI `_refresh_all` 重绘。

**铁律**：所有游戏逻辑判定只在 `match_state.gd` 及 core 组件内；改状态后必须 `state_changed.emit(get_full_state())` 广播；本地模式（LocalGame）与联机（server_main 走同一 MatchState）行为必须一致。

---

## 二、Autoload API

### Config（`scripts/autoload/config.gd`）
静态数据聚合 + 枚举 + 工具函数。所有数据经 `Config.XXX` 访问。
- 枚举：`Phase`、`APType`、`TurnPhase`、`DamageType(PHYSICAL/RANGED/MAGICAL)`、`ResponseType`
- 数据：`CARD_DB`、`CARD_COUNTS`、`CHARACTER_DB`、`CHARACTER_IDS`、`WEAPON_DB`、`ARMOR_DB`、`ATTACK_CARD_TYPES`、`RESPONDABLE_CARDS`
- 工具：`get_damage_type(type_id)->int`（卡→伤害类型）、`get_response_type`、`card_response_by`、`card_response_effect`、`build_initial_deck()->Array`、`get_random_weapon(type, used_ids)`、`is_attack_card`、`is_heal_card`、`card_name`、`char_name`、`get_card_ap_type/cost`、`clamp_position`、`weapon_matches_damage_type`

### Network（`scripts/autoload/network.gd`）
WebSocket 客户端。UI 通过它发消息、收信号。
- 信号：`connected_to_server / server_disconnected / room_created / room_joined / game_starting / state_updated / bp_state_updated / weapon_prompt / response_needed / game_ended / hand_revealed / network_error`
- 方法：`connect_to_server(url)`、`disconnect_from_server()`、`send_*` 系列（bp_action / play_card / response / weapon_choice / end_turn / discard_one / confirm_discard / use_skill / swordsman_choice / reveal_hand）
- 缓存字段：`player_index`、`bp_state_cache`、`battle_state_cache`、`last_game_result`（结算页读取）

### LocalGame（`scripts/autoload/local_game.gd`）
本地自我对战，**接口与 Network 完全一致**（同名信号/方法）。UI 用 `_n()` 统一切换：
```gdscript
func _n():
    if LocalGame.game != null: return LocalGame
    return Network
```
- 关键字段：`game`（当前 MatchState 实例，null=非本地模式）
- `start_bp()` / `start_local_game(p1_char, p2_char, bp_first)`

---

## 三、Core 组件 API（全部由 MatchState 创建，经 `match_state.xxx` 访问）

### MatchState（`scripts/core/match_state.gd`）— 服务端权威状态机
- 信号：`state_changed / weapon_prompt / response_needed / game_ended / bp_state_changed`
- **玩家操作入口**（服务端收到消息后调用）：
  - `process_action(player_idx, {action: "play_card"|"end_turn"|"use_skill"|"swordsman_choice", ...}) -> {success, msg}`
  - `process_response(defender_idx, respond, card_uid)` / `skip_response(defender_idx)`
  - `confirm_weapon(player_idx, accept)`、`discard_one`、`confirm_discard`、`do_bp_action(player_idx, action, char_id)`
- **轮询**：`check_timers()`（每秒调一次：BP 超时 / 出牌超时 / 弃牌超时；server 与 LocalGame 都在调）
- **查询**：`get_full_state(full)`（完整快照，UI 全部依赖它）、`get_player(idx)`、`get_traps()`、`reveal_opponent_hand(idx)`
- 内部流程：`_start_game → _judgment_phase(DoT) → _draw_phase → _action_phase(冻结跳过) → _discard_phase → _advance_to_next_player`
- 内部辅助：`_handle_death`（复活）、`_check_permanent_death`、`_use_card`、`add_log`、`_check_any_death`（吸引/威慑踩陷阱后检查）

### CharacterSkills（`scripts/core/character_skills.gd`）— 角色技能钩子
所有角色技能用 **`match p.char_id:` 分支**实现。钩子分三类：
- 被动钩子（MatchState 固定时机调用）：`on_turn_start`、`on_turn_end`、`on_attack_hit`、`on_taking_damage->int`、`on_heal->int`、`on_attack_cast->int`、`is_immune(idx, effect)`
- 查询钩子（返回值）：`draw_count`、`move_distances`、`hand_limit_bonus`、`can_attack_free`、`can_equip`、`check_hand_condition(idx, cond)`、`can_upgrade_skill`
- 主动技能：`has_active_skills(idx)->[id]`、`skill_button_name`、`skill_game_limit`、`use_skill(idx, skill, params)->{success, msg}`

### CardEffects（`scripts/core/card_effects.gd`）— 卡牌效果注册表
- 唯一入口：`execute(player_idx, card) -> {success, msg}`，按 `card.type_id` 查 `_handlers` 字典
- handler 统一签名：`func(player_idx: int, card: Dictionary) -> Dictionary`（见"实现规范"）

### CombatSystem（`scripts/core/combat_system.gd`）— 伤害计算
- `calculate_attack(attacker_idx, defender_idx, card_type_id) -> {damage, blocked, msg, formula}`
- `process_response(attacker_idx, defender_idx, attack_card, card_uid) -> {success, effect, value}`（near→格挡、range→牵制、magic→闪避）
- `apply_on_hit_effects(attacker_idx, defender_idx, damage, damage_type)`（武器命中特效）
- `apply_dot_damage(player_idx)`（灼烧/中毒结算）
- 私有：`_apply_weapon_damage_bonus`（武器伤害加成）、`_check_armor`（防具 3 耐久：免疫→减半→减半）

### MovementSystem（`scripts/core/movement_system.gd`）— 棋盘/位移/陷阱
- `get_distance()`（|pos差|-1）、`is_adjacent()`、`move_player(idx, dir)->bool`（含推人）
- `get_hand_limit(idx)`（手牌上限=到板边距离+1）
- `attract(idx)`、`deter(idx)`（吸引/威慑，**内部触发陷阱**）
- `check_trap_trigger(idx)->int`（踩陷阱扣 3 血，**内部已扣血记日志**，调用方只做死亡判定）
- `place_trap(idx, pos)`

### EquipmentSystem（`scripts/core/equipment_system.gd`）— 武器/防具
- `process_weapon_card(idx, type)`（武器牌幻化→进入等待确认）、`equip_weapon`、`discard_weapon_offer`
- `equip_armor(idx, type)`（立即装上，圣骑士+1 耐久）、`destroy_equipment(idx, type)`

### StatusSystem（`scripts/core/status_system.gd`）— Buff/DoT/冻结
- `add_buff(idx, type, value, duration)`（duration=-1 回合结束清）、`add_burn`、`add_poison`
- `freeze_player(idx)->bool`（frozen_lockout 防连冻）、`clear_freeze`（冻结生效后调用方需手动解锁 lockout）
- **消费点**：`get_attack_modifier(idx, damage_type)->int`（attack_up/attack_down/near_up 在此结算）、`get_move_modifier`

### CardSystem（`scripts/core/card_system.gd`）— 牌堆/手牌
- 共享牌堆模式：两名玩家持有**同一个** deck/discard 引用
- `draw_cards(n)`、`play_card(uid)`、`discard_card(uid)`、`discard_all`、`random_discard(n)`、`random_take()`（夺取）、`add_to_hand`、`has_card(uid)`、`find_response_card`、`has_heal_card/use_heal_card`

### BPSystem（`scripts/core/bp_system.gd`）— BP 禁选
- `reset()`（设 `match_ref.phase = BP_PHASE`，**必须保留**，否则倒计时不触发）、`get_bp_state()`、`execute_action(idx, action, char_id)->bool`、`check_bp_timer()`（超时随机操作）、`is_done()`

---

## 四、Server API（`scripts/server/server_main.gd`）

- TCPServer 端口 17890；`_process` 每秒 `room.match.check_timers()`
- `_handle_message` 按 `t` 字段分发到各 `_on_*` 处理器
- 信号转发：`_on_match_state_changed`（**隐去对手手牌**后广播）、`_on_bp_timeout`（BP 超时完成→init_match+start_game）、`_on_game_ended`

---

## 五、UI 层约定

- 所有 UI 脚本用 `_n()` 统一获取 LocalGame/Network
- `battle_ui._refresh_all(state)`：收到 state 后**全量重绘**（棋盘 update、手牌重建、日志刷新）
- 弹窗统一用 `battle_ui._popup_box(parent, w, h)`（居中滚动弹窗框架）和 `_mkbtn(text)`（统一按钮样式 220×100）创建
- `battle_ui._apply_safe_area()`：全面屏安全区适配（新增角落 UI 时注意）
- 数据组件：`card_widget.setup(uid, tid, name, ap, is_discard)`、`board_renderer.update(players, traps, my_index)`、`action_log.show_logs(log, max, my_index)`

---

## 六、效果实现规范（加新功能的标准流程）

### 加一张新卡
1. `card_data.gd`：`CARD_DB` 加 `{name, ap, cost, desc}`；`CARD_COUNTS` 加数量；攻击卡加进 `ATTACK_CARD_TYPES`；可被响应的加进 `RESPONDABLE_CARDS`
2. `card_effects.gd`：`_handlers` 注册 `"type_id": handler_func`，handler 签名 `func(player_idx, card) -> {success, msg}`；内部实现调 `_m._handle_*` 或操作 `_m.players/_m.card_systems`，**必须** `_use_card(player_idx, card)` 消耗卡 + `_m.add_log` 记日志
3. 攻击类新卡还需：`config.gd` 的 `get_damage_type/get_response_type` 加映射；`combat_system.calculate_attack` 的 match 加伤害公式；`equip_data.gd` 的 `RESPONSE_BY` 加响应规则；`combat_system.process_response` 的响应分支（如需）

### 加一个新角色
1. `character_data.gd`：`CHARACTER_DB` 加 `{name, hp, near, range, magic, skill, skill_desc}`，`CHARACTER_IDS` 加 id
2. `character_skills.gd`：在需要的钩子里加 `"new_id": 逻辑` 分支（被动：on_turn_start/on_taking_damage/on_attack_hit/on_heal；查询：draw_count/move_distances/hand_limit_bonus/can_equip/is_immune）
3. 主动技能：`has_active_skills` 加条件、`skill_button_name` 加名字、`use_skill` 加 match 分支；带参数技能（选目标/选卡）需在 `battle_ui._exec_skill` 加对应弹窗
4. UI 自动渲染（state.active_skills），无需改场景

### 加武器/防具效果
1. `equip_data.gd`：`WEAPON_DB` 加 `{name, type, effect, value, desc}`（type 决定匹配的伤害类型）；防具加 `ARMOR_DB`
2. 武器效果消费点：伤害加成 → `combat_system._apply_weapon_damage_bonus` 加 `weapon.id` 分支；命中特效 → `apply_on_hit_effects` 加分支（可调 `status.add_buff/add_poison/add_burn`）；距离类 → `calculate_attack` 特判
3. 防具走 `_check_armor` 通用逻辑（type 匹配 + 3 耐久），**无需**逐件分支

### 加一个状态 Buff
1. `status.add_buff(idx, type, value, duration)` 写入 player.buffs（-1=回合结束清，on_turn_end 自动衰减）
2. **在 `status_system._modifier_handlers` 注册表加一行 handler**（签名 `func(buff, aspect, damage_type) -> int`，返回修正值）：
   - 影响攻击伤害：handler 里判断 `aspect == "attack"`（需要时再按 `damage_type` 区分伤害类型）
   - 影响移动：判断 `aspect == "move"`
3. **不需要改任何消费点**——`get_attack_modifier`/`get_move_modifier` 自动走注册表（`query_modifier` 统一入口）
4. **注意伤害类型**：近战限定加成用 `near_up`（仅 `DamageType.PHYSICAL` 生效），通用用 `attack_up`——不要用错（参考狂战士 bug 教训）

### 加技能钩子
钩子 = `character_skills.gd` 新公开函数 + `match_state.gd` 对应流程点调用。匹配一律 `match p.char_id:` 分支 + `_:` 兜底。

---

## 七、网络协议速查

客户端 → 服务端（`{"t": 消息类型}`）：`create_room / join_room / ready / bp_action / play_card / end_turn / respond / weapon_choice / discard_one / confirm_discard / use_skill / reveal_hand / swordsman_choice`

服务端 → 客户端：`room_created / room_joined / game_starting / bp_state / game_state / weapon_prompt / response_needed / game_over / error / hand_revealed`

`play_card` 的 extra 参数：`direction/steps`（移动）、`trap_pos`（陷阱）、`destroy_target/equip_type`（摧毁）、`as_type`（当作某类型打出）、`from_opponent`（从对手手牌出牌）

---

## 八、修改代码的三连问（每改一处必查）

1. **服务端需要改吗？** 改了 core/ 逻辑 → 服务器必须重新部署（`git pull` + 重启 Godot 进程）
2. **本地模式同步了吗？** LocalGame 和 Network 共用同一 MatchState，改服务端逻辑必须确认自我对战仍能跑
3. **状态广播了吗？** 任何状态变更后必须 `state_changed.emit(get_full_state())`，否则客户端不同步

# 卡牌对决 — 项目工作流程文档

> **给下一个 AI 对话的交接文档**  
> 当前阶段：架构和功能基本完成，需要重点修复**运行时逻辑错误**

---

## 一、项目概览

双人对战回合制卡牌游戏。78张共享牌堆、8角色、11格棋盘。Godot 4.7.1 + GDScript。服务端权威（WebSocket），客户端纯UI。

### 仓库
- GitHub: `https://github.com/41hu/card_duel`
- 本地: `D:\projects\card_duel`
- 服务器: `root@47.107.47.251`（阿里云 Ubuntu）

### 文件结构

```
card_duel/
├── project.godot              # 项目配置，autoload: Config, Network, LocalGame, McpInteractionServer
├── scenes/
│   ├── main_menu.tscn         # 主菜单（三页：主页/创建房间/加入房间）
│   ├── bp_scene.tscn           # BP禁选（GridContainer角色卡片）
│   ├── battle_scene.tscn       # 对战界面
│   ├── settlement.tscn         # 结算界面
│   └── server.tscn             # 服务端入口
├── scripts/
│   ├── autoload/
│   │   ├── config.gd           # 【重要】静态数据：78卡牌、8角色、12武器、响应规则表、枚举
│   │   ├── network.gd          # WebSocket客户端通信，信号消息
│   │   └── local_game.gd       # 本地自我对战（模拟Network信号，内部用MatchState）
│   ├── core/
│   │   ├── match_state.gd      # 【核心】服务端权威状态机，回合流程，消息处理
│   │   ├── character_skills.gd # 【重要】角色技能钩子系统（18个钩子），加新角色改这里
│   │   ├── card_effects.gd     # 卡牌效果注册表，加新卡改这里
│   │   ├── card_system.gd      # 牌堆/手牌/弃牌管理（双方共享牌堆）
│   │   ├── combat_system.gd    # 伤害计算/响应/武器防具效果
│   │   ├── movement_system.gd  # 11格棋盘/距离/陷阱/推拉
│   │   ├── equipment_system.gd # 武器幻化/防具管理
│   │   ├── status_system.gd    # Buff/DoT/冻结管理
│   │   └── bp_system.gd        # BP禁选流程（随机先手）
│   ├── server/
│   │   └── server_main.gd      # TCPServer + 房间管理 + 消息转发
│   └── ui/
│       ├── main_menu.gd        # 主菜单逻辑
│       ├── bp_ui.gd            # BP界面逻辑
│       ├── battle_ui.gd        # 【重要】对战界面（手牌渲染/响应弹窗/技能按钮/弃牌UI）
│       └── settlement_ui.gd    # 结算界面
├── GAME_RULES.md               # 原始游戏规则
├── RESPONSE_RULES.md           # 响应规则详解
├── start_server.sh             # 服务端启动脚本
└── deploy.sh                   # 服务器部署脚本
```

---

## 二、游戏流程

### 完整流程
```
主菜单 → 创建/加入房间 → 准备 → BP禁选 → 对战 → 结算 → 主菜单
```

### BP禁选（bp_system.gd）
1. 随机决定先手（`_bp_first = randi()%2`）
2. first_ban → second_ban → first_pick → second_pick
3. `picked_chars[0]` = 先手玩家选的，`picked_chars[1]` = 后手玩家选的
4. server_main.gd 根据 `_bp_first` 映射到 P1/P2

### 回合流程（match_state.gd）
```
_judgment_phase()   # 判定阶段：DoT结算、死亡检查
  ↓
_draw_phase()       # 摸牌阶段：抽N张（char_skills.draw_count）
  ↓
_action_phase()     # 出牌阶段：重置AP、emit状态、等待客户端操作
  ↓ (客户端点"结束出牌")
_discard_phase()    # 弃牌阶段：等待玩家弃牌至≤上限
  ↓ (客户端点"确认弃牌")
_advance_to_next_player()  # 切换到对手
```

### 攻击结算顺序
1. 声明攻击 → 2. 计算基础伤害(面板-距离) → 3. 武器加成 → 4. Buff修正 → 5. 零伤检查 → 6. 响应窗口 → 7. 响应效果(格挡/牵制/闪避) → 8. 技能增伤(char_skills.on_attack_cast) → 9. 消耗攻击卡 → 10. 扣HP → 11. 命中特效(武器+技能) → 12. 死亡判定

---

## 三、角色技能钩子系统

所有技能逻辑集中在 `character_skills.gd`，18个钩子：

| 钩子 | 触发时机 | 返回值 | 用途示例 |
|---|---|---|---|
| `on_turn_start(idx)` | 回合开始 | void | 重置状态、分配AP(术士+1) |
| `on_turn_end(idx)` | 回合结束 | void | 术士额外抽牌 |
| `on_opponent_turn_start(curr)` | 对方回合开始 | void | 未来扩展 |
| `can_attack_free(idx, type)` | 判断是否免费 | bool | 弓手首远程免费 |
| `on_attack_cast(idx, type)` | 攻击牌打出 | int(伤害加成) | 法师+2魔伤 |
| `on_attack_hit(att, def, dmg, type)` | 攻击命中后 | void | 剑士回血 |
| `on_taking_damage(def, att, dmg)` | 受伤前 | int(修正后伤害) | 圣骑士减伤/狂战士加攻 |
| `on_heal(idx, amount)` | 回复时 | int(修正后回复量) | 牧师额外+2 |
| `has_active_skill(idx)` | 检查主动技能 | String(技能名或"") | 法师/刺客按钮 |
| `use_skill(idx, skill, params)` | 执行主动技能 | {success, msg} | 法师弃牌/刺客闪现 |
| `draw_count(idx)` | 每回合抽牌数 | int | 默认2 |
| `can_upgrade_skill(idx)` | 是否可升级 | String | 未来扩展 |
| `upgrade_skill(idx, count)` | 执行升级 | {success, msg} | 弃N牌永久增强 |
| `is_immune(idx, effect)` | 免疫检测 | bool | 免疫冻结/DoT/位移 |
| `modify_max_hp(idx, delta)` | 修改生命上限 | void | 正加负减 |
| `modify_stat(idx, stat, delta)` | 修改面板值 | void | stat="near"/"range"/"magic" |
| `hand_limit_bonus(idx)` | 手牌上限修正 | int | 在基础值上加减 |
| `move_distances(idx)` | 移动步数选项 | Array[int] | 默认[1]，可[1,2] |
| `can_equip(idx, type)` | 装备限制 | String(空=可) | "weapon"/"armor" |
| `skill_game_limit(skill)` | 整局次数限制 | int | -1=无限 |
| `_heal_limit(idx)` | 每回合回复上限 | int | -1=无限 |
| `check_hand_condition(idx, cond)` | 手牌条件检查 | bool | 注册表模式 |
| `set_damage_bonus(idx, types, amt, label)` | 设置增伤标记 | void | 通用接口 |

### 玩家数据字典
```gdscript
{
    index, char_id, hp, max_hp, near_power, range_power, magic_power,
    position(3或7), weapon, armor, buffs, dots,
    frozen, frozen_lockout, frozen_move,
    damage_reduction_used, skill_used_this_turn, free_move_used,
    damage_bonus, combo_attacks_this_turn,
    ap_attack(2), ap_move(1), ap_function(1),
    upgrades, skill_counts, healed_this_turn
}
```

---

## 四、卡牌效果系统（card_effects.gd）

注册表模式。加新卡：
1. `config.gd` 的 `CARD_DB` 加一行定义 → `CARD_COUNTS` 加数量
2. 本文件 `_handlers` 字典加 `"type_id": _handler_func`
3. 写效果函数

### 卡牌响应规则（config.gd）
```gdscript
RESPONDABLE_CARDS = ["near","range","magic","heavy","pierce","chant","freeze"]
RESPONSE_BY = {
    "near":["near"], "heavy":["near"],
    "range":["range"], "pierce":["range","magic"],
    "magic":["range","magic"], "chant":["range","magic"],
    "freeze":["magic"]
}
```

---

## 五、网络协议（JSON）

客户端→服务端：`{"t":"消息类型", ...其他字段...}`
服务端→客户端：同上，服务端广播状态为 `{"t":"game_state", ...}`

| 消息 | 方向 | 说明 |
|---|---|---|
| create_room | C→S | 创建房间 |
| join_room | C→S | 加入房间 |
| ready | C→S | 准备 |
| bp_action | C→S | BP操作 `{action:"ban"/"pick", char_id}` |
| play_card | C→S | 出牌 `{card_uid, extra:{...}}` |
| end_turn | C→S | 结束出牌 |
| respond | C→S | 响应 `{respond:bool, card_uid}` |
| weapon_choice | C→S | 武器确认 `{accept:bool}` |
| discard_one | C→S | 弃单张 `{card_uid}` |
| confirm_discard | C→S | 确认弃牌 `{card_uids:[]}` |
| use_skill | C→S | 使用技能 `{skill:"xxx", ...}` |
| reveal_hand | C→S | 请求查看对方手牌 |

### extra 参数
- `as_type`: 把牌当作某类型打出
- `from_opponent`: 从对手手牌出牌
- `steps`: 移动步数（默认1）
- `direction`: 移动方向（-1左/1右）
- `trap_pos`: 陷阱位置
- `destroy_target`: 摧毁目标（"hand"/"equip"）
- `card_uid`: 法师技能选弃的卡

---

## 六、已知问题和待修复

### 运行时逻辑错误（优先级排序）

1. **响应卡消耗和伤害结算** — 远程攻击被魔法闪避后双方卡都未消耗，游戏卡住
2. **弃牌阶段按钮连点** — confirm_discard 重复发送
3. **魔法攻击间歇性"距离过远"** — 状态同步时序问题
4. **冻结不跳过出牌阶段** — _action_phase 检查可能有问题
5. **盾兵（圣骑士）减伤显示** — 伤害计算顺序问题
6. **DoT 没有造成实际伤害** — combat.apply_dot_damage 返回值未被处理

### 已完成的功能（可回归测试）
- BP流程、回合切换、出牌/弃牌
- 共享牌堆、洗牌
- 响应窗口（格挡/牵制/闪避）
- 卡牌颜色分类、行动点圆圈
- Buff/DoT显示
- 法师主动技能（选卡弃牌→魔法+2）
- 刺客主动技能（免费移动1格）
- 陷阱触发（走/推/拉/吸引/威慑）
- 防具衰减（免疫→减半→减半→碎裂）
- 武器幻化（装备/丢弃/被摧毁回池）
- 角色技能显示、HP条件检查、手牌条件检查
- 免疫系统（冻结/DoT/位移/技能伤害）
- 偷牌/还牌、查看对手手牌
- 整局技能次数限制、每回合回复上限
- 生命上限修改、面板值修改

---

## 七、测试方法

### 本地自我对战
1. Godot 编辑器打开项目
2. 点运行 → 主菜单 → "自我对战"
3. 随机选两个角色直接开打

### 服务端联机
1. 启动服务端（SSH 到服务器）：
```bash
cd ~/card_duel && git pull && pkill -f Godot && nohup ~/godot/Godot_v4.7.1-stable_linux.x86_64 --headless --path ~/card_duel scenes/server.tscn > server.log 2>&1 &
```
2. 客户端填 `ws://47.107.47.251:17890`
3. 创建/加入房间 → 准备 → 对战

### Git 操作
```bash
cd D:\projects\card_duel
git add -A
git commit -m "描述"
git push
```

---

## 八、调试工具

- **远程执行器**：`godot-remote-executor` skill，连到编辑器执行 GDScript
  - Token: `995e7c3f6fabc40a1bcd8a6f94dcad0106959c26c5827d2d3b261e1969109bd7`
  - URL: `http://localhost:5302`
- **MCP Godot工具**：`mcp__godot__*` 系列，需要 `McpInteractionServer` autoload
- **服务端日志**：SSH 到服务器 `cat ~/card_duel/server.log`

---

## 九、注意事项

- GDScript 用 **Tab 缩进**，不用空格
- `match` 是关键字，不能做变量名（已全部改用 `_ms`/`_m`）
- `preload` 必须在引用前声明（const 顺序）
- 服务器监听 `tcpserver.listen(PORT)` 不要绑 `127.0.0.1`（外网连不上）
- 改任何代码后考虑三件事：服务端需要改吗？本地模式要同步吗？改完发状态更新了吗？
- `replace_all` 谨慎使用，容易误伤

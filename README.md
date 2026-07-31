# 卡牌对决 (Card Duel)

双人对战回合制卡牌游戏。78 张共享牌堆、8 名角色、11 格棋盘。服务端权威架构（WebSocket 联机），Godot 4.7 + GDScript，GL Compatibility 渲染器。

---

## 给 AI 协作开发者的说明（请先完整阅读本文件）

你被邀请参与此项目的开发。你的职责是：**修复游戏逻辑 bug、实现新功能**，只改 GDScript 代码和 `.tscn` 场景文件。

### 第一步：按优先级阅读这些文档

| 文档 | 作用 | 权威性 |
|---|---|---|
| `WORKFLOW.md` | **最高权威**。架构、文件地图、游戏流程、角色技能钩子系统、网络协议、**当前已知 bug 清单（第六节）**、测试方法、注意事项 | ⭐ 一切以它为准 |
| `GAME_RULES.md` | 游戏规则（卡牌数值、角色、防具、复活等）。注意：其"八、技术架构"一节已过时，请忽略，以 WORKFLOW.md 为准 | 次权威 |
| `RESPONSE_RULES.md` | 响应（格挡/牵制/闪避）与卡牌效果细节 | 补充 |

### 第二步：明白当前阶段要做什么

**当前阶段：架构和功能基本完成，重点是修复运行时逻辑错误。** WORKFLOW.md 第六节列了按优先级排序的 6 个已知 bug（响应卡消耗、弃牌连点、魔法距离、冻结跳过、圣骑士减伤显示、DoT 无伤害）。开始工作前先读该清单，选一个修。

### 代码地图（改哪类东西去哪个文件）

| 想做什么 | 改哪个文件 |
|---|---|
| 修复对战逻辑 | `scripts/core/match_state.gd`（回合状态机，服务端权威） |
| 加新角色/改技能 | `scripts/core/character_skills.gd`（钩子系统）+ `scripts/autoload/config.gd`（角色数据） |
| 加新卡/改卡效果 | `scripts/autoload/config.gd`（`CARD_DB`/`CARD_COUNTS`）+ `scripts/core/card_effects.gd`（效果注册表） |
| 伤害/响应/武器防具 | `scripts/core/combat_system.gd` |
| 棋盘/移动/陷阱 | `scripts/core/movement_system.gd` |
| Buff/DoT/冻结 | `scripts/core/status_system.gd` |
| BP 禁选流程 | `scripts/core/bp_system.gd` |
| 对战界面 UI | `scripts/ui/battle_ui.gd` + `scenes/battle_scene.tscn` |
| 菜单/房间 UI | `scripts/ui/main_menu.gd` + `scenes/main_menu.tscn` |
| 静态数据（卡/角色/武器/枚举） | `scripts/autoload/config.gd` |

### 开发铁律（每改一处代码必问三件事）

1. **服务端需要改吗？** `match_state.gd` 是唯一权威状态机，所有游戏逻辑判定都在它里面。客户端 UI 不做任何判定，只转发操作。
2. **本地模式要同步吗？** `scripts/autoload/local_game.gd` 用本地 `MatchState` 模拟网络信号（自我对战用）。改了服务端逻辑，要确认自我对战模式仍能跑。
3. **改完发状态更新了吗？** 任何状态变更后要广播 `game_state`，否则客户端显示不同步。

### 代码规范（违反会导致运行错误）

- GDScript 用 **Tab 缩进**，不要用空格
- `match` 是关键字，不能当变量名
- `preload` 必须在引用前声明（const 顺序）
- 服务端 `tcpserver.listen(PORT)` 不要绑 `127.0.0.1`（外网连不上）
- `replace_all` 谨慎使用，容易误伤

### 如何测试你的改动

**本地自我对战（推荐，最快）**：Godot 编辑器打开项目 → 点运行 → 主菜单 → **自我对战** → 随机选两个角色开打。能完整走完：出牌、移动、响应、弃牌、BP 流程。

联机测试需要云服务器（`ws://47.107.47.251:17890`），仅在自我对战测不了的情况下用。

### Git 提交规范

- 新建功能/修复分支，别直接推 main
- 提交信息：简短中文，描述"为什么改"（如 `fix: 响应卡消耗后双方卡都未扣除`）
- 提交前确认自我对战模式无回归

### 不要碰的区域（不在你的职责范围）

- `.github/workflows/build.yml` — CI 自动打包（GitHub Actions）
- `export_presets.cfg`、`android/` — Android 导出配置（keystore 是私有的）
- `deploy.sh`、`start_server.sh` — 服务器部署脚本
- 根目录 `mcp_interaction_server.gd` — 本地 AI 调试桥（不入库，clone 后不存在）
- `addons/` — 编辑器插件（不入库），项目打开提示插件缺失点"忽略"即可，不影响运行

---

## 环境要求

- **Godot 4.7**（必须一致，官网下载，GL Compatibility 渲染器）
- 无其他依赖，clone 即跑

## 运行

```bash
git clone https://github.com/41hu/card_duel.git
# 用 Godot 4.7 打开 project.godot，F5 运行
```

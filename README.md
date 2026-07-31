# 卡牌对决 (Card Duel)

双人对战回合制卡牌游戏。78 张共享牌堆、8 名角色、11 格棋盘。服务端权威架构（WebSocket 联机），Godot 4.7 + GDScript，GL Compatibility 渲染器。

---

## 给 AI 协作开发者的说明（请先完整阅读本文件）

你被邀请参与此项目的开发。**先确认你的身份**：
- 如果你是**主维护者的 AI**（负责推送更新、UI、手机适配、修复 bug）：阅读下面的完整说明，按"文件职责划分"工作
- 如果你是**平衡性开发者的 AI**（负责游戏平衡性调整）：跳到"给平衡性开发者的专属指引"小节，其余部分只需了解"文件职责划分"和"开发铁律"

### 给平衡性开发者的专属指引

你的唯一职责：**游戏平衡性调整**——调整角色数值、卡牌强度、技能效果。不修 UI bug、不做新功能系统、不动推送更新相关代码。

**你可以改的**：
- `scripts/autoload/config.gd` — 卡牌数据（`CARD_DB`/`CARD_COUNTS`）、角色属性、武器效果数值
- `scripts/core/character_skills.gd` — 角色技能逻辑
- `scripts/core/card_effects.gd` — 卡牌效果逻辑
- `scripts/core/combat_system.gd`、`movement_system.gd`、`status_system.gd`、`equipment_system.gd`、`bp_system.gd`、`card_system.gd`、`match_state.gd` — 相关规则逻辑
- `GAME_RULES.md`、`RESPONSE_RULES.md` — 同步更新你改动的规则文档

**你绝对不能改的**：`scripts/ui/`、`scenes/`、`scripts/version.gd`、`scripts/theme/`、`.github/`、`export_presets.cfg`、`deploy.sh`、`start_server.sh`、`project.godot`

**平衡性改动自检清单**（改完逐项确认）：
1. 数值一致性：`CARD_COUNTS` 各卡数量总和仍为 78？角色仍为 8 名？武器/防具池数量与文档一致？
2. 改 `scripts/core/` 后**必须通知主维护者部署服务器**（服务端跑的是同一套逻辑，不部署则联机对战不生效）
3. 提交前用**自我对战**跑一局验证：主菜单 → 自我对战 → 随机选两个角色 → 完整走完一局

**提交规范**：提交信息以 `balance:` 开头（如 `balance: 剑士HP 28→26`），push 前先 `git pull --rebase`。

### 第一步：按优先级阅读这些文档

| 文档 | 作用 | 权威性 |
|---|---|---|
| `API_REFERENCE.md` | **方法级参考**。每个脚本/方法/信号的用途、加卡/加角色/加武器/加状态的**标准实现流程**、网络协议、修改代码三连问 | ⭐ 改代码前先查它 |
| `WORKFLOW.md` | 架构、文件地图、游戏流程、角色技能钩子系统、网络协议、**当前已知 bug 清单（第六节）**、测试方法、注意事项 | ⭐ 一切以它为准 |
| `GAME_RULES.md` | 游戏规则（卡牌数值、角色、防具、复活等）。注意：其"八、技术架构"一节已过时，请忽略，以 WORKFLOW.md 为准 | 次权威 |
| `RESPONSE_RULES.md` | 响应（格挡/牵制/闪避）与卡牌效果细节 | 补充 |

### 第二步：明白当前阶段要做什么

**当前阶段：架构和功能基本完成，重点是修复运行时逻辑错误（主维护者的任务）。** WORKFLOW.md 第六节是完整的已知 bug 清单（含严重度与归属）。平衡性开发者不需要处理此清单，除非改动恰好涉及对应代码。

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

### 文件职责划分（多人协作防冲突，重要）

本项目有两位维护者，分工不同。**只改自己区域的代码，公共区改动前先看是否影响对方**：

| 区域 | 文件 | 归属 |
|---|---|---|
| **平衡性**（另一位开发者） | `scripts/autoload/config.gd`、`scripts/core/` 全部（`match_state`/`character_skills`/`card_effects`/`combat_system`/`movement_system`/`equipment_system`/`status_system`/`bp_system`/`card_system`）、`GAME_RULES.md`、`RESPONSE_RULES.md` | 另一位开发者 |
| **推送更新 + UI/手机适配**（主维护者） | `scripts/version.gd`、`scripts/ui/` 全部（含 `main_menu.gd`）、`scenes/` 全部、`scripts/theme/`、`.github/workflows/build.yml`、`deploy.sh`、`start_server.sh`、`export_presets.cfg` | 主维护者 |
| **公共区** | `project.godot`、`README.md`、`WORKFLOW.md` | 谁改谁负责，改完通知对方 |

两条铁律：
1. **`scripts/version.gd` 只有主维护者能改**（版本号与 CI 发布、游戏内更新提示联动，乱改会导致发布错乱）
2. **改完 `scripts/core/` 的代码必须通知主维护者部署服务器**（服务端跑的是同一套权威逻辑，不部署则联机对战的规则不变）
3. **不要修改 `scripts/ui/` 和 `scenes/` 下的任何文件**（UI 及手机端适配由主维护者负责）。如果在 UI 层发现 bug（如按钮连点、显示错误），**只报告不修改**，交给主维护者处理

协作流程：改自己区域 → 提交 → **`git pull --rebase`**（冲突在此步本地解决）→ `git push`。不要在没拉取远端的情况下直接 push。

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

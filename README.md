# Agent 会话寻回器（macOS）

**适用平台：Mac / macOS 14 及以上。** 图形应用和随仓库提供的 `acf` CLI 都面向 macOS 构建与运行；本仓库不提供 Windows、Linux、iOS 或 Android 版本。

一个本地运行的 macOS SwiftUI 应用，统一查找 Codex App、Codex CLI 和 Claude Code 主会话。按工作目录浏览、搜索正文、查看摘要、管理本地别名，并复制与数据环境匹配的恢复命令。附带 `acf` 命令行工具，方便 Agent 做配置诊断和本地检索。

**仓库只包含源码、合成测试和文档。首次运行读取的是使用者自己的会话；不需要作者的账号、目录、Shell wrapper 或 API Key。**

## 快速开始

需要 macOS 14+、Swift 5.9+、macOS SDK，以及系统自带的 `/usr/bin/sqlite3`。推荐安装完整 Xcode 并完成其初次设置，确保 `swift --version`、`swift test` 可用。应用没有第三方 Swift 包依赖；Codex/Claude CLI 只在恢复或归档时需要。

```sh
# 在已克隆的仓库根目录执行
swift test
./scripts/build-app.sh
open 'build/Agent Conversation Finder.app'
```

要安装到当前用户的 Applications 目录：

```sh
./scripts/install-app.sh
```

安装脚本不覆盖已有安装；更新时先退出应用、把旧包移到其他位置，再运行脚本。可用 `ACF_INSTALL_DIR` 指定其他安装目录。应用在本机临时签名，没有 Apple 公证；无需关闭 Gatekeeper、SIP 或系统安全设置。

也可以直接开发运行：`swift run AgentConversationFinderApp`。

## 给 Agent 的一句话

> 请先读这个仓库的 AGENTS.md，运行 swift test 和 acf doctor；根据我本机实际安装位置配置 config.json，构建并打开应用。不要把会话、缓存、配置、诊断输出或构建产物提交到 Git；恢复命令保持默认权限策略，归档操作先说明会改动哪套 Codex 数据。

其中 `acf doctor` 的完整源码运行命令是 `swift run acf doctor`。

## 配置

默认扫描 `~/.codex` 和 `~/.claude`。第二套 Codex 数据环境默认关闭，可显式开启，界面显示为 **Secondary**。这是通用的第二数据目录，不绑定任何供应商或账号。

配置文件位置：

```text
~/Library/Application Support/Agent Conversation Finder Shared/config.json
```

可以这样创建，再用文本编辑器修改路径：

```sh
mkdir -p "$HOME/Library/Application Support/Agent Conversation Finder Shared"
cp -n config.example.json "$HOME/Library/Application Support/Agent Conversation Finder Shared/config.json"
chmod 700 "$HOME/Library/Application Support/Agent Conversation Finder Shared"
chmod 600 "$HOME/Library/Application Support/Agent Conversation Finder Shared/config.json"
```

`cp -n` 保留已有配置。更改配置后退出并重启应用。Finder 启动也读取此文件，无需修改 `.zshrc`。字段详情：

| JSON 字段 | 默认值 | 对应环境变量 |
| --- | --- | --- |
| `codexHome` | `~/.codex` | `ACF_CODEX_HOME` |
| `secondaryCodexHome` | 空字符串，关闭第二环境 | `ACF_SECONDARY_CODEX_HOME` |
| `claudeHome` | `~/.claude` | `ACF_CLAUDE_HOME` |
| `codexExecutable` | `codex` | `ACF_CODEX_EXECUTABLE` |
| `claudeExecutable` | `claude` | `ACF_CLAUDE_EXECUTABLE` |
| `stateDirectory` | 上述应用支持目录 | `ACF_STATE_DIR` |

`ACF_CONFIG` 可指定另一个 JSON 配置文件。环境变量覆盖 JSON；路径必须是绝对路径或 `~/` 开头，不展开 `$HOME` 等 Shell 变量。CLI 字段只能填程序名或可执行文件路径，不能填一串命令、参数或 Shell 函数。Finder 的 PATH 通常比终端短，归档找不到 Codex 时填写 `command -v codex` 对应的真实可执行文件绝对路径。

例如设置 `secondaryCodexHome` 为 `~/.codex-secondary`，就能分别查看两套 Codex 数据。同一 ID 不跨环境合并；缓存按配置的数据根自动分区，切换账号路径不会复用上一套结果。配置格式错误会显示警告并停止扫描，修正后重启。

## 使用界面

1. 首次启动建立本地索引；之后有缓存就直接展示，点击“刷新”才重新读取。
2. 默认先选工作目录，再选会话。目录名称突出显示，完整路径用于搜索和提示。
3. 默认显示 Codex CLI 和 Claude Code，隐藏 Codex App、已归档会话和 `new-chat` 一类占位目录；在来源菜单中开启需要的项。
4. 输入关键词，空格分隔的多个词按 AND 匹配。支持本地别名、原始标题、规则生成的主题、用户消息、助手关键进展、路径和会话 ID。
5. 详情展示创建时间、最后活动时间及其依据、最近三条用户消息、摘要、主题和阶段；表格模式支持筛选、排序和每页 100 条分页。
6. 重命名只保存本地别名，可以清除；归档前有确认，支持取消归档。

## 继续会话与归档

- **Codex App 会话**：保留前往 Codex App 查找的引导。来源决定恢复方式，不把主数据目录等同于 App。
- **Codex CLI 会话（主环境或第二环境）**：生成显式 `CODEX_HOME` 的 `codex -C ... resume ...` 命令，分别选择配置中的主根或第二根；默认只装 CLI、数据在 `~/.codex` 的用户也可以直接复制恢复命令。已归档会话先生成 `unarchive`。程序、路径和会话 ID 均做 Shell 引号处理。
- **Claude Code**：生成 `(cd -- ... && env CLAUDE_CONFIG_DIR=... claude --resume ...)`，不依赖任何个人 `--cwd` wrapper。
- 恢复命令只供复制，不自动运行，也不默认加入绕过权限确认的参数。执行恢复命令后 Agent 的网络行为由各自 CLI 的配置决定。
- Codex 归档通过配置的本地 CLI 调用原生 `archive` / `unarchive`，显式传递同一数据根。需要该 CLI 版本支持这些子命令；不支持时显示失败，不直接写数据库。
- Claude 没有相同的原生归档接口，因此采用寻回器本地归档，不修改 Claude 自己的恢复列表。

## Agent / CLI 用法

```sh
swift run acf --help
swift run acf doctor
swift run acf scan --query '示例 关键词'
swift run acf scan --query '示例' --json
```

`doctor` 检查配置及路径，不读取对话。`scan` 是一次性的完整只读扫描，不使用 GUI 别名/本地归档、不写索引缓存，也不运行恢复命令。JSON 包含 records 和 warnings；为了完整检索，CLI 不应用 GUI 默认来源/归档过滤。结果可能包含私人内容，只在本机使用。`scan` 有来源警告时仍返回其余可用来源的结果，请检查 warnings。

## 隐私、验证与限制

- 应用自身没有网络请求、遥测、云同步或模型 API；规则摘要完全在本地生成。原始会话正文不被改写，Codex 原生归档会修改其索引/归档状态。
- 索引包含原始检索文本、路径和会话 ID，是敏感数据。文件权限为 `0600`，新建目录为 `0700`；不要上传整个应用支持目录、终端输出或截图。
- 首次索引完整流式读取记录，后续只处理追加的 JSONL 内容。每个会话的检索文本最多保留约 300,000 字符；达到上限后仍更新摘要/最近消息，但无法保证搜索到更晚的全部正文。助手只索引规则识别的关键进展。
- 当前主要支持 Codex `state_5.sqlite` 和常见的 `session_meta` / `event_msg` / `response_item` JSONL；数据库格式不兼容会回退到文件扫描。上游存储格式属于实现细节，升级后可能需要适配。具体兼容策略见 [架构与兼容性](docs/architecture.md)。
- 只收录主会话，排除 Codex exec/子代理来源及 Claude `subagents`；不做删除、跨电脑同步、账号认证或损坏数据恢复。
- 不要在 App 和 CLI 同时向同一个会话写入。规则标题和摘要可能不准确，原始标题与记录仍可查看。

```sh
swift test
python3 scripts/check-release.py
python3 scripts/test-cli.py .build/debug/acf
```

测试使用临时目录中的合成 JSONL/SQLite 和虚构路径，不读取真实账号。GitHub Actions 在 macOS 上运行同样的测试和构建。隐私范围与反馈方式见 [SECURITY.md](SECURITY.md)，设计背景与来源见 [PROVENANCE.md](PROVENANCE.md)。

如果当前 Xcode 初次设置尚未完成，`swift` 可能报告 license 错误；由本机用户自行处理 Xcode 设置。可尝试用已安装且可用的 Command Line Tools 构建：`DEVELOPER_DIR=/Library/Developer/CommandLineTools ./scripts/build-app.sh`。部分 CLT 不附带 XCTest，完整测试仍需要兼容的 Xcode 测试框架。

本机若使用 CLT、同时安装了 Xcode 测试框架，可运行 `./scripts/test-clt.sh`：它先构建全部测试及应用，再使用 XCTest runner 执行完整测试套件。默认选择 SDK 26.5 以避开部分 SDK 27 / CLT 缺 SwiftUI 宏的问题；可通过 `SDKROOT` 和 `ACF_XCODE_DEVELOPER` 指向兼容安装。普通完整 Xcode 环境和 CI 直接使用 `swift test`。

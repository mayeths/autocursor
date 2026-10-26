# AutoCursor

一个 macOS 自动点击器，用系统 Accessibility API 识别 Cursor 中明确的运行确认按钮。当前支持 `full-access` 模式。

## 构建与启动

```bash
./build-app.sh
open AutoCursor.app
```

App 启动后会显示主窗口：

- 顶部：运行状态、总检测数、总点击数和全局开关
- 已发现的 Cursor 窗口列表（高度随窗口数量自适应），每个窗口可单独开关
- 最近活动记录

Cursor 在前台时，每个可见的 Cursor 窗口右上角会出现一条浮动控制条，可单独停用 / 启用该窗口；按住左侧文字区域可拖动位置。主窗口底部可关闭浮动控制条。关闭主窗口后点击 Dock 图标即可重新打开。

## 辅助功能权限

在 `系统设置 -> 隐私与安全性 -> 辅助功能` 中添加 `AutoCursor.app`。授权后 App 会自动开始工作，无需重启。

App 使用 ad-hoc 签名，**每次重新构建后旧的授权会失效**：需要在辅助功能列表中删除旧的 AutoCursor 条目再重新添加，或执行：

```bash
tccutil reset Accessibility local.autocursor
```

## 命令行模式

带参数运行时不显示界面，直接在终端中扫描：

```bash
./.build/release/autocursor --dry-run --verbose
```

```text
--mode full-access   当前支持的确认模式
--app Cursor         目标应用名
--interval 0.35      扫描间隔，单位秒
--dry-run            只检测，不点击
--once               扫描一次后退出
--verbose            输出辅助功能树中的按钮诊断信息
```

扫描范围：只扫描每个 Cursor 窗口里的 Agent 面板。Agent 面板从输入框（旁边带模型选择器）向上定位，一直到再往上一层就会包含编辑器标签栏为止；设置页、文档、终端、文件树都不会被扫描。名称取自对应的 Agent 标签页。主窗口按「窗口 → Agent」分层列出，两层都可以单独开关。未选中的 Agent 标签页 Cursor 不会渲染，因此无法自动确认，需要切换过去或分屏显示。

匹配规则：

- 识别文字为 `Always Run`、`Run command`、`Run`、`Execute` 的控件（快捷键符号如 `⇧⏎` 会被忽略）。Cursor 的按钮是网页里的可点击 `div`，因此原生按钮和文字节点都会被识别。
- 非原生按钮还需要同一按钮行内出现 `Skip`、`Reject`、`Cancel` 等其他选项，且这一行只包含简短的英文按钮文字；聊天内容里的同名文字会被排除。
- 点击后如果同一个元素仍然存在（说明它不是真正的确认按钮），之后不再点击它。
- 「设置」中的「点击间隔」决定同一窗口两次自动点击的最短间隔（0.5s–5s）。
- `Always Allow`、`Allow`、`Approve`、`Confirm` 还要求上下文包含 terminal、command、agent、shell、permission、mcp、tool 等词。
- 同一提示框同时有多个选项时，优先点击 `Always Run`，其次是 `Run command`、`Run`。

识别不到时，点击主窗口右下角「导出诊断」（或菜单「导出辅助功能诊断…」），会在桌面生成 `AutoCursor-diagnostics.txt`，里面是 Cursor 当前的辅助功能树。

## 限制

- 需要 macOS 13 或更高版本。
- Electron/Cursor 版本变化可能影响 Accessibility 树；可用 `--verbose` 排查。

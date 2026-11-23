<p align="center">
  <img src="app/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="WordSnap 浅蓝渐变图标：字母经过镜片被放大" />
</p>

# WordSnap

**随手捕捉单词，留进自己的词库。**

macOS 桌面应用：快捷键呼出悬浮窗 → 查询单词 → 保存到 Obsidian。

读英文时，复制一个生词，按 `⌘L` 查清意思，再按 `⌘Enter` 保存。每个词都是
自己的 Markdown 笔记，可以补充语境、例句，也可以在配套 Obsidian 插件里翻卡复习。

原生 Swift App（SwiftUI + URLSession），无需 Python 或第三方 Swift 运行时依赖。

[下载正式版](https://github.com/LiLYzY54/WordSnap/releases/tag/v1.2.0) ·
[下载 macOS 13+ 兼容测试版](https://github.com/LiLYzY54/WordSnap/releases/download/v1.2.1-beta.1/WordSnap-1.2.1-beta.1-universal.zip) ·
[反馈问题](https://github.com/LiLYzY54/WordSnap/issues) · [MIT 开源许可](LICENSE)

## 下载哪个版本？

| 版本 | 系统要求或兼容目标 | 下载 |
| --- | --- | --- |
| **正式版 v1.2.0** | 要求 macOS 26 或更新版本 | [正式版下载页](https://github.com/LiLYzY54/WordSnap/releases/tag/v1.2.0)（DMG / ZIP） |
| **兼容测试版 v1.2.1-beta.1** | 目标为 macOS 13+，旧系统兼容性待用户验证 | [直接下载测试版 ZIP](https://github.com/LiLYzY54/WordSnap/releases/download/v1.2.1-beta.1/WordSnap-1.2.1-beta.1-universal.zip)（约 2.5 MB）· [版本说明](https://github.com/LiLYzY54/WordSnap/releases/tag/v1.2.1-beta.1) |

两个版本的安装包均为 Universal，同时包含 Apple Silicon 和 Intel 架构，**无需按芯片分别下载**。
但包含 Intel 架构不代表所有 Intel Mac 或旧系统都已验证可用。
目前不支持 macOS 12 及更早版本。

### 兼容测试版：请先了解验证范围

**v1.2.1-beta.1 是预发布测试版，尚未在 macOS 13、14、15 的真机或虚拟机上实测，也未在 Intel 真机验证。**

- macOS 13–15 会使用传统毛玻璃窗口和普通强调按钮；macOS 26 及以上保留 Liquid Glass。
- 已在 Apple M4、macOS 27.3 开发机上完成双架构构建、最低系统标记检查、74 项 Swift 测试、
  29 项插件测试和 8 个迁移场景，以及联网查词、临时词库写入和表格撤销检查。
- 上述结果不能替代旧系统实测。欢迎旧系统用户协助试用；如果目前正在使用正式版且运行正常，可以继续使用正式版。

测试版附件名为 `WordSnap-1.2.1-beta.1-universal.zip`；包内版本号是 **1.2.1，构建号 4**。
请下载 App ZIP，不要下载 GitHub 自动生成的 **Source code** 压缩包。
[测试版 SHA-256 校验文件](https://github.com/LiLYzY54/WordSnap/releases/download/v1.2.1-beta.1/WordSnap-1.2.1-beta.1-SHA256SUMS.txt)
可用于核对下载文件。

## 安装与首次使用

1. 按上表选择版本。退出正在运行的 WordSnap；下载 DMG 后打开并将 WordSnap 拖进「应用程序」，
   下载 ZIP 则先解压，再将 `WordSnap.app` 放入「应用程序」。兼容测试版目前提供 ZIP。
2. 当前发行包为 ad-hoc 签名，**尚未经过 Apple 公证**，macOS 可能阻止首次打开。
   请确认下载来源；也可按下方开发说明从源码构建。
3. 启动后从菜单栏进入「设置…」，把词汇表路径设到自己的 Obsidian vault 内，
   例如 `<你的 vault>/English Vocabulary Learning.md`。查词本身不要求安装 Obsidian。
   **试用兼容测试版时，建议先选择临时词库，或备份原词库。**
4. 复制一个英文单词 → `⌘L` → `Enter` 查词 → `⌘Enter` 保存。
   默认快捷键如与其他工具冲突，可在设置里重新录制。

App 常驻菜单栏，不显示 Dock 图标。`Esc` 可收起查词面板。
配套 Obsidian 插件本次没有改动，可继续使用 v1.2.0 插件。

## 帮忙测试与反馈

请重点试试：能否启动并出现菜单栏图标，快捷键能否呼出/收起窗口，查词、发音、保存和撤销是否正常，
以及毛玻璃背景、文字、按钮和设置窗口是否显示正常。有条件也欢迎检查浅色/深色模式及登录时启动。

测试后请到 [GitHub Issues 反馈](https://github.com/LiLYzY54/WordSnap/issues/new)，
标题可以写 `[兼容测试] macOS 版本 + 测试通过/问题描述`，并附上以下信息。
**系统版本和芯片型号可在苹果菜单 →「关于本机」中查看；请提供完整版本号，而不只是“老系统”。**

```text
macOS 完整版本：（例如 13.6.9 / 14.7.1 / 15.1）
芯片型号：（例如 Apple M1 / M2 / M3，或 Intel Core i5 / i7）
WordSnap 版本：v1.2.1-beta.1（1.2.1，构建 4）
是否能启动：
已测试功能及结果：
如有异常：操作步骤、预期结果、实际结果、报错文字或截图
```

**即使全部正常，也欢迎反馈系统版本、芯片型号和已测试项目**，帮助我们确认兼容范围。
附截图或日志时，请先去除私人词库和笔记内容。

## 快捷键

- `⌘L`: 呼出/隐藏悬浮窗（菜单栏「设置…」可换键并支持录制）
- `Enter`: 在输入框时触发查询
- `⌘Enter`: 预览结果时保存到 Obsidian
- `Esc`: 隐藏窗口

## 使用流程

1. 按 `⌘L` 呼出悬浮窗——剪贴板里若正好是单词会自动预填，回车即查
2. 预览释义（单词 / 音标 / 🔊 发音 / 词性 / 中英释义 / 例句）
3. 按 `⌘Enter` 保存；横幅显示「第 N 个词」，4 秒内可撤销
4. 重复保存不会报错，而是显示「X月X日 存过，又遇到它了」（间隔重复信号）
5. 查不到的词给出「你是不是想找」候选胶囊，一键重查
6. Esc 隐藏窗口；保存后自动收起

词表读取失败时会保留原文件并报错。若词表已保存、词笔记写入失败，面板会
保留错误提示，可点击「重试词笔记」补建，也可撤销本次新增记录。

## Obsidian 词汇库

- **表格（采集日志）**：默认 `~/Documents/Obsidian/English Vocabulary Learning.md`，
  每次保存追加一行
- **词笔记（词的家）**：保存在表格同目录 `Vocabulary/<word>.md`，含
  frontmatter（词/音标/词性/星级/状态）与文末 `word::释义` 单行卡，
  直接兼容 obsidian-spaced-repetition 插件在桌面/手机上背诵
- **菜单栏**：📖 今日一词（点击即查）、近 16 周热力图、设置…

### Obsidian 词库管理界面（自带插件）

仓库 `obsidian-plugin/` 目录是一个零依赖的 Obsidian 插件。可从 Releases 下载
`wordsnap-vocab-1.2.0.zip`，解压后把 `wordsnap-vocab` 文件夹放进 vault 的
`.obsidian/plugins/`，重新加载 Obsidian，在「设置 → 社区插件」中启用
「WordSnap 词库」。也可手动复制仓库中的 `main.js`、`manifest.json`、`styles.css`
到同一目录。插件目前需要手动安装。

启用后即可使用词汇管理面板：

- **词库页**：搜索、状态筛选、卡片网格、🔊 发音、点词开笔记、
  点状态徽章轮换（新词→学习中→熟悉→已掌握）
- **复习页**：翻卡 + 四档评分，评分回写词笔记的 frontmatter `status`
- **统计页**：总词数 / 本月新增 / 已掌握 / 月度柱状 / 16 周热力图

四档评分记录掌握状态，当前插件没有按到期日期调度的 FSRS / SM-2 算法。
需要间隔重复调度时，可另行安装兼容词笔记单行卡的插件。

启动 Obsidian 自动展示（需要 Obsidian 1.1.0+）。插件默认读取 vault 根目录的
`English Vocabulary Learning.md` 和 `Vocabulary/`。若 App 使用自定义位置，
需在插件设置中填写对应的 vault 相对路径；插件不会读取 Mac 的 `~/.wordsnap.json`。

路径配置：菜单栏「设置…」图形化选择，或环境变量 `WORDSNAP_OBSIDIAN_PATH` /
`~/.wordsnap.json`。

表格列：`| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |`
文件不存在时自动创建（含表头），单词列带 Obsidian 双链。

## 技术栈

- Swift 5 + SwiftUI（macOS 13+；macOS 26+ 使用 Liquid Glass，旧系统使用 AppKit 毛玻璃）
- 有道词典 JSON API（`dict.youdao.com/jsonapi`，免费无需 Key）
- XcodeGen 构建工程
- 全局快捷键：Carbon `RegisterEventHotKey`（可配置、可持久化）

## 开发与构建

Xcode 工程不入库，由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `app/project.yml` 生成。

```bash
# 获取源码
git clone https://github.com/LiLYzY54/WordSnap.git
cd WordSnap

# 一键构建（需要 Xcode 26+ 和 xcodegen；首次克隆直接跑即可）
./scripts/setup.sh

# 运行应用（构建产物在 ~/Library/Developer/Xcode/WordSnap，不被 Spotlight 索引）
open ~/Library/Developer/Xcode/WordSnap/DerivedData/Build/Products/Debug/WordSnap.app

# 单元测试（解析 / 分帧解码 / 表格写入 / 词笔记 / 统计等纯逻辑）
xcodebuild test -project app/WordSnap.xcodeproj -scheme WordSnap -destination 'platform=macOS'

# Obsidian 插件回归测试（Node.js 18+，无需安装 npm 依赖）
node --test obsidian-plugin/tests/*.test.cjs

# 迁移脚本回归测试（隔离临时文件，包含备份保护）
./scripts/test_migrate_vocab.sh

# 一次运行全部验证：生成工程、构建及 Swift 测试、插件测试、迁移测试
./scripts/test.sh
```

改构建配置请编辑 `app/project.yml` 后在 `app/` 下执行 `xcodegen generate`，
不要手工编辑工程文件。架构细节见 `SPEC.md`。

构建仍需 Xcode 26+（使用 Liquid Glass SDK），运行只需 macOS 13+。
默认构建同时包含 Apple Silicon 和 Intel；最低系统版本由 `MACOSX_DEPLOYMENT_TARGET`
统一控制，生成的 Info.plist 自动使用同一值。

在新系统预览旧版毛玻璃（仅 Debug 构建生效）：

```bash
WORDSNAP_TRADITIONAL_MATERIAL=1 WORDSNAP_AUTOSHOW=lookup \
  ~/Library/Developer/Xcode/WordSnap/DerivedData/Build/Products/Debug/WordSnap.app/Contents/MacOS/WordSnap
```

转为正式版前仍需在 macOS 13 真机或虚拟机验证启动、快捷键、查词、发音、保存/撤销、
设置与登录启动；新系统上的兼容分支测试不能代替旧系统实测。
Xcode 26 的 XCTest 运行库要求 macOS 14+，因此测试包以 14 为最低版本，App 仍以 13 为最低版本。

## 注意

- 当前源码需要 macOS 13 及以上；已发布的 v1.2.0 安装包仍需要 macOS 26 及以上
- 应用为常驻辅助进程（LSUIElement），不会出现在 Dock；快捷键无效时请检查系统设置中的应用权限

## 数据与网络

- 词表和词笔记写入你选择的本地目录；WordSnap 不提供账号或词库云同步。
  多设备同步由你自己的 Obsidian vault 同步方案负责。
- 呼出面板时会读取剪贴板，符合单个英文词格式时预填；不会清空剪贴板。
  预填后仍需触发查询。
- 查词、纠错候选和发音会请求有道服务；查词成功后会预取该词发音。
  查询词会发送给服务提供方，查词并非完全离线。
- 该项目与有道无隶属关系；第三方接口的可用性和返回内容可能变化。

## 参与与许可

欢迎通过 Issues 提交问题、使用反馈，或通过 Pull Request 贡献改进。
提交代码前请运行 `./scripts/test.sh`（需要 Xcode 26+、XcodeGen 和 Node.js 18+）。
报告问题时请附 macOS / App 版本和复现步骤，日志与截图请先去除私人笔记内容。

项目采用 [MIT License](LICENSE)。

# WordSnap

macOS 桌面应用：快捷键呼出 Liquid Glass 悬浮窗 → 查询单词 → 保存到 Obsidian。

纯 Swift 实现（SwiftUI + URLSession），无 Python、无外部依赖。

## 快捷键

- `⌘L`: 呼出/隐藏悬浮窗（菜单栏「设置…」可换键并支持录制）
- `Enter`: 在输入框时触发查询
- `⌘Enter`: 预览结果时保存到 Obsidian
- `Esc`: 隐藏窗口

## 使用流程

1. 按 `⌘L` 呼出悬浮窗——剪贴板里若正好是单词会自动预填，回车即查
2. 预览释义（单词 / 音标 / 🔊 发音 / 词性 / 中英释义 / 例句）
3. 按 `⌘Enter` 保存；横幅显示「第 N 个词 · 连续第 M 天」，4 秒内可撤销
4. 重复保存不会报错，而是显示「X月X日 存过，又遇到它了」（间隔重复信号）
5. 查不到的词给出「你是不是想找」候选胶囊，一键重查
6. Esc 隐藏窗口；保存后自动收起

## Obsidian 词汇库

- **表格（采集日志）**：默认 `~/Documents/Obsidian/English Vocabulary Learning.md`，
  每次保存追加一行
- **词笔记（词的家）**：保存在表格同目录 `Vocabulary/<word>.md`，含
  frontmatter（词/音标/词性/星级/状态）与文末 `word::释义` 单行卡，
  直接兼容 obsidian-spaced-repetition 插件在桌面/手机上背诵
- **菜单栏**：📖 今日一词（点击即查）、近 16 周热力图、设置…

### Obsidian 词库管理界面（自带插件）

仓库 `obsidian-plugin/` 目录是一个零依赖的 Obsidian 插件，装进 vault
（拷贝到 `.obsidian/plugins/wordsnap-vocab/` 并在社区插件里启用）后，
打开 Obsidian 即得词汇管理面板：

- **词库页**：搜索、状态筛选、卡片网格、🔊 发音、点词开笔记、
  点状态徽章轮换（新词→学习中→熟悉→已掌握）
- **复习页**：翻卡 + 四档评分，评分回写词笔记的 frontmatter `status`
- **统计页**：总词数 / 本月新增 / 已掌握 / 月度柱状 / 16 周热力图

启动 Obsidian 自动展示（可在设置里改表格与笔记路径）。

路径配置：菜单栏「设置…」图形化选择，或环境变量 `WORDSNAP_OBSIDIAN_PATH` /
`~/.wordsnap.json`。

表格列：`| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |`
文件不存在时自动创建（含表头），单词列带 Obsidian 双链。

## 技术栈

- Swift 5 + SwiftUI（macOS 26 Liquid Glass 质感）
- 有道词典 JSON API（`dict.youdao.com/jsonapi`，免费无需 Key）
- XcodeGen 构建工程
- 全局快捷键：Carbon `RegisterEventHotKey`（可配置、可持久化）

## 开发与构建

Xcode 工程不入库，由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `app/project.yml` 生成。

```bash
# 一键构建（需要 Xcode 26+ 和 xcodegen；首次克隆直接跑即可）
./scripts/setup.sh

# 运行应用
open build/DerivedData/Build/Products/Debug/WordSnap.app

# 单元测试（解析 / 分帧解码 / 表格写入 / 词笔记 / 统计等纯逻辑）
xcodebuild test -project app/WordSnap.xcodeproj -scheme WordSnap -destination 'platform=macOS'
```

改构建配置请编辑 `app/project.yml` 后在 `app/` 下执行 `xcodegen generate`，
不要手工编辑工程文件。架构细节见 `SPEC.md`。

## 注意

- 需要 macOS 26 及以上系统
- 应用为常驻辅助进程（LSUIElement），不会出现在 Dock；快捷键无效时请检查系统设置中的应用权限

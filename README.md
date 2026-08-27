# WordSnap

macOS 桌面应用：快捷键呼出 Liquid Glass 悬浮窗 → 查询单词 → 保存到 Obsidian 表格。

纯 Swift 实现（SwiftUI + URLSession），无 Python、无外部依赖。

## 快捷键

- `⌘L`: 呼出/隐藏悬浮窗口
- `Enter`: 在输入框时触发查询
- `⌘Enter`: 预览结果时保存到 Obsidian
- `Esc`: 隐藏窗口

## 使用流程

1. 按 `⌘L` 呼出悬浮窗口
2. 输入单词，回车查询
3. 预览释义（单词 / 音标 / 词性 / 释义 / 例句）
4. 按 `⌘Enter` 或点击「保存」写入 Obsidian 表格
5. 显示「已保存 ✓」后自动消失

## Obsidian 目标文件

默认：`~/Documents/Obsidian/English Vocabulary Learning.md`（可配置，见下）

自定义保存路径（优先级从高到低）：
1. 环境变量 `WORDSNAP_OBSIDIAN_PATH`
2. 配置文件 `~/.wordsnap.json`：`{ "obsidianPath": "~/你的路径/词汇表.md" }`
3. 上述默认路径

表格列：`| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |`
文件不存在时自动创建（含表头），单词列带 Obsidian 双链。

## 技术栈

- Swift 5 + SwiftUI（macOS 26 Liquid Glass 质感）
- 有道词典 JSON API（`dict.youdao.com/jsonapi`，免费无需 Key）
- XcodeGen 构建工程
- 全局快捷键：Carbon `RegisterEventHotKey`

## 开发与构建

Xcode 工程不入库，由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `app/project.yml` 生成。

```bash
# 一键构建（需要 Xcode 26+ 和 xcodegen；首次克隆直接跑即可）
./scripts/setup.sh

# 运行应用
open build/DerivedData/Build/Products/Debug/WordSnap.app

# 单元测试（解析 / 分帧解码 / 表格写入等纯逻辑）
xcodebuild test -project app/WordSnap.xcodeproj -scheme WordSnap -destination 'platform=macOS'
```

改构建配置请编辑 `app/project.yml` 后在 `app/` 下执行 `xcodegen generate`，
不要手工编辑工程文件。架构细节见 `SPEC.md`。

## 注意

- 需要 macOS 26 及以上系统
- 应用为常驻辅助进程（LSUIElement），不会出现在 Dock；快捷键无效时请检查系统设置中的应用权限

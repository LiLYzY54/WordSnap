# WordSnap 设计文档

## 概述

**项目名称**: WordSnap
**功能**: 快捷键呼出悬浮窗 → 输入单词 → 查询完整释义 → 预览确认 → 自动追加到 Obsidian 表格文件
**目标用户**: 在 Mac 上阅读英文内容时需要即时查词并保存到 Obsidian 的用户

## 技术栈

| 组件 | 技术选型 | 说明 |
|------|---------|------|
| 快捷键触发 + 悬浮窗 | Alfred Workflow | mac 原生方案，Hotkey + Custom Window |
| 查词逻辑 | Python 脚本 | 调用在线词典 API |
| 数据写入 | Python 文件操作 | append row 到 Markdown 表格 |
| 在线词典 | 有道词典 API / Free Dictionary API | 完整版（单词+音标+释义+例句+来源）|

## 工作流程

```
1. 用户按全局快捷键（如 ⌘⇧W）→ Alfred 触发悬浮窗口
2. 窗口显示输入框 → 用户输入单词 → 回车
3. Python 查询词典 API（完整版）
4. 悬浮窗展示查询结果（单词/音标/释义/例句/来源）供预览
5. 用户按"保存"或回车 → Python 追加一行到 Obsidian 文件
6. 窗口显示"已保存 ✓" → 2秒后自动消失
```

## 文件结构

```
WordSnap/
├── SPEC.md                          # 本文档
├── scripts/
│   └── lookup_word.py               # 查词脚本（API调用 + 文件写入）
├── alfred/
│   └── WordSnap.alfredworkflow       # Alfred Workflow 文件
└── README.md
```

## Obsidian 目标文件

**路径**: `~/Documents/Obsidian/English Vocabulary Learning.md`

**表格格式**:

```markdown
| 单词 | 音标 | 释义 | 例句 | 来源 | 查询时间 |
|------|------|------|------|------|----------|
| serendipity | /ˌser.ənˈdɪp.ə.ti/ | n. 意外发现美好事物的运气 | It was a happy serendipity that we met at the conference. | Cambridge | 2026-05-25 |
```

**自动追加逻辑**: 每次查询结果直接 append 一行，无需手动维护。如文件不存在则自动创建（含表头）。

## 查词 API

### 方案 A：有道词典 API（推荐）
- 免费，无需 API Key
- 接口: `https://dict.youdao.com/jsonapi?q={word}`
- 返回: 音标、释义、例句

### 方案 B：Free Dictionary API（备选）
- 完全免费开源
- 接口: `https://api.dictionaryapi.dev/api/v2/entries/en/{word}`
- 返回: 音标、释义、例句、来源

## 悬浮窗 UI（Alfred Custom Window）

```
┌─────────────────────────────────────┐
│  🔍 输入单词...                      │
│                                     │
│  ┌───────────────────────────────┐  │
│  │ serendipity                  │  │
│  │ /ˌser.ənˈdɪp.ə.ti/           │  │
│  │ n. 意外发现美好事物的运气      │  │
│  │                              │  │
│  │ 例句:                        │  │
│  │ "It was a happy serendipity  │  │
│  │  that we met..."              │  │
│  │                              │  │
│  │ 来源: Cambridge Dictionary    │  │
│  └───────────────────────────────┘  │
│                                     │
│        [保存]  (Enter)             │
└─────────────────────────────────────┘
```

## 错误处理

| 场景 | 处理方式 |
|------|---------|
| 单词未找到 | 悬浮窗显示"未找到该单词"，允许用户重试或手动输入释义 |
| 网络错误 | 显示"网络错误，请检查网络"，提供手动输入选项 |
| 文件写入失败 | 显示错误信息，提供重试按钮 |

## 待验证事项

- [ ] Alfred Hotkey 与其他全局快捷键是否冲突
- [ ] 有道 API 是否稳定可用（国内网络）
- [ ] Obsidian 文件路径是否正确

## 实现顺序

1. 先写 `lookup_word.py` 脚本，命令行测试查词 + 写入
2. 导出为 Alfred Workflow + 配置 Hotkey
3. 调试验证完整流程

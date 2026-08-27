# WordSnap 设计文档（现行实现）

> 本文档描述 ox alpha 重构后的纯 Swift 架构。最初的 Alfred Workflow + Python
> 脚本方案已被整体替换，历史设计见 git 历史。

## 概述

**功能**: 全局快捷键呼出 Liquid Glass 悬浮窗 → 输入单词 → 在线查词预览 → 确认后追加到 Obsidian 词汇表。
**目标用户**: 在 Mac 上阅读英文内容时需要即时查词并归档到 Obsidian 的用户。

## 技术栈与关键决策

| 组件 | 选型 | 决策原因 |
|------|------|---------|
| 应用壳 | Swift + AppKit，`LSUIElement` 常驻 | 无外部依赖、无 Python 进程开销 |
| 悬浮窗 | `NSPanel` + `NSGlassEffectView`（macOS 26 Liquid Glass） | 单块玻璃胶囊 ↔ 结果面板液态变形 |
| 查词 API | 有道词典 `dict.youdao.com/jsonapi` | 免费、无 Key、含柯林斯/例句 |
| 直连层 | `NWConnection` 手写 HTTP/1.1 + actor 隔离 | 绕开 TUN 代理 fake-IP DNS，连接复用近零延迟 |
| 快捷键 | Carbon `RegisterEventHotKey` (⌘L) | 系统级全局热键 |
| 持久化 | 直接读写 Obsidian Markdown 表格 | Obsidian 原生渲染，双链自动建词条笔记 |
| 构建 | XcodeGen（`project.yml` 为唯一事实来源） | 工程文件不入库，克隆即可生成 |

## 模块结构

```
app/Sources/
├── main.swift               # NSApplication 启动（accessory 常驻）
├── AppDelegate.swift        # 装配：热键注册 / 登录项 CLI 参数 / 直连预热 / WORDSNAP_AUTOSHOW 调试口
├── HotkeyManager.swift      # Carbon 全局热键封装
├── StatusBarController.swift# 菜单栏图标：呼出面板 / 登录时启动 / 退出
├── FloatingWindow.swift     # NSPanel + 玻璃容器；胶囊↔面板共弹簧形变；订阅隐藏通知
├── SearchView.swift         # SwiftUI 界面 + SearchModel 状态机（idle/loading/loaded/failed/saved）
└── WordService.swift        # 核心域逻辑：
    ├── lookup()             #   直连快路径 → notFound 直接上抛；仅异常才降级系统代理慢路径
    ├── YoudaoDirectClient   #   actor：IP 学习池(每日 getaddrinfo 刷新) + TLS SNI 固定 +
    │                        #   keep-alive 复用；HTTP 解析支持 Content-Length/chunked/
    │                        #   connection:close 三种分帧与非 2xx 拒绝
    ├── parse()              #   柯林斯优先（英文释义/中文释义拆分）→ ec → simple.custom 兜底
    └── save()               #   读-改-写原子落表：建表头 / 大小写不敏感去重 / 管道符转义
```

## 查词管线

```
⌘L 呼出 → 输入回车
  → YoudaoDirectClient.lookup(word)     # 命中记忆 IP 的活 TLS 连接（~百ms 内）
      ✗ 连接失败 → 逐 IP 重试（学习过的优先）
  → parse(data)
      ✓ 得到 WordEntry（word/音标/词性/中文释义/英文释义/例句/来源/日期）
      ✗ 释义为空 → notFound 直接显示「未找到该单词」（不走代理重试）
      ✗ JSON 异常 → proxyFetch 兜底再试一次
  → ⌘Enter 保存 → append 表格行（重复词提示已在表）→ 1.4s 后自动收起
Esc / 隐藏通知 → orderOut
```

## 数据格式

词汇表 7 列固定，向旧文件兼容读取（`[[word|别名]]` 旧写法可被去重识别）：

```markdown
| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
|------|------|------|------|------|------|------|
| [[serendipity]] | /ˌser.ənˈdɪp.ə.ti/ | n. | 意外发现的乐趣 | It was pure serendipity… | Youdao | 2026-08-27 |
```

目标路径解析优先级：环境变量 `WORDSNAP_OBSIDIAN_PATH` > `~/.wordsnap.json` 的
`obsidianPath` > 默认 `~/Documents/Obsidian/English Vocabulary Learning.md`。

## 错误处理

| 场景 | 行为 |
|------|------|
| 词不存在 | 「未找到该单词」，可直接改词重查（不触发网络降级） |
| 网络/代理不可达 | 直连超时 → IP 列表重试 → 系统代理 URLSession（1.5s 上限）→ 「网络连接失败」 |
| 接口响应异常（非 2xx / 非 JSON / 分帧损坏） | badResponse，直连失败自动走代理兜底 |
| 保存失败（路径不可写等） | 显示具体错误；文件不存在时自动创建含表头 |

## 测试

纯逻辑全部可单测（`app/Tests/WordSnapTests/`，19 例）：chunked 分帧解码、
状态行解析、有道 JSON 解析三路兜底、中英拆分、表格行转义/去重。

```bash
xcodebuild test -project app/WordSnap.xcodeproj -scheme WordSnap -destination 'platform=macOS'
```

## 已知取舍

- 种子 IP 写死作为 DNS 刷新前的兜底；首次使用且解析失败时会退化到代理路径。
- 无分帧头且 keep-alive 的非标准响应按「已到达字节即正文」处理（best effort，
  与真实服务端行为无关，仅为防御性宽容）。

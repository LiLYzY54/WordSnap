# WordSnap · Obsidian 词汇库设计

## 总体结构

```
English Vocabulary Learning.md   ← 主表：流水账（WordSnap 直接写入）
└── Vocab/<word>.md              ← 词条笔记：每个词一篇（Templater 生成）
```

主表满足「表格形式快速存入」；词条笔记承载深度信息，用 `[[双链]]` 与主表互连，天然进入图谱/反链/ Dataview 生态。

## 主表 Schema（WordSnap 写入格式）

```markdown
| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
|------|------|------|------|------|------|------|
| [[ephemeral|ephemeral]] | /ɪˈfemərəl/ | 形容词 | 短暂的; 瞬间的 | He talked about ... | Youdao | 2026-08-23 |
```

规则：
- **单词列 = Obsidian 双链**：点击跳转词条笔记（不存在则自动创建入口）
- **去重**：同词只存一条，重复保存提示「已在词汇表」
- **日期列**：复习/时间线锚点
- 文件不存在时自动创建含表头；追加写入原子操作，不留空行

## 词条笔记模板（Templater）

文件：`Templates/word-note.md`

```markdown
---
word: {{word}}
phonetic: "{{phonetic}}"
pos: "{{pos}}"
meaning: "{{meaning}}"
source: "{{source}}"
added: "{{date}}"
status: 新学
tags: [vocab, english]
---

# {{word}}

> {{phonetic}} · {{pos}}

**释义**：{{meaning}}

**例句**：
> {{example}}

## 词根词缀

## 联想与场景

## 复习记录
- [ ] 2026-XX-XX 复习
```

## 主表增强区块（可粘贴到笔记底部）

### 统计（Dataview）

```dataview
TABLE length(rows) AS 数量
WHERE file.name = "English Vocabulary Learning"
FLATTEN file.lists AS l
```

### 按日期倒序（Dataview）

```dataview
TABLE WITHOUT ID
  link AS 单词,
  phonetic AS 音标,
  pos AS 词性,
  meaning AS 释义,
  date AS 添加日期
FROM "Vocab"
SORT date DESC
```

### 按词性分组

```dataview
TABLE rows.file.link AS 单词
FROM "Vocab"
GROUP BY pos
```

## 推荐插件组合

| 插件 | 用途 |
|------|------|
| Dataview | 主表底部自动统计/排序/分组 |
| Templater | 一键从模板建词条笔记（⌘N） |
| Spaced Repetition | 用 `status` 字段做间隔复习 |
| Obsidian Dictionary | 内置查词补充 |
| Tag Wrangler | 管理 `#vocab` 标签 |
| Excalidraw | 词根词缀思维导图 |
| Calendar / Day Planner | 按日期列做复习时间线 |

## 迁移与备份

- 旧格式（6/7 列混用、含 HTML 标签、重复行）→ 新格式：`swift scripts/migrate_vocab.swift <file>`
- 迁移自动备份为 `<file>.bak`
- 自定义目标路径：环境变量 `WORDSNAP_OBSIDIAN_PATH`

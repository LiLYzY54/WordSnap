# WordSnap 纸质词卡 × 简洁工作区

视觉参考：[Minimal](https://github.com/kepano/obsidian-minimal) 的留白与卡片布局；学习流程参考 [LearnKit](https://github.com/ctrlaltwill/LearnKit) 与 [Spaced Repetition](https://github.com/st3v3nmw/obsidian-spaced-repetition)。本项目独立实现样式，没有复制这些项目的代码，也没有安装这些插件。

- `词语书房.md`：词库入口，使用时替换 URI 的 vault 名及笔记路径。
- `单词笔记.md`：Templater 模板，插入到以单词命名的新笔记中。先填写释义，再使用回忆卡。
- 仪表盘从配置的 Markdown 表格读取单词，从对应 Vocabulary 笔记读取状态。手动笔记需同时登记词表。
- 四档评分表示掌握程度，没有 FSRS/SM-2 到期调度；不要将「待复习」数量解释为算法计算的今日到期数。
- CSS 仅作用于 WordSnap 面板和 `wordsnap-note` class，不替换全库主题。

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wordsnap-migration-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "$SCRIPT_DIR/migrate_vocab.swift" -o "$TEST_DIR/migrate"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
    if "$TEST_DIR/migrate" "$1" > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"; then
        fail "expected migration to reject $1"
    fi
}

cat > "$TEST_DIR/legacy.md" <<'MD'
# Vocabulary

| 单词 | 音标 | 词性 | 释义 | 英文原意 | 例句 | 备注 |
|---|---|---|---|---|---|---|
| [[word|alias]] | /w/ | n. | <b>词</b>\|字 | definition | Say a\|b. | book |
| WORD | ignored | ignored | ignored | ignored | ignored | ignored |
| [[other\|别名]] | /o/ | adj. | 其他 | other meaning | Another word. | paper |

Keep this paragraph.
MD
cp "$TEST_DIR/legacy.md" "$TEST_DIR/original.md"
cat > "$TEST_DIR/expected.md" <<'MD'
# Vocabulary

| 单词 | 音标 | 词性 | 释义 | 例句 | 来源 | 日期 |
|------|------|------|------|------|------|------|
| word | /w/ | n. | 词\|字 | Say a\|b. | book |  |
| other | /o/ | adj. | 其他 | Another word. | paper |  |

Keep this paragraph.
MD

# Dry runs decode aliases and escaped cells, without touching the source.
"$TEST_DIR/migrate" "$TEST_DIR/legacy.md" --dry-run > "$TEST_DIR/preview"
cmp "$TEST_DIR/legacy.md" "$TEST_DIR/original.md"
test ! -e "$TEST_DIR/legacy.md.bak"
tail -n +2 "$TEST_DIR/preview" > "$TEST_DIR/preview-content"
# print() adds one newline to a source which already ends with a newline.
printf '\n' >> "$TEST_DIR/expected.md"
cmp "$TEST_DIR/preview-content" "$TEST_DIR/expected.md"
sed '$d' "$TEST_DIR/expected.md" > "$TEST_DIR/expected-file.md"

# Successful migration preserves outside prose and an exact original backup.
"$TEST_DIR/migrate" "$TEST_DIR/legacy.md" > /dev/null
cmp "$TEST_DIR/legacy.md" "$TEST_DIR/expected-file.md"
cmp "$TEST_DIR/legacy.md.bak" "$TEST_DIR/original.md"

# Running on the new schema is a no-op, even when the first backup exists.
"$TEST_DIR/migrate" "$TEST_DIR/legacy.md" > /dev/null
cmp "$TEST_DIR/legacy.md" "$TEST_DIR/expected-file.md"
cmp "$TEST_DIR/legacy.md.bak" "$TEST_DIR/original.md"

# Reject unrecognized headers and malformed column counts before any write.
sed 's/英文原意/未知列/' "$TEST_DIR/original.md" > "$TEST_DIR/unknown.md"
cp "$TEST_DIR/unknown.md" "$TEST_DIR/unknown-before.md"
expect_failure "$TEST_DIR/unknown.md"
cmp "$TEST_DIR/unknown.md" "$TEST_DIR/unknown-before.md"
test ! -e "$TEST_DIR/unknown.md.bak"
sed 's/ | book |/ |/' "$TEST_DIR/original.md" > "$TEST_DIR/malformed.md"
cp "$TEST_DIR/malformed.md" "$TEST_DIR/malformed-before.md"
expect_failure "$TEST_DIR/malformed.md"
cmp "$TEST_DIR/malformed.md" "$TEST_DIR/malformed-before.md"
test ! -e "$TEST_DIR/malformed.md.bak"

# Never replace a previous backup.
cp "$TEST_DIR/original.md" "$TEST_DIR/protected.md"
printf 'previous backup\n' > "$TEST_DIR/protected.md.bak"
cp "$TEST_DIR/protected.md.bak" "$TEST_DIR/backup-before"
expect_failure "$TEST_DIR/protected.md"
cmp "$TEST_DIR/protected.md" "$TEST_DIR/original.md"
cmp "$TEST_DIR/protected.md.bak" "$TEST_DIR/backup-before"

# A dangling backup symlink passes fileExists, but copyItem must fail safely.
cp "$TEST_DIR/original.md" "$TEST_DIR/copy-failure.md"
ln -s "$TEST_DIR/missing-target" "$TEST_DIR/copy-failure.md.bak"
expect_failure "$TEST_DIR/copy-failure.md"
cmp "$TEST_DIR/copy-failure.md" "$TEST_DIR/original.md"
test -L "$TEST_DIR/copy-failure.md.bak"
test ! -e "$TEST_DIR/missing-target"

# The explicitly supported old eight-column schema preserves its date.
cat > "$TEST_DIR/dated.md" <<'MD'
| 单词 | 音标 | 词性 | 释义 | 英文原意 | 例句 | 备注 | 日期 |
|---|---|---|---|---|---|---|---|
| [[dated|alias]] | /d/ | adj. | 过时的 | old | An old word. | book | 2026-08-27 |
MD
"$TEST_DIR/migrate" "$TEST_DIR/dated.md" > /dev/null
grep -Fq '| dated | /d/ | adj. | 过时的 | An old word. | book | 2026-08-27 |' "$TEST_DIR/dated.md"

echo "Migration regressions passed (8 scenarios)."

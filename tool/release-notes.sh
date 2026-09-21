#!/usr/bin/env bash
# 生成滚动 Release 的标准化更新日志。
# 用法: tool/release-notes.sh [上次构建的 commit] [本次构建的 commit]
#   - 上次 commit 省略时（首次发布）只展示最近 20 条提交。
#   - 输出到 stdout；workflow 里重定向到 release_notes.md 供 --notes-file 使用。
# 分组规则：conventional commit 前缀（feat/fix/perf/refactor/docs/ci/…），
# 固定小节顺序、固定标题，条目附短 SHA 与仓库链接。
# 纯 bash 3.2 兼容实现（无关联数组），macOS 与 Linux 通用。
set -euo pipefail
cd "$(dirname "$0")/.."

PREV="${1:-}"
CUR="$(git rev-parse "${2:-HEAD}")"
REPO_URL="$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"

if [ -n "$PREV" ]; then
  PREV="$(git rev-parse "$PREV")"
  RANGE="$PREV..$CUR"
else
  RANGE="-20"
fi

KNOWN="feat fix perf refactor ci docs build test style chore"
# bash 3.2 的 =~ 对带括号的字面正则会报语法错，正则必须经变量传入。
RE_SCOPE='^[a-z]+\(([^)]*)\)[!:][[:space:]]*(.+)$'
RE_PLAIN='^[a-z]+[!:][[:space:]]*(.+)$'

# 输出某类型的条目（sha\tdesc\tscope 行）；type=other 收纳全部未识别前缀。
entries_for() {
  want="$1"
  while IFS=$'\t' read -r sha subject; do
    [ -z "$sha" ] && continue
    type="other"
    for t in $KNOWN; do
      if [ "${subject#"$t("}" != "$subject" ] || [ "${subject#"$t:"}" != "$subject" ] || [ "${subject#"$t!"}" != "$subject" ]; then
        type="$t"
        break
      fi
    done
    [ "$type" != "$want" ] && continue
    scope=""
    desc="$subject"
    if [[ "$subject" =~ $RE_SCOPE ]]; then
      scope="${BASH_REMATCH[1]}"
      desc="${BASH_REMATCH[2]}"
    elif [[ "$subject" =~ $RE_PLAIN ]]; then
      desc="${BASH_REMATCH[1]}"
    fi
    printf '%s\t%s\t%s\n' "$sha" "$desc" "$scope"
  done < <(git log --no-merges --format="%h%x09%s" $RANGE)
}

# 分节标题与类型对（other 额外并入 build/test/style/chore）。
print_section() {
  title="$1"; shift
  got=0
  body=""
  for type in "$@"; do
    body="$body$(entries_for "$type")"
  done
  [ -z "$body" ] && return 0
  echo "### $title"
  echo
  # $() 会剥掉尾部换行：末行无换行时 read 直接 EOF 返回、循环体不执行，会吞掉最后一条。
  printf '%s\n' "$body" | while IFS=$'\t' read -r sha desc scope; do
    [ -z "$sha" ] && continue
    link="[$sha](https://github.com/${REPO_URL}/commit/${sha})"
    if [ -n "$scope" ]; then
      echo "- **${scope}**：${desc}（${link}）"
    else
      echo "- ${desc}（${link}）"
    fi
  done
  echo
}

echo "# BiliHaromny 自动构建"
echo
if [ -n "$PREV" ]; then
  count=$(git rev-list --count "$RANGE")
  echo "**更新范围**：\`${PREV:0:7}\` → \`${CUR:0:7}\`，共 $count 个提交"
else
  echo "**更新范围**：首次发布，最近 20 条提交"
fi
echo

print_section "✨ 新功能" feat
print_section "🐛 问题修复" fix
print_section "⚡ 性能" perf
print_section "♻️ 重构" refactor
print_section "🛠️ 构建与 CI" ci
print_section "📝 文档" docs
print_section "🧹 其他" build test style chore other

echo "---"
echo
echo "## 构建信息"
echo
echo "- 构建提交：\`$CUR\`"
echo "- 质量：全量回归测试（7 个测试文件）通过后才会产出本包"
echo "- 产物：\`entry-default-unsigned.hap\`（**未签名**，安装前需自行签名）与 \`hap.sha256\` 校验和"
if [ -n "$PREV" ]; then
  echo "- [完整提交对比](https://github.com/$REPO_URL/compare/$PREV...$CUR)"
fi

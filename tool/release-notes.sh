#!/usr/bin/env bash
# 生成不可变版本 Release 的标准化更新日志。
# 用法: tool/release-notes.sh [上次已发布的编号 tag] [本次 commit] [versionName]
#   - 上次 tag 省略时（首次发布）只展示当前 commit 前最近 20 条提交。
#   - 输出到 stdout；workflow 里重定向到 release_notes.md 供 --notes-file 使用。
# 分组规则：conventional commit 前缀（feat/fix/perf/refactor/docs/ci/…），
# 固定小节顺序、固定标题，条目附短 SHA 与仓库链接。
# 纯 bash 3.2 兼容实现（无关联数组），macOS 与 Linux 通用。
set -euo pipefail
cd "$(dirname "$0")/.."

PREV="${1:-}"
CUR="$(git rev-parse --verify "${2:-HEAD}^{commit}")"
VERSION="${3:-$(node -p 'JSON.parse(require("node:fs").readFileSync("AppScope/app.json5", "utf8")).app.versionName')}"
RE_VERSION='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if ! [[ "$VERSION" =~ $RE_VERSION ]]; then
  echo 'versionName must be a stable X.Y.Z version' >&2
  exit 1
fi
REPO_URL="${GITHUB_REPOSITORY:-$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')}"

if [ -n "$PREV" ]; then
  PREV_TAG="$PREV"
  PREV="$(git rev-parse --verify "$PREV^{commit}")"
  git merge-base --is-ancestor "$PREV" "$CUR"
  RANGE="$PREV..$CUR"
else
  RANGE="$CUR"
fi

KNOWN="feat fix perf refactor ci docs build test style chore"
# bash 3.2 的 =~ 对带括号的字面正则会报语法错，正则必须经变量传入。
RE_SCOPE='^[a-z]+\(([^)]*)\)!?:[[:space:]]*(.+)$'
RE_PLAIN='^[a-z]+!?:[[:space:]]*(.+)$'

commit_log() {
  if [ -n "$PREV" ]; then
    git log --no-merges --format='%h%x09%s' "$RANGE"
  else
    git log -20 --no-merges --format='%h%x09%s' "$CUR"
  fi
}

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
  done < <(commit_log)
}

# 分节标题与类型对（other 额外并入 build/test/style/chore）。
print_section() {
  title="$1"; shift
  body=""
  for type in "$@"; do
    entries="$(entries_for "$type")"
    if [ -n "$entries" ]; then
      # 保留不同类型之间的换行，不能用多个 $(...) 直接连接最后一行。
      body="$body$entries"$'\n'
    fi
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

echo "# BiliHarmony v$VERSION"
echo
if [ -n "$PREV" ]; then
  count=$(git rev-list --count "$RANGE")
  echo "**更新范围**：\`$PREV_TAG\` → \`v$VERSION\`，共 $count 个提交"
else
  echo "**更新范围**：首次发布，最近 20 条提交"
fi
echo

# 每个版本的人工更新记录随源码保留；只引用本版，不能把未来版本混入。
if [ -f CHANGELOG.md ]; then
  version_section="$(awk -v version="$VERSION" '
    /^##[[:space:]]/ {
      if (selected) exit
      heading = $2
      sub(/^\[/, "", heading)
      sub(/^v/, "", heading)
      sub(/\]$/, "", heading)
      selected = (heading == version)
      next
    }
    selected { print }
  ' CHANGELOG.md)"
  if [ -n "$version_section" ]; then
    echo '## 本版本更新'
    echo
    printf '%s\n\n' "$version_section"
  fi
  echo "[查看本次提交的完整更新日志](https://github.com/$REPO_URL/blob/$CUR/CHANGELOG.md)"
  echo
fi

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
echo "- 版本：\`v$VERSION\`（标签、更新日志与安装包按版本保留）"
echo "- 质量：全部服务与播放器内核回归测试、未签名 HAP 打包检查通过"
echo "- 产物：\`biliharmony-v$VERSION-unsigned.hap\`（**未签名**，安装前需自行签名）与 \`hap.sha256\` 校验和"
if [ -n "$PREV" ]; then
  echo "- [完整提交对比](https://github.com/$REPO_URL/compare/$PREV_TAG...v$VERSION)"
fi

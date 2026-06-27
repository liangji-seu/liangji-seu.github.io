#!/usr/bin/env bash

# Hexo 博客辅助脚本：兼容 macOS / Linux / Git Bash
# 用法：./blog.sh push [提交信息]

# 不使用 set -e，避免 grep 无匹配、git commit 无改动等正常情况直接中断。
set -u

# 进入脚本所在目录，避免从其他目录执行时找不到 source/_posts 或 python 脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# 颜色定义：仅在终端里启用颜色，避免日志/CI 输出乱码
if [ -t 1 ]; then
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  NC="\033[0m"
else
  GREEN=""
  RED=""
  YELLOW=""
  NC=""
fi

info() { printf "%b\n" "${GREEN}>>> $*${NC}"; }
warn() { printf "%b\n" "${YELLOW}>>> $*${NC}"; }
err()  { printf "%b\n" "${RED}>>> $*${NC}"; }

# 自动选择 Python：macOS 通常只有 python3，没有 python
find_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "python3"
  elif command -v python >/dev/null 2>&1; then
    printf '%s\n' "python"
  else
    return 1
  fi
}

# 自动选择 Hexo：优先用全局 hexo；没有则尝试项目本地 npx hexo
run_hexo() {
  if command -v hexo >/dev/null 2>&1; then
    hexo "$@"
  elif command -v npx >/dev/null 2>&1; then
    npx hexo "$@"
  else
    err "未找到 hexo 或 npx。请先安装 Node.js 依赖，例如：npm install"
    return 127
  fi
}

run_python_script() {
  script_name="$1"
  shift || true

  if [ ! -f "$script_name" ]; then
    err "找不到脚本：$script_name"
    return 1
  fi

  PYTHON_CMD="$(find_python)" || {
    err "未找到 Python。macOS 建议安装 python3，例如：brew install python"
    return 127
  }

  "$PYTHON_CMD" "$script_name" "$@"
}

# 图片语法检查函数
check_images() {
  POSTS_DIR="source/_posts"

  warn "正在检索图片引用规范..."

  if [ ! -d "$POSTS_DIR" ]; then
    warn "未找到 $POSTS_DIR，跳过图片引用检查。"
    return 0
  fi

  # 检查典型非标准语法：
  # 1. WikiLink 图片格式：![[xxx]]
  # 2. 畸形混合格式：![[xxx]](yyy)
  # macOS 的 BSD grep 支持 -rE；用 if grep 避免无匹配时误判为错误。
  if grep -rE -m 1 '(!\[\[.*\]\]|!\[\[.*\]\]\(.*\))' "$POSTS_DIR" >/dev/null 2>&1; then
    warn "检测到非标准图片引用，启动自动修复程序..."

    if run_python_script "fix_hexo_images.py"; then
      info "修复完成。"
    else
      err "修复脚本执行出错，请检查！"
      return 1
    fi
  else
    info "图片引用检查通过，无需修复。"
  fi
}

# Git 提交并推送。兼容“没有文件改动”的情况。
git_push_source() {
  commit_msg="$1"

  info "正在提交源码..."
  git add . || return 1

  if git diff --cached --quiet; then
    warn "没有检测到需要提交的源码改动，跳过 commit。"
  else
    git commit -m "$commit_msg" || return 1
  fi

  info "正在推送到 origin/source..."
  git push origin source
}

show_help() {
  printf "%b\n" "${GREEN}=== 常用命令 ===${NC}"
  echo "./blog.sh img [path]  - 处理单个文件图片"
  echo "./blog.sh test        - 本地预览"
  echo "./blog.sh push [msg]  - 检查并提交源码"
  echo "./blog.sh deploy      - 检查并部署上线"
  echo "./blog.sh pull        - 拉取 source 分支"
  echo "./blog.sh new [title] - 新建文章"
}

case "${1:-help}" in
  pull)
    git pull origin source
    ;;

  push)
    check_images || exit 1
    commit_msg="${2:-更新博客}"
    git_push_source "$commit_msg" || exit 1
    ;;

  new)
    if [ -z "${2:-}" ]; then
      err "标题不能为空"
      exit 1
    fi
    title="${2%.md}"
    run_hexo new "$title"
    ;;

  img)
    if [ -z "${2:-}" ]; then
      err "用法: ./blog.sh img source/_posts/xxx.md"
      exit 1
    fi
    info "正在处理：$2"
    if run_python_script "hexo_img_refactor.py" "$2"; then
      info "处理完成！"
    else
      err "处理失败。"
      exit 1
    fi
    ;;

  test)
    run_hexo clean && run_hexo g && run_hexo s
    ;;

  deploy)
    check_images || exit 1
    info "正在生成并部署..."
    run_hexo clean && run_hexo g && run_hexo d
    ;;

  help|-h|--help|*)
    show_help
    ;;
esac

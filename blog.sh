#!/bin/bash

# 博客管理脚本：支持 first-pull/pull/push/test/deploy/new/img/help 命令
# 使用方法：
# ./blog.sh first-pull    # 首次克隆后：切换source分支+安装依赖（仅需执行1次）
# ./blog.sh pull          # 同步远程 source 分支的最新源文件
# ./blog.sh push [备注]   # 提交本地变更到 source 分支（备注可选，默认"更新博客"）
# ./blog.sh new "标题"    # 新建Hexo文章（自动生成.md文件）
# ./blog.sh img "路径"    # 自动化处理图片：重命名、移动到images并修正MD引用
# ./blog.sh test          # 本地预览：清理缓存→编译→启动本地服务器
# ./blog.sh deploy        # 编译并部署到 main 分支（GitHub Pages）
# ./blog.sh help          # 查看帮助

# 定义颜色输出
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m" 

# 检查命令是否存在
check_command() {
  if ! command -v $1 &> /dev/null; then
    echo -e "${RED}错误：未找到命令 $1，请先安装相关环境！${NC}"
    exit 1
  fi
}

check_command git
check_command node
check_command npm
check_command hexo

case "$1" in
  first-pull)
    echo -e "${GREEN}=== 开始执行首次配置 ===${NC}"
    if git show-ref --verify --quiet refs/heads/source; then
      echo -e "${YELLOW}提示：本地已存在 source 分支${NC}"
      git checkout source
    else
      git checkout -b source remotes/origin/source
      echo -e "${GREEN}✅ 成功创建并切换到 source 分支${NC}"
    fi
    echo -e "${GREEN}=== 开始安装Hexo依赖... ===${NC}"
    npm install
    ;;

  pull)
    echo -e "${GREEN}=== 开始同步远程 source 分支 ===${NC}"
    git pull origin source
    ;;

  push)
    commit_msg=${2:-"更新博客"}
    echo -e "${GREEN}=== 开始提交变更（备注：$commit_msg）===${NC}"
    git add .
    git commit -m "$commit_msg"
    git push origin source
    ;;

  new)
    if [ -z "$2" ]; then
      echo -e "${RED}错误：请输入文章标题！${NC}"
      exit 1
    fi
    article_title=${2%.md}
    echo -e "${GREEN}=== 开始新建文章：$article_title ===${NC}"
    hexo new "$article_title"
    ;;

  # 新增：图片自动化处理
  img)
    if [ -z "$2" ]; then
      echo -e "${RED}错误：请指定要处理的 Markdown 文件路径！${NC}"
      echo -e "${YELLOW}示例：./blog.sh img source/_posts/xxx.md${NC}"
      exit 1
    fi
    # 自动识别 python 或 python3
    PYTHON_CMD=$(command -v python3 || command -v python)
    SCRIPT_PATH="./hexo_img_refactor.py"
    
    if [ ! -f "$SCRIPT_PATH" ]; then
      echo -e "${RED}错误：未在根目录找到 hexo_img_refactor.py 脚本！${NC}"
      exit 1
    fi
    echo -e "${GREEN}=== 开始处理图片：$2 ===${NC}"
    $PYTHON_CMD "$SCRIPT_PATH" "$2"
    ;;

  test)
    echo -e "${GREEN}=== 开始本地预览 ===${NC}"
    hexo clean && hexo g && hexo s
    ;;

  deploy)
    echo -e "${GREEN}=== 开始部署到 GitHub Pages ===${NC}"
    hexo clean && hexo g && hexo d
    ;;

  help|*)
    echo -e "${GREEN}=== 博客管理脚本使用说明 ===${NC}"
    echo "1. 首次配置：  ./blog.sh first-pull"
    echo "2. 同步远程：  ./blog.sh pull"
    echo "3. 提交变更：  ./blog.sh push [备注]"
    echo "4. 新建文章：  ./blog.sh new '文章标题'"
    echo "5. 处理图片：  ./blog.sh img 'source/_posts/文件名.md'"
    echo "6. 本地预览：  ./blog.sh test"
    echo "7. 编译部署：  ./blog.sh deploy"
    echo "8. 查看帮助：  ./blog.sh help"
    ;;
esac

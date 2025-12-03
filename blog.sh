#!/bin/bash

# 博客管理脚本：支持 pull/push/deploy/first-pull/test/help 命令
# 使用方法：
# ./blog.sh first-pull    # 首次克隆后：切换source分支+安装依赖（仅需执行1次）
# ./blog.sh pull          # 同步远程 source 分支的最新源文件
# ./blog.sh push [备注]   # 提交本地变更到 source 分支（备注可选，默认"更新博客"）
# ./blog.sh test          # 本地预览：清理缓存→编译→启动本地服务器（localhost:4000）
# ./blog.sh deploy        # 编译并部署到 main 分支（GitHub Pages）
# ./blog.sh help          # 查看帮助

# 定义颜色输出（增强可读性）
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"  # 恢复默认颜色

# 检查命令是否存在（避免环境缺失报错）
check_command() {
  if ! command -v $1 &> /dev/null; then
    echo -e "${RED}错误：未找到命令 $1，请先安装相关环境！${NC}"
    exit 1
  fi
}

# 检查必要命令（Git/Node.js/Hexo）
check_command git
check_command node
check_command npm

# 处理参数
case "$1" in
  # 首次拉取：切换source分支+安装依赖（适合新设备克隆后首次使用）
  first-pull)
    echo -e "${GREEN}=== 开始执行首次配置：切换source分支 + 安装Hexo依赖 ===" ${NC}
    
    # 检查本地是否已存在source分支
    if git show-ref --verify --quiet refs/heads/source; then
      echo -e "${YELLOW}提示：本地已存在 source 分支，跳过分支创建步骤${NC}"
      git checkout source  # 直接切换到已有分支
    else
      # 从远程origin/source创建并切换本地source分支
      git checkout -b source remotes/origin/source
      if [ $? -ne 0 ]; then
        echo -e "${RED}错误：创建/切换 source 分支失败！请检查远程是否存在 source 分支${NC}"
        exit 1
      fi
      echo -e "${GREEN}✅ 成功创建并切换到 source 分支${NC}"
    fi
    
    # 安装Hexo依赖（读取package.json）
    echo -e "${GREEN}=== 开始安装Hexo依赖...（耐心等待）===" ${NC}
    npm install
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✅ 依赖安装成功！首次配置完成～${NC}"
      echo -e "${YELLOW}下一步：可执行 ./blog.sh new 标题 或直接编辑 source/_posts 文件夹写文章${NC}"
    else
      echo -e "${RED}错误：依赖安装失败，请检查网络或package.json文件${NC}"
    fi
    ;;

  # 同步远程source分支
  pull)
    echo -e "${GREEN}=== 开始同步远程 source 分支 ===" ${NC}
    git pull origin source
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✅ 同步成功！${NC}"
    else
      echo -e "${RED}错误：同步失败，请检查网络或分支状态！${NC}"
    fi
    ;;

  # 提交本地变更到source分支
  push)
    # 处理可选的提交备注（默认"更新博客"）
    commit_msg=${2:-"更新博客"}
    echo -e "${GREEN}=== 开始提交变更到 source 分支（备注：$commit_msg）===" ${NC}
    
    git add .
    git commit -m "$commit_msg"
    git push origin source

    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✅ 提交推送成功！${NC}"
    else
      echo -e "${RED}错误：提交或推送失败，请检查命令输出！${NC}"
    fi
    ;;

  # 本地预览：清理缓存→编译→启动本地服务器
  test)
    echo -e "${GREEN}=== 开始本地预览：清理缓存 → 编译静态文件 → 启动服务器 ===" ${NC}
    echo -e "${YELLOW}提示：预览地址为 http://localhost:4000，按 Ctrl+C 停止服务器${NC}"
    hexo clean && hexo g && hexo s

    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✅ 本地预览服务已停止${NC}"
    else
      echo -e "${RED}错误：本地预览失败，请检查Hexo配置或文章语法！${NC}"
    fi
    ;;

  # 编译并部署到main分支（GitHub Pages）
  deploy)
    echo -e "${GREEN}=== 开始部署：清理缓存 → 编译 → 推送至 main 分支 ===" ${NC}
    hexo clean && hexo g && hexo d

    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✅ 部署成功！请等待 5-10 分钟后访问博客确认～${NC}"
    else
      echo -e "${RED}错误：部署失败，请检查Hexo配置或依赖！${NC}"
    fi
    ;;

  # 帮助信息
  help)
    echo -e "${GREEN}=== 博客管理脚本使用说明 ===" ${NC}
    echo "1. 首次配置（新设备克隆后）：./blog.sh first-pull"
    echo "   → 自动切换source分支 + 安装Hexo依赖（仅需执行1次）"
    echo "2. 同步远程源文件：./blog.sh pull"
    echo "3. 提交本地变更：./blog.sh push [可选备注]"
    echo "   示例：./blog.sh push '新增文章：Hexo 脚本使用指南'"
    echo "4. 本地预览博客：./blog.sh test"
    echo "   → 启动本地服务器：http://localhost:4000（按Ctrl+C停止）"
    echo "5. 编译部署到GitHub Pages：./blog.sh deploy"
    echo "6. 查看帮助：./blog.sh help"
    ;;

  # 无效参数
  *)
    echo -e "${RED}错误：无效命令！请使用以下参数：${NC}"
    echo "./blog.sh first-pull - 首次配置（切换分支+安装依赖）"
    echo "./blog.sh pull       - 同步远程 source 分支"
    echo "./blog.sh push       - 提交变更到 source 分支（可加备注）"
    echo "./blog.sh test       - 本地预览博客（localhost:4000）"
    echo "./blog.sh deploy     - 编译部署到 GitHub Pages"
    echo "./blog.sh help       - 查看使用说明"
    exit 1
    ;;
esac

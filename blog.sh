#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

# --- 新增：图片语法检查函数 ---
check_images() {
    echo -e "${YELLOW}>>> 正在检索图片引用规范...${NC}"
    
    # 使用 grep 检索是否存在典型的非标准语法：
    # 1. WikiLink 格式: ![[
    # 2. 畸形的混合格式: ![[ ]]( )
    # 注意：这里只扫描 source/_posts 目录
    BAD_SYNTAX=$(grep -rE "(!\[\[.*\]\]|!\[\[.*\]\]\(.*\))" source/_posts)

    if [ -n "$BAD_SYNTAX" ]; then
        echo -e "${YELLOW}>>> 检测到非标准图片引用，启动自动修复程序...${NC}"
        python fix_hexo_images.py
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}>>> 修复完成。${NC}"
        else
            echo -e "${RED}>>> 修复脚本执行出错，请检查！${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}>>> 图片引用检查通过，无需修复。${NC}"
    fi
}

case "$1" in
  pull)
    git pull origin source
    ;;
  push)
    # 1. 先做图片修复检查
    check_images
    # 2. 执行常规提交
    commit_msg=${2:-"更新博客"}
    echo -e "${GREEN}>>> 正在提交源码...${NC}"
    git add . && git commit -m "$commit_msg" && git push origin source
    ;;
  new)
    [ -z "$2" ] && echo -e "${RED}标题不能为空${NC}" && exit 1
    hexo new "${2%.md}"
    ;;
  img)
    if [ -z "$2" ]; then
      echo -e "${RED}用法: ./blog.sh img source/_posts/xxx.md${NC}"
      exit 1
    fi
    echo -e "${GREEN}>>> 正在处理：$2${NC}"
    python hexo_img_refactor.py "$2"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}>>> 处理完成！${NC}"
    else
      echo -e "${RED}>>> 处理失败。${NC}"
    fi
    ;;
  test)
    hexo clean && hexo g && hexo s
    ;;
  deploy)
    # 1. 部署前也检查一遍，防止漏网之鱼
    check_images
    # 2. 执行 Hexo 部署流程
    echo -e "${GREEN}>>> 正在生成并部署...${NC}"
    hexo clean && hexo g && hexo d
    ;;
  help|*)
    echo -e "${GREEN}=== 常用命令 ===${NC}"
    echo "./blog.sh img [path]  - 处理单个文件图片"
    echo "./blog.sh test        - 本地预览"
    echo "./blog.sh push [msg]  - 检查并提交源码"
    echo "./blog.sh deploy      - 检查并部署上线"
    ;;
esac

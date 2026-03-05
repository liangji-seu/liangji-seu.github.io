#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

case "$1" in
  pull)
    git pull origin source
    ;;
  push)
    commit_msg=${2:-"更新博客"}
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
    # 直接使用你测试成功的 python 命令
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
    hexo clean && hexo g && hexo d
    ;;
  help|*)
    echo -e "${GREEN}=== 常用命令 ===${NC}"
    echo "./blog.sh img [path]  - 处理图片"
    echo "./blog.sh test        - 本地预览"
    echo "./blog.sh push [msg]  - 提交源码"
    ;;
esac
import os
import re
import urllib.parse

# 确保在和 source 同级的根目录执行
BASE_DIR = os.getcwd()
POSTS_DIR = os.path.join(BASE_DIR, "source", "_posts")
# 假设你的图片集中存放在 source/images 目录下
IMG_DIR = os.path.join(BASE_DIR, "source", "images")

def normalize_images():
    if not os.path.exists(POSTS_DIR):
        print(f"❌ 错误: 找不到目录 {POSTS_DIR}，请确认你在博客根目录运行此脚本！")
        return

    # 匹配逻辑 (按照复杂程度从高到低排列)
    hybrid_pattern = re.compile(r'!\[\[(.*?)\]\]\((.*?)\)')  # 匹配畸形的混合语法
    wiki_pattern = re.compile(r'!\[\[(.*?)\]\]')             # 匹配 Wiki 语法
    md_pattern = re.compile(r'!\[(.*?)\]\((.*?)\)')          # 匹配标准 Markdown

    modified_files = 0

    for root, dirs, files in os.walk(POSTS_DIR):
        for file in files:
            if not file.endswith('.md'): continue
            
            filepath = os.path.join(root, file)
            
            # 【核心亮点】：动态计算相对路径
            # 无论 md 文件藏在 _posts 的几级目录下，都能算出精确的 ../images 或 ../../images
            rel_img_dir = os.path.relpath(IMG_DIR, root).replace('\\', '/')

            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()

            original_content = content

            # 通用处理：剥离原有的混乱路径，只保留文件名，并安全转义空格
            def process_path(path_str):
                clean_path = urllib.parse.unquote(path_str) # 先解开可能存在的 %20
                filename = os.path.basename(clean_path)     # 斩断原有目录结构，只取文件名
                return filename.replace(' ', '%20')         # 仅转义空格，不破坏中文文件名

            # 1. 修复最乱的混合语法: ![[path|size]](alt) -> ![alt|size](new_path)
            def replace_hybrid(match):
                path_and_size, alt_text = match.group(1), match.group(2)
                size = path_and_size.split('|')[1] if '|' in path_and_size else ""
                filename = process_path(path_and_size.split('|')[0])
                
                # 组合 alt: 优先保留 alt 文本，如果有尺寸属性则用 | 拼接到后面，Obsidian 和 Hexo 都能兼容
                alt_str = f"{alt_text}|{size}" if size and alt_text else (alt_text or size)
                return f"![{alt_str}]({rel_img_dir}/{filename})"

            content = hybrid_pattern.sub(replace_hybrid, content)

            # 2. 修复 Wiki 语法: ![[path|size]] -> ![size](new_path)
            def replace_wiki(match):
                path_and_size = match.group(1)
                size = path_and_size.split('|')[1] if '|' in path_and_size else ""
                filename = process_path(path_and_size.split('|')[0])
                
                return f"![{size}]({rel_img_dir}/{filename})"

            content = wiki_pattern.sub(replace_wiki, content)

            # 3. 规范化标准 Markdown: ![alt](path) -> ![alt](new_path)
            def replace_md(match):
                alt_str, old_path = match.group(1), match.group(2)
                # 过滤掉网络图片（http 开头），不需要修改它们
                if old_path.startswith("http"):
                    return match.group(0)
                    
                filename = process_path(old_path)
                return f"![{alt_str}]({rel_img_dir}/{filename})"

            content = md_pattern.sub(replace_md, content)

            # 只有发生变化时才执行写入，避免修改文件的最后修改时间
            if content != original_content:
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(content)
                modified_files += 1

    print(f"✅ 搞定！扫描并标准化重构了 {modified_files} 个 Markdown 文件中的图片路径。")

if __name__ == "__main__":
    print("🚀 开始执行 Hexo 图片路径重构脚本...")
    normalize_images()

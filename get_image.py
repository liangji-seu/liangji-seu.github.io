import os
import re
from collections import Counter

# 这里的路径改为你 Obsidian 仓库的根目录，或者存放 md 的目录
VAULT_DIR = "." 

def analyze_img_syntax():
    # 匹配多种常见的图片语法：
    # 1. Standard Markdown: ![alt](path)
    # 2. WikiLinks: ![[path]]
    # 3. HTML: <img src="path" ...>
    patterns = {
        "Standard Markdown": r'!\[.*?\]\((.*?)\)',
        "WikiLinks": r'!\[\[(.*?)\]\]',
        "HTML Tag": r'<img [^>]*src=["\'](.*?)["\']'
    }

    all_matches = []
    syntax_counter = Counter()
    examples = {}

    for root, dirs, files in os.walk(VAULT_DIR):
        # 排除 git 和 hexo 的缓存目录
        if '.git' in dirs: dirs.remove('.git')
        if 'node_modules' in dirs: dirs.remove('node_modules')

        for file in files:
            if file.endswith('.md'):
                file_path = os.path.join(root, file)
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    for name, pattern in patterns.items():
                        matches = re.findall(pattern, content)
                        if matches:
                            syntax_counter[name] += len(matches)
                            all_matches.extend(matches)
                            # 记录每种格式的一个真实例子，方便你确认
                            if name not in examples:
                                full_match = re.search(pattern, content).group(0)
                                examples[name] = full_match

    print("--- 图片引用语法总结 ---")
    if not syntax_counter:
        print("未发现任何图片引用。")
        return

    for name, count in syntax_counter.items():
        print(f"[{name}]: 共 {count} 处")
        print(f"   典型写法: {examples[name]}")
    
    print("\n--- 路径特征分析 (前 15 条唯一路径预览) ---")
    unique_paths = list(set(all_matches))
    for p in unique_paths[:15]:
        print(f" - {p}")
    
    if len(unique_paths) > 15:
        print(f" ... 以及其他 {len(unique_paths)-15} 条路径")

if __name__ == "__main__":
    analyze_img_syntax()

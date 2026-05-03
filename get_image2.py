import os
import re

VAULT_DIR = "."

def extract_reference_styles():
    # 分别匹配 标准 Markdown 和 Obsidian WikiLink
    md_regex = re.compile(r'(!\[.*?\]\((.*?)\))')
    wiki_regex = re.compile(r'(!\[\[(.*?)\]\])')

    # 字典用于存储：结构特征 -> 真实代码示例
    styles_found = {}

    for root, dirs, files in os.walk(VAULT_DIR):
        if any(d in root for d in ['.git', 'node_modules', '.obsidian']): continue
        
        for file in files:
            if not file.endswith('.md'): continue
            with open(os.path.join(root, file), 'r', encoding='utf-8') as f:
                content = f.read()
                
                # 1. 抽样 Standard Markdown 格式
                for full_match, path in md_regex.findall(content):
                    style_tags = ["Markdown语法 ![]()"]
                    
                    # 路径前缀判定
                    if path.startswith('../'): style_tags.append("相对路径(上一级 ../)")
                    elif path.startswith('./'): style_tags.append("相对路径(当前级 ./)")
                    elif path.startswith('/'): style_tags.append("绝对路径(根目录开始 /)")
                    elif path.startswith('http'): style_tags.append("网络链接(http)")
                    elif '/' in path: style_tags.append("子目录(如 images/)")
                    else: style_tags.append("纯文件名(无路径)")
                    
                    # 特殊字符判定
                    if '%20' in path: style_tags.append("空格被转义(%20)")
                    elif ' ' in path: style_tags.append("包含原生空格")
                        
                    signature = " + ".join(style_tags)
                    if signature not in styles_found:
                        styles_found[signature] = full_match

                # 2. 抽样 WikiLink 格式
                for full_match, path in wiki_regex.findall(content):
                    style_tags = ["Wiki语法 ![[]]"]
                    
                    if path.startswith('../'): style_tags.append("相对路径(上一级 ../)")
                    elif path.startswith('./'): style_tags.append("相对路径(当前级 ./)")
                    elif path.startswith('/'): style_tags.append("绝对路径(根目录开始 /)")
                    elif path.startswith('http'): style_tags.append("网络链接(http)")
                    elif '/' in path: style_tags.append("子目录(如 images/)")
                    else: style_tags.append("纯文件名(无路径)")
                    
                    if '|' in path: style_tags.append("带尺寸参数(|)")
                    if ' ' in path: style_tags.append("包含原生空格")

                    signature = " + ".join(style_tags)
                    if signature not in styles_found:
                        styles_found[signature] = full_match

    # 打印结果
    print("=== 发现的独特图片引用写法抽样 ===")
    if not styles_found:
        print("没有找到任何图片引用。")
        return

    for i, (signature, example) in enumerate(styles_found.items(), 1):
        print(f"\n[{i}] 结构: {signature}")
        print(f"    示例: {example}")

if __name__ == "__main__":
    extract_reference_styles()

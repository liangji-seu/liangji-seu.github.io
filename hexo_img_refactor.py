import os
import re
import shutil
import sys

def refactor_md_images(md_path):
    # 1. 路径解析
    md_path = os.path.abspath(md_path)
    md_dir = os.path.dirname(md_path) # 应该是 .../source/_posts
    md_name = os.path.splitext(os.path.basename(md_path))[0]
    
    # 目标图片目录: source/images/
    # 因为 md 在 _posts 下，所以上一级是 source，再进 images
    source_dir = os.path.abspath(os.path.join(md_dir, ".."))
    target_img_dir = os.path.join(source_dir, "images")
    
    if not os.path.exists(target_img_dir):
        os.makedirs(target_img_dir)
        print(f"创建目录: {target_img_dir}")

    # 2. 读取内容
    with open(md_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # 3. 匹配逻辑 (匹配粘贴时的 image.png 或 image-1.png)
    img_pattern = re.compile(r'!\[(.*?)\]\(((image-?\d*\.(?:png|jpg|jpeg|gif|webp)))\)')
    matches = img_pattern.findall(content)

    if not matches:
        print("未发现匹配的 image.png 引用。")
        return

    new_content = content
    for idx, (alt_text, old_img_name, ext) in enumerate(matches, 1):
        # 构造新文件名
        new_img_name = f"{md_name}-{idx:02d}{os.path.splitext(old_img_name)[1]}"
        old_img_path = os.path.join(md_dir, old_img_name)
        new_img_path = os.path.join(target_img_dir, new_img_name)

        if os.path.exists(old_img_path):
            # 移动文件
            shutil.move(old_img_path, new_img_path)
            
            # 关键修改：使用相对路径 ../images/
            # 在 Markdown 中统一使用正斜杠 /，确保跨平台兼容性
            new_rel_path = f"../images/{new_img_name}"
            
            # 替换原始引用
            old_ref = f"({old_img_name})"
            new_ref = f"({new_rel_path})"
            new_content = new_content.replace(old_ref, new_ref)
            
            print(f"成功: {old_img_name} -> {new_rel_path}")
        else:
            print(f"跳过: 找不到文件 {old_img_path}")

    # 4. 写回文件
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write(new_content)
    
    print("\n[完成] Markdown 引用已修正为相对路径。")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("使用方法: python hexo_img_refactor.py <markdown文件路径>")
    else:
        target_md = sys.argv[1]
        if os.path.exists(target_md):
            refactor_md_images(target_md)
        else:
            print(f"错误: 找不到文件 {target_md}")

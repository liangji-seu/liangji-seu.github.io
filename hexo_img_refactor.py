import os
import re
import shutil
import sys
from datetime import datetime

def refactor_md_images(md_path):
    # 路径标准化
    md_path = os.path.abspath(md_path)
    if not os.path.exists(md_path):
        print(f"错误: 找不到文件 {md_path}")
        sys.exit(1)

    md_dir = os.path.dirname(md_path)
    md_name = os.path.splitext(os.path.basename(md_path))[0]
    
    # 寻找 source 目录
    source_dir = os.path.abspath(os.path.join(md_dir, ".."))
    target_img_dir = os.path.join(source_dir, "images")
    
    if not os.path.exists(target_img_dir):
        os.makedirs(target_img_dir)

    # 时间戳精确到秒 (月日时分秒)
    timestamp = datetime.now().strftime("%m%d%H%M%S")

    with open(md_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # 匹配 image.png 或 image-1.png 等
    img_pattern = re.compile(r'!\[(.*?)\]\(((image-?\d*\.(?:png|jpg|jpeg|gif|webp)))\)')
    matches = img_pattern.findall(content)

    if not matches:
        print("未发现匹配的原始图片引用。")
        return

    new_content = content
    for idx, (alt_text, old_img_name, ext) in enumerate(matches, 1):
        # 命名格式: 文章名-序号-时间戳.ext
        new_img_name = f"{md_name}-{idx:02d}-{timestamp}{os.path.splitext(old_img_name)[1]}"
        old_img_path = os.path.join(md_dir, old_img_name)
        new_img_path = os.path.join(target_img_dir, new_img_name)

        if os.path.exists(old_img_path):
            shutil.move(old_img_path, new_img_path)
            # Markdown 引用路径
            new_rel_path = f"../images/{new_img_name}"
            new_content = new_content.replace(f"({old_img_name})", f"({new_rel_path})")
            print(f"成功移至: {new_rel_path}")
        else:
            print(f"跳过(文件不存在): {old_img_name}")

    with open(md_path, 'w', encoding='utf-8') as f:
        f.write(new_content)
    print(f"\n[OK] 处理完毕。")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        refactor_md_images(sys.argv[1])
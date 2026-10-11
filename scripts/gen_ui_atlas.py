#!/usr/bin/env python3
# 生成 Android 端界面文案贴图（ui.bin）+ Zig 侧索引表（ui_assets.zig）
# 设计：设备端不依赖任何字体，所有中文文案在构建期用 Noto Sans CJK SC 预渲染成图集，
#       运行时按名字取槽位贴图；动态数字用同一图集里的 ASCII 字符槽位按步进宽度拼。
import json, math, os, struct, sys
from PIL import Image, ImageDraw, ImageFont

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "android/app/src"
FONT_PATH = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
SIZE = 44                     # 基础字号（设备端按屏幕高度缩放）
WRAP_PX = 620                 # 帮助文案换行宽度（基础字号下的像素）
ATLAS_W = 2048  # GLES2 只保证 MAX_TEXTURE_SIZE ≥ 2048，图集必须控制在这个范围内

def pick_sc_font(path, size):
    for idx in range(0, 6):
        try:
            f = ImageFont.truetype(path, size, index=idx)
        except Exception:
            continue
        name = " ".join(str(x) for x in f.getname())
        if "SC" in name:
            return f, name
    return ImageFont.truetype(path, size, index=0), "fallback"

font, font_name = pick_sc_font(FONT_PATH, SIZE)
asc, desc = font.getmetrics()
LINE_H = asc + desc
print(f"font={font_name} size={SIZE} ascent={asc} descent={desc} line_h={LINE_H}")

def render(s):
    """把一个字符串渲染成 RGBA 图（统一高度，方便逐行对齐）"""
    wid = max(1, int(math.ceil(font.getlength(s))))
    img = Image.new("RGBA", (wid + 2, LINE_H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.text((1, 0), s, font=font, fill=(255, 255, 255, 255))
    return img

def wrap(text, max_px):
    """按像素宽度折行：CJK 逐字，ASCII 逐词尽量成组"""
    out = []
    for para in text.split("\n"):
        if para.strip() == "":
            out.append("")
            continue
        cur = ""
        for ch in para:
            trial = cur + ch
            if font.getlength(trial) > max_px and cur:
                out.append(cur)
                cur = ch
            else:
                cur = trial
        if cur:
            out.append(cur)
    return out

HELP = ("雷区里有四种雷。\n"
        "点击格子翻开，长按插旗，点击已翻开的数字展开周围。\n"
        "点人脸按钮或者菜单里的「开局」开始新的一局。\n"
        "\n"
        "圆复数模式：\n"
        "四种雷分别是正实雷、负实雷、正虚雷、负虚雷。\n"
        "数字代表该格周围所有雷的加和之模长，均被写为整数或最简根式。\n"
        "当旗帜数量等于周围真实雷数，且实虚比例符合真实比例或其倒数的时候，可以展开。\n"
        "\n"
        "双曲复数模式（闵可夫斯基模式）：\n"
        "四种雷分别是正实雷（正类空雷）、负实雷（负类空雷）、正双曲虚雷（正类时雷）、负双曲虚雷（负类时雷）。\n"
        "定义双曲虚数单位（类时单位）j²=1，形式模长（时空间隔）S=√(a²-b²)，所以，可以出现虚数。\n"
        "（本模式只是从闵可夫斯基时空度规得来的灵感，跟广义相对论没有多大关系。）\n"
        "数字是该格周围所有雷之加和的形式模长（时空间隔），均被写为整数或最简根式。\n"
        "当旗帜数量等于周围真实雷数，且实部（类空部）、j部（类时部）的数量等于真实数量时，可以展开。")

ENTRIES = []
def add(name, text):
    ENTRIES.append((name, text))

# —— 顶栏
add("tb_menu", "菜单"); add("tb_flag", "插旗"); add("tb_open", "翻开"); add("tb_restart", "重开")
add("tb_out", "缩小"); add("tb_in", "放大")
add("hint_open", "点击翻开 · 长按插旗 · 点数字展开")
add("hint_flag", "插旗模式 · 点击插旗 · 长按翻开")
add("hint_z1", "缩放 150% · 单指拖动平移")
add("hint_z2", "缩放 200% · 单指拖动平移")
add("hint_z3", "缩放 300% · 单指拖动平移")
add("hint_z4", "缩放 400% · 单指拖动平移")
# —— 主菜单
add("m_title", "复扫雷 Complexweeper")
add("m_new", "开局（新游戏）")
add("m_cplx", "圆复数模式")
add("m_hyper", "双曲复数模式（闵可夫斯基模式）")
add("m_sound_on", "声音：开")
add("m_sound_off", "声音：关")
add("m_zoom", "缩放")
add("m_help", "玩法与操作")
add("m_about", "关于复扫雷")
add("m_close", "关闭菜单")
# —— 模式子菜单
add("sm_title_cplx", "圆复数模式")
add("sm_title_hyper", "双曲复数模式（闵可夫斯基模式）")
add("sm_beg", "初级 9×9 · 10 雷"); add("sm_int", "中级 16×16 · 40 雷"); add("sm_exp", "高级 30×16 · 99 雷")
add("sm_custom", "自定义雷区…"); add("sm_best", "最高分纪录…"); add("sm_back", "返回")
# —— 缩放子菜单
add("zm_title", "缩放"); add("zm_auto", "适应屏幕"); add("zm_150", "150%"); add("zm_200", "200%"); add("zm_300", "300%"); add("zm_400", "400%"); add("zm_back", "返回")
# —— 自定义雷区
add("cu_title", "自定义雷区"); add("cu_height", "高度"); add("cu_width", "宽度")
add("cu_t1", "正实雷"); add("cu_t2", "负实雷"); add("cu_t3", "正虚雷"); add("cu_t4", "负虚雷")
add("cu_h1", "正实雷（正类空雷）"); add("cu_h2", "负实雷（负类空雷）")
add("cu_h3", "正双曲虚雷（正类时雷）"); add("cu_h4", "负双曲虚雷（负类时雷）")
add("cu_rows", "9 – 30 行"); add("cu_cols", "9 – 40 列")
add("cu_split", "按合计均分"); add("cu_ok", "确定"); add("cu_cancel", "取消")
add("cu_e_height", "高度要在 9 – 30 之间。"); add("cu_e_width", "宽度要在 9 – 40 之间。")
add("cu_e_zero", "四种雷合计至少 1 颗。"); add("cu_e_big", "合计超过上限（格数 − 9）。")
# —— 最高分纪录
add("sc_title_cplx", "最高分纪录 · 圆复数模式"); add("sc_title_hyper", "最高分纪录 · 双曲复数模式（闵可夫斯基模式）")
add("sc_new_cplx", "新纪录！ · 圆复数模式"); add("sc_new_hyper", "新纪录！ · 双曲复数模式（闵可夫斯基模式）")
add("sc_beg", "初级"); add("sc_int", "中级"); add("sc_exp", "高级"); add("sc_sec", "秒"); add("sc_none", "———"); add("sc_close", "关闭")
# —— 玩法与操作
add("hp_title", "玩法与操作"); add("hp_close", "关闭")
for i, line in enumerate(wrap(HELP, WRAP_PX), 1):
    add("hp_%02d" % i, line)
HELP_LINES = i
# —— 关于
add("ab_title", "关于复扫雷")
add("ab_l1", "复扫雷 Complexweeper 1.2.0")
add("ab_l2", "基于 Microsoft® 扫雷（原版作者：Robert Donner、Curt Johnson）")
add("ab_l3", "图像素材来源：Microsoft（扫雷原始图像素材）；青月晓（新增图像素材）。")
add("ab_l4", "Copyright © 2026 青月晓")
add("ab_l5", "本程序为免费软件")
add("ab_l6", "与 Microsoft 公司无隶属关系")
add("ab_close", "关闭")

# 图集条目：文案 + ASCII 字符 + 纯色块 + 圆点
imgs = []
for name, text in ENTRIES:
    imgs.append((name, render(text), 0))
CH_FIRST, CH_LAST = 32, 126
ch_adv = []
for code in range(CH_FIRST, CH_LAST + 1):
    ch = chr(code)
    wid = max(1, int(math.ceil(font.getlength(ch))))
    img = Image.new("RGBA", (wid + 2, LINE_H), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((1, 0), ch, font=font, fill=(255, 255, 255, 255))
    imgs.append(("ch_%d" % code, img, int(round(font.getlength(ch)))))
    ch_adv.append(int(round(font.getlength(ch))))
white = Image.new("RGBA", (4, 4), (255, 255, 255, 255))
imgs.append(("ui_white", white, 0))
dot = Image.new("RGBA", (LINE_H, LINE_H), (0, 0, 0, 0))
dr = ImageDraw.Draw(dot)
r = LINE_H // 2 - 6
c = LINE_H // 2
dr.ellipse((c - r, c - r, c + r, c + r), fill=(255, 255, 255, 255))
imgs.append(("ui_dot", dot, 0))

# —— 货架式打包（高的先放，减少碎片）
order = sorted(range(len(imgs)), key=lambda i: (-imgs[i][1].height, -imgs[i][1].width))
placed = {}
shelf_y, shelf_h, x = 0, 0, 0
PAD = 2
for i in order:
    im = imgs[i][1]
    w, h = im.width + PAD, im.height + PAD
    if x + w > ATLAS_W:
        shelf_y += shelf_h
        shelf_h = 0
        x = 0
    placed[i] = (x, shelf_y)
    x += w
    shelf_h = max(shelf_h, h)
atlas_h = shelf_y + shelf_h
atlas_h = ((atlas_h + 3) // 4) * 4
atlas = Image.new("RGBA", (ATLAS_W, atlas_h), (0, 0, 0, 0))
rects = []
for i, (name, im, adv) in enumerate(imgs):
    px, py = placed[i]
    atlas.paste(im, (px, py))
    rects.append((name, px, py, im.width, im.height, adv))

# —— 写出 ui.bin（小端：魔数/版本/条目数/尺寸/基准行高 + 索引 + RGBA 像素）
pix = atlas.tobytes()
hdr = b"CSUI" + struct.pack("<HHHHHH", 1, len(rects), ATLAS_W, atlas_h, LINE_H, 0)
idx = b"".join(struct.pack("<HHHHHH", x, y, w, h, adv, 0) for (_, x, y, w, h, adv) in rects)
bin_path = os.path.join(OUT_DIR, "ui.bin")
with open(bin_path, "wb") as f:
    f.write(hdr); f.write(idx); f.write(pix)

# —— 写出 Zig 索引表
zig = ["// 本文件由 scripts/gen_ui_atlas.py 自动生成，不要手改。",

       "pub const atlas_w: u16 = %d;" % ATLAS_W,
       "pub const atlas_h: u16 = %d;" % atlas_h,
       "pub const count: u16 = %d;" % len(rects),
       "pub const line_h: u16 = %d;" % LINE_H,
       "pub const help_lines: u16 = %d;" % HELP_LINES,
       "",
       "pub const Rect = struct { x: u16, y: u16, w: u16, h: u16, adv: u16 };",
       "pub const rects = [_]Rect{"]
for (_, x, y, w, h, adv) in rects:
    zig.append("    .{ .x = %d, .y = %d, .w = %d, .h = %d, .adv = %d }," % (x, y, w, h, adv))
zig.append("};")
zig.append("pub fn rect(i: u16) Rect { return rects[i]; }")
zig.append("")
for i, (name, _, _, _, _, _) in enumerate(rects):
    zig.append("pub const %s: u16 = %d;" % (name, i))
zig.append("")
zig.append("pub const ch_first: u8 = %d;" % CH_FIRST)
zig.append("pub const ch_last: u8 = %d;" % CH_LAST)
zig.append("pub const ch_idx = [_]u16{ %s };" % ", ".join(
    str(i) for i, (n, *_ ) in enumerate(rects) if n.startswith("ch_")))
zig.append("pub const ch_adv = [_]u16{ %s };" % ", ".join(str(a) for a in ch_adv))
with open(os.path.join(OUT_DIR, "ui_assets.zig"), "w") as f:
    f.write("\n".join(zig) + "\n")

print("ui.bin: %d x %d, %d 条目, %.2f MB" % (ATLAS_W, atlas_h, len(rects), len(pix) / 1048576))
print("帮助文案折行 %d 行" % HELP_LINES)

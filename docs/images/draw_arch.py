from PIL import Image, ImageDraw, ImageFont
import math, os

W, H = 2000, 1420
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)

FONT = "/home/rubbishbro/.fonts/windows/msyh.ttc"
if not os.path.exists(FONT):
    FONT = "/usr/share/fonts/google-droid-sans-fonts/DroidSansFallbackFull.ttf"

def fnt(sz, bold=False):
    return ImageFont.truetype(FONT, sz, index=0)

def text(x, y, s, sz=20, fill="#111111", anchor="la", bold=False):
    d.text((x, y), s, font=fnt(sz, bold), fill=fill, anchor=anchor)

def dashed_line(p1, p2, fill, width=2, dash=10, gap=7):
    x1, y1 = p1; x2, y2 = p2
    dx, dy = x2 - x1, y2 - y1
    ln = math.hypot(dx, dy)
    if ln == 0: return
    ux, uy = dx / ln, dy / ln
    t = 0
    while t < ln:
        a = (x1 + ux * t, y1 + uy * t)
        b = (x1 + ux * min(t + dash, ln), y1 + uy * min(t + dash, ln))
        d.line([a, b], fill=fill, width=width)
        t += dash + gap

def dashed_rect(x, y, w, h, color, width=2):
    dashed_line((x, y), (x + w, y), color, width)
    dashed_line((x + w, y), (x + w, y + h), color, width)
    dashed_line((x + w, y + h), (x, y + h), color, width)
    dashed_line((x, y + h), (x, y), color, width)

def box(x, y, w, h, title, lines, color, fill="#F7FFF7", dash=False, tsz=25, bsz=18):
    if dash:
        d.rounded_rectangle([x, y, x + w, y + h], radius=12, fill=fill, outline=fill)
        dashed_rect(x, y, w, h, color, 3)
    else:
        d.rounded_rectangle([x, y, x + w, y + h], radius=12, fill=fill, outline=color, width=3)
    text(x + 16, y + 10, title, tsz, color, bold=True)
    yy = y + 48
    for line in lines:
        text(x + 16, yy, line, bsz, "#222222")
        yy += 25

def arrow(p1, p2, color="#2E7D32", width=3, dash=False, head=True):
    x1, y1 = p1; x2, y2 = p2
    if dash:
        dashed_line(p1, p2, color, width)
    else:
        d.line([p1, p2], fill=color, width=width)
    if head:
        ang = math.atan2(y2 - y1, x2 - x1)
        L = 13; Wd = 7
        left = (x2 - L * math.cos(ang) + Wd * math.sin(ang),
                y2 - L * math.sin(ang) - Wd * math.cos(ang))
        right = (x2 - L * math.cos(ang) - Wd * math.sin(ang),
                 y2 - L * math.sin(ang) + Wd * math.cos(ang))
        d.polygon([p2, left, right], fill=color)

GREEN = "#2E7D32"
ORANGE = "#E65100"
GRAY = "#757575"
BLUE = "#1565C0"

# title
text(50, 22, "ENG1 A/B/C 迁移现状（2026-10-20，按当前 SV）", 34, "#111111", bold=True)
# legend
d.rounded_rectangle([1450, 18, 1474, 42], radius=4, fill=GREEN)
text(1484, 20, "已接通/有测试", 18)
d.rounded_rectangle([1650, 18, 1674, 42], radius=4, fill=ORANGE)
text(1684, 20, "单测/部分", 18)
d.rounded_rectangle([1810, 18, 1834, 42], radius=4, fill=GRAY)
text(1844, 20, "未接/tie-off", 18)

# outer top
d.rounded_rectangle([30, 80, 1970, 1390], radius=18, outline="#90A4AE", width=3, fill="#FCFCFC")
text(50, 92, "synth_top", 28, "#37474F", bold=True)
text(170, 98, "（BUF + ENG1 + ENG2）", 18, "#607D8B")

# left BUF
box(60, 150, 360, 300, "synth_buf", [
    "256-bit 共享 BUF（max-width）",
    "ENG1 region: 72b 系数",
    "ENG2 region: 224b 系数",
    "结果 ping-pong: res_mem[2][2]",
    "rd1: 接 A/B/C loader（USE_BUF）",
    "rd2: 未接 ENG2",
    "res_we 结果写：已接",
], GREEN, fill="#F1F8E9")
text(70, 430, "rd2 未接 ENG2", 17, ORANGE)
dashed_line((70, 452), (410, 452), ORANGE, 2)

# bus ports left
text(8, 520, "load_* /\nclass /\nvel", 18, "#455A64")
text(8, 820, "start /\nactive /\nx_vec", 18, "#455A64")
text(8, 1120, "res_*", 18, "#455A64")

# ENG1 cluster
d.rounded_rectangle([450, 130, 1460, 1200], radius=16, outline=BLUE, width=3, fill="#F5FAFF")
text(470, 142, "eng1_voice_top", 28, BLUE, bold=True)
text(680, 148, "（A/B/C 统一 32 声部 × 48 模态）", 18, "#546E7A")

# b_x_pool
box(490, 195, 430, 185, "b_x_pool", [
    "N × b_voice_ctrl",
    "Control 解析：base_inc[95:64]",
    "attack[39:16] / release[63:40]",
    "class==1 才输出 x",
], GREEN, fill="#F1F8E9")

# x mux
box(490, 420, 430, 95, "x mux（按 class）", [
    "A: 外部 x_vec   B: b_x_pool   C: 0",
], GREEN, fill="#F1F8E9", tsz=23, bsz=17)

# modal_engine cluster
d.rounded_rectangle([470, 545, 1430, 1170], radius=14, outline="#6A1B9A", width=3, fill="#FBF7FF")
text(490, 556, "modal_engine", 26, "#6A1B9A", bold=True)
text(700, 562, "（统一 Event→Index→Control→Core→Seed→Bank）", 17, "#7E57C2")

# loader mux
box(500, 600, 380, 190, "class_loader_mux", [
    "A: class_loader（20-bit index）",
    "B/C: class_loader64（64-bit）",
    "Control 256 / Core 72 / Seed 64",
    "commit_ctrl → voice_ctrl",
], GREEN, fill="#F1F8E9")

# bank
box(960, 600, 430, 240, "modal_poly_bank", [
    "4 × poly_modal_lane",
    "32 voices × 48 modes",
    "clear / cfg / seed 写口",
    "mix_sum / voice_sum / sat",
], GREEN, fill="#F1F8E9")

# voice ctrl
box(500, 840, 380, 115, "voice_ctrl[32] / ctrl_flat", [
    "load_done 时写 commit_ctrl",
    "ctrl_flat 送 b_x_pool",
], GREEN, fill="#F1F8E9", tsz=23, bsz=17)

# job port
box(960, 880, 430, 110, "job / result", [
    "start + active_mask + x → mix/voice",
    "out_valid / error",
], GREEN, fill="#F1F8E9", tsz=23, bsz=17)

# arrows inside eng1
arrow((920, 290), (920, 420), GREEN)                 # bx -> xmux
text(930, 340, "b_x[N]", 16, GREEN)
text(455, 395, "外部 x（A）", 16, "#455A64")
arrow((440, 468), (490, 468), "#455A64")
arrow((705, 515), (705, 600), GREEN)                 # xmux -> engine
text(725, 528, "x_mux", 16, GREEN)
arrow((880, 840), (900, 380), GREEN)                 # ctrl_flat -> bx（走 loader/bank 间隙）
text(898, 742, "ctrl_flat", 14, GREEN)
arrow((880, 695), (960, 695), GREEN)                 # loader -> bank
text(885, 640, "clear/", 14, GREEN)
text(885, 658, "cfg/seed", 14, GREEN)
arrow((1190, 840), (1190, 880), GREEN)
text(1200, 850, "result", 15, GREEN)

# external load to loader
text(60, 650, "Event\nclass/inst/\nnote/vel", 17, "#455A64")
arrow((150, 700), (500, 700), "#455A64")
text(180, 672, "load", 16, "#455A64")

# result to BUF (bottom path)
arrow((960, 980), (240, 980), GREEN)
arrow((240, 980), (240, 450), GREEN)
text(280, 950, "mix/voice（结果）", 16, GREEN)

# ENG2 cluster
box(1500, 150, 420, 300, "eng2_voice_top", [
    "modal_voice_top（sythsound）",
    "modal_engine7（7-field）",
    "",
    "coeff / x / start 全 0",
    "当前 tie-off，仅壳",
], GRAY, fill="#FAFAFA", dash=True)
text(1520, 466, "ENG2 实际数据未接", 17, ORANGE)

# standalone modules
box(1500, 560, 420, 110, "b_a1_refresh", [
    "sqrt + 小角度展开，单测 1/1",
], ORANGE, fill="#FFF3E0", dash=True, tsz=23, bsz=17)
box(1500, 700, 420, 110, "c_voice_timer", [
    "每声部 length / choke",
    "已接 eng1_voice_top",
], GREEN, fill="#F1F8E9", tsz=23, bsz=17)
arrow((1460, 755), (1500, 755), GREEN)
text(1500, 835, "a1 刷新仍未接（橙）", 17, ORANGE)

# tests footer
d.rounded_rectangle([50, 1235, 1950, 1362], radius=12, outline="#B0BEC5", width=2, fill="#FAFAFA")
text(70, 1245, "测试：", 20, "#37474F", bold=True)
text(150, 1248, "test_synth_top（A）✔   test_synth_top_bc（B 装载+x 出声）✔   test_synth_top_c（C seed 振铃）✔", 17, "#2E7D32")
text(150, 1280, "test_b_x_pool 2/2 ✔   test_engine_bc ✔   test_class_loader64 2/2 ✔   b_a1 / b_ctrl / c_timer 各 1/1 ✔", 17, "#2E7D32")
text(150, 1312, "test_synth_top_buf ✔（BUF 读）   C timer active→done ✔", 17, "#2E7D32")
text(150, 1340, "未完成：a1 刷新接入、ENG2 实际数据、C timer 回收/active_mask、B/C 逐位与 e02/e07", 17, ORANGE)

out = "/home/rubbishbro/Projects/FPGA_IDC_2026/docs/images/rtl_arch_2026-10-20.png"
img.save(out)
print(out, img.size)

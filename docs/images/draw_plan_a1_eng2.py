from PIL import Image, ImageDraw, ImageFont
import math, os

W, H = 2000, 1220
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)
FONT = "/home/rubbishbro/.fonts/windows/msyh.ttc"
if not os.path.exists(FONT):
    FONT = "/usr/share/fonts/google-droid-sans-fonts/DroidSansFallbackFull.ttf"

def fnt(sz):
    return ImageFont.truetype(FONT, sz, index=0)

def text(x, y, s, sz=18, fill="#111111", anchor="la"):
    d.text((x, y), s, font=fnt(sz), fill=fill, anchor=anchor)

def dashed_line(p1, p2, fill, width=2, dash=10, gap=7):
    x1, y1 = p1; x2, y2 = p2
    dx, dy = x2-x1, y2-y1
    ln = math.hypot(dx, dy)
    if ln == 0: return
    ux, uy = dx/ln, dy/ln
    t = 0
    while t < ln:
        a = (x1+ux*t, y1+uy*t)
        b = (x1+ux*min(t+dash, ln), y1+uy*min(t+dash, ln))
        d.line([a, b], fill=fill, width=width)
        t += dash+gap

def dashed_rect(x,y,w,h,c,width=3):
    dashed_line((x,y),(x+w,y),c,width); dashed_line((x+w,y),(x+w,y+h),c,width)
    dashed_line((x+w,y+h),(x,y+h),c,width); dashed_line((x,y+h),(x,y),c,width)

def box(x,y,w,h,title,lines,color,fill,dash=False,tsz=23,bsz=17):
    if dash:
        d.rounded_rectangle([x,y,x+w,y+h], radius=10, fill=fill)
        dashed_rect(x,y,w,h,color,3)
    else:
        d.rounded_rectangle([x,y,x+w,y+h], radius=10, fill=fill, outline=color, width=3)
    text(x+14,y+8,title,tsz,color)
    yy = y+42
    for line in lines:
        text(x+14,yy,line,bsz,"#222222")
        yy += 23

def arrow(p1,p2,c,width=3,dash=False):
    x1,y1=p1; x2,y2=p2
    if dash: dashed_line(p1,p2,c,width)
    else: d.line([p1,p2],fill=c,width=width)
    ang=math.atan2(y2-y1,x2-x1); L=13; Wd=7
    left=(x2-L*math.cos(ang)+Wd*math.sin(ang), y2-L*math.sin(ang)-Wd*math.cos(ang))
    right=(x2-L*math.cos(ang)-Wd*math.sin(ang), y2-L*math.sin(ang)+Wd*math.cos(ang))
    d.polygon([p2,left,right],fill=c)

def circle(x,y,n,c):
    d.ellipse([x-16,y-16,x+16,y+16],fill=c,outline="white",width=2)
    text(x,y-11,str(n),18,"white",anchor="ma")

GREEN="#2E7D32"; BLUE="#1565C0"; ORANGE="#E65100"; GRAY="#757575"; PURPLE="#6A1B9A"

text(40,18,"a1 刷新 / ENG2 数据路径：在图中的位置与改法",34,"#111111")
# legend
d.rounded_rectangle([1450,18,1474,42],radius=4,fill=GREEN); text(1484,20,"现有",18)
d.rounded_rectangle([1580,18,1604,42],radius=4,fill=BLUE); text(1614,20,"新增/改动",18)
d.rounded_rectangle([1740,18,1764,42],radius=4,fill=GRAY); text(1774,20,"tie-off",18)
d.rounded_rectangle([1860,18,1884,42],radius=4,fill=ORANGE); text(1894,20,"要移动",18)

# panels
d.rounded_rectangle([30,80,970,1190],radius=16,outline="#90A4AE",width=2,fill="#FCFCFC")
d.rounded_rectangle([990,80,1970,1190],radius=16,outline="#90A4AE",width=2,fill="#FCFCFC")
text(50,92,"① a1 刷新路径（B 类）",27,BLUE)
text(1010,92,"② ENG2 实际数据路径",27,GRAY)

# ---------- left: a1 ----------
box(60,150,300,100,"class_loader64",["CORE / CTRL / SEED","A/B/C 共用装载器"],GREEN,"#F1F8E9")
box(60,300,300,130,"θ ROM（b_theta.mem，固定）",["与 core 同布局（COEFF_DEPTH）","只读；refresh 按 theta_base+mode 读","不写 RAM"],BLUE,"#E3F2FD",dash=True)
box(60,570,300,130,"b_a1_refresh",["sqrt(4a2−a1²) + 小角度展开","输入 a1_nom/a2/θ/ratio","1 mode/cycle，bank idle 时刷"],BLUE,"#E3F2FD",dash=True)
box(60,750,180,55,"b_ratio",["UQ1.15"],GREEN,"#F1F8E9",tsz=21,bsz=16)

box(480,250,430,500,"modal_poly_bank",["4 × poly_modal_lane","32 voices × 48 modes"],GREEN,"#F1F8E9")
box(510,420,370,95,"a1 shadow（每个 lane）","",BLUE,"#E3F2FD",dash=True)
text(524,458,"32×12×22 bit / lane；1W1R",17,"#222222")
text(524,482,"ctx_a1 = class==B ? shadow : a1_nom",16,"#222222")

# arrows
arrow((210,430),(210,570),BLUE)
arrow((160,750),(160,700),GREEN)
arrow((360,635),(510,470),BLUE)          # refresh -> shadow
text(365,600,"a1_we",16,BLUE)
arrow((510,440),(360,600),ORANGE)        # bank read -> refresh
text(380,545,"a1_nom/a2",15,ORANGE)
arrow((510,500),(360,650),ORANGE)
text(380,515,"θ",15,ORANGE)

circle(45,165,1,BLUE); circle(45,315,2,BLUE); circle(455,435,3,BLUE); circle(45,585,4,BLUE)

# left notes
text(60,900,"改哪里 / 怎么改",22,BLUE)
notes = [
"① class_loader64：只写 per-voice theta_base（32×16 FF），不写 θ 内容。",
"② θ ROM：与 b_coeff 同布局；refresh 按 theta_base+mode 读，只读。",
"③ poly_modal_lane：加 a1_shadow（32×12×22/lane）+ a1_we/a1_sel；",
"   ctx_a1 按 class 从 shadow 或原 72-bit 字取。",
"④ b_a1_refresh：从独立模块移进 eng1_voice_top，bank idle 时",
"   按 voice/mode 轮询，1 mode/cycle；全量 1536 拍 ≈15 µs。",
"⑤ 刷新读 bank 的 a1_nom/a2 和 θ，写回 a1 shadow；sample 来则让路。",
]
yy=935
for n in notes:
    text(60,yy,n,16,"#333333"); yy+=27

# ---------- right: ENG2 ----------
box(1020,150,320,170,"synth_buf",["ENG2 region 256-bit","rd2 现在是 tie-off","wr/res 已接"],GREEN,"#F1F8E9")
box(1020,390,320,150,"eng2_loader（新）",["IDLE→COEFF→X→START","→RESULT→DONE","768 coeff + x"],BLUE,"#E3F2FD",dash=True)
box(1020,610,320,60,"USE_ENG2",["0=tie-off，1=on"],BLUE,"#E3F2FD",dash=True,tsz=21,bsz=16)

box(1420,250,470,380,"eng2_voice_top",["modal_voice_top（sythsound）","modal_engine7（7-field）"],GRAY,"#FAFAFA",dash=True)
text(1440,330,"端口：co_we/co_addr/co_data",16,"#333333")
text(1440,356,"      x_we/x_addr/x_data",16,"#333333")
text(1440,382,"      start/n_voices/n_samples/n_modes",16,"#333333")
text(1440,408,"      rd_en/rd_addr/rd_data/rd_valid",16,"#333333")
text(1440,450,"coeff 7×24=168 bit；768 字",16,"#333333")
text(1440,476,"x 16×256×32 bit；结果 y_out[256]",16,"#333333")

box(1420,700,470,100,"结果回 BUF",["rd_data（每采样 Σwo·q）","res_we=1, res_engine=1, res_bank"],BLUE,"#E3F2FD",dash=True)

arrow((1180,320),(1180,390),BLUE)          # BUF -> loader
text(1190,345,"rd2",15,BLUE)
arrow((1340,465),(1420,465),BLUE)          # loader -> voice top
text(1345,435,"co/x/start",15,BLUE)
arrow((1655,630),(1655,700),BLUE)          # voice top -> result
text(1665,650,"rd_*",15,BLUE)
arrow((1420,750),(1380,750),BLUE)
arrow((1380,750),(1380,330),BLUE)
arrow((1380,330),(1340,330),BLUE)
text(1385,545,"res_we",14,BLUE)

circle(1005,165,6,BLUE); circle(1005,405,7,BLUE); circle(1005,625,8,BLUE); circle(1405,715,9,BLUE)

# right notes
text(1010,900,"改哪里 / 怎么改",22,GRAY)
notes = [
"⑥ eng2_loader：读 BUF 的 ENG2 region，拆 7×24 bit 写 co_*，",
"   再写 x_*；然后 start，等 done，读 rd_*，写 res_*。",
"⑦ synth_top 先暴露 raw 端口（co_*/x_*/start/rd_*），加 USE_ENG2；",
"   测试 1 voice/1 mode/1 sample，确认结果非零。",
"⑧ 结果写 BUF 的 res_mem[1][bank]；ENG1/ENG2 分时用 BUF，别同拍抢。",
"⑨ BUF 布局：0x0000 起 768 个 256-bit coeff；x 建议 8×32 打包。",
]
yy=935
for n in notes:
    text(1010,yy,n,16,"#333333"); yy+=27

img.save("/home/rubbishbro/Projects/FPGA_IDC_2026/docs/images/rtl_arch_plan_a1_eng2.png")
print("saved")

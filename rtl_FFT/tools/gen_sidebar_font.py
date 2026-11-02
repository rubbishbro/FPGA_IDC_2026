#!/usr/bin/env python3
"""Generate the small 16x16 Chinese/ASCII ROM used by the sidebar renderer (Pillow)."""
from pathlib import Path
import argparse
import json
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[1]
LABELS={0:"",1:"设置",2:"声音",3:"效果",4:"音域",5:"显示",6:"输入",7:"系统",
        127:"室内",50:"关闭",51:"开启",52:"大厅",53:"浴室",54:"柱状频谱",55:"时域波形",56:"历史曲线",
        57:"青绿",58:"琥珀",59:"低音组",60:"高音组",61:"压力垫",62:"有线MIDI",63:"蓝牙MIDI",
        64:"全部",65:"慢",66:"标准",67:"快",68:"小",69:"大",70:"确认执行",71:"返回取消",
        72:"未接入",73:"等待接收",74:"应用中",75:"已应用",76:"不支持",77:"失败",78:"请回中",
        79:"示例音频",80:"草稿",81:"确认应用",82:"参数",83:"音色编号",84:"调制深度",85:"已提交",
        86:"请松手",87:"菜单",88:"低频",89:"高频",90:"静音",91:"仅有线",92:"仅蓝牙",93:"有线与蓝牙",40:"演奏方式",94:"自动演奏",95:"引导演奏",
        110:"应按",111:"按中",112:"已按",113:"余辉",114:"当前音组",115:"超出音区",
        116:"通信异常",117:"准备中",118:"等待音符",119:"键",120:"通道",121:"仅提示",122:"MIDI",123:"演奏中"}
for index,label in enumerate(["乐器音色","主音量","混响预设","","","键位绑定",
                              "频谱样式","视觉主题","峰值标记","显示平滑","背景网格","演奏来源",
                              "MIDI通道","远程配置","","","重新校准","立即清音",
                              "重置通信",""]):
    LABELS[20+index]=label
for index,label in enumerate(["钢琴1","吉他1","长笛","小号","大提琴","小提琴","双簧管","鼓组","班卓","曼陀林"]):
    LABELS[100+index]=label
LABELS[41]='声像'
LABELS[124]='钢琴2'
LABELS[125]='吉他2'
LABELS[126]='自定义键位'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font',type=Path,default=Path('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'))
    parser.add_argument('--reuse-bitmap',action='store_true',help='Update labels using existing glyph IDs and bitmap ROM')
    args=parser.parse_args()
    chars=[' ']+sorted(set(''.join(LABELS.values())+'0123456789%#<>+-')-{' '})
    assert len(chars)<256
    ids={ch:i for i,ch in enumerate(chars)}
    rows=[]
    if args.reuse_bitmap:
        ids=json.loads((ROOT/'board/sidebar_glyphs.json').read_text())
        rows=[int(row,16) for row in (ROOT/'board/sidebar_font.mem').read_text().split()]
        missing=sorted(set(chars)-ids.keys())
        if missing:
            font=ImageFont.truetype(str(args.font),15,index=2)
            for ch in missing:
                glyph_id=max(ids.values())+1
                if glyph_id>=256:raise ValueError('glyph ROM full')
                ids[ch]=glyph_id
                image=Image.new('L',(16,16),0)
                draw=ImageDraw.Draw(image)
                box=draw.textbbox((0,0),ch,font=font)
                draw.text(((16-(box[2]-box[0]))//2-box[0],(16-(box[3]-box[1]))//2-box[1]),ch,font=font,fill=255)
                rows[glyph_id*16:glyph_id*16+16]=[
                    sum((image.getpixel((x,y))>=96)<<(15-x) for x in range(16)) for y in range(16)]
    else:
        font=ImageFont.truetype(str(args.font),15,index=2)  # Noto CJK SC
        for ch in chars:
            image=Image.new('L',(16,16),0)
            draw=ImageDraw.Draw(image)
            if ch!=' ':
                box=draw.textbbox((0,0),ch,font=font)
                width=box[2]-box[0];height=box[3]-box[1]
                draw.text(((16-width)//2-box[0],(16-height)//2-box[1]),ch,font=font,fill=255)
            for y in range(16):
                rows.append(sum((image.getpixel((x,y))>=96)<<(15-x) for x in range(16)))
    rows.extend([0]*(4096-len(rows)))
    (ROOT/'board/sidebar_font.mem').write_text(''.join(f'{row:04x}\n' for row in rows))
    labels=bytearray(4096)
    for key,value in sorted(LABELS.items()):
        if not 0<=key<256 or len(value)>16:raise ValueError('label exceeds ROM address space')
        labels[key*16:key*16+16]=bytes(ids[c] for c in value).ljust(16,b'\0')
    (ROOT/'board/sidebar_labels.mem').write_text(''.join(f'{value:02x}\n' for value in labels))
    (ROOT/'board/sidebar_glyphs.json').write_text(json.dumps(ids,ensure_ascii=False,indent=2)+'\n')
    lines=['// Generated glyph constants; label text lives in sidebar_labels.mem.',
           '// Bitmap source: Noto Sans CJK SC (OFL-1.1).',
           'package sidebar_font_pkg;',
           '    function automatic logic[7:0] digit_glyph(input logic[3:0] digit);','        case(digit)']
    for n in range(10):lines.append(f"            4'd{n}:digit_glyph=8'd{ids[str(n)]};")
    lines+=['            default:digit_glyph=0;','        endcase','    endfunction']
    for name,char in [('PERCENT','%'),('HASH','#'),('LEFT','<'),('RIGHT','>')]:
        lines.append(f"    localparam logic[7:0] GLYPH_{name}=8'd{ids[char]};")
    lines+=['endpackage','']
    (ROOT/'src/ui/sidebar_font_pkg.sv').write_text('\n'.join(lines))
    print(f'{len(chars)} glyphs, {len(rows)} rows')


if __name__=='__main__': main()

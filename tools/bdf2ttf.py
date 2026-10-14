#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bdf2ttf.py -- 把 BDF 位图字体转成 Aseprite 能用的 TTF

为什么需要它：Aseprite 的字体加载器（laf/text）只支持 spritesheet / truetype / system，
BDF 用不了（见 src/app/ui/skin/skin_theme.cpp 里 type= 的取值）。

做法：每个点亮的像素转成一个方形轮廓；同一行里连续的像素合并成一个矩形，
再把上下相同的矩形纵向合并（减少轮廓数、避免内部接缝）。
坐标系：unitsPerEm=1000，1 个设计像素 = 100 单位，所以 10px 字体正好 10*100=1000。

用法：
  python tools/bdf2ttf.py <bdf1> [bdf2 ...] -o out.ttf [--family "名字"]

多个 BDF 会按码位合并成一个 TTF（字体回退只查第一层，所以只能用一个文件，
合并后覆盖最全）。优先级按命令行顺序，前面的赢。
"""

import argparse
import os
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPEM = 1000
PX = UPEM // 10  # 1 个设计像素 = 100 单位（10px 设计尺寸）


def parse_bdf(path):
    """解析 BDF，返回 (font_meta, glyphs)；glyphs: {codepoint: {w,h,xoff,yoff,rows}}"""
    meta = {}
    glyphs = {}
    cur = None
    rows = []
    reading_bitmap = False

    with open(path, 'r', encoding='latin-1') as f:
        for raw in f:
            line = raw.rstrip('\r\n')
            if reading_bitmap:
                if line.startswith('ENDCHAR'):
                    reading_bitmap = False
                    if cur is not None and cur.get('encoding') is not None:
                        cur['rows'] = rows
                        glyphs.setdefault(cur['encoding'], cur)
                    cur, rows = None, []
                else:
                    rows.append(line)
                continue

            if line.startswith('STARTCHAR'):
                cur = {'name': line.split(None, 1)[1] if len(line.split(None, 1)) > 1 else 'g'}
            elif line.startswith('ENCODING'):
                if cur is not None:
                    cur['encoding'] = int(line.split()[1])
            elif line.startswith('SWIDTH'):
                if cur is not None:
                    cur['swidth'] = float(line.split()[1])
            elif line.startswith('DWIDTH'):
                if cur is not None:
                    cur['dwidth'] = float(line.split()[1])
            elif line.startswith('BBX'):
                if cur is not None:
                    p = line.split()
                    cur['w'], cur['h'], cur['xoff'], cur['yoff'] = (
                        int(p[1]), int(p[2]), int(p[3]), int(p[4]))
            elif line.startswith('BITMAP'):
                reading_bitmap = True
                rows = []
            elif line.startswith('FONTBOUNDINGBOX'):
                p = line.split()
                meta['bbox'] = tuple(int(v) for v in p[1:5])
            elif line.startswith('FONT_ASCENT'):
                meta['ascent'] = int(line.split()[1])
            elif line.startswith('FONT_DESCENT'):
                meta['descent'] = int(line.split()[1])
            elif line.startswith('FAMILY_NAME'):
                meta['family'] = line.split(None, 1)[1].strip('"')

    return meta, glyphs


def bitmap_rows_to_pixels(g):
    """把 BDF 的十六进制位图行转成 {row: set(col)}，row 0 = 最上面一行"""
    w, h = g['w'], g['h']
    if w <= 0 or h <= 0 or not g.get('rows'):
        return []
    row_bytes = (w + 7) // 8
    out = []
    for i in range(h):
        if i >= len(g['rows']):
            out.append(set())
            continue
        hexs = g['rows'][i].strip()
        val = int(hexs, 16) if hexs else 0
        bits = bin(val)[2:].zfill(row_bytes * 8)
        out.append({c for c in range(w) if bits[c] == '1'})
    return out


def pixels_to_rects(pix_rows):
    """把逐行像素合并成矩形：先按行合并连续段，再纵向合并相同的段"""
    rects = []
    prev = {}  # 段(x0,x1) -> 该段开始的起始行（用于纵向延伸）
    open_runs = {}  # (x0,x1) -> start_row

    def runs_of(rowset):
        runs = []
        s = None
        for c in sorted(rowset):
            if s is None:
                s = c
            elif c != prev_c + 1:
                runs.append((s, prev_c))
                s = c
            prev_c = c
        if s is not None:
            runs.append((s, prev_c))
        return runs

    for r, rowset in enumerate(pix_rows):
        cur_runs = set(runs_of(rowset))
        # 已经不在当前行的段：收尾
        for run in list(open_runs.keys()):
            if run not in cur_runs:
                rects.append((run[0], run[1], open_runs[run], r - 1))
                del open_runs[run]
        for run in cur_runs:
            if run not in open_runs:
                open_runs[run] = r
    for run, start in open_runs.items():
        rects.append((run[0], run[1], start, len(pix_rows) - 1))
    return rects


def build_glyph(g):
    """BDF 字形 -> TTF 轮廓。返回 (glyph, advance_width_units)"""
    w, h, xoff, yoff = g.get('w', 0), g.get('h', 0), g.get('xoff', 0), g.get('yoff', 0)
    advance = int(round(g.get('swidth', g.get('dwidth', 0) * 100)))

    pen = TTGlyphPen(None)
    pix_rows = bitmap_rows_to_pixels(g)
    for (x0, x1, r_top, r_bot) in pixels_to_rects(pix_rows):
        # 行号 -> 基线以上像素坐标：BBX 的 yoff 是位图底边相对基线的偏移
        y_bottom = yoff + (h - 1 - r_bot)
        y_top = yoff + (h - 1 - r_top) + 1
        X0, X1 = (xoff + x0) * PX, (xoff + x1 + 1) * PX
        Y0, Y1 = y_bottom * PX, y_top * PX
        pen.moveTo((X0, Y0))
        pen.lineTo((X1, Y0))
        pen.lineTo((X1, Y1))
        pen.lineTo((X0, Y1))
        pen.closePath()
    return pen.glyph(), advance


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inputs', nargs='+')
    ap.add_argument('-o', '--out', required=True)
    ap.add_argument('--family', default='Fusion Pixel 10px')
    ap.add_argument('--style', default='Regular')
    args = ap.parse_args()

    merged = {}
    metas = []
    for path in args.inputs:
        meta, glyphs = parse_bdf(path)
        metas.append(meta)
        added = 0
        for cp, g in glyphs.items():
            if cp not in merged:
                merged[cp] = g
                added += 1
        print(f"  {os.path.basename(path)}: {len(glyphs)} 字形, 新增 {added}")

    # .notdef：用 65534 那个，或者造一个空的
    notdef = merged.pop(65534, None)
    codes = sorted(cp for cp in merged.keys() if 0 < cp <= 0xFFFF)

    glyph_order = ['.notdef']
    glyphs_tt = {}
    metrics = {}
    cmap = {}

    if notdef is not None:
        g, adv = build_glyph(notdef)
    else:
        g, adv = TTGlyphPen(None).glyph(), UPEM // 2
    glyphs_tt['.notdef'] = g
    metrics['.notdef'] = (adv, 0)

    for cp in codes:
        name = f"uni{cp:04X}"
        g, adv = build_glyph(merged[cp])
        glyph_order.append(name)
        glyphs_tt[name] = g
        metrics[name] = (adv, 0)
        cmap[cp] = name

    ascent = metas[0].get('ascent', 9) * PX
    descent = -metas[0].get('descent', 1) * PX

    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs_tt)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ascent, descent=descent, lineGap=0)
    fb.setupNameTable({
        'familyName': args.family,
        'styleName': args.style,
        'uniqueFontIdentifier': f"{args.family} {args.style} (bdf2ttf)",
        'fullName': f"{args.family} {args.style}",
        'psName': args.family.replace(' ', '') + '-' + args.style,
        'version': 'Version 1.0',
    })
    fb.setupOS2(sTypoAscender=ascent, sTypoDescender=descent,
                usWinAscent=ascent, usWinDescent=-descent)
    fb.setupPost()
    # gasp：告诉渲染器不要抗锯齿（位图字体转过来的，抗锯齿只会糊）。
    # 只保留 GASP_GRIDFIT(1)，不设 GASP_DOGRAY(2)。
    from fontTools.ttLib import newTable
    gasp = newTable('gasp')
    gasp.version = 1
    gasp.gaspRange = {0xFFFF: 0x0001}
    fb.font['gasp'] = gasp
    fb.save(args.out)

    print(f"  写出 {args.out}")
    print(f"  字形 {len(glyph_order)} 个，码位 {len(cmap)} 个，"
          f"ascent={ascent} descent={descent} UPEM={UPEM}")


if __name__ == '__main__':
    main()

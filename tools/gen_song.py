#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_song.py -- 生成 viz_led.v 曲目指引用的曲谱 hex (rtl/rom/song_demo.hex)

曲谱格式 (每行 16bit hex, 供 $readmemh 读入):
    word = {gate[15], note[14:8], dur[7:0]}
      gate: 1=发声条目, 0=休止
      note: MIDI 音号 0..127 (0=休止时无所谓)
      dur : 时长, 单位=拍 (viz_led 的 BEAT_CLKS 决定一拍多久)
    word == 0x0000 表示曲终 (viz_led 停在指引外; SONG_LOOP=1 时回卷循环)

旋律记法: 空格分隔的 token, 每个 "音名:拍数"
    音名: C4 / A#3 / Db5 (升降号 # 或 b) 或直接 MIDI 数字 (60)
    休止: R 或 r
例: --melody "C4:1 C4:1 G4:1 R:1 60:2"

用法:
    .venv\\Scripts\\python.exe tools\\gen_song.py                      # 内置演示曲
    .venv\\Scripts\\python.exe tools\\gen_song.py --melody "C4:1 E4:1 G4:2" --out rtl\\rom\\my_song.hex
"""
import argparse
import os
import re
import sys

# 音名 -> 半音偏移 (C=0)
PITCH = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}

TOK_RE = re.compile(r'^([A-G])([#b]?)(-?\d+)$')

# 内置演示曲: 小星星前两句 (C4 起两个八度窗口内, 每颗灯一个半音)
DEMO = ('C4:1 C4:1 G4:1 G4:1 A4:1 A4:1 G4:2 '
        'F4:1 F4:1 E4:1 E4:1 D4:1 D4:1 C4:2')


def parse_note(tok):
    """'C4'/'A#3'/'Db5'/'60' -> MIDI 音号; 'R' -> None (休止)"""
    if tok.upper() == 'R':
        return None
    if tok.isdigit():
        n = int(tok)
        if not 0 <= n <= 127:
            raise ValueError(f'MIDI 音号超范围: {tok}')
        return n
    m = TOK_RE.match(tok)
    if not m:
        raise ValueError(f'看不懂的音名: {tok}')
    name, acc, octv = m.group(1), m.group(2), int(m.group(3))
    semi = PITCH[name] + (1 if acc == '#' else -1 if acc == 'b' else 0)
    n = (octv + 1) * 12 + semi          # MIDI: C4=60 → (4+1)*12+0
    if not 0 <= n <= 127:
        raise ValueError(f'MIDI 音号超范围: {tok} -> {n}')
    return n


def build_words(melody):
    """旋律字符串 -> [word, ...] (不含曲终符)"""
    words = []
    for tok in melody.split():
        if ':' not in tok:
            raise ValueError(f'缺拍数(应为 音名:拍数): {tok}')
        name, dur = tok.rsplit(':', 1)
        dur = int(dur)
        if not 1 <= dur <= 255:
            raise ValueError(f'拍数超范围(1..255): {tok}')
        n = parse_note(name)
        gate = 0 if n is None else 1
        note = 0 if n is None else n
        words.append((gate << 15) | (note << 8) | dur)
    return words


def main():
    ap = argparse.ArgumentParser(description='viz_led 曲谱 hex 生成器')
    ap.add_argument('--melody', default=DEMO, help='旋律: "C4:1 C4:1 G4:2 R:1 ..."')
    ap.add_argument('--out', default=os.path.join('rtl', 'rom', 'song_demo.hex'))
    ap.add_argument('--verify', action='store_true',
                    help='只校验 --out 与 --melody 一致, 不写文件')
    args = ap.parse_args()

    words = build_words(args.melody)
    lines = ['%04X' % w for w in words] + ['0000']      # 尾部曲终符

    if args.verify:
        with open(args.out, 'r', encoding='ascii') as f:
            old = [ln.strip() for ln in f if ln.strip() and not ln.strip().startswith('//')]
        ok = (old == lines)
        print('VERIFY %s: %s' % (args.out, '一致' if ok else '不一致!\n  旧=%s\n  新=%s' % (old, lines)))
        return 0 if ok else 1

    os.makedirs(os.path.dirname(args.out) or '.', exist_ok=True)
    with open(args.out, 'w', encoding='ascii', newline='\n') as f:
        # hex 必须纯 ASCII (与 rtl/rom 其它 hex 一致, ModelSim 对非 ASCII 敏感)
        f.write('// viz_led song (tools/gen_song.py): word={gate,note[6:0],dur[7:0]}\n')
        f.write('// %d entries + end mark; melody: %s\n' % (len(words), args.melody))
        f.write('\n'.join(lines) + '\n')

    print('OK: %s (%d 条目 + 曲终符)' % (args.out, len(words)))
    # 自检: 与 NPIX=24 / NOTE_BASE=60 的窗口对一下, 提醒超窗音符
    lo, hi = 60, 60 + 24
    out = [w for w in words if (w >> 15) and not (lo <= ((w >> 8) & 0x7F) < hi)]
    if out:
        print('提示: %d 个发声音符在 24 灯窗口(C4..B5)外, 播放时不亮指引灯: %s'
              % (len(out), [hex(w) for w in out]))
    return 0


if __name__ == '__main__':
    sys.exit(main())

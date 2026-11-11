#!/usr/bin/env python3
"""Sample worksheets for the study mode (#86): data + printable A4 sheets.

    python3 tools/build_worksheets.py          # writes config/worksheets.json and docs/worksheets/
    python3 tools/build_worksheets.py --check  # exit 1 when the files are out of date (tests / CI)

One worksheet per grade (12 grades: 保育園 年少 .. 中学 3 年), always 3 problems:
1 and 2 easy, 3 a challenge (the HELP target). Nursery sheets use counts, shapes and
pictures (no reading needed); from 小 1 up, arithmetic / mathematics of that grade.

Coordinates are millimetres on the A4 page (210 x 297), origin top-left, x right, y down.
Four corner marks (fiducials) let the overview image <-> paper mapping be computed:
their centres are in `fiducials`, so a homography from the 4 marks found in a camera
image maps every region (problem, answer box) into that image. Standard library only.
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_PATH = ROOT / "config" / "worksheets.json"
SVG_DIR = ROOT / "docs" / "worksheets"

PAPER = (210.0, 297.0)
FIDUCIAL_SIZE = 12.0
FIDUCIALS = {"tl": (14.0, 14.0), "tr": (196.0, 14.0), "bl": (14.0, 283.0), "br": (196.0, 283.0)}
PROBLEM_TOP = 52.0
PROBLEM_PITCH = 76.0
PROBLEM_H = 70.0
X0, X1 = 20.0, 190.0
ANSWER_BOX = (135.0, 30.0, 185.0, 62.0)  # x0, dy0, x1, dy1 inside a problem
FONT = "'Hiragino Maru Gothic ProN', 'BIZ UDPGothic', 'Noto Sans JP', sans-serif"

GRADES = [
    ("nursery_1", "保育園 年少", "picture"), ("nursery_2", "保育園 年中", "picture"),
    ("nursery_3", "保育園 年長", "picture"),
    ("elem_1", "小学1年", "text"), ("elem_2", "小学2年", "text"), ("elem_3", "小学3年", "text"),
    ("elem_4", "小学4年", "text"), ("elem_5", "小学5年", "text"), ("elem_6", "小学6年", "text"),
    ("jhs_1", "中学1年", "text"), ("jhs_2", "中学2年", "text"), ("jhs_3", "中学3年", "text"),
]


def p(prompt, answer, solution, hints, description_en, figure=None, answer_area="box"):
    return {"prompt": prompt, "answer": answer, "solution": solution, "hints": hints,
            "description_en": description_en, "figure": figure, "answer_area": answer_area}


# grade -> (title, [problem 1, problem 2, problem 3 (challenge)])
CONTENT = {
    "nursery_1": ("かぞえてみよう", [
        p("りんご は いくつ かな？ かずだけ ○ を ぬろう", "3", "りんごを 1つずつ ゆびで さして かぞえると 3つ。",
          ["りんごを ゆびで さしてみよう", "ひとつ、ふたつ…と こえに だして かぞえよう", "さいごに いった かずが こたえだよ"],
          "problem 1: count the apples and fill in that many circles",
          {"type": "count", "shape": "apple", "count": 3}, "figure"),
        p("まる（○）は どれかな？ ゆびで さして ○ を つけよう", "まる", "かどが ない かたちが まる。",
          ["かどが とがっている かたちは どれかな", "ころころ ころがりそうな かたちを さがそう", "かどが ない のが まるだよ"],
          "problem 2: circle the round shape among a circle, a triangle and a square",
          {"type": "choices", "shapes": ["triangle", "circle", "square"]}, "figure"),
        p("ほし が いちばん おおい のは どれ？ ○ を つけよう", "まんなか（4こ）",
          "それぞれ かぞえると 2こ・4こ・3こ。いちばん おおいのは まんなかの 4こ。",
          ["ひとつの グループずつ かぞえてみよう", "かぞえた かずを おぼえて くらべよう", "いちばん たくさん かぞえた グループは どれかな"],
          "problem 3: circle the group with the most stars (groups of 2, 4 and 3 stars)",
          {"type": "groups", "shape": "star", "counts": [2, 4, 3]}, "figure"),
    ]),
    "nursery_2": ("かたちと かず", [
        p("ほし は いくつ かな？ かずだけ ○ を ぬろう", "5", "ほしを ひとつずつ かぞえると 5こ。",
          ["ほしを ゆびで さしてみよう", "かぞえた ほしには しるしを つけよう", "ぜんぶで いくつ だったかな"],
          "problem 1: count the stars and fill in that many circles",
          {"type": "count", "shape": "star", "count": 5}, "figure"),
        p("さんかく（△）は いくつ あるかな？", "2", "かどが 3つ ある かたちを かぞえると 2こ。",
          ["かどが 3つ ある かたちを さがそう", "みつけたら ゆびで さそう", "さんかくだけ かぞえよう"],
          "problem 2: count the triangles among the shapes",
          {"type": "choices", "shapes": ["triangle", "circle", "triangle", "square"]}, "figure"),
        p("つぎに くる かたちは どれ？ ? の ところに かこう", "さんかく",
          "まる・さんかく・まる・さんかく… と じゅんばんに ならんでいるので、つぎは さんかく。",
          ["かたちを ひだりから じゅんばんに いってみよう", "おなじ ならびが くりかえして いないかな", "まるの つぎは なにが きていたかな"],
          "problem 3: draw the next shape in the repeating pattern circle, triangle, circle, triangle, circle, ?",
          {"type": "pattern", "shapes": ["circle", "triangle", "circle", "triangle", "circle", "?"]}, "figure"),
    ]),
    "nursery_3": ("かずの おけいこ", [
        p("あわせて いくつ？ □に かずを かこう", "3", "2こ と 1こ を あわせると 3こ。",
          ["ひだりの まるを かぞえよう", "みぎの まるも かぞえよう", "ぜんぶ まとめて かぞえよう"],
          "problem 1: how many dots in all (2 dots and 1 dot)",
          {"type": "sum", "shape": "circle", "a": 2, "b": 1}),
        p("りんご は いくつ？ □に かずを かこう", "8", "ひとつずつ かぞえると 8こ。",
          ["5こ まで かぞえたら ひと やすみ", "5の つぎは 6、7、8…", "さいごの かずを かこう"],
          "problem 2: count the apples and write the number",
          {"type": "count", "shape": "apple", "count": 8}),
        p("5 は 3 と いくつ？ □に かずを かこう", "2", "5こ の うち 3こ を かくすと のこりは 2こ。",
          ["まるを 5こ かいてみよう", "そのうち 3こ に ×を つけよう", "×が ついていない まるは いくつかな"],
          "problem 3: 5 is 3 and how many (number composition)",
          {"type": "split", "shape": "circle", "total": 5, "known": 3}),
    ]),
    "elem_1": ("たしざん・ひきざん", [
        p("3 + 4 =", "7", "3 から 4 つ ふやすと 4、5、6、7。こたえは 7。",
          ["3 から かぞえて いこう", "ゆびを 4ほん つかって ふやそう", "3、4、5、6、7…"],
          "problem 1: 3 + 4"),
        p("9 − 5 =", "4", "9 から 5 を とると 4。",
          ["9 この まるを かんがえよう", "5 こ けすと いくつ のこるかな", "9 は 5 と いくつ かな"],
          "problem 2: 9 - 5"),
        p("はとが 8わ います。3わ とんで いき、2わ きました。はとは いま なんわ？", "7わ",
          "8 − 3 = 5、5 + 2 = 7 で 7わ。",
          ["さいしょに なんわ いたかな", "とんで いくと へる、くると ふえるよ", "じゅんばんに けいさん してみよう"],
          "problem 3: word problem about pigeons (8, 3 fly away, 2 come)"),
    ]),
    "elem_2": ("2けたの けいさんと かけざん", [
        p("23 + 45 =", "68", "一のくらい 3+5=8、十のくらい 2+4=6 で 68。",
          ["一のくらい どうしを たそう", "十のくらい どうしを たそう", "ふたつを ならべて かこう"],
          "problem 1: 23 + 45"),
        p("7 × 6 =", "42", "7のだん: 7、14、21、28、35、42。",
          ["7のだんを となえてみよう", "7 × 5 = 35 だったね", "35 に もう 7 を たそう"],
          "problem 2: 7 x 6"),
        p("1こ 8円の あめを 6こ と、50円の ガムを 1こ かいます。100円で かえますか。のこりは なん円？",
          "かえる。のこり 2円", "8 × 6 = 48円、48 + 50 = 98円。100 − 98 = 2円 のこる。",
          ["まず あめ ぜんぶの ねだんを もとめよう", "つぎに ガムの ねだんを たそう", "100円から ひいて のこりを もとめよう"],
          "problem 3: word problem about candy and gum with 100 yen"),
    ]),
    "elem_3": ("大きい数と わり算", [
        p("365 + 478 =", "843", "くり上がりに 気をつけて 一のくらいから 計算する。",
          ["一のくらい 5 + 8 = 13、1 くり上がる", "十のくらい 6 + 7 + 1", "百のくらいも くり上がりに 注意"],
          "problem 1: 365 + 478"),
        p("56 ÷ 7 =", "8", "7 × 8 = 56 なので 8。",
          ["7のだんで 56 に なるのは？", "7 × 8 を 思い出そう", "わり算は かけ算の ぎゃく"],
          "problem 2: 56 / 7"),
        p("45cm の テープを 4本 つなぎます。つなぎめは 3cm ずつ かさねます。ぜんぶで 何cm？", "171cm",
          "45 × 4 = 180cm。つなぎめは 3か所 なので 3 × 3 = 9cm へる。180 − 9 = 171cm。",
          ["4本 ならべた 長さを まず 考えよう", "つなぎめは 何か所 できるかな（図を かこう）", "かさなった ぶんだけ 短く なるよ"],
          "problem 3: word problem about joining four 45 cm tapes overlapping 3 cm"),
    ]),
    "elem_4": ("大きな数の かけ算・わり算", [
        p("312 × 24 =", "7488", "312 × 4 = 1248、312 × 20 = 6240、合わせて 7488。",
          ["312 × 4 を 計算しよう", "312 × 20 も 計算しよう", "2つを たそう"],
          "problem 1: 312 x 24"),
        p("864 ÷ 6 =", "144", "8 ÷ 6 = 1 あまり 2、26 ÷ 6 = 4 あまり 2、24 ÷ 6 = 4 で 144。",
          ["上の くらいから じゅんに わろう", "あまりは 次の くらいに おろそう", "答えに 6 を かけて たしかめよう"],
          "problem 2: 864 / 6"),
        p("長さ 48m の 道の 片側に、はしから はしまで 6m おきに 木を 植えます（両はしにも 植える）。木は 何本？",
          "9本", "48 ÷ 6 = 8 で 間は 8つ。両はしに 植えるので 木は 8 + 1 = 9本。",
          ["まず 間が いくつ あるか 考えよう", "短い 道（例えば 12m）で 図を かいて みよう", "木の 数と 間の 数は 同じかな？"],
          "problem 3: tree planting problem, 48 m road every 6 m including both ends"),
    ]),
    "elem_5": ("小数・分数", [
        p("2.4 × 3.5 =", "8.4", "24 × 35 = 840。小数点以下は 2けた なので 8.40 = 8.4。",
          ["小数点を ないものと して 計算しよう", "24 × 35 は？", "小数点の 位置を もどそう"],
          "problem 1: 2.4 x 3.5"),
        p("3/4 + 1/6 =", "11/12", "通分すると 9/12 + 2/12 = 11/12。",
          ["分母を そろえよう", "4 と 6 の 最小公倍数は？", "分子どうしを たそう"],
          "problem 2: 3/4 + 1/6"),
        p("時速 4.5km で 40分 歩くと、何km 進みますか。", "3km",
          "40分 = 40/60 時間 = 2/3 時間。4.5 × 2/3 = 3km。",
          ["時速は 1時間に 進む 道のり", "40分は 何時間かな（分数で）", "道のり = 速さ × 時間"],
          "problem 3: speed problem, 4.5 km per hour for 40 minutes"),
    ]),
    "elem_6": ("分数の かけ算・わり算と 比", [
        p("2/3 × 9/10 =", "3/5", "約分して (2 × 9)/(3 × 10) = 18/30 = 3/5。",
          ["分子どうし、分母どうしを かけよう", "とちゅうで 約分すると 楽", "答えも 約分しよう"],
          "problem 1: 2/3 x 9/10"),
        p("3/8 ÷ 9/4 =", "1/6", "わる数を 逆数に して 3/8 × 4/9 = 12/72 = 1/6。",
          ["わり算は 逆数の かけ算に なおそう", "9/4 の 逆数は？", "約分を わすれずに"],
          "problem 2: 3/8 / 9/4"),
        p("A と B の 比は 3 : 5 です。合計が 64 の とき、B は いくつ？", "40",
          "全体は 3 + 5 = 8 つ分。1つ分は 64 ÷ 8 = 8。B は 5つ分で 40。",
          ["全体は 何こ分かな", "1こ分は いくつ？", "B は 何こ分？"],
          "problem 3: ratio problem, A:B = 3:5 and A + B = 64"),
    ]),
    "jhs_1": ("正負の数と 方程式", [
        p("(−7) + 12 =", "5", "12 − 7 = 5。",
          ["数直線で −7 から 右へ 12 進もう", "符号の ちがう 数の たし算は 差を 考える", "絶対値の 大きい ほうの 符号に なる"],
          "problem 1: (-7) + 12"),
        p("3x − 5 = 16 を 解きなさい。", "x = 7", "3x = 21、x = 7。",
          ["−5 を 右辺に 移項しよう", "3x = 21 に なったら？", "両辺を 3 で わろう"],
          "problem 2: solve 3x - 5 = 16"),
        p("連続する 3つの 整数の 和が 72 です。いちばん 大きい 数を 求めなさい。", "25",
          "まん中を x と すると (x−1) + x + (x+1) = 3x = 72、x = 24。いちばん 大きい 数は 25。",
          ["3つの 数を 文字で 表して みよう", "まん中の 数を x に すると 楽", "式を 立てて 解こう"],
          "problem 3: three consecutive integers sum to 72, find the largest"),
    ]),
    "jhs_2": ("式の 計算と 連立方程式", [
        p("(3a + 2b) − (a − 4b) を 計算しなさい。", "2a + 6b", "かっこを はずすと 3a + 2b − a + 4b = 2a + 6b。",
          ["−( ) を はずすと 符号は どうなる？", "同類項を まとめよう", "a と b を 別々に 計算"],
          "problem 1: simplify (3a + 2b) - (a - 4b)"),
        p("x + y = 10、x − y = 4 を 解きなさい。", "x = 7、y = 3", "2式を たすと 2x = 14、x = 7、y = 3。",
          ["2つの 式を たすと どうなる？", "y が 消えたら x を 求めよう", "x を 代入して y を 求めよう"],
          "problem 2: solve x + y = 10 and x - y = 4"),
        p("2点 (1, 3)、(3, 7) を 通る 直線の 式を 求めなさい。", "y = 2x + 1",
          "傾きは (7 − 3) ÷ (3 − 1) = 2。y = 2x + b に (1, 3) を 代入して b = 1。",
          ["まず 傾きを 求めよう（y の 増加量 ÷ x の 増加量）", "y = ax + b の a が わかったら？", "1点を 代入して b を 求めよう"],
          "problem 3: line through (1, 3) and (3, 7)"),
    ]),
    "jhs_3": ("展開・平方根・2次方程式", [
        p("(x + 3)(x − 5) を 展開しなさい。", "x² − 2x − 15", "x² + (3 − 5)x + 3 × (−5) = x² − 2x − 15。",
          ["(x + a)(x + b) の 公式を 思い出そう", "a + b と ab を 求めよう", "順番に ならべよう"],
          "problem 1: expand (x + 3)(x - 5)"),
        p("√12 × √3 を 計算しなさい。", "6", "√12 × √3 = √36 = 6。",
          ["根号の 中どうしを かけられるよ", "√36 は？", "答えは 整数に なる"],
          "problem 2: sqrt(12) x sqrt(3)"),
        p("連続する 2つの 正の 整数の 積が 56 です。小さい ほうの 数を 求めなさい。", "7",
          "小さい 数を x と すると x(x + 1) = 56、x² + x − 56 = 0、(x + 8)(x − 7) = 0。正の 数なので x = 7。",
          ["小さい ほうを x と おいて みよう", "大きい ほうは どう 表せる？", "2次方程式を 解いて、問題に 合う 答えを 選ぼう"],
          "problem 3: two consecutive positive integers with product 56, find the smaller"),
    ]),
}


def build() -> dict:
    sheets = []
    for order, (grade, label, reading) in enumerate(GRADES):
        title, problems = CONTENT[grade]
        assert len(problems) == 3, grade
        out = []
        for i, prob in enumerate(problems):
            n = i + 1
            y0 = PROBLEM_TOP + PROBLEM_PITCH * i
            region = [X0, y0, X1, y0 + PROBLEM_H]
            if prob["answer_area"] == "figure":
                box = [X0 + 4.0, y0 + 18.0, X1 - 4.0, y0 + PROBLEM_H - 4.0]
            else:
                box = [ANSWER_BOX[0], y0 + ANSWER_BOX[1], ANSWER_BOX[2], y0 + ANSWER_BOX[3]]
            out.append({
                "number": n, "difficulty": "challenge" if n == 3 else "easy",
                "prompt": prob["prompt"], "answer": prob["answer"], "solution": prob["solution"],
                "hints": prob["hints"], "description_en": prob["description_en"], "figure": prob["figure"],
                "region_mm": region, "answer_box_mm": box,
            })
        sheets.append({"worksheet_id": f"mon-{grade}-01", "grade": grade, "grade_label": label,
                       "grade_order": order, "reading": reading, "title": title, "weekday": "monday",
                       "help_problem": 3, "problems": out})
    return {
        "_note": "Generated by tools/build_worksheets.py (edit the script, not this file). Millimetres on the A4 "
                 "page, origin top-left, x right, y down. fiducials = the centres of the 4 corner marks: a "
                 "homography from them (found in a camera image) maps region_mm / answer_box_mm into that image. "
                 "help_problem = the problem HELP looks at (the challenge).",
        "format_version": 1,
        "paper_mm": list(PAPER),
        "fiducials": {k: {"center_mm": list(v), "size_mm": FIDUCIAL_SIZE} for k, v in FIDUCIALS.items()},
        "grades": [{"id": g, "label": label, "order": i, "reading": r} for i, (g, label, r) in enumerate(GRADES)],
        "worksheets": sheets,
    }


# ------------------------------------------------------------------ printable SVG
def _t(x, y, text, size=5.0, weight="normal", anchor="start", fill="#222"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" '
            f'fill="{fill}">{html.escape(text)}</text>')


def _shape(kind: str, cx: float, cy: float, r: float) -> str:
    if kind == "circle":
        return f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="none" stroke="#222" stroke-width="0.8"/>'
    if kind == "square":
        return (f'<rect x="{cx - r:.1f}" y="{cy - r:.1f}" width="{2 * r:.1f}" height="{2 * r:.1f}" fill="none" '
                f'stroke="#222" stroke-width="0.8"/>')
    if kind == "triangle":
        pts = f"{cx:.1f},{cy - r:.1f} {cx - r:.1f},{cy + r * 0.8:.1f} {cx + r:.1f},{cy + r * 0.8:.1f}"
        return f'<polygon points="{pts}" fill="none" stroke="#222" stroke-width="0.8"/>'
    if kind == "star":
        import math
        pts = []
        for k in range(10):
            rr = r if k % 2 == 0 else r * 0.45
            a = -math.pi / 2 + k * math.pi / 5
            pts.append(f"{cx + rr * math.cos(a):.1f},{cy + rr * math.sin(a):.1f}")
        return f'<polygon points="{" ".join(pts)}" fill="#f6c945" stroke="#222" stroke-width="0.6"/>'
    if kind == "apple":
        return (f'<circle cx="{cx:.1f}" cy="{cy + r * 0.1:.1f}" r="{r * 0.85:.1f}" fill="#e85a4f" stroke="#222" '
                f'stroke-width="0.6"/><line x1="{cx:.1f}" y1="{cy - r * 0.7:.1f}" x2="{cx + r * 0.2:.1f}" '
                f'y2="{cy - r:.1f}" stroke="#5a3" stroke-width="0.9"/>')
    if kind == "?":
        return _t(cx, cy + r * 0.6, "?", size=r * 2.0, weight="bold", anchor="middle")
    return ""


def _figure(fig: dict, x: float, y: float, w: float, h: float) -> list[str]:
    out = []
    t = fig["type"]
    cy = y + h / 2
    if t == "count":
        n = fig["count"]
        step = min(w / (n + 1), 18.0)
        for k in range(n):
            out.append(_shape(fig["shape"], x + step * (k + 1), cy - 6, 5.5))
        for k in range(10):  # circles to fill in
            out.append(f'<circle cx="{x + 8 + k * 11:.1f}" cy="{cy + 12:.1f}" r="3.6" fill="none" '
                       f'stroke="#888" stroke-width="0.6"/>')
    elif t in ("choices", "pattern"):
        shapes = fig["shapes"]
        step = w / (len(shapes) + 1)
        for k, s in enumerate(shapes):
            out.append(_shape(s, x + step * (k + 1), cy, 7.0))
    elif t == "groups":
        gw = w / len(fig["counts"])
        for g, n in enumerate(fig["counts"]):
            gx = x + gw * g
            out.append(f'<rect x="{gx + 3:.1f}" y="{y + 2:.1f}" width="{gw - 6:.1f}" height="{h - 4:.1f}" rx="4" '
                       f'fill="none" stroke="#aaa" stroke-width="0.5"/>')
            for k in range(n):
                out.append(_shape(fig["shape"], gx + 12 + (k % 3) * 13, y + 14 + (k // 3) * 14, 5.0))
    elif t == "sum":
        for k in range(fig["a"]):
            out.append(_shape(fig["shape"], x + 10 + k * 12, cy, 4.5))
        out.append(_t(x + 16 + fig["a"] * 12, cy + 3, "と", 7))
        for k in range(fig["b"]):
            out.append(_shape(fig["shape"], x + 36 + fig["a"] * 12 + k * 12, cy, 4.5))
    elif t == "split":
        for k in range(fig["total"]):
            out.append(_shape(fig["shape"], x + 10 + k * 12, cy, 4.5))
    return out


def svg(sheet: dict) -> str:
    w, h = PAPER
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}mm" height="{h}mm" viewBox="0 0 {w} {h}" '
             f'font-family="{FONT}">', f'<rect width="{w}" height="{h}" fill="#fff"/>']
    for c in FIDUCIALS.values():
        s = FIDUCIAL_SIZE
        parts.append(f'<rect x="{c[0] - s / 2}" y="{c[1] - s / 2}" width="{s}" height="{s}" fill="#000"/>')
        parts.append(f'<rect x="{c[0] - s / 6}" y="{c[1] - s / 6}" width="{s / 3}" height="{s / 3}" fill="#fff"/>')
    parts.append(_t(28, 26, f"げつようびの しゅくだい　{sheet['grade_label']}", 6.5, "bold"))
    parts.append(_t(28, 36, sheet["title"], 5.5))
    parts.append(_t(132, 36, "なまえ", 4.5))
    parts.append('<line x1="148" y1="37" x2="186" y2="37" stroke="#222" stroke-width="0.4"/>')
    parts.append(_t(105, 292, f"{sheet['worksheet_id']}　UFOくん 勉強モード", 3.0, anchor="middle", fill="#777"))
    for prob in sheet["problems"]:
        x0, y0, x1, y1 = prob["region_mm"]
        hard = prob["difficulty"] == "challenge"
        parts.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="3" fill="none" '
                     f'stroke="{"#e07a00" if hard else "#999"}" stroke-width="{0.9 if hard else 0.4}"/>')
        parts.append(f'<circle cx="{x0 + 7}" cy="{y0 + 8}" r="5" fill="{"#e07a00" if hard else "#3b7dd8"}"/>')
        parts.append(_t(x0 + 7, y0 + 10, str(prob["number"]), 5.5, "bold", "middle", "#fff"))
        if hard:
            parts.append(_t(x0 + 6, y1 - 3, "★ チャレンジ", 4.0, "bold", "start", "#e07a00"))
        # the prompt, wrapped by hand at ~30 characters
        text = prob["prompt"]
        lines = [text[i:i + 30] for i in range(0, len(text), 30)] or [""]
        for k, line in enumerate(lines[:3]):
            parts.append(_t(x0 + 15, y0 + 10 + k * 7, line, 5.0))
        bx0, by0, bx1, by1 = prob["answer_box_mm"]
        if prob["figure"] is not None:
            fx1 = bx1 if bx0 <= x0 + 10 else bx0 - 4
            parts += _figure(prob["figure"], x0 + 6, y0 + 20, fx1 - x0 - 10, y1 - y0 - 24)
        if not (bx0 <= x0 + 10):
            parts.append(f'<rect x="{bx0}" y="{by0}" width="{bx1 - bx0}" height="{by1 - by0}" fill="none" '
                         f'stroke="#222" stroke-width="0.6"/>')
            parts.append(_t(bx0, by0 - 1.5, "こたえ", 3.2, fill="#555"))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def index_html(data: dict) -> str:
    items = "\n".join(f'<li><a href="{s["worksheet_id"]}.svg">{html.escape(s["grade_label"])}: '
                      f'{html.escape(s["title"])}</a></li>' for s in data["worksheets"])
    return ("<!doctype html>\n<meta charset=\"utf-8\">\n<title>UFOくん 勉強モード サンプルプリント</title>\n"
            "<h1>UFOくん 勉強モード サンプルプリント（A4）</h1>\n<p>各 SVG をブラウザで開き、A4・倍率 100%・余白なしで"
            "印刷してください。四隅の黒い四角は位置合わせ用の基準マークです（切らない・隠さない）。</p>\n"
            f"<ul>\n{items}\n</ul>\n")


def outputs() -> dict[Path, str]:
    data = build()
    files = {DATA_PATH: json.dumps(data, ensure_ascii=False, indent=1) + "\n",
             SVG_DIR / "index.html": index_html(data)}
    for s in data["worksheets"]:
        files[SVG_DIR / f"{s['worksheet_id']}.svg"] = svg(s)
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="exit 1 when the generated files are out of date")
    args = ap.parse_args()
    stale = []
    for path, text in outputs().items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    if stale:
        print("out of date (run python3 tools/build_worksheets.py):\n  " + "\n  ".join(stale), file=sys.stderr)
        return 1
    if not args.check:
        print(f"wrote {DATA_PATH.relative_to(ROOT)} and {SVG_DIR.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())

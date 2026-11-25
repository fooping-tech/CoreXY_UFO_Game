# タイトル画面の元の絵（#283）

Codex（codex-cli 0.154.0）の画像生成で作った元の絵。`tools/build_title_art.py` でゲームの大きさ（`game/assets/title/`）に変換する。下は Codex に渡した指示そのまま。

## bg / cow / chick / pig / sheep / bird

```text
Use your image generation tool to create pixel-art images for the title screen of a kids' crane game called "SUMMON THE UFO" (a cute blue UFO character catches capsules). Save every final image as a PNG file in the current directory with exactly the file names below. Do not write any code or touch other directories. Generate each image separately.

Shared style for all images: bright, cheerful, pop pixel art like a 16-bit console game; clean hard pixel edges, no anti-aliasing blur, no text, no watermark, limited saturated palette (sky blue, mint green, sunny yellow, pink, white), thick dark outline on characters.

1. `bg.png` — portrait 9:16 (e.g. 1024x1820 or the closest portrait size you support). A sunny daytime countryside seen from the side: bright blue sky with puffy white pixel clouds at the top, a few distant rolling green hills and a small red barn and a windmill far away, colourful flowers. The large middle area (from 35% to 85% of the height) must stay calm and simple (mostly soft sky and gentle hills, low detail) because menu cards will cover it. The bottom 12% is a flat grassy path/ground strip running across the whole width where animals will walk. Leave the top 30% mostly sky (a logo goes there). No characters, no animals, no UFO, no text.

2. Walk-cycle sprite sheets for animals that stroll across the ground. Each is ONE horizontal row of exactly 4 frames of the same animal walking to the RIGHT, side view, frames equally spaced and the same size, on a solid flat pure magenta (#FF00FF) background with no shadows, no ground and no gradients (the magenta will be keyed out). Make the animal fill most of each frame.
   - `cow.png` — a cute black-and-white dairy cow
   - `chick.png` — a round yellow chick
   - `pig.png` — a pink pig
   - `sheep.png` — a fluffy white sheep
3. `bird.png` — ONE horizontal row of exactly 4 frames of a small blue bird flying to the RIGHT (wing flap cycle), same rules: pure magenta (#FF00FF) background, equally spaced frames.

When done, list the files you saved with their pixel sizes.
```

## bg（夕暮れ）

ユーザーの希望で、上の指示で作った昼の bg.png を見本に渡して夕暮れに描き直したものを `bg.png` にしている（ロゴが映えるように）。

```text
Use your image generation tool to create `dusk.png` in the current directory: the attached pixel-art countryside background (day.png), redrawn at DUSK. Do not write code or touch other directories.

Keep the same portrait 9:16 composition, the same pixel-art style (bright 16-bit console look, hard pixel edges, no anti-aliasing), and the same elements in the same places: clouds near the top, rolling hills with a small red barn at the left and a windmill at the right low on the screen, flowers, the flat grassy path strip and brown soil at the very bottom. The big middle area stays calm and simple (menu cards will cover it).

Change only the time of day to a warm, vivid sunset dusk: the sky a smooth banded pixel gradient from deep violet/indigo at the top through magenta-pink to warm orange and golden yellow near the horizon, a large half-set pixel sun glowing just behind the hills in the middle, clouds lit pink and orange from below, a few tiny twinkling pixel stars in the darkest top part, hills and grass in warmer, slightly darker greens with orange rim light, the barn and windmill with soft warm lights in their windows. Keep it cheerful and pop, not gloomy. No characters, no animals, no UFO, no text, no watermark.

When done, report the file and its pixel size.
```

## logo

**#310 から:** `logo.png` はユーザーが用意したロゴ「UFOを召喚せよ」（2167 x 725、背景は透明。Codex で作ったものではない）。`tools/build_title_art.py` でほかの絵と同じ格子（幅 165、画面で 4 倍）に変換する。背景が透明なので緑の抜きは何もしない。半透明の光は、不透明度が半分以上のところだけ残る。

それまでの `logo.png`（「SUMMON / THE UFO」、下の指示で作ったもの）は Git の履歴にある。ユーザーが見本に出した「ネオンの文字」のロゴを、木の看板なしの文字の部分だけ、ピクセルアートで作ったもの（それより前の 2 つの案は使っていない）。

```text
Use your image generation tool to create a game title logo as PIXEL ART. Save the final image as `logo.png` in the current directory. Do not write code or touch other directories.

Design (follow closely; there is NO signboard, NO wooden board, NO frame, NO panel behind the text):
- Retro 16-bit pixel-art neon-sign style text in two lines, slanted/italic and rising slightly to the right: "SUMMON" (large) on the first line, "THE UFO" on the second line, with "UFO" the largest word.
- Letters are bold rounded blocky pixel letters with bright white cores and a neon glow drawn as stepped pixel bands (no smooth blur): hot pink / magenta glow on the left side blending into violet and electric blue on the right side.
- Above "SUMMON": a small flying saucer drawn as a neon pixel outline (an elliptical ring with a dome arc, white core with violet/blue pixel glow), with two tiny orange pixel star sparkles inside the dome.
- A neon pixel swoosh orbit line starting pink at the lower left, passing under the text and sweeping up to the upper right in blue.
- Two golden four-point pixel star sparkles at the upper left.
- Clean hard pixel edges, a visible pixel grid, limited palette, no anti-aliasing, no gradients outside the pixel bands.
- Spelling must be exactly: SUMMON / THE UFO. No other text, no watermark.

Background: solid flat pure green (#00FF00) everywhere outside the logo (it will be keyed out); no shadow, no board, no gradient. Wide composition (about 3:1), the logo filling most of the image.

If the spelling in the result is wrong, regenerate until it is correct. When done, report the file and its pixel size.
```

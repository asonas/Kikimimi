# 生成プロンプト

内蔵 imagegen を使用。両編集とも `transparent_background: true`。

## A3から耳だけを取り出す

```text
Use case: background-extraction / precise-object-edit.
Edit target: the attached approved A3 Kikimimi icon.
Create the production foreground artwork for Apple Icon Composer, with a genuine transparent alpha background.
Extract ONLY the warm ink-black rabbit-ear emblem from the supplied image. Preserve exactly the approved A3 short, broad, rounded ear silhouette, its two outward-leaning loops, their large rounded teardrop interior holes, and the shallow upward-arched bridge connecting the bases. Do NOT lengthen or reshape the ears. Preserve the original emblem scale and position in the square canvas: approximately x=20% to 79%, y=33% to 71%, horizontally centered, slightly below vertical center. Full square 1024x1024 canvas, do not tightly crop.
Remove the entire off-white rounded-square tile, outer background, shadow, bevel, texture, reflections, highlights, and lighting. Remove the off-white fill INSIDE BOTH ear loops too: those inner holes must be fully transparent, just like the outside. The ONLY opaque pixels are the rabbit-ear emblem itself.
Use a perfectly flat uniform warm ink-black #1c1917 fill, smoothly antialiased contours, no baked-in material, no shading or gloss, no edge halo, no drop shadow, no outline, no extra objects, no text. This foreground asset will have its background and material supplied separately by Icon Composer. No checkerboard painted into the image: genuine alpha transparency. Identity-preserving cutout, not a redesign.
```

## 小サイズでの視認性を調整する（最終生成）

```text
Use case: precise-object-edit. Edit target is the supplied transparent Kikimimi A3 ear emblem.
Make a restrained optical-size refinement for legibility at 16px while preserving its identity: the SAME pair of short broad softly rounded rabbit-ear loops leaning outward, joined by a shallow upward-arched bridge. NOT long upright rabbit ears; keep the low wide A3 aspect ratio.
On a square transparent canvas, enlarge the entire emblem to occupy approximately 72% of canvas width, x=14%..86%, with overall height approximately 45% of canvas, y=29%..74%. Center horizontally, visual center slightly below canvas center.
Widen the central transparent gap modestly so its narrowest part just ABOVE the bridge is 6% of canvas width. Preserve both large rounded teardrop interior holes and keep them fully transparent. The bridge should have thickness about 5% of canvas so it survives downscaling. Keep generous bold, smoothly rounded loop walls.
The mark must have a perfectly FLAT uniform solid fill #1c1917, opacity 100% in the interior. No texture, light, gradient, shading, shadow or bevel. Edges smoothly antialiased. Remove any residual texture from the input.
Outside the mark and inside both loops must be genuinely transparent alpha. No tile, no rounded-square base, no background, no painted checkerboard, no additional symbols or text. This is the foreground-only layer for Icon Composer; background and effects will be provided there. Output square 1024x1024.
```

生成結果をImageMagickで1024pxにリサイズして納品し、同じマスターから16px・32px・64pxの検証画像を作成した。

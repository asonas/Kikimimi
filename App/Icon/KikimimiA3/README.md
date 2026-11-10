# Kikimimi 耳の前景素材（垂れ耳を復元）

ユーザーが提示した参照画像に合わせ、左の耳先が外側へ垂れ、右の耳が立つ形に修正したIcon Composer用の前景素材。保存先のフォルダ名は従来のKikimimiA3を維持している。

## 納品ファイル

- `Kikimimi.icon`: Icon Composerで作成・保存した編集用ファイル。耳のPNGを内包し、生成りの単色背景、控えめな影（0.2）と透け感（0.1）を設定済み。
- `KikimimiEars.png`: 1024 × 1024 px、RGBA PNG。背景と左右の耳の内側は透過。角丸の台座、背景色、影は含まない。
- `previews/ears-16.png`、`ears-32.png`、`ears-64.png`: マスターから縮小した透過PNG。64pxは32ptの2倍解像度の参考用。
- `previews/size-check.png`: 16pxと32pxの実寸、および最近傍拡大による画素比較。生成りの背景は確認用。
- `previews/ears-on-ivory.png`: 生成りの上で見た320pxの確認画像。取り込み素材ではない。
- `drooping-ear-prompt.md`: 現在の垂れ耳版の生成プロンプト。`generation-prompts.md`は修正前の生成記録。

## デザイン

参照画像にある左耳の折れと垂れた先端、右耳の高さ、根元の緩いアーチを優先した。意匠はキャンバス幅の約68%を占める。左右対称の短い耳に変更しない。

色は墨色 `#1c1917` を指定して生成した。ラスター生成のため、実画素にはわずかな色・不透明度の揺れがある。背景色の想定は生成り `#f5f5f4`。

## Icon Composerへの引き渡し

取り込む前景素材は `KikimimiEars.png`。正方形キャンバスの透明余白も配置の一部として含む。角丸の台座と背景色、質感はIcon Composer側で設定する。

Icon ComposerでPNGを読み込み、`Kikimimi.icon`を保存済み。背景と効果の値は保存されたJSONで調整し、Icon Composerで再度開いて表示を確認した。`project.yml`でリソースとして追加し、アプリアイコン名を`Kikimimi`に設定している。Xcodeが旧OS向け画像もビルド時に生成する。従来の波形SVGとAppIcon.appiconsetは削除した。`mise run icon`はIcon Composerを開き、`mise run build`でアプリに反映する。

## 確認結果

2026-11-10にImageMagick 7.1.2-34で修正版マスターをLanczos縮小し、16px・32pxの実寸と最近傍拡大を確認した。32pxでは左耳の垂れた先端と左右の内側の抜けを確認できる。16pxでも左右の高さと形の違いが見えるが、左耳の細い輪郭の一部は半透明の画素になる。

アルファ値50%の二値化では、マスターと32pxで「つながった耳の意匠1個、内側の穴2個」を確認した。16pxは二値化すると細い部分が分断されるため、単色の二値画像としては未調整。通常のアルファ付きPNGとしての見え方を確認している。マスターの外側と左右の穴は透過。

小サイズの検証は前景PNGを対象としている。Icon Composerでは生成り背景と効果を適用したDefault表示を確認済み。Xcode 27.2で署名付きビルドとcodesign検証に成功し、生成されたCFBundleIconName、Assets.car、Kikimimi.icnsを確認した。icnsを展開して意匠も確認済み。ビルドしたアプリを起動し、録音一覧と書き起こし画面の表示を確認した。録音・書き起こし処理の再実行、旧macOS実機、Dockの表示は未確認。

# Kikimimi

オンライン面接の音声を、自分の声と相手の声を別々のトラックに分けて録音し、Mac の中で文字起こしする macOS アプリです。

- 録音と文字起こしはこの Mac の中で完結します。
- 要約を使う場合だけ、文字起こしを OpenAI に送ります。送る前に確認があります。
- 書き起こしと要約は Markdown のノートとして書き出せます。

## インストール

macOS 14 以降が必要です。

1. [最新のリリース](https://github.com/asonas/Kikimimi/releases/latest)から `Kikimimi.dmg` をダウンロードします。
2. DMG を開き、Kikimimi をアプリケーションフォルダへドラッグします。

新しいバージョンが出ると、アプリが起動中に知らせます。メニューの Kikimimi > アップデートを確認… からも確認できます。

## 開発

[mise](https://mise.jdx.dev/) と Xcode が必要です。

```bash
mise run test    # core/ のテスト
mise run build   # Debug ビルド
mise run app     # ビルドしたアプリを起動
```

リリースの手順は [docs/release.md](docs/release.md) にあります。

## ライセンス

[Apache License 2.0](LICENSE)

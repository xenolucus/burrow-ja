# Burrow JA

[Burrow](https://github.com/khan-umirzakoff/Mole-GUI) の非公式な日本語版です。Mac のクリーナー [Mole](https://github.com/tw93/Mole) を画面から操作できます。

Burrow の作者、Mole の作者、Mole for Mac とは関係ありません。問題はこのリポジトリに報告してください。

## 元の Burrow との違い

- 画面を日本語化しました。Mole が出す文章も、対訳があるものは日本語で表示します。対訳がない文章は英語のままです。
- アプリ名、bundle ID、更新先を変更し、元の Burrow と同時に入れられるようにしました。
- 同梱の `status-go` と `analyze-go` を、Mole V1.65.0 の公式リリースのバイナリに差し替えました。
- Swift 6.2.3 でビルドできるよう、1行修正しました。
- メニューバーに CPU、メモリ、ネットワークなどの値を表示できます。項目は「設定」で選びます。
- アプリから更新を確認できます。更新の前に変更内容を表示します。
- 試験的な機能として、外付けドライブの不要なシステムファイルの削除（Mole の `--external`）と、Adobe、Xcode、Steam、Unity の既知のキャッシュの削除ができます。削除は完全削除で、元に戻せません。
- 試験的な機能として、メニューバーのアプリをまとめて隠せます。まとめはページのように切り替えられ、ショートカットにも対応しています。
- 「設定」の「キャッシュを最大限に消す」で、作り直せるキャッシュの保護をまとめて外せます。iCloud やアプリの設定は保護したままです。

Mole の解析処理は元の英語のままです。削除の判断は Mole の安全確認に任せています。

## 動作環境

macOS 26 以上の Apple シリコン Mac。

## インストール

1. [Releases](https://github.com/xenolucus/burrow-ja/releases) から `BurrowJA.dmg` をダウンロードします。
2. 開いて `Burrow JA` をアプリケーションフォルダに入れます。
3. Apple の公証を受けていないため、初回は macOS に止められます。「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 「プライバシーとセキュリティ」→「フルディスクアクセス」で Burrow JA をオンにします。

ファイルを削除するアプリです。実行前に確認画面の内容を必ず読んでください。

## ビルド

Xcode Command Line Tools と Python 3 が必要です。

```bash
python3 ja/apply_ja.py
cd build-ja
scripts/bundle.sh
```

`build-ja/build/Burrow JA.app` ができます。

## 元の Burrow の更新を取り込む

`Sources/` は元のまま保ち、翻訳は `ja/` に置いています。

```bash
git fetch upstream
git merge upstream/main
python3 ja/apply_ja.py
```

`MISSING` と表示された文字列は、`ja/pairs.py` の対訳を直します。

## 自動更新の仕組み

GitHub Actions が毎日、元の Burrow と Mole の更新を確認します。更新があればビルドとテストを行い、下書きの Release を作ります。未翻訳の文字列は Issue に一覧で出ます。翻訳がなくてもアプリは英語で表示を続けます。

## ライセンス

GPL-3.0 です。元のプロジェクトと同じです。項目を隠す処理は [Ellipsis](https://github.com/ronny/ellipsis)（Apache-2.0）をもとにしています（`ja/LICENSE-Ellipsis.txt`）。

- Burrow © Khan Umirzakoff
- Mole © tw93 and contributors

元の説明は [README.upstream.md](README.upstream.md) にあります。

<div align="center">

<img src="docs/icon.png" alt="" width="112">

# Burrow JA

**Mac を画面から掃除できる、[Burrow](https://github.com/khan-umirzakoff/Mole-GUI) の非公式な日本語版**

[![最新版](https://img.shields.io/github/v/release/xenolucus/burrow-ja?label=%E6%9C%80%E6%96%B0%E7%89%88)](https://github.com/xenolucus/burrow-ja/releases/latest)
[![ダウンロード](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fxenolucus%2Fburrow-ja%2Fstats%2Fdownloads.json&label=%E3%83%80%E3%82%A6%E3%83%B3%E3%83%AD%E3%83%BC%E3%83%89)](https://github.com/xenolucus/burrow-ja/tree/stats)
[![アプリ内更新](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fxenolucus%2Fburrow-ja%2Fstats%2Fupdates.json&label=%E3%82%A2%E3%83%97%E3%83%AA%E5%86%85%E6%9B%B4%E6%96%B0)](https://github.com/xenolucus/burrow-ja/tree/stats)
[![ライセンス](https://img.shields.io/github/license/xenolucus/burrow-ja?label=%E3%83%A9%E3%82%A4%E3%82%BB%E3%83%B3%E3%82%B9)](LICENSE)
![対応 OS](https://img.shields.io/badge/macOS-26%2B-555)
![Apple シリコン](https://img.shields.io/badge/Apple%20%E3%82%B7%E3%83%AA%E3%82%B3%E3%83%B3-%E5%AF%BE%E5%BF%9C-555)

[**ダウンロード**](https://github.com/xenolucus/burrow-ja/releases/latest/download/BurrowJA.dmg) ·
[更新履歴](https://github.com/xenolucus/burrow-ja/releases) ·
[バージョン別のダウンロード数](https://github.com/xenolucus/burrow-ja/tree/stats) ·
[問題を報告](https://github.com/xenolucus/burrow-ja/issues)

</div>

Mac のクリーナー [Mole](https://github.com/tw93/Mole) を画面から操作できるアプリです。Burrow の作者、Mole の作者、Mole for Mac とは関係ありません。問題はこのリポジトリに報告してください。

> [!WARNING]
> ファイルを削除するアプリです。実行前に確認画面の内容を必ず読んでください。完全削除の項目は元に戻せません。

## インストール

1. [BurrowJA.dmg](https://github.com/xenolucus/burrow-ja/releases/latest/download/BurrowJA.dmg) をダウンロードします。
2. 開いて `Burrow JA` をアプリケーションフォルダに入れます。
3. Apple の公証を受けていないため、初回は macOS に止められます。「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 「プライバシーとセキュリティ」→「フルディスクアクセス」で Burrow JA をオンにします。

2回目からは、アプリ内の更新で新しい版に上げられます。更新の前に変更内容を確認できます。

## 元の Burrow との違い

### 掃除

| 機能 | 内容 |
|---|---|
| Mole が残した項目 | 保護された項目や削除できなかった項目を、選んで完全削除できます。Apple のシステム用の項目は表示しません。 |
| キャッシュを最大限に消す | 作り直せるキャッシュの保護をまとめて外せます。iCloud やアプリの設定は保護したままです。 |
| 重複ファイル | 同じ内容のファイルを探して、ゴミ箱に入れられます。ダウンロードのコピーは最初から選択し、残すフォルダもまとめて選べます。外付けドライブにも対応しています。 |
| 手動項目の消し方 | Docker や LM Studio など、Mole が手動としている項目の消し方を案内します。 |
| ゴミ箱 | 外付けドライブと iCloud Drive のゴミ箱も、Finder でまとめて空にできます。 |
| 外付けドライブ（試験的） | 不要なシステムファイルと、Adobe、Xcode、Steam、Unity の既知のキャッシュを削除できます。削除は完全削除です。 |

### 見守り

| 機能 | 内容 |
|---|---|
| メニューバーの値 | CPU、メモリ、ネットワーク、バッテリーなどを表示できます。項目、順番、間隔、デザインのほか、値ごとにアイコン、サイズ、位置も変えられます。 |
| メニューバーのまとめ（試験的） | メニューバーのアプリをアイコンにまとめて隠せます。ページのように切り替えられ、ショートカットにも対応しています。 |
| 通知 | 空き容量が少ないときと、クリーンできる量が増えたときに通知できます。自動では削除しません。 |
| 負荷の高いアプリ | 最適化の画面に CPU 使用率の高いアプリを表示し、その場で終了できます。 |
| ツール | 画面拭き、キーボード清掃、モニターのチェック（ドット抜け、プロジェクター）、ファンの回転数の確認と速さの変更（管理者パスワードが必要）。 |
| ドライブと累計 | 外付けドライブの状態と古い動画、これまでに整理した容量を確認できます。 |

### そのほか

- 画面を日本語化しました。Mole が出す文章も、対訳があるものは日本語で表示します。対訳がない文章は英語のままです。
- アプリ名、bundle ID、更新先を変更し、元の Burrow と同時に入れられるようにしました。
- Dock にアイコンを出さず、メニューバーだけで使えます。
- サイドバーの順番を変えられます。追加機能は不要なら外せます。
- 同梱の `status-go` と `analyze-go` を、Mole の公式リリースのバイナリに差し替えました。

Mole の解析処理は元の英語のままです。Mole の掃除の判断は Mole の安全確認に任せています。

## 開発者向け

<details>
<summary>ビルド</summary>

Xcode Command Line Tools と Python 3 が必要です。

```bash
python3 ja/apply_ja.py
cd build-ja
scripts/bundle.sh
```

`build-ja/build/Burrow JA.app` ができます。

</details>

<details>
<summary>元の Burrow の更新を取り込む</summary>

`Sources/` は元のまま保ち、翻訳は `ja/` に置いています。

```bash
git fetch upstream
git merge upstream/main
python3 ja/apply_ja.py
```

`MISSING` と表示された文字列は、`ja/pairs.py` の対訳を直します。

</details>

<details>
<summary>自動更新の仕組み</summary>

GitHub Actions が毎日、元の Burrow と Mole の更新を確認します。更新があればビルドとテストを行い、下書きの Release を作ります。未翻訳の文字列は Issue に一覧で出ます。翻訳がなくてもアプリは英語で表示を続けます。

</details>

## ライセンス

GPL-3.0 です。元のプロジェクトと同じです。項目を隠す処理は [Ellipsis](https://github.com/ronny/ellipsis)（Apache-2.0）をもとにしています（`ja/LICENSE-Ellipsis.txt`）。

- Burrow © Khan Umirzakoff
- Mole © tw93 and contributors

元の説明は [README.upstream.md](README.upstream.md) にあります。

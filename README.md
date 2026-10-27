# 釣果海図ログ

海図（地理院タイル＋OpenSeaMap航路標識）の上に、釣果（位置・魚種・棚・気象・潮汐・波浪）を記録するWebアプリです。
等深線と推定水深は GEBCO_2026 Grid から作っています（日本周辺、1度×1度の区画ごと）。

## フォルダ構成

```
index.html          アプリ本体
tiles/index.json    区画の一覧
tiles/36_137.json   等深線（北緯36〜37度・東経137〜138度）
tiles/36_137.bin    水深格子（推定水深用、241×241 Int16、陸は -1）
tools/build_tiles.py  GEBCOのGeoTIFFから tiles/ を作り直すスクリプト
```

区画名は「南端の緯度_西端の経度」です。

## 動かし方

`index.html` をダブルクリックで開くと、記録はできますが等深線は出ません（ブラウザがローカルファイルの読み込みを止めるため）。
次のどちらかで開いてください。

### PCで試す（ローカルサーバー）

このフォルダで次を実行し、ブラウザで http://localhost:8000/ を開きます。

```
python -m http.server 8000
```

### スマホでも使う（GitHub Pages）

1. GitHubで新しいリポジトリを作る
2. このフォルダの中身（index.html と tiles/ など）をそのままアップロード
3. Settings → Pages → Branch を `main` / `(root)` にして保存
4. 数分後に表示される `https://<ユーザー名>.github.io/<リポジトリ名>/` を開く

## データの出典と注意

- 水深: GEBCO Compilation Group (2026) GEBCO 2026 Grid（パブリックドメイン。出典表示が条件）
- 地図: 国土地理院 地理院タイル / 航路標識: OpenSeaMap
- 気象・波浪・潮位: Open-Meteo（モデル値）
- 等深線・推定水深は約400m格子からの参考値です。航海には使えません。
- 記録はブラウザ内（IndexedDB）に保存されます。サイトのURLが変わると別の保存領域になるので、移行時はJSONバックアップ→復元を使ってください。

## 等深線の作り直し

```
pip install numpy scipy matplotlib tifffile shapely
python tools/build_tiles.py gebco_2026_xxx.tif .
```

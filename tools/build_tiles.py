"""GEBCO GeoTIFF（日本周辺）から1度×1度の区画ファイルを作る。

出力（out_dir/tiles/）:
  {lat}_{lon}.json  等深線 GeoJSON（プロパティ d = 水深m）
  {lat}_{lon}.bin   水深格子 Int16（241×241、北→南、西→東、陸は -1）
  index.json        作成した区画の一覧と格子情報

使い方:
  python3 build_tiles.py <gebco.tif> <out_dir>
"""
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import tifffile
from scipy.ndimage import gaussian_filter, zoom
from shapely.geometry import LineString

RES = 1 / 240                     # 15秒
LEVELS = [10, 20, 30, 50, 75, 100, 150, 200, 300, 400, 500, 600, 700, 800, 900, 1000,
          1200, 1500, 2000, 2500, 3000, 4000, 5000, 6000, 7000, 8000, 9000]
MAX_SHALLOW = 2000                # この水深より浅い海がない区画（外洋）は作らない


def main(tif, out_dir):
    t = tifffile.TiffFile(tif)
    p = t.pages[0]
    elev = p.asarray().astype(np.float32)
    w0, n0 = p.tags["ModelTiepointTag"].value[3:5]
    w0, n0 = round(w0), round(n0)
    rows, cols = elev.shape
    s0, e0 = n0 - rows * RES, w0 + cols * RES

    depth = -elev
    depth[elev >= 0] = 0                          # 陸は0として平滑化（海岸線付近の歪みを抑える）
    smooth = gaussian_filter(depth, 0.7)          # 全体で一度だけ平滑化 → 区画の境目で線がつながる

    os.makedirs(os.path.join(out_dir, "tiles"), exist_ok=True)
    index = {"res": RES, "size": 241, "tiles": []}
    total = 0
    for la in range(int(round(s0)), int(round(n0))):
        for lo in range(int(round(w0)), int(round(e0))):
            # 区画の北西端セルから、隣の区画と1セル重ねて241×241を切り出す
            r0 = int(round((n0 - (la + 1)) / RES))
            c0 = int(round((lo - w0) / RES))
            r1, c1 = min(r0 + 241, rows), min(c0 + 241, cols)
            raw = elev[r0:r1, c0:c1]
            sea = raw < 0
            if sea.sum() < 20:
                continue
            if (-raw[sea]).min() > MAX_SHALLOW:
                continue
            key = f"{la}_{lo}"

            # 水深格子（生値、陸=-1）
            g = np.where(sea, np.clip(-raw, 0, 32000), -1).astype("<i2")
            if g.shape != (241, 241):
                g = np.pad(g, ((0, 241 - g.shape[0]), (0, 241 - g.shape[1])), constant_values=-1)
            g.tofile(os.path.join(out_dir, "tiles", key + ".bin"))

            # 等深線：平滑化済み格子を2倍に線形補間して描く
            sm = smooth[r0:r1, c0:c1]
            lat = n0 - (np.arange(r0, r1) + 0.5) * RES
            lon = w0 + (np.arange(c0, c1) + 0.5) * RES
            z = zoom(sm, 2, order=1)
            zl = np.linspace(lat[0], lat[-1], z.shape[0])
            zo = np.linspace(lon[0], lon[-1], z.shape[1])
            z = np.where(z < 1, np.nan, z)
            lv = [l for l in LEVELS if np.nanmin(z) < l < np.nanmax(z)] if np.isfinite(z).any() else []
            feats = []
            if lv:
                cs = plt.contour(zo, zl, z, levels=lv)
                for lev, segs in zip(cs.levels, cs.allsegs):
                    tol = 0.00012 if lev < 200 else 0.00035   # 約10m / 30m で間引き
                    for s in segs:
                        if len(s) < 3:
                            continue
                        ls = LineString(s).simplify(tol, preserve_topology=False)
                        c = np.asarray(ls.coords)
                        if len(c) < 2:
                            continue
                        feats.append({"type": "Feature", "properties": {"d": int(lev)},
                                      "geometry": {"type": "LineString",
                                                   "coordinates": [[round(x, 5), round(y, 5)] for x, y in c]}})
                plt.close("all")
            with open(os.path.join(out_dir, "tiles", key + ".json"), "w") as f:
                json.dump({"type": "FeatureCollection", "features": feats}, f, separators=(",", ":"))
            index["tiles"].append(key)
            total += 1
    with open(os.path.join(out_dir, "tiles", "index.json"), "w") as f:
        json.dump(index, f, separators=(",", ":"))
    print("tiles:", total)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

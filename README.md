# otsuri_docter

## なにをするアプリか
- カメラで硬貨を映し、CoreMLモデルで枚数を推定して合計金額を表示する（Flutter版 `kozeniapp` の Swift 版）
- 推論結果は画面下部に `1 yen 2` / `合計: 300円` のように表示されます

## 使い方
1. `otsuri_doctor/otsuri_doctor/otsuri_doctor/` に CoreML のモデルファイルを配置  
   - `.mlmodelc` を置くのがベスト（ビルド済み）  
   - `.mlmodel` しかない場合はアプリ起動時に自動でコンパイルして読み込みます
2. ラベルは `labels.txt` を読み込みます（初期値は Flutter 版と同じ以下7行）  
   ```
   1 yen
   5 yen
   10 yen
   50 yen
   100 yen
   500 yen
   other
   ```
3. アプリを起動し、カメラアクセスを許可してください。1秒おきに推論して合計を更新します。

## 備考
- 推論がうまくいかないときは CoreML モデルの入出力形状が Flutter 版と一致しているか確認してください（出力はラベル順に枚数が入っている前提です）。
- カメラ権限の説明文は `NSCameraUsageDescription` に追加済みです。

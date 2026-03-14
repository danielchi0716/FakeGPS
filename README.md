# FakeGPS

<p align="center">
  <img src="FakeGPS/Assets.xcassets/AppIcon.appiconset/256.png" width="128" alt="FakeGPS Icon">
</p>

<p align="center">
  macOS 應用程式，透過 USB 連接模擬 iOS 裝置的 GPS 定位。
</p>

## 功能特色

**定點模擬**
- 在地圖上點選任意位置設定模擬座標
- 支援搜尋地址 / 地標快速定位
- 手動輸入經緯度（含格式驗證）
- 搖桿控制即時移動，可調整移動速度

**路線模擬**
- 建立多點路線，模擬裝置沿路線移動
- 可調速度（1 ~ 200 km/h），內建快速切換按鈕（5、30、60、120 km/h）
- GPS 漂移模擬，還原真實移動時的訊號偏移（±3 公尺）
- 地圖上即時顯示路線、編號標記點與目前位置

**裝置管理**
- 自動偵測 USB 連接的 iOS 裝置
- 顯示裝置名稱、型號、系統版本與 UDID
- Tunnel 連線管理（iOS 17+）

**其他**
- 收藏地點，快速切換常用座標
- 所有依賴已內建，下載即可使用，無需額外安裝 Python 或其他工具

## 系統需求

| 項目 | 需求 |
|------|------|
| macOS | 14.0 或以上 |
| iOS 裝置 | iOS 17+，透過 USB 連接 |
| iPhone 設定 | 需開啟開發者模式並信任此 Mac |

## 安裝

### 1. 下載 FakeGPS

從 [Releases](https://github.com/danielchi0716/FakeGPS/releases/latest) 下載最新的 `FakeGPS.zip` 並解壓縮。

由於應用程式未經 Apple 簽名，macOS 會阻擋開啟。請依照以下步驟移除隔離標記：

1. 開啟「終端機」（可透過 Spotlight 搜尋 `Terminal`，或從「應用程式 → 工具程式 → 終端機」開啟）
2. 輸入以下指令後按 Enter：

```bash
xattr -d com.apple.quarantine ~/Downloads/FakeGPS.app
```

> 如果 app 不在 Downloads 資料夾，請將路徑替換為實際位置。也可以先輸入 `xattr -d com.apple.quarantine `（注意結尾空格），再將 FakeGPS.app 拖入終端機視窗，會自動填入路徑。

### 2. iPhone 開啟開發者模式

1. 前往 **設定 → 隱私權與安全性**，滑到最底部找到 **開發者模式**
2. 開啟開發者模式，iPhone 會要求重新啟動
3. 重啟後點擊確認啟用

> 如果看不到「開發者模式」選項，請先用 USB 連接 Mac 並開啟 Xcode，選項就會出現。

## 使用方式

1. 透過 USB 將 iPhone 連接至 Mac，在 iPhone 上點擊「**信任此電腦**」
2. 開啟 FakeGPS，等待自動偵測裝置
3. 點擊「啟動 Tunnel」建立連線（需輸入 Mac 登入密碼）
4. 在地圖上點選目標位置，或手動輸入座標
5. 點擊「設定位置」開始模擬
6. 點擊「清除位置」恢復真實定位

### 路線模擬

1. 切換到路線模式
2. 在地圖上依序點擊新增路徑點
3. 調整移動速度，可選擇開啟 GPS 漂移
4. 點擊「開始模擬」，裝置將沿路線移動

## 常見問題

**Q: 偵測不到裝置？**
- 確認 USB 線已連接，且 iPhone 上已點擊「信任此電腦」
- 確認已開啟開發者模式（設定 → 隱私權與安全性 → 開發者模式）

**Q: Tunnel 啟動失敗？**
- Tunnel 需要 sudo 權限，請在彈出的密碼視窗輸入 Mac 登入密碼

**Q: 打開 app 顯示「無法驗證開發者」？**
- 執行 `xattr -d com.apple.quarantine /path/to/FakeGPS.app`

## License

MIT License

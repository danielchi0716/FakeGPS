# FakeGPS

macOS 應用程式，用於模擬 iOS 裝置的 GPS 定位。

## 系統需求

- macOS 14.0 或以上
- Python 3.8+
- iOS 裝置透過 USB 連接

## 安裝依賴

### 1. 安裝 pymobiledevice3

```bash
pip3 install pymobiledevice3
```

pymobiledevice3 是與 iOS 裝置通訊的核心工具，負責裝置偵測與位置模擬。

### 2. 驗證安裝

```bash
pymobiledevice3 usbmux list
```

連接 iOS 裝置後執行上述指令，能看到裝置資訊代表安裝成功。

## 下載與執行

從 [Releases](https://github.com/danielchi0716/FakeGPS/releases/latest) 下載最新的 `FakeGPS.zip`，解壓縮後，在終端機執行以下指令移除 macOS 下載隔離標記：

```bash
xattr -d com.apple.quarantine /path/to/FakeGPS.app
```

將 `/path/to/FakeGPS.app` 替換為實際路徑，例如：

```bash
xattr -d com.apple.quarantine ~/Downloads/FakeGPS.app
```

之後即可正常開啟應用程式。

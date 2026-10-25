# RGB 光控中心

一個給 Windows 用的簡單 RGB 燈光控制面板。它透過 [OpenRGB](https://openrgb.org) 控制主機板、顯示卡、滑鼠、鍵盤、燈條等裝置，把 OpenRGB 複雜的設定收成幾顆按鈕。

- **自動偵測**：第一次打開時讀取電腦裡有哪些 RGB 裝置、各自支援哪些燈效，介面依結果自動產生。
- **一鍵情境**：超誇張（彩虹爆閃、全速全亮）、日常（冰藍靜態、70% 亮度）、全關閉。
- **每個裝置一個分頁**：選模式（靜態、呼吸、閃爍、彩虹…）、顏色、速度、亮度；多燈區的裝置可以每區設不同顏色。裝置不支援的選項會自動隱藏。
- **全部開關**：一顆電源鍵關掉所有燈，再按一次恢復原本的設定。
- **不卡畫面**：燈控在背景執行，所有裝置合併成一次 OpenRGB 呼叫，大約 2 秒生效。

## 需求

- Windows 10 / 11（內建的 Windows PowerShell 5.1 即可）
- [OpenRGB](https://openrgb.org) 0.9 以上，安裝在預設位置，或第一次開啟時手動指定 `OpenRGB.exe`

## 安裝

1. 下載或 `git clone` 這個資料夾，放在一般使用者可以寫入的位置（例如 `文件` 底下）。設定和紀錄會存在同一個資料夾。
2. 在資料夾裡執行一次下面的指令，建立桌面捷徑：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1
   ```

3. 雙擊桌面上的「RGB 光控中心」。

## 使用前請先關掉 OpenRGB 主程式

如果 OpenRGB 的主視窗或系統匣圖示開著，它會和這個工具搶裝置控制權，可能把這裡的設定蓋掉。

## 命令列

不開視窗也可以直接執行，適合綁快捷鍵或工作排程器：

```powershell
.\RGB-CommandCenter.ps1 -Action Off      # 全部關燈
.\RGB-CommandCenter.ps1 -Action On       # 全部開燈（恢復上次設定）
.\RGB-CommandCenter.ps1 -Action Toggle   # 開關切換
.\RGB-CommandCenter.ps1 -Action Daily    # 日常情境
.\RGB-CommandCenter.ps1 -Action Crazy    # 超誇張情境
.\RGB-CommandCenter.ps1 -Action Apply    # 重新送出目前的設定
.\RGB-CommandCenter.ps1 -Action Scan     # 重新偵測裝置
```

## 安全性

- 偵測只是請 OpenRGB 列出裝置，和 OpenRGB 每次執行指令前做的偵測相同，不會寫入任何韌體。
- **建議用一般權限執行。** 以系統管理員身分執行時，OpenRGB 會額外掃描 SMBus／I2C 匯流排（記憶體燈條等）。這部分在少數硬體上曾造成問題，OpenRGB 官方也有提醒；一般權限下這部分會自動跳過（紀錄裡會看到 `PawnIO initialization aborted`，屬正常）。
- 這個工具只切換燈效模式，不會把設定存進裝置的永久記憶。

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `RGB-CommandCenter.ps1` | 主程式（視窗＋命令列） |
| `RGB-CommandCenter.vbs` | 不跳黑色主控台視窗的啟動器 |
| `Install-Shortcut.ps1` | 建立桌面捷徑 |
| `RGB-devices.json` | 偵測結果快取（自動產生） |
| `RGB-switch-state.json` | 各裝置的設定（自動產生） |
| `RGB-CommandCenter.log` | 執行紀錄（自動產生） |

## 運作方式

1. 執行 `OpenRGB --save-profile` 產生一份暫存設定檔（`.orp`），裡面記錄了每個裝置的名稱、類型、燈區，以及每個模式支援的顏色／速度／亮度。
2. 解析這份設定檔，建立裝置清單並快取到 `RGB-devices.json`。
3. 之後每次調整，都把受影響裝置的設定組成一次 `OpenRGB --device … --mode … --color …` 呼叫送出。

## 授權

MIT。OpenRGB 本身是 GPL-2.0，這個專案只呼叫它的執行檔，沒有包含或修改 OpenRGB 的程式碼；請另外從官方網站安裝 OpenRGB。

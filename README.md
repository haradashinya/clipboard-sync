# clipboard-sync

Mac でコピーした内容（テキスト・画像）を、Tailscale 経由でリモートの Linux（Wayland）クリップボードに自動同期するツール。

- **方向**: Mac → Linux の片方向のみ
- **ネットワーク**: Tailscale（追加の認証・暗号化設定は不要）
- **対応コンテンツ**: テキスト、画像（PNG / TIFF）

## 構成

```
mac-sender/        # Swift 製デーモン（macOS）
linux-receiver/    # Go 製 HTTP サーバー（Linux / Wayland）
launchd/           # Mac 自動起動設定
systemd/           # Linux 自動起動設定
```

### 動作フロー

```
[Mac] NSPasteboard をポーリング
  → 変更を検知
  → HTTP POST（テキスト or PNG バイナリ）
    → [Linux] wl-copy でクリップボードにセット
```

## セットアップ

### 前提条件

- Mac と Linux が同一の Tailscale ネットワークに接続済み
- Linux に `wl-clipboard` がインストール済み

  ```bash
  sudo apt install wl-clipboard
  ```

---

### Linux 側（受信サーバー）

**1. ビルド**

```bash
cd linux-receiver
go build -o ~/bin/clipboard-receiver .
```

**2. systemd user service として登録**

```bash
mkdir -p ~/.config/systemd/user
cp systemd/clipboard-sync.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now clipboard-sync
```

**3. 動作確認**

```bash
systemctl --user status clipboard-sync
journalctl --user -u clipboard-sync -f
```

> **Wayland 環境変数について**
> `WAYLAND_DISPLAY` が自動設定されない場合は、`~/.config/systemd/user/clipboard-sync.service` の
> `Environment=WAYLAND_DISPLAY=wayland-0` 行をアンコメントして調整してください。

---

### Mac 側（送信デーモン）

**1. ビルド**

```bash
cd mac-sender
swift build -c release
```

**2. launchd plist を編集**

`launchd/com.user.clipboard-sync.plist` の以下2箇所を書き換える：

| プレースホルダー | 設定値 |
|---|---|
| `YOUR_USERNAME` | Mac のユーザー名 |
| `YOUR_LINUX_TAILSCALE_IP` | Linux の Tailscale IP またはホスト名 |

**3. launchd に登録**

```bash
cp launchd/com.user.clipboard-sync.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.clipboard-sync.plist
```

**4. 動作確認**

```bash
tail -f /tmp/clipboard-sync.log
tail -f /tmp/clipboard-sync.err
```

---

## 使い方

登録後は自動的に起動します。Mac でテキストや画像をコピーすると、約 0.3 秒後に Linux のクリップボードに反映されます。

### 一時停止

パスワードマネージャー等からコピーするときは、フラグファイルで送信を一時停止できます。

```bash
touch ~/.clipboard-sync-pause   # 停止
rm ~/.clipboard-sync-pause      # 再開
```

### 除外アプリ

以下のアプリがフォアグラウンドにある間は自動的に送信をスキップします。

- 1Password
- Keychain Access
- Bitwarden

追加したい場合は `mac-sender/Sources/main.swift` の `excludedApps` に追記してください。

---

## 設定

### 環境変数（Mac 側）

| 変数名 | デフォルト | 説明 |
|---|---|---|
| `CLIPBOARD_SYNC_HOST` | `localhost` | Linux 側のホスト名または IP |
| `CLIPBOARD_SYNC_PORT` | `8765` | Linux 側のポート番号 |

launchd plist の `EnvironmentVariables` セクションで設定します。

### ポート番号（Linux 側）

`linux-receiver/main.go` の `port` 定数を変更してください（デフォルト: `8765`）。

---

## トラブルシューティング

**Mac からの送信が届かない**
- Linux 側で `systemctl --user status clipboard-sync` を確認
- Tailscale の接続状態を確認（`tailscale status`）
- Linux のファイアウォールでポート 8765 が開いているか確認

**画像が貼り付けられない**
- `wl-copy --version` で `wl-clipboard` のバージョンを確認
- KDE Klipper との競合が疑われる場合、一度 Klipper を無効化して試す

**`wl-copy: compositor doesn't support...` エラー**
- `WAYLAND_DISPLAY` が正しく設定されているか確認
- `echo $WAYLAND_DISPLAY` を実行して値を確認し、systemd service の `Environment=` に設定する

## スコープ外

- Linux → Mac の逆方向同期
- Finder でのファイルコピー（`public.file-url`）への対応
- クリップボード履歴（直近の 1 件のみ同期）

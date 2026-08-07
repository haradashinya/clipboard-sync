# clipboard-sync

Mac と Linux（Wayland）の間で、コピーした内容（テキスト・画像）を Tailscale 経由で双方向に自動同期するツール。

- **方向**: Mac ⇔ Linux の双方向
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
Mac -> Linux:
  [Mac] NSPasteboard をポーリング
    → 変更を検知
    → HTTP POST（テキスト or PNG バイナリ）→ [Linux:8765]
      → wl-copy でクリップボードにセット

Linux -> Mac:
  [Linux] wl-paste をポーリング
    → 変更を検知
    → HTTP POST（テキスト or PNG バイナリ）→ [Mac:8766]
      → NSPasteboard にセット
```

Mac 側・Linux 側とも「送信」と「受信」を同じプロセス（同じバイナリ）内で行う。
相手から受信してクリップボードにセットした内容は、直後の自分のポーリングでは
「自分がセットしたもの」として検知され、送り返さないようになっている
（そうしないと Mac ⇔ Linux 間で無限にエコーし続けてしまう）。

## セットアップ

### 前提条件

- Mac と Linux が同一の Tailscale ネットワークに接続済み
- Linux に `wl-clipboard` がインストール済み

  ```bash
  sudo apt install wl-clipboard
  ```

---

### Linux 側（送受信デーモン）

**1. ビルド**

```bash
cd linux-receiver
go build -o ~/bin/clipboard-receiver .
```

**2. `systemd/clipboard-sync.service` を編集して Mac への送信先を設定**

Linux → Mac 方向を有効にするには、`Environment=CLIPBOARD_SYNC_MAC_HOST=...` の行の
コメントを外し、Mac の Tailscale IP に書き換える（`CLIPBOARD_SYNC_MAC_PORT` は
Mac 側の待受ポートに合わせる。デフォルト `8766`）。

**3. systemd user service として登録**

```bash
mkdir -p ~/.config/systemd/user
cp systemd/clipboard-sync.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now clipboard-sync
```

**4. 動作確認**

```bash
systemctl --user status clipboard-sync
journalctl --user -u clipboard-sync -f
```

> **Wayland 環境変数について**
> `WAYLAND_DISPLAY` が自動設定されない場合は、`~/.config/systemd/user/clipboard-sync.service` の
> `Environment=WAYLAND_DISPLAY=wayland-0` 行をアンコメントして調整してください。

---

### Mac 側（送受信デーモン）

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

登録後は自動的に起動します。どちらかでテキストや画像をコピーすると、約 0.3 秒後にもう一方のクリップボードに反映されます。

### 一時停止

パスワードマネージャー等からコピーするときは、フラグファイルで送信を一時停止できます（Mac / Linux 共通の仕組み。それぞれのマシン上で個別に効きます）。

```bash
touch ~/.clipboard-sync-pause   # 停止
rm ~/.clipboard-sync-pause      # 再開
```

### 除外アプリ（Mac のみ）

以下のアプリがフォアグラウンドにある間は、Mac → Linux 方向の自動送信をスキップします。

- 1Password
- Keychain Access
- Bitwarden

追加したい場合は `mac-sender/Sources/main.swift` の `excludedApps` に追記してください。
（Linux → Mac 方向には同等の仕組みはないため、除外したい場合は一時停止フラグを使ってください。）

---

## 設定

### 環境変数（Mac 側）

| 変数名 | デフォルト | 説明 |
|---|---|---|
| `CLIPBOARD_SYNC_HOST` | `localhost` | 送信先（Linux）のホスト名または IP |
| `CLIPBOARD_SYNC_PORT` | `8765` | 送信先（Linux）のポート番号 |
| `CLIPBOARD_SYNC_LISTEN_PORT` | `8766` | Linux からの受信を待ち受けるポート番号 |

launchd plist の `EnvironmentVariables` セクションで設定します。

### 環境変数（Linux 側）

| 変数名 | デフォルト | 説明 |
|---|---|---|
| `CLIPBOARD_SYNC_MAC_HOST` | （未設定） | 送信先（Mac）の Tailscale IP。未設定の場合 Linux → Mac 方向は無効になる |
| `CLIPBOARD_SYNC_MAC_PORT` | `8766` | 送信先（Mac）のポート番号 |

systemd service の `Environment=` 行で設定します。受信ポート（Mac → Linux、デフォルト `8765`）は
`linux-receiver/main.go` の `port` 定数を変更してください。

---

## トラブルシューティング

**Mac → Linux の送信が届かない**
- Linux 側で `systemctl --user status clipboard-sync` を確認
- Tailscale の接続状態を確認（`tailscale status`）
- Linux のファイアウォールでポート 8765 が開いているか確認

**Linux → Mac の送信が届かない**
- Mac 側で `tail -f /tmp/clipboard-sync.err` に `[clipboard-receiver] listening on port 8766` が出ているか確認
- `launchd/com.user.clipboard-sync.plist` の `CLIPBOARD_SYNC_LISTEN_PORT` と、Linux 側の
  `CLIPBOARD_SYNC_MAC_PORT` が一致しているか確認
- macOS のファイアウォール（システム設定 > ネットワーク > ファイアウォール）で
  ビルドしたバイナリへの受信接続がブロックされていないか確認
- Linux 側で `journalctl --user -u clipboard-sync -f` を見て `forward to mac failed` が出ていないか確認

**画像が貼り付けられない**
- `wl-copy --version` / `wl-paste --version` で `wl-clipboard` のバージョンを確認
- KDE Klipper との競合が疑われる場合、一度 Klipper を無効化して試す

**`wl-copy: compositor doesn't support...` エラー**
- `WAYLAND_DISPLAY` が正しく設定されているか確認
- `echo $WAYLAND_DISPLAY` を実行して値を確認し、systemd service の `Environment=` に設定する

## スコープ外

- クリップボード履歴（直近の 1 件のみ同期）

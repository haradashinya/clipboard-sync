package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	port     = "8765"           // Mac -> Linux 受信ポート
	maxBytes = 50 * 1024 * 1024 // 50 MB
	// Klipper のシグナルが使えないときだけ使うポーリング間隔。
	// wl-paste はフォーカスを奪うので短くしすぎないこと。
	fallbackPollInterval = 5 * time.Second
)

var (
	macHost = getEnv("CLIPBOARD_SYNC_MAC_HOST", "")
	macPort = getEnv("CLIPBOARD_SYNC_MAC_PORT", "8766")
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// MARK: - ループ防止
//
// Mac から受信した内容をそのまま wl-copy でセットすると、それを自分自身の
// clipboard ポーリングが「ローカルでの変更」として検知してしまい、Mac に送り返す
// 無限ループ（Mac -> Linux -> Mac -> ...）になる。
// 直近で自分がセットした内容のハッシュを覚えておき、一致する場合は送信をスキップする。

var (
	lastAppliedMu   sync.Mutex
	lastAppliedHash [32]byte
	hasLastApplied  bool
)

// MARK: - wl-copy プロセス管理
//
// wl-copy はクリップボードのオーナーとして動き続けるため cmd.Run() は永遠にブロックする。
// cmd.Start() で非同期起動し、次の wl-copy を起動するときに前のプロセスを終了させる。

var (
	activeWlCopyMu sync.Mutex
	activeWlCopy   *exec.Cmd
)

func startWlCopy(cmd *exec.Cmd) error {
	activeWlCopyMu.Lock()
	defer activeWlCopyMu.Unlock()
	if activeWlCopy != nil && activeWlCopy.Process != nil {
		_ = activeWlCopy.Process.Kill()
		_ = activeWlCopy.Wait()
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	activeWlCopy = cmd
	return nil
}

func markApplied(data []byte) {
	lastAppliedMu.Lock()
	defer lastAppliedMu.Unlock()
	lastAppliedHash = sha256.Sum256(data)
	hasLastApplied = true
}

func isLastApplied(data []byte) bool {
	lastAppliedMu.Lock()
	defer lastAppliedMu.Unlock()
	if !hasLastApplied {
		return false
	}
	return sha256.Sum256(data) == lastAppliedHash
}

func pauseFlagPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".clipboard-sync-pause")
}

func isPaused() bool {
	path := pauseFlagPath()
	if path == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
}

func handleClipboard(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	contentType := r.Header.Get("Content-Type")
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBytes))
	if err != nil {
		http.Error(w, "read error", http.StatusInternalServerError)
		log.Printf("read error: %v", err)
		return
	}
	defer r.Body.Close()

	var cmd *exec.Cmd
	if strings.HasPrefix(contentType, "image/png") {
		// 画像をファイルに保存してファイルパスをクリップボードにセット
		homeDir, err := os.UserHomeDir()
		if err != nil {
			http.Error(w, "homedir error", http.StatusInternalServerError)
			log.Printf("homedir error: %v", err)
			return
		}
		dir := filepath.Join(homeDir, "Pictures", "clipboard-sync")
		if err := os.MkdirAll(dir, 0755); err != nil {
			http.Error(w, "mkdir error", http.StatusInternalServerError)
			log.Printf("mkdir error: %v", err)
			return
		}
		filename := fmt.Sprintf("clipboard-%s.png", time.Now().Format("2006-01-02-150405"))
		filePath := filepath.Join(dir, filename)
		if err := os.WriteFile(filePath, body, 0644); err != nil {
			http.Error(w, "write error", http.StatusInternalServerError)
			log.Printf("write error: %v", err)
			return
		}
		log.Printf("received image (%d bytes) -> %s", len(body), filePath)
		cmd = exec.Command("wl-copy")
		cmd.Stdin = bytes.NewReader([]byte(filePath))
	} else {
		cmd = exec.Command("wl-copy")
		preview := string(body)
		if len(preview) > 80 {
			preview = preview[:80] + "..."
		}
		log.Printf("received text: %q", preview)
		cmd.Stdin = bytes.NewReader(body)
	}

	cmd.Stderr = os.Stderr

	if err := startWlCopy(cmd); err != nil {
		http.Error(w, "wl-copy error", http.StatusInternalServerError)
		log.Printf("wl-copy error: %v", err)
		return
	}

	markApplied(body)
	w.WriteHeader(http.StatusOK)
}

// MARK: - Linux -> Mac 送信

func readClipboard() (contentType string, data []byte, err error) {
	typesOut, err := exec.Command("wl-paste", "--list-types").Output()
	if err != nil {
		return "", nil, err
	}
	types := map[string]bool{}
	for _, t := range strings.Split(strings.TrimSpace(string(typesOut)), "\n") {
		if t = strings.TrimSpace(t); t != "" {
			types[t] = true
		}
	}

	if types["image/png"] {
		data, err := exec.Command("wl-paste", "--no-newline", "--type", "image/png").Output()
		if err != nil {
			return "", nil, err
		}
		return "image/png", data, nil
	}

	// wl-paste を --type なしで呼ぶと、テキスト系の型が無いクリップボード
	// （KDE 独自の MIME 型だけ等）で wl-clipboard 2.2.1 が assert で abort し、
	// ポーリングのたびに大量のクラッシュレポートが出る。
	// 型は必ず自分で選んで明示的に渡し、該当する型が無ければスキップする。
	textType := pickTextType(types)
	if textType == "" {
		return "", nil, nil
	}
	data, err = exec.Command("wl-paste", "--no-newline", "--type", textType).Output()
	if err != nil {
		return "", nil, err
	}
	return "text/plain; charset=utf-8", data, nil
}

func pickTextType(types map[string]bool) string {
	for _, t := range []string{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING"} {
		if types[t] {
			return t
		}
	}
	return ""
}

func forwardToMac(client *http.Client, endpoint, contentType string, data []byte) error {
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", contentType)

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status: %d", resp.StatusCode)
	}
	return nil
}

func pollAndForward() {
	if macHost == "" {
		log.Printf("CLIPBOARD_SYNC_MAC_HOST is not set. Linux -> Mac sync is disabled.")
		return
	}
	endpoint := fmt.Sprintf("http://%s:%s/clipboard", macHost, macPort)
	client := &http.Client{Timeout: 5 * time.Second}
	log.Printf("Linux -> Mac sync enabled. target=%s", endpoint)

	var lastSeenHash [32]byte
	hasLastSeen := false

	// wl-paste は data-control プロトコルが使えない環境（wl-clipboard 2.2.1 + KWin 6）
	// では、読み取りのたびに一瞬だけ見えないウィンドウを作ってフォーカスを奪う。
	// 300ms ごとにポーリングすると右クリックメニュー等のポップアップが即座に閉じてしまう。
	// そのため Klipper の clipboardHistoryUpdated シグナルを受けたときだけ読みに行く。
	trigger := clipboardChanges()
	for range trigger {
		if isPaused() {
			continue
		}

		contentType, data, err := readClipboard()
		if err != nil || len(data) == 0 {
			continue
		}

		hash := sha256.Sum256(data)
		if hasLastSeen && hash == lastSeenHash {
			continue // 変化なし
		}
		lastSeenHash = hash
		hasLastSeen = true

		if isLastApplied(data) {
			// Mac から受信した内容がそのまま返ってきただけ（エコー）
			continue
		}

		if err := forwardToMac(client, endpoint, contentType, data); err != nil {
			log.Printf("forward to mac failed: %v", err)
			continue
		}
		log.Printf("forwarded clipboard to mac (%d bytes, %s)", len(data), contentType)
	}
}

// clipboardChanges はクリップボードが変わった可能性があるタイミングを通知する。
// Klipper の D-Bus シグナルが使えればそれを使い、使えなければ低頻度のポーリングに落とす。
func clipboardChanges() <-chan struct{} {
	ch := make(chan struct{}, 1)
	notify := func() {
		select {
		case ch <- struct{}{}:
		default: // 未処理の通知があればまとめる
		}
	}

	conn, err := dbus.ConnectSessionBus()
	if err == nil {
		err = conn.AddMatchSignal(
			dbus.WithMatchInterface("org.kde.klipper.klipper"),
			dbus.WithMatchMember("clipboardHistoryUpdated"),
		)
	}
	if err != nil {
		log.Printf("klipper signal unavailable (%v); falling back to polling every %s", err, fallbackPollInterval)
		go func() {
			for range time.Tick(fallbackPollInterval) {
				notify()
			}
		}()
		return ch
	}

	log.Printf("watching klipper clipboardHistoryUpdated signal")
	signals := make(chan *dbus.Signal, 16)
	conn.Signal(signals)
	go func() {
		notify() // 起動時に現在の内容を一度読んで基準にする
		for range signals {
			notify()
		}
	}()
	return ch
}

func main() {
	http.HandleFunc("/clipboard", handleClipboard)
	addr := ":" + port
	log.Printf("clipboard-receiver listening on %s", addr)

	go pollAndForward()

	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

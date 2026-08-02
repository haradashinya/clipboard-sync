package main

import (
	"bytes"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
)

const (
	port     = "8765"
	maxBytes = 50 * 1024 * 1024 // 50 MB
)

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
		cmd = exec.Command("wl-copy", "--type", "image/png")
		log.Printf("received image (%d bytes)", len(body))
	} else {
		cmd = exec.Command("wl-copy")
		preview := string(body)
		if len(preview) > 80 {
			preview = preview[:80] + "..."
		}
		log.Printf("received text: %q", preview)
	}

	cmd.Stdin = bytes.NewReader(body)
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		http.Error(w, "wl-copy error", http.StatusInternalServerError)
		log.Printf("wl-copy error: %v", err)
		return
	}

	w.WriteHeader(http.StatusOK)
}

func main() {
	http.HandleFunc("/clipboard", handleClipboard)
	addr := ":" + port
	log.Printf("clipboard-receiver listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

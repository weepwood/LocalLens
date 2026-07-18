package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /api/v1/server", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{
			"name": a.cfg.ServerName, "version": version, "apiVersion": "v1",
		})
	})
	mux.Handle("GET /api/v1/libraries", a.auth(http.HandlerFunc(a.libraries)))
	mux.Handle("GET /api/v1/stats", a.auth(http.HandlerFunc(a.stats)))
	mux.Handle("GET /api/v1/media", a.auth(http.HandlerFunc(a.mediaList)))
	mux.Handle("GET /api/v1/media/{id}", a.auth(http.HandlerFunc(a.mediaDetail)))
	mux.Handle("PUT /api/v1/media/{id}/favorite", a.auth(http.HandlerFunc(a.favorite)))
	mux.Handle("DELETE /api/v1/media/{id}/favorite", a.auth(http.HandlerFunc(a.favorite)))
	mux.Handle("GET /api/v1/media/{id}/thumbnail", a.auth(http.HandlerFunc(a.thumbnail)))
	mux.Handle("GET /api/v1/media/{id}/original", a.auth(http.HandlerFunc(a.original)))
	mux.Handle("GET /api/v1/media/{id}/stream", a.auth(http.HandlerFunc(a.original)))
	mux.Handle("POST /api/v1/scan", a.auth(http.HandlerFunc(a.scanStart)))
	mux.Handle("GET /api/v1/scan", a.auth(http.HandlerFunc(a.scanState)))
	return a.cors(mux)
}

func (a *App) libraries(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.QueryContext(r.Context(), `
SELECT
  l.id,l.name,l.recursive,l.enabled,l.last_scanned_at,
  COALESCE(SUM(CASE WHEN m.missing=0 THEN 1 ELSE 0 END),0)
FROM libraries l
LEFT JOIN media_items m ON m.library_id=l.id
GROUP BY l.id,l.name,l.recursive,l.enabled,l.last_scanned_at
ORDER BY l.name`)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	items := []map[string]any{}
	for rows.Next() {
		var id, name string
		var recursive, enabled bool
		var last sql.NullString
		var mediaCount int64
		if err := rows.Scan(&id, &name, &recursive, &enabled, &last, &mediaCount); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		items = append(items, map[string]any{
			"id": id, "name": name, "recursive": recursive, "enabled": enabled,
			"lastScannedAt": last.String, "mediaCount": mediaCount,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (a *App) stats(w http.ResponseWriter, r *http.Request) {
	var total, images, videos, favorites, bytes int64
	err := a.db.QueryRowContext(r.Context(), `
SELECT
  COUNT(*),
  COALESCE(SUM(CASE WHEN media_type='image' THEN 1 ELSE 0 END),0),
  COALESCE(SUM(CASE WHEN media_type='video' THEN 1 ELSE 0 END),0),
  COALESCE(SUM(CASE WHEN favorite=1 THEN 1 ELSE 0 END),0),
  COALESCE(SUM(size_bytes),0)
FROM media_items
WHERE missing=0`).Scan(&total, &images, &videos, &favorites, &bytes)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{
		"total": total, "images": images, "videos": videos,
		"favorites": favorites, "sizeBytes": bytes,
	})
}

func (a *App) mediaList(w http.ResponseWriter, r *http.Request) {
	limit := clampInt(queryInt(r, "limit", 100), 1, 200)
	offset := max(queryInt(r, "offset", 0), 0)
	page, err := a.queryMedia(
		r.Context(),
		r.URL.Query().Get("type"),
		strings.TrimSpace(r.URL.Query().Get("q")),
		strings.TrimSpace(r.URL.Query().Get("libraryId")),
		queryBool(r, "favorite"),
		limit,
		offset,
		strings.TrimSpace(r.URL.Query().Get("cursor")),
	)
	if err != nil {
		if strings.Contains(err.Error(), "cursor") {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	items := make([]map[string]any, 0, len(page.Items))
	for _, item := range page.Items {
		items = append(items, mediaResponse(item))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"items": items, "total": page.Total, "limit": page.Limit,
		"offset": page.Offset, "nextCursor": page.NextCursor, "hasMore": page.HasMore,
	})
}

func (a *App) mediaDetail(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if ok {
		writeJSON(w, http.StatusOK, mediaResponse(item))
	}
}

func (a *App) favorite(w http.ResponseWriter, r *http.Request) {
	favorite := r.Method == http.MethodPut
	if err := a.setFavorite(r.Context(), r.PathValue("id"), favorite); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			http.Error(w, "media not found", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	item, err := a.findMediaByID(r.Context(), r.PathValue("id"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, mediaResponse(item))
}

func (a *App) thumbnail(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if !ok {
		return
	}
	width := clampInt(queryInt(r, "width", 480), 64, 1920)
	path := filepath.Join(
		a.cfg.DataDir,
		"thumbnails",
		item.ID[:2],
		fmt.Sprintf("%s-%d-%d.jpg", item.ID, item.ModifiedAt.Unix(), width),
	)
	if err := a.ensureThumbnail(r.Context(), item, width, path); err != nil {
		a.logger.Warn("thumbnail", "media", item.ID, "error", err)
		http.Error(w, "thumbnail unavailable", http.StatusServiceUnavailable)
		return
	}
	serveFile(w, r, path, "image/jpeg")
}

func (a *App) ensureThumbnail(ctx context.Context, item Media, width int, path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	a.thumbnailMu.Lock()
	defer a.thumbnailMu.Unlock()
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	if a.cfg.FFmpegPath == "" {
		return errors.New("ffmpeg is not configured")
	}
	if _, err := os.Stat(a.cfg.FFmpegPath); err != nil {
		return fmt.Errorf("ffmpeg unavailable: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	tempPath := path + "." + randomID() + ".jpg"
	defer os.Remove(tempPath)
	args := []string{"-hide_banner", "-loglevel", "error"}
	if item.Type == "video" {
		args = append(args, "-ss", "2")
	}
	args = append(
		args,
		"-i", item.Path(),
		"-frames:v", "1",
		"-vf", "scale="+strconv.Itoa(width)+":-2",
		"-q:v", "4",
		"-y", tempPath,
	)
	if output, err := exec.CommandContext(ctx, a.cfg.FFmpegPath, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("ffmpeg: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return os.Rename(tempPath, path)
}

func (a *App) original(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if ok {
		serveFile(w, r, item.Path(), item.MIMEType)
	}
}

func (a *App) scanStart(w http.ResponseWriter, _ *http.Request) {
	if !a.startScan() {
		http.Error(w, "scan already running", http.StatusConflict)
		return
	}
	a.scanState(w, nil)
}

func (a *App) scanState(w http.ResponseWriter, _ *http.Request) {
	a.mu.RLock()
	status := a.scan
	a.mu.RUnlock()
	writeJSON(w, http.StatusOK, status)
}

func (a *App) findMedia(w http.ResponseWriter, r *http.Request) (Media, bool) {
	item, err := a.findMediaByID(r.Context(), r.PathValue("id"))
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "media not found", http.StatusNotFound)
		return Media{}, false
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return Media{}, false
	}
	if item.Missing {
		http.Error(w, "media missing", http.StatusGone)
		return Media{}, false
	}
	if !within(item.RootPath, item.Path()) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return Media{}, false
	}
	return item, true
}

func serveFile(w http.ResponseWriter, r *http.Request, path, contentType string) {
	file, err := os.Open(path)
	if err != nil {
		http.Error(w, "file unavailable", http.StatusNotFound)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	http.ServeContent(w, r, info.Name(), info.ModTime(), file)
}

func (a *App) auth(next http.Handler) http.Handler {
	expected := []byte(a.cfg.APIToken)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		token := []byte(strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")))
		if !strings.HasPrefix(header, "Bearer ") || subtle.ConstantTimeCompare(token, expected) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *App) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Range")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

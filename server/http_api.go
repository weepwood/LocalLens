package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /api/v1/server", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"name": a.cfg.ServerName, "version": version, "apiVersion": "v1",
			"capabilities": []string{"timeline", "folders", "favorites", "ratings", "albums", "tags", "playback", "pairing"},
		})
	})
	mux.HandleFunc("POST /api/v1/pairing/claim", a.pairingClaim)

	mux.Handle("GET /api/v1/libraries", a.auth(http.HandlerFunc(a.libraries)))
	mux.Handle("GET /api/v1/stats", a.auth(http.HandlerFunc(a.stats)))
	mux.Handle("GET /api/v1/folders", a.auth(http.HandlerFunc(a.folders)))
	mux.Handle("GET /api/v1/media", a.auth(http.HandlerFunc(a.mediaList)))
	mux.Handle("GET /api/v1/media/{id}", a.auth(http.HandlerFunc(a.mediaDetail)))
	mux.Handle("PUT /api/v1/media/{id}/favorite", a.auth(http.HandlerFunc(a.favorite)))
	mux.Handle("DELETE /api/v1/media/{id}/favorite", a.auth(http.HandlerFunc(a.favorite)))
	mux.Handle("PUT /api/v1/media/{id}/rating", a.auth(http.HandlerFunc(a.rating)))
	mux.Handle("DELETE /api/v1/media/{id}/rating", a.auth(http.HandlerFunc(a.rating)))
	mux.Handle("GET /api/v1/media/{id}/collections", a.auth(http.HandlerFunc(a.mediaCollectionState)))
	mux.Handle("GET /api/v1/media/{id}/progress", a.auth(http.HandlerFunc(a.playbackProgress)))
	mux.Handle("PUT /api/v1/media/{id}/progress", a.auth(http.HandlerFunc(a.playbackProgress)))
	mux.Handle("POST /api/v1/media/{id}/metadata", a.auth(http.HandlerFunc(a.retryMetadata)))
	mux.Handle("GET /api/v1/media/{id}/thumbnail", a.auth(http.HandlerFunc(a.thumbnail)))
	mux.Handle("GET /api/v1/media/{id}/original", a.auth(http.HandlerFunc(a.original)))
	mux.Handle("GET /api/v1/media/{id}/stream", a.auth(http.HandlerFunc(a.original)))

	mux.Handle("GET /api/v1/albums", a.auth(http.HandlerFunc(a.albums)))
	mux.Handle("POST /api/v1/albums", a.auth(http.HandlerFunc(a.albums)))
	mux.Handle("DELETE /api/v1/albums/{id}", a.auth(http.HandlerFunc(a.albumDelete)))
	mux.Handle("PUT /api/v1/albums/{id}/items/{mediaId}", a.auth(http.HandlerFunc(a.albumItem)))
	mux.Handle("DELETE /api/v1/albums/{id}/items/{mediaId}", a.auth(http.HandlerFunc(a.albumItem)))
	mux.Handle("GET /api/v1/tags", a.auth(http.HandlerFunc(a.tags)))
	mux.Handle("POST /api/v1/tags", a.auth(http.HandlerFunc(a.tags)))
	mux.Handle("DELETE /api/v1/tags/{id}", a.auth(http.HandlerFunc(a.tagDelete)))
	mux.Handle("PUT /api/v1/media/{id}/tags/{tagId}", a.auth(http.HandlerFunc(a.mediaTag)))
	mux.Handle("DELETE /api/v1/media/{id}/tags/{tagId}", a.auth(http.HandlerFunc(a.mediaTag)))

	mux.Handle("POST /api/v1/scan", a.auth(http.HandlerFunc(a.scanStart)))
	mux.Handle("GET /api/v1/scan", a.auth(http.HandlerFunc(a.scanState)))
	mux.Handle("POST /api/v1/pairing/session", a.auth(http.HandlerFunc(a.pairingStart)))
	mux.Handle("GET /api/v1/pairing/session/{id}/qr", a.auth(http.HandlerFunc(a.pairingQR)))
	mux.Handle("GET /api/v1/devices", a.auth(http.HandlerFunc(a.devices)))
	mux.Handle("DELETE /api/v1/devices/{id}", a.auth(http.HandlerFunc(a.deviceRevoke)))
	return a.cors(mux)
}

func (a *App) libraries(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.QueryContext(r.Context(), `
SELECT l.id,l.name,l.recursive,l.enabled,l.last_scanned_at,
  COALESCE(SUM(CASE WHEN m.missing=0 THEN 1 ELSE 0 END),0)
FROM libraries l LEFT JOIN media_items m ON m.library_id=l.id
GROUP BY l.id,l.name,l.recursive,l.enabled,l.last_scanned_at ORDER BY l.name`)
	if err != nil {
		serverError(w, err)
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
			serverError(w, err)
			return
		}
		items = append(items, map[string]any{"id": id, "name": name, "recursive": recursive, "enabled": enabled, "lastScannedAt": last.String, "mediaCount": mediaCount})
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (a *App) stats(w http.ResponseWriter, r *http.Request) {
	var total, images, videos, favorites, bytes, metadataPending, thumbsPending int64
	err := a.db.QueryRowContext(r.Context(), `
SELECT COUNT(*),
 COALESCE(SUM(CASE WHEN media_type='image' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN media_type='video' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN favorite=1 THEN 1 ELSE 0 END),0),
 COALESCE(SUM(size_bytes),0),
 COALESCE(SUM(CASE WHEN metadata_status='pending' THEN 1 ELSE 0 END),0)
FROM media_items WHERE missing=0`).Scan(&total, &images, &videos, &favorites, &bytes, &metadataPending)
	if err != nil {
		serverError(w, err)
		return
	}
	_ = a.db.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM thumbnail_jobs WHERE status IN ('pending','running')`).Scan(&thumbsPending)
	writeJSON(w, http.StatusOK, map[string]int64{"total": total, "images": images, "videos": videos, "favorites": favorites, "sizeBytes": bytes, "metadataPending": metadataPending, "thumbnailsPending": thumbsPending})
}

func (a *App) folders(w http.ResponseWriter, r *http.Request) {
	libraryID := strings.TrimSpace(r.URL.Query().Get("libraryId"))
	if libraryID == "" {
		http.Error(w, "libraryId is required", http.StatusBadRequest)
		return
	}
	items, err := a.listFolders(r.Context(), libraryID, strings.Trim(strings.TrimSpace(r.URL.Query().Get("parent")), "/"))
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (a *App) mediaList(w http.ResponseWriter, r *http.Request) {
	_, folderSet := r.URL.Query()["folder"]
	page, err := a.queryMedia(r.Context(), MediaQuery{
		Kind: r.URL.Query().Get("type"), Search: strings.TrimSpace(r.URL.Query().Get("q")),
		LibraryID: strings.TrimSpace(r.URL.Query().Get("libraryId")), FolderPath: strings.Trim(strings.TrimSpace(r.URL.Query().Get("folder")), "/"),
		FolderSet: folderSet, Recursive: queryBool(r, "recursive"), FavoriteOnly: queryBool(r, "favorite"),
		AlbumID: strings.TrimSpace(r.URL.Query().Get("albumId")), TagID: strings.TrimSpace(r.URL.Query().Get("tagId")),
		MinRating: queryInt(r, "minRating", 0), Sort: strings.TrimSpace(r.URL.Query().Get("sort")),
		Limit: clampInt(queryInt(r, "limit", 100), 1, 200), Offset: max(queryInt(r, "offset", 0), 0),
		Cursor: strings.TrimSpace(r.URL.Query().Get("cursor")),
	})
	if err != nil {
		if strings.Contains(err.Error(), "cursor") {
			http.Error(w, err.Error(), http.StatusBadRequest)
		} else {
			serverError(w, err)
		}
		return
	}
	items := make([]map[string]any, 0, len(page.Items))
	for _, item := range page.Items {
		items = append(items, mediaResponse(item))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": page.Total, "limit": page.Limit, "offset": page.Offset, "nextCursor": page.NextCursor, "hasMore": page.HasMore})
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
		writeStoreError(w, err)
		return
	}
	item, _ := a.findMediaByID(r.Context(), r.PathValue("id"))
	writeJSON(w, http.StatusOK, mediaResponse(item))
}

func (a *App) rating(w http.ResponseWriter, r *http.Request) {
	rating := 0
	if r.Method == http.MethodPut {
		var body struct{ Rating int `json:"rating"` }
		if err := decodeJSON(r, &body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		rating = body.Rating
	}
	if err := a.setRating(r.Context(), r.PathValue("id"), rating); err != nil {
		writeStoreError(w, err)
		return
	}
	item, _ := a.findMediaByID(r.Context(), r.PathValue("id"))
	writeJSON(w, http.StatusOK, mediaResponse(item))
}

func (a *App) mediaCollectionState(w http.ResponseWriter, r *http.Request) {
	albumIDs, tagIDs, err := a.mediaCollections(r.Context(), r.PathValue("id"))
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"albumIds": albumIDs, "tagIds": tagIDs})
}

func (a *App) playbackProgress(w http.ResponseWriter, r *http.Request) {
	identity := identityFromRequest(r)
	mediaID := r.PathValue("id")
	if r.Method == http.MethodGet {
		progress, err := a.getPlaybackProgress(r.Context(), identity.DeviceID, mediaID)
		if errors.Is(err, sql.ErrNoRows) {
			writeJSON(w, http.StatusOK, PlaybackProgress{DeviceID: identity.DeviceID, MediaID: mediaID})
			return
		}
		if err != nil {
			serverError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, progress)
		return
	}
	var body struct {
		PositionMS int64 `json:"positionMs"`
		DurationMS int64 `json:"durationMs"`
		Completed bool `json:"completed"`
	}
	if err := decodeJSON(r, &body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	progress := PlaybackProgress{DeviceID: identity.DeviceID, MediaID: mediaID, PositionMS: body.PositionMS, DurationMS: body.DurationMS, Completed: body.Completed}
	if err := a.savePlaybackProgress(r.Context(), progress); err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, progress)
}

func (a *App) retryMetadata(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if !ok {
		return
	}
	if err := a.enqueueMetadata(r.Context(), item.ID, item.ModifiedAt.UTC().Format(time.RFC3339Nano)); err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "queued"})
}

func (a *App) thumbnail(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if !ok {
		return
	}
	width := clampInt(queryInt(r, "width", 480), 64, 1920)
	path := a.thumbnailPath(item, width)
	if _, err := os.Stat(path); err == nil {
		serveFile(w, r, path, "image/jpeg")
		return
	}
	if err := a.enqueueThumbnail(r.Context(), item.ID, width, item.ModifiedAt.UTC().Format(time.RFC3339Nano)); err != nil {
		serverError(w, err)
		return
	}
	if waitForFile(r.Context(), path, 8*time.Second) {
		serveFile(w, r, path, "image/jpeg")
		return
	}
	w.Header().Set("Retry-After", "3")
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "queued"})
}

func waitForFile(ctx context.Context, path string, timeout time.Duration) bool {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(180 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return false
		case <-deadline.C:
			return false
		case <-ticker.C:
			if _, err := os.Stat(path); err == nil {
				return true
			}
		}
	}
}

func (a *App) original(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if ok {
		serveFile(w, r, item.Path(), item.MIMEType)
	}
}

func (a *App) albums(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		items, err := a.listAlbums(r.Context())
		if err != nil {
			serverError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
		return
	}
	var body struct { Name string `json:"name"`; Description string `json:"description"` }
	if err := decodeJSON(r, &body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	item, err := a.createAlbum(r.Context(), body.Name, body.Description)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusCreated, item)
}

func (a *App) albumDelete(w http.ResponseWriter, r *http.Request) {
	if err := a.deleteAlbum(r.Context(), r.PathValue("id")); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) albumItem(w http.ResponseWriter, r *http.Request) {
	if err := a.setAlbumItem(r.Context(), r.PathValue("id"), r.PathValue("mediaId"), r.Method == http.MethodPut); err != nil {
		serverError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) tags(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		items, err := a.listTags(r.Context())
		if err != nil {
			serverError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items})
		return
	}
	var body struct { Name string `json:"name"`; Color string `json:"color"` }
	if err := decodeJSON(r, &body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	item, err := a.createTag(r.Context(), body.Name, body.Color)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusCreated, item)
}

func (a *App) tagDelete(w http.ResponseWriter, r *http.Request) {
	if err := a.deleteTag(r.Context(), r.PathValue("id")); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) mediaTag(w http.ResponseWriter, r *http.Request) {
	if err := a.setMediaTag(r.Context(), r.PathValue("id"), r.PathValue("tagId"), r.Method == http.MethodPut); err != nil {
		serverError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) scanStart(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	if !a.startScan() {
		http.Error(w, "scan already running", http.StatusConflict)
		return
	}
	a.scanState(w, r)
}

func (a *App) scanState(w http.ResponseWriter, _ *http.Request) {
	a.mu.RLock()
	status := a.scan
	a.mu.RUnlock()
	writeJSON(w, http.StatusOK, status)
}

func (a *App) pairingStart(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	session, err := a.createPairingSession(a.requestBaseURL(r))
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": session.ID, "payload": session.Payload, "expiresAt": session.ExpiresAt, "qrUrl": "/api/v1/pairing/session/" + session.ID + "/qr"})
}

func (a *App) pairingQR(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	png, err := a.pairingQRCode(r.PathValue("id"))
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "pairing session not found", http.StatusNotFound)
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(png)
}

func (a *App) pairingClaim(w http.ResponseWriter, r *http.Request) {
	var claim pairingClaim
	if err := decodeJSON(r, &claim); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	device, token, err := a.claimPairing(r.Context(), claim)
	if err != nil {
		http.Error(w, err.Error(), http.StatusUnauthorized)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"device": device, "token": token})
}

func (a *App) devices(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	items, err := a.listDevices(r.Context())
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (a *App) deviceRevoke(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	if err := a.revokeDevice(r.Context(), r.PathValue("id")); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) findMedia(w http.ResponseWriter, r *http.Request) (Media, bool) {
	item, err := a.findMediaByID(r.Context(), r.PathValue("id"))
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "media not found", http.StatusNotFound)
		return Media{}, false
	}
	if err != nil {
		serverError(w, err)
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
		serverError(w, err)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	http.ServeContent(w, r, info.Name(), info.ModTime(), file)
}

func (a *App) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		identity, err := a.authenticateToken(r.Context(), strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")))
		if err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, withIdentity(r, identity))
	})
}

func requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	if !identityFromRequest(r).Admin {
		http.Error(w, "administrator token required", http.StatusForbidden)
		return false
	}
	return true
}

func (a *App) requestBaseURL(r *http.Request) string {
	if a.cfg.PublicURL != "" {
		return a.cfg.PublicURL
	}
	scheme := strings.TrimSpace(r.Header.Get("X-Forwarded-Proto"))
	if scheme == "" {
		scheme = "http"
		if r.TLS != nil {
			scheme = "https"
		}
	}
	return scheme + "://" + r.Host
}

func (a *App) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Range")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range, Retry-After")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func decodeJSON(r *http.Request, target any) error {
	decoder := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func writeStoreError(w http.ResponseWriter, err error) {
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if strings.Contains(strings.ToLower(err.Error()), "constraint") {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	serverError(w, err)
}

func serverError(w http.ResponseWriter, err error) {
	http.Error(w, fmt.Sprintf("internal server error: %v", err), http.StatusInternalServerError)
}

func queryInt(r *http.Request, key string, fallback int) int {
	value, err := strconv.Atoi(r.URL.Query().Get(key))
	if err != nil {
		return fallback
	}
	return value
}

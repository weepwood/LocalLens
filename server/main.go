package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

const version = "0.1.0"

var mediaTypes = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
	".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
	".mp4": "video/mp4", ".m4v": "video/x-m4v", ".mov": "video/quicktime",
	".mkv": "video/x-matroska", ".avi": "video/x-msvideo", ".webm": "video/webm",
}

type Config struct {
	ListenAddress string    `json:"listen_address"`
	ServerName    string    `json:"server_name"`
	DataDir       string    `json:"data_dir"`
	APIToken      string    `json:"api_token"`
	FFmpegPath    string    `json:"ffmpeg_path"`
	AutoScan      bool      `json:"auto_scan"`
	Libraries     []Library `json:"libraries"`
}

type Library struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Path      string `json:"path,omitempty"`
	Recursive bool   `json:"recursive"`
	Enabled   bool   `json:"enabled"`
}

type Media struct {
	ID           string    `json:"id"`
	LibraryID    string    `json:"libraryId"`
	RootPath     string    `json:"-"`
	RelativePath string    `json:"-"`
	FileName     string    `json:"fileName"`
	Type         string    `json:"type"`
	MIMEType     string    `json:"mimeType"`
	SizeBytes    int64     `json:"sizeBytes"`
	ModifiedAt   time.Time `json:"modifiedAt"`
	Missing      bool      `json:"missing"`
}

func (m Media) Path() string { return filepath.Join(m.RootPath, filepath.FromSlash(m.RelativePath)) }

type ScanStatus struct {
	Running      bool       `json:"running"`
	StartedAt    *time.Time `json:"startedAt,omitempty"`
	FinishedAt   *time.Time `json:"finishedAt,omitempty"`
	Current      string     `json:"current,omitempty"`
	Discovered   int64      `json:"discovered"`
	Indexed      int64      `json:"indexed"`
	Failed       int64      `json:"failed"`
	ErrorMessage string     `json:"errorMessage,omitempty"`
}

type App struct {
	cfg    Config
	db     *sql.DB
	logger *slog.Logger
	mu     sync.RWMutex
	scan   ScanStatus
}

func main() {
	configPath := flag.String("config", "./config.json", "path to JSON config")
	flag.Parse()
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := loadConfig(*configPath)
	if err != nil {
		logger.Error("load config", "error", err)
		os.Exit(1)
	}
	db, err := openDB(cfg.DataDir)
	if err != nil {
		logger.Error("open database", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	app := &App{cfg: cfg, db: db, logger: logger}
	if err := app.syncLibraries(context.Background()); err != nil {
		logger.Error("sync libraries", "error", err)
		os.Exit(1)
	}
	if cfg.AutoScan {
		app.startScan()
	}

	server := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           app.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	go func() {
		logger.Info("server started", "address", cfg.ListenAddress, "version", version)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen", "error", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = server.Shutdown(ctx)
}

func loadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, err
	}
	if cfg.ListenAddress == "" {
		cfg.ListenAddress = "0.0.0.0:9527"
	}
	if cfg.ServerName == "" {
		cfg.ServerName = "LocalLens"
	}
	if cfg.DataDir == "" {
		cfg.DataDir = "./data"
	}
	if len(cfg.APIToken) < 16 {
		return Config{}, errors.New("api_token must contain at least 16 characters")
	}
	if len(cfg.Libraries) == 0 {
		return Config{}, errors.New("at least one library is required")
	}
	base, _ := filepath.Abs(filepath.Dir(path))
	resolve := func(value string) string {
		if value == "" || filepath.IsAbs(value) {
			return value
		}
		absolute, _ := filepath.Abs(filepath.Join(base, value))
		return absolute
	}
	cfg.DataDir = resolve(cfg.DataDir)
	cfg.FFmpegPath = resolve(cfg.FFmpegPath)
	seen := map[string]bool{}
	for i := range cfg.Libraries {
		lib := &cfg.Libraries[i]
		if lib.ID == "" || lib.Name == "" || lib.Path == "" {
			return Config{}, errors.New("library id, name and path are required")
		}
		absolute, err := filepath.Abs(lib.Path)
		if err != nil {
			return Config{}, err
		}
		lib.Path = filepath.Clean(absolute)
		if seen[lib.ID] {
			return Config{}, fmt.Errorf("duplicate library id %q", lib.ID)
		}
		seen[lib.ID] = true
	}
	return cfg, nil
}

func openDB(dataDir string) (*sql.DB, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.ToSlash(filepath.Join(dataDir, "locallens.db"))
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	const schema = `
CREATE TABLE IF NOT EXISTS libraries (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, root_path TEXT NOT NULL UNIQUE,
 recursive INTEGER NOT NULL, enabled INTEGER NOT NULL, last_scanned_at TEXT
);
CREATE TABLE IF NOT EXISTS media_items (
 id TEXT PRIMARY KEY, library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 relative_path TEXT NOT NULL, file_name TEXT NOT NULL, media_type TEXT NOT NULL,
 mime_type TEXT NOT NULL, size_bytes INTEGER NOT NULL, modified_at TEXT NOT NULL,
 missing INTEGER NOT NULL DEFAULT 0, last_seen_scan TEXT NOT NULL,
 UNIQUE(library_id, relative_path)
);
CREATE INDEX IF NOT EXISTS idx_media_type_modified ON media_items(media_type, modified_at DESC);
CREATE INDEX IF NOT EXISTS idx_media_library ON media_items(library_id);
`
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, db.Ping()
}

func (a *App) syncLibraries(ctx context.Context) error {
	stmt, err := a.db.PrepareContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES(?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET name=excluded.name,root_path=excluded.root_path,
recursive=excluded.recursive,enabled=excluded.enabled`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, lib := range a.cfg.Libraries {
		if _, err := stmt.ExecContext(ctx, lib.ID, lib.Name, lib.Path, lib.Recursive, lib.Enabled); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) startScan() bool {
	a.mu.Lock()
	if a.scan.Running {
		a.mu.Unlock()
		return false
	}
	now := time.Now().UTC()
	a.scan = ScanStatus{Running: true, StartedAt: &now}
	a.mu.Unlock()
	go a.runScan()
	return true
}

func (a *App) runScan() {
	ctx := context.Background()
	var runErr error
	for _, lib := range a.cfg.Libraries {
		if !lib.Enabled {
			continue
		}
		a.mu.Lock()
		a.scan.Current = lib.Name
		a.mu.Unlock()
		if err := a.scanLibrary(ctx, lib); err != nil {
			runErr = err
			break
		}
	}
	finished := time.Now().UTC()
	a.mu.Lock()
	a.scan.Running = false
	a.scan.FinishedAt = &finished
	if runErr != nil {
		a.scan.ErrorMessage = runErr.Error()
	}
	a.mu.Unlock()
}

func (a *App) scanLibrary(ctx context.Context, lib Library) error {
	if info, err := os.Stat(lib.Path); err != nil || !info.IsDir() {
		return fmt.Errorf("library unavailable: %s", lib.Path)
	}
	scanID := randomID()
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.PrepareContext(ctx, `
INSERT INTO media_items(id,library_id,relative_path,file_name,media_type,mime_type,size_bytes,modified_at,missing,last_seen_scan)
VALUES(?,?,?,?,?,?,?,?,0,?)
ON CONFLICT(library_id,relative_path) DO UPDATE SET
id=excluded.id,file_name=excluded.file_name,media_type=excluded.media_type,
mime_type=excluded.mime_type,size_bytes=excluded.size_bytes,modified_at=excluded.modified_at,
missing=0,last_seen_scan=excluded.last_seen_scan`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	err = filepath.WalkDir(lib.Path, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			a.addFailed()
			return nil
		}
		if entry.IsDir() {
			if path != lib.Path && !lib.Recursive {
				return filepath.SkipDir
			}
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		mimeType, ok := mediaTypes[ext]
		if !ok {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			a.addFailed()
			return nil
		}
		relative, err := filepath.Rel(lib.Path, path)
		if err != nil {
			return nil
		}
		relative = filepath.ToSlash(relative)
		mediaType := "image"
		if strings.HasPrefix(mimeType, "video/") {
			mediaType = "video"
		}
		a.mu.Lock()
		a.scan.Discovered++
		a.mu.Unlock()
		if _, err := stmt.ExecContext(
			ctx, stableID(lib.ID, relative), lib.ID, relative, entry.Name(), mediaType,
			mimeType, info.Size(), info.ModTime().UTC().Format(time.RFC3339Nano), scanID,
		); err != nil {
			return err
		}
		a.mu.Lock()
		a.scan.Indexed++
		a.mu.Unlock()
		return nil
	})
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE media_items SET missing=1 WHERE library_id=? AND last_seen_scan<>?`, lib.ID, scanID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE libraries SET last_scanned_at=? WHERE id=?`, time.Now().UTC().Format(time.RFC3339Nano), lib.ID); err != nil {
		return err
	}
	return tx.Commit()
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /api/v1/server", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]string{"name": a.cfg.ServerName, "version": version, "apiVersion": "v1"})
	})
	mux.Handle("GET /api/v1/libraries", a.auth(http.HandlerFunc(a.libraries)))
	mux.Handle("GET /api/v1/media", a.auth(http.HandlerFunc(a.mediaList)))
	mux.Handle("GET /api/v1/media/{id}", a.auth(http.HandlerFunc(a.mediaDetail)))
	mux.Handle("GET /api/v1/media/{id}/thumbnail", a.auth(http.HandlerFunc(a.thumbnail)))
	mux.Handle("GET /api/v1/media/{id}/original", a.auth(http.HandlerFunc(a.original)))
	mux.Handle("GET /api/v1/media/{id}/stream", a.auth(http.HandlerFunc(a.original)))
	mux.Handle("POST /api/v1/scan", a.auth(http.HandlerFunc(a.scanStart)))
	mux.Handle("GET /api/v1/scan", a.auth(http.HandlerFunc(a.scanState)))
	return a.cors(mux)
}

func (a *App) libraries(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.QueryContext(r.Context(), `SELECT id,name,recursive,enabled,last_scanned_at FROM libraries ORDER BY name`)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id, name string
		var recursive, enabled bool
		var last sql.NullString
		if err := rows.Scan(&id, &name, &recursive, &enabled, &last); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		items = append(items, map[string]any{"id": id, "name": name, "recursive": recursive, "enabled": enabled, "lastScannedAt": last.String})
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (a *App) mediaList(w http.ResponseWriter, r *http.Request) {
	limit := clampInt(queryInt(r, "limit", 100), 1, 200)
	offset := max(queryInt(r, "offset", 0), 0)
	kind := r.URL.Query().Get("type")
	search := strings.TrimSpace(r.URL.Query().Get("q"))
	where, args := "m.missing=0", []any{}
	if kind == "image" || kind == "video" {
		where += " AND m.media_type=?"
		args = append(args, kind)
	}
	if search != "" {
		where += " AND m.file_name LIKE ?"
		args = append(args, "%"+search+"%")
	}
	var total int64
	_ = a.db.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM media_items m WHERE `+where, args...).Scan(&total)
	query := `SELECT m.id,m.library_id,l.root_path,m.relative_path,m.file_name,m.media_type,m.mime_type,m.size_bytes,m.modified_at,m.missing
FROM media_items m JOIN libraries l ON l.id=m.library_id WHERE ` + where + ` ORDER BY m.modified_at DESC,m.id DESC LIMIT ? OFFSET ?`
	rows, err := a.db.QueryContext(r.Context(), query, append(args, limit, offset)...)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		item, err := scanMedia(rows)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		items = append(items, response(item))
	}
	writeJSON(w, 200, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func (a *App) mediaDetail(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if ok {
		writeJSON(w, 200, response(item))
	}
}

func (a *App) thumbnail(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if !ok {
		return
	}
	width := clampInt(queryInt(r, "width", 480), 64, 1920)
	path := filepath.Join(a.cfg.DataDir, "thumbnails", item.ID[:2], fmt.Sprintf("%s-%d-%d.jpg", item.ID, item.ModifiedAt.Unix(), width))
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		if a.cfg.FFmpegPath == "" {
			http.Error(w, "ffmpeg is required for thumbnails", 503)
			return
		}
		args := []string{"-hide_banner", "-loglevel", "error"}
		if item.Type == "video" {
			args = append(args, "-ss", "2")
		}
		args = append(args, "-i", item.Path(), "-frames:v", "1", "-vf", "scale="+strconv.Itoa(width)+":-2", "-q:v", "4", "-y", path)
		if output, err := exec.CommandContext(r.Context(), a.cfg.FFmpegPath, args...).CombinedOutput(); err != nil {
			a.logger.Warn("thumbnail", "error", err, "output", string(output))
			http.Error(w, "thumbnail unavailable", 503)
			return
		}
	}
	serveFile(w, r, path, "image/jpeg")
}

func (a *App) original(w http.ResponseWriter, r *http.Request) {
	item, ok := a.findMedia(w, r)
	if ok {
		serveFile(w, r, item.Path(), item.MIMEType)
	}
}

func (a *App) scanStart(w http.ResponseWriter, _ *http.Request) {
	if !a.startScan() {
		http.Error(w, "scan already running", 409)
		return
	}
	a.scanState(w, nil)
}

func (a *App) scanState(w http.ResponseWriter, _ *http.Request) {
	a.mu.RLock()
	status := a.scan
	a.mu.RUnlock()
	writeJSON(w, 200, status)
}

func (a *App) findMedia(w http.ResponseWriter, r *http.Request) (Media, bool) {
	row := a.db.QueryRowContext(r.Context(), `SELECT m.id,m.library_id,l.root_path,m.relative_path,m.file_name,m.media_type,m.mime_type,m.size_bytes,m.modified_at,m.missing
FROM media_items m JOIN libraries l ON l.id=m.library_id WHERE m.id=?`, r.PathValue("id"))
	item, err := scanMedia(row)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "media not found", 404)
		return Media{}, false
	}
	if err != nil {
		http.Error(w, err.Error(), 500)
		return Media{}, false
	}
	if item.Missing {
		http.Error(w, "media missing", 410)
		return Media{}, false
	}
	if !within(item.RootPath, item.Path()) {
		http.Error(w, "forbidden", 403)
		return Media{}, false
	}
	return item, true
}

type scanner interface{ Scan(...any) error }

func scanMedia(row scanner) (Media, error) {
	var item Media
	var modified string
	if err := row.Scan(&item.ID, &item.LibraryID, &item.RootPath, &item.RelativePath, &item.FileName, &item.Type, &item.MIMEType, &item.SizeBytes, &modified, &item.Missing); err != nil {
		return Media{}, err
	}
	parsed, err := time.Parse(time.RFC3339Nano, modified)
	item.ModifiedAt = parsed
	return item, err
}

func response(item Media) map[string]any {
	base := "/api/v1/media/" + item.ID
	return map[string]any{
		"id": item.ID, "libraryId": item.LibraryID, "fileName": item.FileName,
		"type": item.Type, "mimeType": item.MIMEType, "sizeBytes": item.SizeBytes,
		"modifiedAt": item.ModifiedAt, "thumbnailUrl": base + "/thumbnail?width=480",
		"originalUrl": base + "/original", "streamUrl": base + "/stream",
	}
}

func serveFile(w http.ResponseWriter, r *http.Request, path, contentType string) {
	file, err := os.Open(path)
	if err != nil {
		http.Error(w, "file unavailable", 404)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		http.Error(w, err.Error(), 500)
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
			http.Error(w, "unauthorized", 401)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *App) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Range")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Expose-Headers", "Accept-Ranges, Content-Length, Content-Range")
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func stableID(libraryID, relative string) string {
	hash := sha256.Sum256([]byte(libraryID + "\x00" + strings.ToLower(relative)))
	return hex.EncodeToString(hash[:16])
}

func randomID() string {
	data := make([]byte, 16)
	_, _ = rand.Read(data)
	return hex.EncodeToString(data)
}

func within(root, target string) bool {
	relative, err := filepath.Rel(filepath.Clean(root), filepath.Clean(target))
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func queryInt(r *http.Request, key string, fallback int) int {
	value, err := strconv.Atoi(r.URL.Query().Get(key))
	if err != nil {
		return fallback
	}
	return value
}

func clampInt(value, low, high int) int { return min(max(value, low), high) }

func (a *App) addFailed() {
	a.mu.Lock()
	a.scan.Failed++
	a.mu.Unlock()
}

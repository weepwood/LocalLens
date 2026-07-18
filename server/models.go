package main

import (
	"database/sql"
	"log/slog"
	"path/filepath"
	"sync"
	"time"
)

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
	Favorite     bool      `json:"favorite"`
}

func (m Media) Path() string {
	return filepath.Join(m.RootPath, filepath.FromSlash(m.RelativePath))
}

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

func newApp(cfg Config, db *sql.DB, logger *slog.Logger) *App {
	return &App{cfg: cfg, db: db, logger: logger}
}

type MediaPage struct {
	Items      []Media
	Total      int64
	Limit      int
	Offset     int
	NextCursor string
	HasMore    bool
}

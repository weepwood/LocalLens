package main

import (
	"context"
	"database/sql"
	"log/slog"
	"path/filepath"
	"sync"
	"time"
)

var mediaTypes = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
	".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
	".tif": "image/tiff", ".tiff": "image/tiff", ".heic": "image/heic",
	".mp4": "video/mp4", ".m4v": "video/x-m4v", ".mov": "video/quicktime",
	".mkv": "video/x-matroska", ".avi": "video/x-msvideo", ".webm": "video/webm",
}

type Config struct {
	ListenAddress    string    `json:"listen_address"`
	PublicURL        string    `json:"public_url"`
	ServerName       string    `json:"server_name"`
	DataDir          string    `json:"data_dir"`
	APIToken         string    `json:"api_token"`
	FFmpegPath       string    `json:"ffmpeg_path"`
	FFprobePath      string    `json:"ffprobe_path"`
	AutoScan         bool      `json:"auto_scan"`
	WatchFiles       bool      `json:"watch_files"`
	ThumbnailWorkers int       `json:"thumbnail_workers"`
	MetadataWorkers  int       `json:"metadata_workers"`
	PairingTTLMinutes int      `json:"pairing_ttl_minutes"`
	Libraries        []Library `json:"libraries"`
}

type Library struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Path      string `json:"path,omitempty"`
	Recursive bool   `json:"recursive"`
	Enabled   bool   `json:"enabled"`
}

type Media struct {
	ID               string     `json:"id"`
	LibraryID        string     `json:"libraryId"`
	RootPath         string     `json:"-"`
	RelativePath     string     `json:"relativePath"`
	FolderPath       string     `json:"folderPath"`
	FileName         string     `json:"fileName"`
	Type             string     `json:"type"`
	MIMEType         string     `json:"mimeType"`
	SizeBytes        int64      `json:"sizeBytes"`
	ModifiedAt       time.Time  `json:"modifiedAt"`
	CapturedAt       time.Time  `json:"capturedAt"`
	CapturedAtSource string     `json:"capturedAtSource"`
	Width            int        `json:"width"`
	Height           int        `json:"height"`
	DurationMS       int64      `json:"durationMs"`
	Codec            string     `json:"codec"`
	Latitude         *float64   `json:"latitude,omitempty"`
	Longitude        *float64   `json:"longitude,omitempty"`
	CameraModel      string     `json:"cameraModel,omitempty"`
	MetadataStatus   string     `json:"metadataStatus"`
	MetadataError    string     `json:"metadataError,omitempty"`
	Missing          bool       `json:"missing"`
	Favorite         bool       `json:"favorite"`
	Rating           int        `json:"rating"`
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

type MediaPage struct {
	Items      []Media
	Total      int64
	Limit      int
	Offset     int
	NextCursor string
	HasMore    bool
}

type FolderInfo struct {
	ID         string `json:"id"`
	LibraryID  string `json:"libraryId"`
	Path       string `json:"path"`
	ParentPath string `json:"parentPath"`
	Name       string `json:"name"`
	MediaCount int64  `json:"mediaCount"`
	ChildCount int64  `json:"childCount"`
}

type ThumbnailJob struct {
	MediaID         string
	Width           int
	SourceModifiedAt string
	Attempts        int
}

type MetadataJob struct {
	MediaID          string
	SourceModifiedAt string
	Attempts         int
}

type PlaybackProgress struct {
	DeviceID   string    `json:"deviceId"`
	MediaID    string    `json:"mediaId"`
	PositionMS int64     `json:"positionMs"`
	DurationMS int64     `json:"durationMs"`
	Completed  bool      `json:"completed"`
	UpdatedAt  time.Time `json:"updatedAt"`
}

type Album struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description"`
	ItemCount   int64     `json:"itemCount"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

type Tag struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Color     string    `json:"color"`
	ItemCount int64     `json:"itemCount"`
	CreatedAt time.Time `json:"createdAt"`
}

type Device struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Platform   string     `json:"platform"`
	Scopes     string     `json:"scopes"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastSeenAt *time.Time `json:"lastSeenAt,omitempty"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
}

type AuthIdentity struct {
	DeviceID string
	Name     string
	Admin    bool
	Scopes   string
}

type PairingSession struct {
	ID         string
	SecretHash string
	Payload    string
	ExpiresAt  time.Time
}

type PairingManager struct {
	mu       sync.Mutex
	sessions map[string]PairingSession
}

type App struct {
	cfg    Config
	db     *sql.DB
	logger *slog.Logger

	mu   sync.RWMutex
	scan ScanStatus

	serviceCtx    context.Context
	serviceCancel context.CancelFunc
	workerWG      sync.WaitGroup
	thumbnailWake chan struct{}
	metadataWake  chan struct{}
	watcher       *FileWatcher
	pairing       *PairingManager
}

func newApp(cfg Config, db *sql.DB, logger *slog.Logger) *App {
	ctx, cancel := context.WithCancel(context.Background())
	return &App{
		cfg: cfg,
		db: db,
		logger: logger,
		serviceCtx: ctx,
		serviceCancel: cancel,
		thumbnailWake: make(chan struct{}, 1),
		metadataWake: make(chan struct{}, 1),
		pairing: &PairingManager{sessions: make(map[string]PairingSession)},
	}
}

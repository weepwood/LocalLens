package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type migration struct {
	version int
	apply   func(*sql.Tx) error
}

func openDB(dataDir string) (*sql.DB, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.ToSlash(filepath.Join(dataDir, "locallens.db"))
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(15000)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// WAL allows readers to continue while a writer is active, but SQLite still
	// permits only one writer. Keep a bounded pool and let busy_timeout absorb
	// short write bursts from the watcher, API and background workers.
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(4)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := runMigrations(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func runMigrations(db *sql.DB) error {
	if _, err := db.Exec(`
CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);`); err != nil {
		return err
	}

	migrations := []migration{
		{version: 1, apply: migrateBaseSchema},
		{version: 2, apply: migrateFavorites},
		{version: 3, apply: migrateMediaMetadata},
		{version: 4, apply: migrateFolders},
		{version: 5, apply: migrateJobs},
		{version: 6, apply: migrateDevicesAndPlayback},
		{version: 7, apply: migrateCollections},
		{version: 8, apply: migrateV02Indexes},
	}

	for _, item := range migrations {
		var applied int
		if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations WHERE version=?`, item.version).Scan(&applied); err != nil {
			return err
		}
		if applied > 0 {
			continue
		}
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		if err := item.apply(tx); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("migration %d: %w", item.version, err)
		}
		if _, err := tx.Exec(
			`INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)`,
			item.version,
			time.Now().UTC().Format(time.RFC3339Nano),
		); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

func migrateBaseSchema(tx *sql.Tx) error {
	_, err := tx.Exec(`
CREATE TABLE IF NOT EXISTS libraries (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  root_path TEXT NOT NULL UNIQUE,
  recursive INTEGER NOT NULL,
  enabled INTEGER NOT NULL,
  last_scanned_at TEXT
);
CREATE TABLE IF NOT EXISTS media_items (
  id TEXT PRIMARY KEY,
  library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  media_type TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  modified_at TEXT NOT NULL,
  missing INTEGER NOT NULL DEFAULT 0,
  last_seen_scan TEXT NOT NULL,
  UNIQUE(library_id, relative_path)
);
CREATE INDEX IF NOT EXISTS idx_media_type_modified
  ON media_items(media_type, modified_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_media_library
  ON media_items(library_id);
`)
	return err
}

func migrateFavorites(tx *sql.Tx) error {
	if err := addColumnIfMissing(tx, "media_items", "favorite", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	_, err := tx.Exec(`CREATE INDEX IF NOT EXISTS idx_media_favorite_modified ON media_items(favorite, modified_at DESC, id DESC)`)
	return err
}

func migrateMediaMetadata(tx *sql.Tx) error {
	columns := []struct {
		name string
		def  string
	}{
		{"folder_path", "TEXT NOT NULL DEFAULT ''"},
		{"captured_at", "TEXT"},
		{"captured_at_source", "TEXT NOT NULL DEFAULT 'modified'"},
		{"width", "INTEGER NOT NULL DEFAULT 0"},
		{"height", "INTEGER NOT NULL DEFAULT 0"},
		{"duration_ms", "INTEGER NOT NULL DEFAULT 0"},
		{"codec", "TEXT NOT NULL DEFAULT ''"},
		{"latitude", "REAL"},
		{"longitude", "REAL"},
		{"camera_model", "TEXT NOT NULL DEFAULT ''"},
		{"metadata_status", "TEXT NOT NULL DEFAULT 'pending'"},
		{"metadata_error", "TEXT NOT NULL DEFAULT ''"},
		{"rating", "INTEGER NOT NULL DEFAULT 0"},
	}
	for _, column := range columns {
		if err := addColumnIfMissing(tx, "media_items", column.name, column.def); err != nil {
			return err
		}
	}
	_, err := tx.Exec(`
UPDATE media_items
SET captured_at=modified_at,
    captured_at_source='modified'
WHERE captured_at IS NULL OR captured_at='';
CREATE INDEX IF NOT EXISTS idx_media_captured
  ON media_items(captured_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_media_folder
  ON media_items(library_id, folder_path, captured_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_media_rating
  ON media_items(rating, captured_at DESC, id DESC);
`)
	return err
}

func migrateFolders(tx *sql.Tx) error {
	_, err := tx.Exec(`
CREATE TABLE IF NOT EXISTS folders (
  id TEXT PRIMARY KEY,
  library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL,
  parent_path TEXT NOT NULL,
  name TEXT NOT NULL,
  missing INTEGER NOT NULL DEFAULT 0,
  last_seen_scan TEXT NOT NULL,
  UNIQUE(library_id, relative_path)
);
CREATE INDEX IF NOT EXISTS idx_folders_parent
  ON folders(library_id, parent_path, name);
`)
	return err
}

func migrateJobs(tx *sql.Tx) error {
	_, err := tx.Exec(`
CREATE TABLE IF NOT EXISTS thumbnail_jobs (
  media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  width INTEGER NOT NULL,
  source_modified_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(media_id, width)
);
CREATE INDEX IF NOT EXISTS idx_thumbnail_jobs_status
  ON thumbnail_jobs(status, updated_at);
CREATE TABLE IF NOT EXISTS metadata_jobs (
  media_id TEXT PRIMARY KEY REFERENCES media_items(id) ON DELETE CASCADE,
  source_modified_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_metadata_jobs_status
  ON metadata_jobs(status, updated_at);
UPDATE thumbnail_jobs SET status='pending' WHERE status='running';
UPDATE metadata_jobs SET status='pending' WHERE status='running';
`)
	return err
}

func migrateDevicesAndPlayback(tx *sql.Tx) error {
	_, err := tx.Exec(`
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  scopes TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_devices_token
  ON devices(token_hash, revoked_at);
CREATE TABLE IF NOT EXISTS playback_progress (
  device_id TEXT NOT NULL,
  media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  position_ms INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(device_id, media_id)
);
CREATE INDEX IF NOT EXISTS idx_playback_updated
  ON playback_progress(device_id, updated_at DESC);
`)
	return err
}

func migrateCollections(tx *sql.Tx) error {
	_, err := tx.Exec(`
CREATE TABLE IF NOT EXISTS albums (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS album_items (
  album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  position INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL,
  PRIMARY KEY(album_id, media_id)
);
CREATE INDEX IF NOT EXISTS idx_album_items_media ON album_items(media_id);
CREATE TABLE IF NOT EXISTS tags (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL COLLATE NOCASE UNIQUE,
  color TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS media_tags (
  media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  added_at TEXT NOT NULL,
  PRIMARY KEY(media_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_media_tags_tag ON media_tags(tag_id, media_id);
`)
	return err
}

func migrateV02Indexes(tx *sql.Tx) error {
	_, err := tx.Exec(`
CREATE INDEX IF NOT EXISTS idx_media_library_captured
  ON media_items(library_id, captured_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_media_missing_captured
  ON media_items(missing, captured_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_media_metadata_status
  ON media_items(metadata_status, modified_at);
`)
	return err
}

func addColumnIfMissing(tx *sql.Tx, table, column, definition string) error {
	rows, err := tx.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return err
	}
	found := false
	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull, primaryKey int
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			_ = rows.Close()
			return err
		}
		if name == column {
			found = true
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if found {
		return nil
	}
	_, err = tx.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + definition)
	return err
}

func (a *App) syncLibraries(ctx context.Context) error {
	stmt, err := a.db.PrepareContext(ctx, `
INSERT INTO libraries(id,name,root_path,recursive,enabled)
VALUES(?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET
  name=excluded.name,
  root_path=excluded.root_path,
  recursive=excluded.recursive,
  enabled=excluded.enabled`)
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

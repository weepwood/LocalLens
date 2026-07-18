package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"
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
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)

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
	rows, err := tx.Query(`PRAGMA table_info(media_items)`)
	if err != nil {
		return err
	}
	hasFavorite := false
	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull, primaryKey int
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			_ = rows.Close()
			return err
		}
		if name == "favorite" {
			hasFavorite = true
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if !hasFavorite {
		if _, err := tx.Exec(`ALTER TABLE media_items ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0`); err != nil {
			return err
		}
	}
	_, err = tx.Exec(`CREATE INDEX IF NOT EXISTS idx_media_favorite_modified ON media_items(favorite, modified_at DESC, id DESC)`)
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

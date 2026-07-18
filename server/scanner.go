package main

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

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
	errorsFound := make([]string, 0)
	for _, lib := range a.cfg.Libraries {
		if !lib.Enabled {
			continue
		}
		a.mu.Lock()
		a.scan.Current = lib.Name
		a.mu.Unlock()
		if err := a.scanLibrary(ctx, lib); err != nil {
			a.logger.Warn("scan library", "library", lib.ID, "error", err)
			errorsFound = append(errorsFound, fmt.Sprintf("%s: %v", lib.Name, err))
		}
	}

	finished := time.Now().UTC()
	a.mu.Lock()
	a.scan.Running = false
	a.scan.Current = ""
	a.scan.FinishedAt = &finished
	if len(errorsFound) > 0 {
		a.scan.ErrorMessage = strings.Join(errorsFound, "; ")
	}
	a.mu.Unlock()
}

func (a *App) scanLibrary(ctx context.Context, lib Library) error {
	info, err := os.Stat(lib.Path)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("library unavailable: %s", lib.Path)
	}

	scanID := randomID()
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	stmt, err := tx.PrepareContext(ctx, `
INSERT INTO media_items(
  id,library_id,relative_path,file_name,media_type,mime_type,
  size_bytes,modified_at,missing,last_seen_scan
)
VALUES(?,?,?,?,?,?,?,?,0,?)
ON CONFLICT(library_id,relative_path) DO UPDATE SET
  id=excluded.id,
  file_name=excluded.file_name,
  media_type=excluded.media_type,
  mime_type=excluded.mime_type,
  size_bytes=excluded.size_bytes,
  modified_at=excluded.modified_at,
  missing=0,
  last_seen_scan=excluded.last_seen_scan`)
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
		fileInfo, err := entry.Info()
		if err != nil {
			a.addFailed()
			return nil
		}
		relative, err := filepath.Rel(lib.Path, path)
		if err != nil {
			a.addFailed()
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
			ctx,
			stableID(lib.ID, relative),
			lib.ID,
			relative,
			entry.Name(),
			mediaType,
			mimeType,
			fileInfo.Size(),
			fileInfo.ModTime().UTC().Format(time.RFC3339Nano),
			scanID,
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
	if _, err := tx.ExecContext(
		ctx,
		`UPDATE media_items SET missing=1 WHERE library_id=? AND last_seen_scan<>?`,
		lib.ID,
		scanID,
	); err != nil {
		return err
	}
	if _, err := tx.ExecContext(
		ctx,
		`UPDATE libraries SET last_scanned_at=? WHERE id=?`,
		time.Now().UTC().Format(time.RFC3339Nano),
		lib.ID,
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (a *App) addFailed() {
	a.mu.Lock()
	a.scan.Failed++
	a.mu.Unlock()
}

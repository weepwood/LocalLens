package main

import (
	"context"
	"database/sql"
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
	ctx := a.serviceCtx
	errorsFound := make([]string, 0)
	for _, lib := range a.cfg.Libraries {
		if !lib.Enabled || ctx.Err() != nil {
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

	statements, err := prepareIndexStatements(ctx, tx)
	if err != nil {
		return err
	}
	defer statements.close()

	if err := statements.upsertFolder(ctx, lib, "", "", lib.Name, scanID); err != nil {
		return err
	}

	err = filepath.WalkDir(lib.Path, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			a.addFailed()
			return nil
		}
		if entry.IsDir() {
			if path != lib.Path && !lib.Recursive {
				return filepath.SkipDir
			}
			if path == lib.Path {
				return nil
			}
			relative, err := filepath.Rel(lib.Path, path)
			if err != nil {
				a.addFailed()
				return nil
			}
			relative = filepath.ToSlash(relative)
			parent := parentFolder(relative)
			return statements.upsertFolder(ctx, lib, relative, parent, entry.Name(), scanID)
		}

		if _, ok := mediaTypes[strings.ToLower(filepath.Ext(path))]; !ok {
			return nil
		}
		fileInfo, err := entry.Info()
		if err != nil {
			a.addFailed()
			return nil
		}
		if err := a.indexMediaFile(ctx, statements, lib, path, fileInfo, scanID); err != nil {
			return err
		}
		a.mu.Lock()
		a.scan.Discovered++
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
	if _, err := tx.ExecContext(ctx, `UPDATE folders SET missing=1 WHERE library_id=? AND last_seen_scan<>?`, lib.ID, scanID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE libraries SET last_scanned_at=? WHERE id=?`, time.Now().UTC().Format(time.RFC3339Nano), lib.ID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	a.wakeMetadataWorkers()
	a.wakeThumbnailWorkers()
	return nil
}

type indexStatements struct {
	media    *sql.Stmt
	folder   *sql.Stmt
	metadata *sql.Stmt
	thumb    *sql.Stmt
}

func prepareIndexStatements(ctx context.Context, tx *sql.Tx) (*indexStatements, error) {
	media, err := tx.PrepareContext(ctx, `
INSERT INTO media_items(
  id,library_id,relative_path,folder_path,file_name,media_type,mime_type,
  size_bytes,modified_at,captured_at,captured_at_source,missing,last_seen_scan,
  metadata_status,metadata_error
)
VALUES(?,?,?,?,?,?,?,?,?,?,?,0,?,'pending','')
ON CONFLICT(library_id,relative_path) DO UPDATE SET
  id=excluded.id,
  folder_path=excluded.folder_path,
  file_name=excluded.file_name,
  media_type=excluded.media_type,
  mime_type=excluded.mime_type,
  size_bytes=excluded.size_bytes,
  captured_at=CASE WHEN media_items.modified_at<>excluded.modified_at THEN excluded.modified_at ELSE media_items.captured_at END,
  captured_at_source=CASE WHEN media_items.modified_at<>excluded.modified_at THEN 'modified' ELSE media_items.captured_at_source END,
  metadata_status=CASE WHEN media_items.modified_at<>excluded.modified_at THEN 'pending' ELSE media_items.metadata_status END,
  metadata_error=CASE WHEN media_items.modified_at<>excluded.modified_at THEN '' ELSE media_items.metadata_error END,
  modified_at=excluded.modified_at,
  missing=0,
  last_seen_scan=excluded.last_seen_scan`)
	if err != nil {
		return nil, err
	}
	folder, err := tx.PrepareContext(ctx, `
INSERT INTO folders(id,library_id,relative_path,parent_path,name,missing,last_seen_scan)
VALUES(?,?,?,?,?,0,?)
ON CONFLICT(library_id,relative_path) DO UPDATE SET
  id=excluded.id,parent_path=excluded.parent_path,name=excluded.name,
  missing=0,last_seen_scan=excluded.last_seen_scan`)
	if err != nil {
		_ = media.Close()
		return nil, err
	}
	metadata, err := tx.PrepareContext(ctx, `
INSERT INTO metadata_jobs(media_id,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,?,'pending',0,'',?,?)
ON CONFLICT(media_id) DO UPDATE SET
  source_modified_at=excluded.source_modified_at,
  status=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN 'pending' ELSE metadata_jobs.status END,
  attempts=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE metadata_jobs.attempts END,
  last_error=CASE WHEN metadata_jobs.source_modified_at<>excluded.source_modified_at THEN '' ELSE metadata_jobs.last_error END,
  updated_at=excluded.updated_at`)
	if err != nil {
		_ = media.Close()
		_ = folder.Close()
		return nil, err
	}
	thumb, err := tx.PrepareContext(ctx, `
INSERT INTO thumbnail_jobs(media_id,width,source_modified_at,status,attempts,last_error,created_at,updated_at)
VALUES(?,480,?,'pending',0,'',?,?)
ON CONFLICT(media_id,width) DO UPDATE SET
  source_modified_at=excluded.source_modified_at,
  status=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN 'pending' ELSE thumbnail_jobs.status END,
  attempts=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN 0 ELSE thumbnail_jobs.attempts END,
  last_error=CASE WHEN thumbnail_jobs.source_modified_at<>excluded.source_modified_at THEN '' ELSE thumbnail_jobs.last_error END,
  updated_at=excluded.updated_at`)
	if err != nil {
		_ = media.Close()
		_ = folder.Close()
		_ = metadata.Close()
		return nil, err
	}
	return &indexStatements{media: media, folder: folder, metadata: metadata, thumb: thumb}, nil
}

func (s *indexStatements) close() {
	_ = s.media.Close()
	_ = s.folder.Close()
	_ = s.metadata.Close()
	_ = s.thumb.Close()
}

func (s *indexStatements) upsertFolder(ctx context.Context, lib Library, relative, parent, name, scanID string) error {
	_, err := s.folder.ExecContext(ctx, stableID(lib.ID, "folder\x00"+relative), lib.ID, relative, parent, name, scanID)
	return err
}

func (a *App) indexMediaFile(ctx context.Context, statements *indexStatements, lib Library, path string, fileInfo fs.FileInfo, scanID string) error {
	ext := strings.ToLower(filepath.Ext(path))
	mimeType, ok := mediaTypes[ext]
	if !ok {
		return nil
	}
	relative, err := filepath.Rel(lib.Path, path)
	if err != nil {
		return err
	}
	relative = filepath.ToSlash(relative)
	folderPath := parentFolder(relative)
	if folderPath != "" {
		if err := statements.upsertFolder(ctx, lib, folderPath, parentFolder(folderPath), filepath.Base(filepath.FromSlash(folderPath)), scanID); err != nil {
			return err
		}
	}
	mediaType := "image"
	if strings.HasPrefix(mimeType, "video/") {
		mediaType = "video"
	}
	modified := fileInfo.ModTime().UTC().Format(time.RFC3339Nano)
	id := stableID(lib.ID, relative)
	if _, err := statements.media.ExecContext(ctx, id, lib.ID, relative, folderPath, fileInfo.Name(), mediaType, mimeType, fileInfo.Size(), modified, modified, "modified", scanID); err != nil {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := statements.metadata.ExecContext(ctx, id, modified, now, now); err != nil {
		return err
	}
	if _, err := statements.thumb.ExecContext(ctx, id, modified, now, now); err != nil {
		return err
	}
	return nil
}

func (a *App) upsertSinglePath(ctx context.Context, lib Library, path string) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return a.markPathMissing(ctx, lib, path)
		}
		return err
	}
	if info.IsDir() {
		return a.scanSubtree(ctx, lib, path)
	}
	if _, ok := mediaTypes[strings.ToLower(filepath.Ext(path))]; !ok {
		return nil
	}
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	statements, err := prepareIndexStatements(ctx, tx)
	if err != nil {
		return err
	}
	defer statements.close()
	if err := a.indexMediaFile(ctx, statements, lib, path, info, randomID()); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	a.wakeMetadataWorkers()
	a.wakeThumbnailWorkers()
	return nil
}

func (a *App) scanSubtree(ctx context.Context, lib Library, root string) error {
	scanID := randomID()
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	statements, err := prepareIndexStatements(ctx, tx)
	if err != nil {
		return err
	}
	defer statements.close()
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if entry.IsDir() {
			relative, err := filepath.Rel(lib.Path, path)
			if err != nil {
				return nil
			}
			relative = filepath.ToSlash(relative)
			name := entry.Name()
			if relative == "." || relative == "" {
				relative, name = "", lib.Name
			}
			return statements.upsertFolder(ctx, lib, relative, parentFolder(relative), name, scanID)
		}
		info, err := entry.Info()
		if err != nil {
			return nil
		}
		return a.indexMediaFile(ctx, statements, lib, path, info, scanID)
	})
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	a.wakeMetadataWorkers()
	a.wakeThumbnailWorkers()
	return nil
}

func (a *App) markPathMissing(ctx context.Context, lib Library, path string) error {
	relative, err := filepath.Rel(lib.Path, path)
	if err != nil || relative == "." {
		return err
	}
	relative = filepath.ToSlash(relative)
	like := relative + "/%"
	if _, err := a.db.ExecContext(ctx, `
UPDATE media_items SET missing=1
WHERE library_id=? AND (relative_path=? OR folder_path=? OR folder_path LIKE ?)`, lib.ID, relative, relative, like); err != nil {
		return err
	}
	_, err = a.db.ExecContext(ctx, `
UPDATE folders SET missing=1
WHERE library_id=? AND (relative_path=? OR relative_path LIKE ?)`, lib.ID, relative, like)
	return err
}

func parentFolder(relative string) string {
	relative = filepath.ToSlash(strings.Trim(relative, "/"))
	if relative == "" {
		return ""
	}
	index := strings.LastIndex(relative, "/")
	if index < 0 {
		return ""
	}
	return relative[:index]
}

func (a *App) addFailed() {
	a.mu.Lock()
	a.scan.Failed++
	a.mu.Unlock()
}

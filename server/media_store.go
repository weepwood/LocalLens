package main

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

type mediaCursor struct {
	SortAt string `json:"sortAt"`
	ID     string `json:"id"`
}

type MediaQuery struct {
	Kind         string
	Search       string
	LibraryID    string
	FolderPath   string
	FolderSet    bool
	Recursive    bool
	FavoriteOnly bool
	AlbumID      string
	TagID        string
	MinRating    int
	Sort         string
	Limit        int
	Offset       int
	Cursor       string
}

func encodeCursor(item Media, sort string) string {
	sortAt := item.CapturedAt
	if sort == "modified" {
		sortAt = item.ModifiedAt
	}
	payload, _ := json.Marshal(mediaCursor{SortAt: sortAt.UTC().Format(time.RFC3339Nano), ID: item.ID})
	return base64.RawURLEncoding.EncodeToString(payload)
}

func decodeCursor(value string) (mediaCursor, error) {
	if strings.TrimSpace(value) == "" {
		return mediaCursor{}, errors.New("cursor is empty")
	}
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return mediaCursor{}, errors.New("invalid cursor encoding")
	}
	var cursor mediaCursor
	if err := json.Unmarshal(data, &cursor); err != nil {
		return mediaCursor{}, errors.New("invalid cursor payload")
	}
	if cursor.ID == "" || cursor.SortAt == "" {
		return mediaCursor{}, errors.New("invalid cursor fields")
	}
	if _, err := time.Parse(time.RFC3339Nano, cursor.SortAt); err != nil {
		return mediaCursor{}, errors.New("invalid cursor timestamp")
	}
	return cursor, nil
}

func (a *App) queryMedia(ctx context.Context, request MediaQuery) (MediaPage, error) {
	conditions := []string{"m.missing=0"}
	args := make([]any, 0, 16)
	if request.Kind == "image" || request.Kind == "video" {
		conditions = append(conditions, "m.media_type=?")
		args = append(args, request.Kind)
	}
	if request.LibraryID != "" {
		conditions = append(conditions, "m.library_id=?")
		args = append(args, request.LibraryID)
	}
	if request.FolderSet {
		if request.Recursive && request.FolderPath != "" {
			conditions = append(conditions, "(m.folder_path=? OR m.folder_path LIKE ?)")
			args = append(args, request.FolderPath, request.FolderPath+"/%")
		} else {
			conditions = append(conditions, "m.folder_path=?")
			args = append(args, request.FolderPath)
		}
	}
	if request.Search != "" {
		conditions = append(conditions, "(m.file_name LIKE ? OR m.relative_path LIKE ?)")
		args = append(args, "%"+request.Search+"%", "%"+request.Search+"%")
	}
	if request.FavoriteOnly {
		conditions = append(conditions, "m.favorite=1")
	}
	if request.MinRating > 0 {
		conditions = append(conditions, "m.rating>=?")
		args = append(args, clampInt(request.MinRating, 1, 5))
	}
	if request.AlbumID != "" {
		conditions = append(conditions, "EXISTS(SELECT 1 FROM album_items ai WHERE ai.media_id=m.id AND ai.album_id=?)")
		args = append(args, request.AlbumID)
	}
	if request.TagID != "" {
		conditions = append(conditions, "EXISTS(SELECT 1 FROM media_tags mt WHERE mt.media_id=m.id AND mt.tag_id=?)")
		args = append(args, request.TagID)
	}

	baseWhere := strings.Join(conditions, " AND ")
	var total int64
	if err := a.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM media_items m WHERE `+baseWhere, args...).Scan(&total); err != nil {
		return MediaPage{}, err
	}

	sort := request.Sort
	if sort == "" {
		sort = "timeline"
	}
	sortExpression := "COALESCE(NULLIF(m.captured_at,''),m.modified_at)"
	order := sortExpression + " DESC,m.id DESC"
	if sort == "modified" {
		sortExpression = "m.modified_at"
		order = "m.modified_at DESC,m.id DESC"
	} else if sort == "name" {
		order = "m.file_name COLLATE NOCASE ASC,m.id ASC"
		request.Cursor = ""
	}

	queryArgs := append([]any{}, args...)
	where := baseWhere
	if request.Cursor != "" {
		cursor, err := decodeCursor(request.Cursor)
		if err != nil {
			return MediaPage{}, err
		}
		where += " AND (" + sortExpression + " < ? OR (" + sortExpression + " = ? AND m.id < ?))"
		queryArgs = append(queryArgs, cursor.SortAt, cursor.SortAt, cursor.ID)
		request.Offset = 0
	}

	query := mediaSelectSQL + ` WHERE ` + where + ` ORDER BY ` + order + ` LIMIT ?`
	queryArgs = append(queryArgs, request.Limit+1)
	if request.Cursor == "" && request.Offset > 0 {
		query += " OFFSET ?"
		queryArgs = append(queryArgs, request.Offset)
	}
	rows, err := a.db.QueryContext(ctx, query, queryArgs...)
	if err != nil {
		return MediaPage{}, err
	}
	defer rows.Close()
	items := make([]Media, 0, request.Limit+1)
	for rows.Next() {
		item, err := scanMedia(rows)
		if err != nil {
			return MediaPage{}, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return MediaPage{}, err
	}
	hasMore := len(items) > request.Limit
	if hasMore {
		items = items[:request.Limit]
	}
	nextCursor := ""
	if hasMore && len(items) > 0 && sort != "name" {
		nextCursor = encodeCursor(items[len(items)-1], sort)
	}
	return MediaPage{Items: items, Total: total, Limit: request.Limit, Offset: request.Offset, NextCursor: nextCursor, HasMore: hasMore}, nil
}

const mediaSelectSQL = `
SELECT
  m.id,m.library_id,l.root_path,m.relative_path,m.folder_path,m.file_name,
  m.media_type,m.mime_type,m.size_bytes,m.modified_at,m.captured_at,
  m.captured_at_source,m.width,m.height,m.duration_ms,m.codec,
  m.latitude,m.longitude,m.camera_model,m.metadata_status,m.metadata_error,
  m.missing,m.favorite,m.rating
FROM media_items m
JOIN libraries l ON l.id=m.library_id`

func (a *App) findMediaByID(ctx context.Context, id string) (Media, error) {
	return scanMedia(a.db.QueryRowContext(ctx, mediaSelectSQL+` WHERE m.id=?`, id))
}

func (a *App) setFavorite(ctx context.Context, id string, favorite bool) error {
	return updateMediaValue(ctx, a.db, `UPDATE media_items SET favorite=? WHERE id=? AND missing=0`, favorite, id)
}

func (a *App) setRating(ctx context.Context, id string, rating int) error {
	if rating < 0 || rating > 5 {
		return errors.New("rating must be between 0 and 5")
	}
	return updateMediaValue(ctx, a.db, `UPDATE media_items SET rating=? WHERE id=? AND missing=0`, rating, id)
}

func updateMediaValue(ctx context.Context, db *sql.DB, query string, args ...any) error {
	result, err := db.ExecContext(ctx, query, args...)
	if err != nil {
		return err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if changed == 0 {
		return sql.ErrNoRows
	}
	return nil
}

type rowScanner interface{ Scan(...any) error }

func scanMedia(row rowScanner) (Media, error) {
	var item Media
	var modified, captured sql.NullString
	var latitude, longitude sql.NullFloat64
	if err := row.Scan(
		&item.ID, &item.LibraryID, &item.RootPath, &item.RelativePath, &item.FolderPath,
		&item.FileName, &item.Type, &item.MIMEType, &item.SizeBytes, &modified, &captured,
		&item.CapturedAtSource, &item.Width, &item.Height, &item.DurationMS, &item.Codec,
		&latitude, &longitude, &item.CameraModel, &item.MetadataStatus, &item.MetadataError,
		&item.Missing, &item.Favorite, &item.Rating,
	); err != nil {
		return Media{}, err
	}
	parsed, err := time.Parse(time.RFC3339Nano, modified.String)
	if err != nil {
		return Media{}, fmt.Errorf("parse modified time: %w", err)
	}
	item.ModifiedAt = parsed
	if captured.Valid && captured.String != "" {
		item.CapturedAt, _ = time.Parse(time.RFC3339Nano, captured.String)
	}
	if item.CapturedAt.IsZero() {
		item.CapturedAt = item.ModifiedAt
		item.CapturedAtSource = "modified"
	}
	if latitude.Valid {
		value := latitude.Float64
		item.Latitude = &value
	}
	if longitude.Valid {
		value := longitude.Float64
		item.Longitude = &value
	}
	return item, nil
}

func mediaResponse(item Media) map[string]any {
	base := "/api/v1/media/" + item.ID
	return map[string]any{
		"id": item.ID, "libraryId": item.LibraryID, "relativePath": item.RelativePath,
		"folderPath": item.FolderPath, "fileName": item.FileName, "type": item.Type,
		"mimeType": item.MIMEType, "sizeBytes": item.SizeBytes, "modifiedAt": item.ModifiedAt,
		"capturedAt": item.CapturedAt, "capturedAtSource": item.CapturedAtSource,
		"width": item.Width, "height": item.Height, "durationMs": item.DurationMS,
		"codec": item.Codec, "latitude": item.Latitude, "longitude": item.Longitude,
		"cameraModel": item.CameraModel, "metadataStatus": item.MetadataStatus,
		"metadataError": item.MetadataError, "favorite": item.Favorite, "rating": item.Rating,
		"thumbnailUrl": base + "/thumbnail?width=480", "originalUrl": base + "/original",
		"streamUrl": base + "/stream",
	}
}

func (a *App) listFolders(ctx context.Context, libraryID, parent string) ([]FolderInfo, error) {
	rows, err := a.db.QueryContext(ctx, `
SELECT f.id,f.library_id,f.relative_path,f.parent_path,f.name,
  (SELECT COUNT(*) FROM media_items m WHERE m.library_id=f.library_id AND m.folder_path=f.relative_path AND m.missing=0),
  (SELECT COUNT(*) FROM folders c WHERE c.library_id=f.library_id AND c.parent_path=f.relative_path AND c.missing=0)
FROM folders f
WHERE f.library_id=? AND f.parent_path=? AND f.relative_path<>'' AND f.missing=0
ORDER BY f.name COLLATE NOCASE`, libraryID, parent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []FolderInfo{}
	for rows.Next() {
		var item FolderInfo
		if err := rows.Scan(&item.ID, &item.LibraryID, &item.Path, &item.ParentPath, &item.Name, &item.MediaCount, &item.ChildCount); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (a *App) getPlaybackProgress(ctx context.Context, deviceID, mediaID string) (PlaybackProgress, error) {
	var progress PlaybackProgress
	var updated string
	err := a.db.QueryRowContext(ctx, `
SELECT device_id,media_id,position_ms,duration_ms,completed,updated_at
FROM playback_progress WHERE device_id=? AND media_id=?`, deviceID, mediaID).Scan(
		&progress.DeviceID, &progress.MediaID, &progress.PositionMS, &progress.DurationMS, &progress.Completed, &updated,
	)
	if err != nil {
		return PlaybackProgress{}, err
	}
	progress.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
	return progress, nil
}

func (a *App) savePlaybackProgress(ctx context.Context, progress PlaybackProgress) error {
	progress.PositionMS = max(progress.PositionMS, 0)
	progress.DurationMS = max(progress.DurationMS, 0)
	if progress.DurationMS > 0 && progress.PositionMS > progress.DurationMS {
		progress.PositionMS = progress.DurationMS
	}
	_, err := a.db.ExecContext(ctx, `
INSERT INTO playback_progress(device_id,media_id,position_ms,duration_ms,completed,updated_at)
VALUES(?,?,?,?,?,?)
ON CONFLICT(device_id,media_id) DO UPDATE SET
 position_ms=excluded.position_ms,duration_ms=excluded.duration_ms,
 completed=excluded.completed,updated_at=excluded.updated_at`,
		progress.DeviceID, progress.MediaID, progress.PositionMS, progress.DurationMS,
		progress.Completed, time.Now().UTC().Format(time.RFC3339Nano))
	return err
}

func (a *App) listAlbums(ctx context.Context) ([]Album, error) {
	rows, err := a.db.QueryContext(ctx, `
SELECT a.id,a.name,a.description,a.created_at,a.updated_at,COUNT(ai.media_id)
FROM albums a LEFT JOIN album_items ai ON ai.album_id=a.id
GROUP BY a.id ORDER BY a.updated_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Album{}
	for rows.Next() {
		var item Album
		var created, updated string
		if err := rows.Scan(&item.ID, &item.Name, &item.Description, &created, &updated, &item.ItemCount); err != nil {
			return nil, err
		}
		item.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
		item.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updated)
		items = append(items, item)
	}
	return items, rows.Err()
}

func (a *App) createAlbum(ctx context.Context, name, description string) (Album, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return Album{}, errors.New("album name is required")
	}
	now := time.Now().UTC()
	item := Album{ID: randomID(), Name: name, Description: strings.TrimSpace(description), CreatedAt: now, UpdatedAt: now}
	_, err := a.db.ExecContext(ctx, `INSERT INTO albums(id,name,description,created_at,updated_at) VALUES(?,?,?,?,?)`, item.ID, item.Name, item.Description, now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano))
	return item, err
}

func (a *App) deleteAlbum(ctx context.Context, id string) error {
	result, err := a.db.ExecContext(ctx, `DELETE FROM albums WHERE id=?`, id)
	if err != nil {
		return err
	}
	changed, _ := result.RowsAffected()
	if changed == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (a *App) setAlbumItem(ctx context.Context, albumID, mediaID string, add bool) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if add {
		_, err := a.db.ExecContext(ctx, `INSERT OR IGNORE INTO album_items(album_id,media_id,added_at) VALUES(?,?,?)`, albumID, mediaID, now)
		if err == nil {
			_, _ = a.db.ExecContext(ctx, `UPDATE albums SET updated_at=? WHERE id=?`, now, albumID)
		}
		return err
	}
	_, err := a.db.ExecContext(ctx, `DELETE FROM album_items WHERE album_id=? AND media_id=?`, albumID, mediaID)
	return err
}

func (a *App) listTags(ctx context.Context) ([]Tag, error) {
	rows, err := a.db.QueryContext(ctx, `
SELECT t.id,t.name,t.color,t.created_at,COUNT(mt.media_id)
FROM tags t LEFT JOIN media_tags mt ON mt.tag_id=t.id
GROUP BY t.id ORDER BY t.name COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Tag{}
	for rows.Next() {
		var item Tag
		var created string
		if err := rows.Scan(&item.ID, &item.Name, &item.Color, &created, &item.ItemCount); err != nil {
			return nil, err
		}
		item.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
		items = append(items, item)
	}
	return items, rows.Err()
}

func (a *App) createTag(ctx context.Context, name, color string) (Tag, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return Tag{}, errors.New("tag name is required")
	}
	item := Tag{ID: randomID(), Name: name, Color: strings.TrimSpace(color), CreatedAt: time.Now().UTC()}
	_, err := a.db.ExecContext(ctx, `INSERT INTO tags(id,name,color,created_at) VALUES(?,?,?,?)`, item.ID, item.Name, item.Color, item.CreatedAt.Format(time.RFC3339Nano))
	return item, err
}

func (a *App) deleteTag(ctx context.Context, id string) error {
	result, err := a.db.ExecContext(ctx, `DELETE FROM tags WHERE id=?`, id)
	if err != nil {
		return err
	}
	changed, _ := result.RowsAffected()
	if changed == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (a *App) setMediaTag(ctx context.Context, mediaID, tagID string, add bool) error {
	if add {
		_, err := a.db.ExecContext(ctx, `INSERT OR IGNORE INTO media_tags(media_id,tag_id,added_at) VALUES(?,?,?)`, mediaID, tagID, time.Now().UTC().Format(time.RFC3339Nano))
		return err
	}
	_, err := a.db.ExecContext(ctx, `DELETE FROM media_tags WHERE media_id=? AND tag_id=?`, mediaID, tagID)
	return err
}

func (a *App) mediaCollections(ctx context.Context, mediaID string) (albumIDs, tagIDs []string, err error) {
	albumIDs, err = queryStringColumn(ctx, a.db, `SELECT album_id FROM album_items WHERE media_id=? ORDER BY added_at`, mediaID)
	if err != nil {
		return nil, nil, err
	}
	tagIDs, err = queryStringColumn(ctx, a.db, `SELECT tag_id FROM media_tags WHERE media_id=? ORDER BY added_at`, mediaID)
	return albumIDs, tagIDs, err
}

func queryStringColumn(ctx context.Context, db *sql.DB, query string, arg any) ([]string, error) {
	rows, err := db.QueryContext(ctx, query, arg)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	values := []string{}
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			return nil, err
		}
		values = append(values, value)
	}
	return values, rows.Err()
}

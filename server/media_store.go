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
	ModifiedAt string `json:"modifiedAt"`
	ID         string `json:"id"`
}

func encodeCursor(item Media) string {
	payload, _ := json.Marshal(mediaCursor{
		ModifiedAt: item.ModifiedAt.UTC().Format(time.RFC3339Nano),
		ID:         item.ID,
	})
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
	if cursor.ID == "" || cursor.ModifiedAt == "" {
		return mediaCursor{}, errors.New("invalid cursor fields")
	}
	if _, err := time.Parse(time.RFC3339Nano, cursor.ModifiedAt); err != nil {
		return mediaCursor{}, errors.New("invalid cursor timestamp")
	}
	return cursor, nil
}

func (a *App) queryMedia(
	ctx context.Context,
	kind string,
	search string,
	libraryID string,
	favoriteOnly bool,
	limit int,
	offset int,
	cursorValue string,
) (MediaPage, error) {
	conditions := []string{"m.missing=0"}
	args := make([]any, 0, 8)
	if kind == "image" || kind == "video" {
		conditions = append(conditions, "m.media_type=?")
		args = append(args, kind)
	}
	if libraryID != "" {
		conditions = append(conditions, "m.library_id=?")
		args = append(args, libraryID)
	}
	if search != "" {
		conditions = append(conditions, "m.file_name LIKE ?")
		args = append(args, "%"+search+"%")
	}
	if favoriteOnly {
		conditions = append(conditions, "m.favorite=1")
	}

	baseWhere := strings.Join(conditions, " AND ")
	var total int64
	if err := a.db.QueryRowContext(
		ctx,
		`SELECT COUNT(*) FROM media_items m WHERE `+baseWhere,
		args...,
	).Scan(&total); err != nil {
		return MediaPage{}, err
	}

	queryArgs := append([]any{}, args...)
	where := baseWhere
	if cursorValue != "" {
		cursor, err := decodeCursor(cursorValue)
		if err != nil {
			return MediaPage{}, err
		}
		where += " AND (m.modified_at < ? OR (m.modified_at = ? AND m.id < ?))"
		queryArgs = append(queryArgs, cursor.ModifiedAt, cursor.ModifiedAt, cursor.ID)
		offset = 0
	}

	query := `
SELECT
  m.id,m.library_id,l.root_path,m.relative_path,m.file_name,
  m.media_type,m.mime_type,m.size_bytes,m.modified_at,m.missing,m.favorite
FROM media_items m
JOIN libraries l ON l.id=m.library_id
WHERE ` + where + `
ORDER BY m.modified_at DESC,m.id DESC
LIMIT ?`
	queryArgs = append(queryArgs, limit+1)
	if cursorValue == "" && offset > 0 {
		query += " OFFSET ?"
		queryArgs = append(queryArgs, offset)
	}

	rows, err := a.db.QueryContext(ctx, query, queryArgs...)
	if err != nil {
		return MediaPage{}, err
	}
	defer rows.Close()

	items := make([]Media, 0, limit+1)
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

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	nextCursor := ""
	if hasMore && len(items) > 0 {
		nextCursor = encodeCursor(items[len(items)-1])
	}
	return MediaPage{
		Items:      items,
		Total:      total,
		Limit:      limit,
		Offset:     offset,
		NextCursor: nextCursor,
		HasMore:    hasMore,
	}, nil
}

func (a *App) findMediaByID(ctx context.Context, id string) (Media, error) {
	row := a.db.QueryRowContext(ctx, `
SELECT
  m.id,m.library_id,l.root_path,m.relative_path,m.file_name,
  m.media_type,m.mime_type,m.size_bytes,m.modified_at,m.missing,m.favorite
FROM media_items m
JOIN libraries l ON l.id=m.library_id
WHERE m.id=?`, id)
	return scanMedia(row)
}

func (a *App) setFavorite(ctx context.Context, id string, favorite bool) error {
	result, err := a.db.ExecContext(ctx, `UPDATE media_items SET favorite=? WHERE id=? AND missing=0`, favorite, id)
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

type rowScanner interface {
	Scan(...any) error
}

func scanMedia(row rowScanner) (Media, error) {
	var item Media
	var modified string
	if err := row.Scan(
		&item.ID,
		&item.LibraryID,
		&item.RootPath,
		&item.RelativePath,
		&item.FileName,
		&item.Type,
		&item.MIMEType,
		&item.SizeBytes,
		&modified,
		&item.Missing,
		&item.Favorite,
	); err != nil {
		return Media{}, err
	}
	parsed, err := time.Parse(time.RFC3339Nano, modified)
	if err != nil {
		return Media{}, fmt.Errorf("parse modified time: %w", err)
	}
	item.ModifiedAt = parsed
	return item, nil
}

func mediaResponse(item Media) map[string]any {
	base := "/api/v1/media/" + item.ID
	return map[string]any{
		"id":           item.ID,
		"libraryId":    item.LibraryID,
		"fileName":     item.FileName,
		"type":         item.Type,
		"mimeType":     item.MIMEType,
		"sizeBytes":    item.SizeBytes,
		"modifiedAt":   item.ModifiedAt,
		"favorite":     item.Favorite,
		"thumbnailUrl": base + "/thumbnail?width=480",
		"originalUrl":  base + "/original",
		"streamUrl":    base + "/stream",
	}
}

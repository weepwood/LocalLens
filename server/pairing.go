package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

type authContextKey struct{}

type pairingPayload struct {
	Version   int    `json:"version"`
	BaseURL   string `json:"baseUrl"`
	ServerName string `json:"serverName"`
	PairingID string `json:"pairingId"`
	Secret    string `json:"secret"`
	ExpiresAt string `json:"expiresAt"`
}

type pairingClaim struct {
	PairingID string `json:"pairingId"`
	Secret    string `json:"secret"`
	DeviceName string `json:"deviceName"`
	Platform  string `json:"platform"`
}

func (a *App) createPairingSession(baseURL string) (PairingSession, error) {
	id := randomID()
	secret := randomID() + randomID()
	expiresAt := time.Now().UTC().Add(time.Duration(a.cfg.PairingTTLMinutes) * time.Minute)
	payloadValue := pairingPayload{
		Version: 1,
		BaseURL: strings.TrimRight(baseURL, "/"),
		ServerName: a.cfg.ServerName,
		PairingID: id,
		Secret: secret,
		ExpiresAt: expiresAt.Format(time.RFC3339Nano),
	}
	payloadBytes, err := json.Marshal(payloadValue)
	if err != nil {
		return PairingSession{}, err
	}
	session := PairingSession{ID: id, SecretHash: hashToken(secret), Payload: string(payloadBytes), ExpiresAt: expiresAt}
	a.pairing.mu.Lock()
	defer a.pairing.mu.Unlock()
	a.pairing.removeExpiredLocked()
	a.pairing.sessions[id] = session
	return session, nil
}

func (p *PairingManager) removeExpiredLocked() {
	now := time.Now().UTC()
	for id, session := range p.sessions {
		if now.After(session.ExpiresAt) {
			delete(p.sessions, id)
		}
	}
}

func (a *App) pairingQRCode(sessionID string) ([]byte, error) {
	a.pairing.mu.Lock()
	defer a.pairing.mu.Unlock()
	a.pairing.removeExpiredLocked()
	session, ok := a.pairing.sessions[sessionID]
	if !ok {
		return nil, sql.ErrNoRows
	}
	return qrcode.Encode(session.Payload, qrcode.Medium, 384)
}

func (a *App) claimPairing(ctx context.Context, claim pairingClaim) (Device, string, error) {
	claim.PairingID = strings.TrimSpace(claim.PairingID)
	claim.Secret = strings.TrimSpace(claim.Secret)
	claim.DeviceName = strings.TrimSpace(claim.DeviceName)
	claim.Platform = strings.TrimSpace(claim.Platform)
	if claim.PairingID == "" || claim.Secret == "" || claim.DeviceName == "" {
		return Device{}, "", errors.New("pairingId, secret and deviceName are required")
	}

	a.pairing.mu.Lock()
	a.pairing.removeExpiredLocked()
	session, ok := a.pairing.sessions[claim.PairingID]
	if !ok || subtle.ConstantTimeCompare([]byte(session.SecretHash), []byte(hashToken(claim.Secret))) != 1 {
		a.pairing.mu.Unlock()
		return Device{}, "", errors.New("pairing session is invalid or expired")
	}
	delete(a.pairing.sessions, claim.PairingID)
	a.pairing.mu.Unlock()

	token := randomID() + randomID()
	now := time.Now().UTC()
	device := Device{
		ID: randomID(), Name: claim.DeviceName, Platform: claim.Platform,
		Scopes: "media:read,media:write", CreatedAt: now,
	}
	_, err := a.db.ExecContext(ctx, `
INSERT INTO devices(id,name,platform,token_hash,scopes,created_at)
VALUES(?,?,?,?,?,?)`, device.ID, device.Name, device.Platform, hashToken(token), device.Scopes, now.Format(time.RFC3339Nano))
	if err != nil {
		return Device{}, "", err
	}
	return device, token, nil
}

func (a *App) authenticateToken(ctx context.Context, token string) (AuthIdentity, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return AuthIdentity{}, errors.New("missing token")
	}
	if subtle.ConstantTimeCompare([]byte(token), []byte(a.cfg.APIToken)) == 1 {
		return AuthIdentity{DeviceID: "admin", Name: "Administrator", Admin: true, Scopes: "*"}, nil
	}
	var identity AuthIdentity
	var revoked sql.NullString
	err := a.db.QueryRowContext(ctx, `
SELECT id,name,scopes,revoked_at FROM devices WHERE token_hash=?`, hashToken(token)).Scan(
		&identity.DeviceID, &identity.Name, &identity.Scopes, &revoked,
	)
	if err != nil {
		return AuthIdentity{}, err
	}
	if revoked.Valid {
		return AuthIdentity{}, errors.New("device token revoked")
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, _ = a.db.ExecContext(ctx, `UPDATE devices SET last_seen_at=? WHERE id=?`, now, identity.DeviceID)
	return identity, nil
}

func withIdentity(r *http.Request, identity AuthIdentity) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), authContextKey{}, identity))
}

func identityFromRequest(r *http.Request) AuthIdentity {
	identity, _ := r.Context().Value(authContextKey{}).(AuthIdentity)
	return identity
}

func (a *App) listDevices(ctx context.Context) ([]Device, error) {
	rows, err := a.db.QueryContext(ctx, `
SELECT id,name,platform,scopes,created_at,last_seen_at,revoked_at
FROM devices ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Device{}
	for rows.Next() {
		var item Device
		var created string
		var lastSeen, revoked sql.NullString
		if err := rows.Scan(&item.ID, &item.Name, &item.Platform, &item.Scopes, &created, &lastSeen, &revoked); err != nil {
			return nil, err
		}
		item.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
		if lastSeen.Valid {
			value, _ := time.Parse(time.RFC3339Nano, lastSeen.String)
			item.LastSeenAt = &value
		}
		if revoked.Valid {
			value, _ := time.Parse(time.RFC3339Nano, revoked.String)
			item.RevokedAt = &value
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (a *App) revokeDevice(ctx context.Context, id string) error {
	result, err := a.db.ExecContext(ctx, `UPDATE devices SET revoked_at=? WHERE id=? AND revoked_at IS NULL`, time.Now().UTC().Format(time.RFC3339Nano), id)
	if err != nil {
		return err
	}
	changed, _ := result.RowsAffected()
	if changed == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func hashToken(value string) string {
	hash := sha256.Sum256([]byte(value))
	return hex.EncodeToString(hash[:])
}

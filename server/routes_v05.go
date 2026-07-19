package main

import "net/http"

func (a *App) routesV05Release() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/server", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"name":       a.cfg.ServerName,
			"version":    version,
			"apiVersion": "v1",
			"capabilities": []string{
				"timeline",
				"folders",
				"favorites",
				"ratings",
				"albums",
				"tags",
				"playback",
				"pairing",
				"playback_manifest",
				"hls_transcode",
				"transcode_diagnostics",
				"external_subtitles",
			},
		})
	})
	mux.Handle("/", a.routesV05())
	return a.cors(mux)
}

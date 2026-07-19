# LocalLens unified Windows application

The Windows distribution contains one user-facing application, `LocalLens.exe`.
The Flutter desktop process supervises an embedded Go server located at
`runtime/LocalLensServer.exe`.

## First launch

On the first launch LocalLens creates:

```text
%LOCALAPPDATA%\LocalLens\
├── config\server.json
├── data\
├── cache\
└── logs\
```

A 256-bit administrator token is generated automatically. The default media
library is the current Windows user's Pictures folder. The local client connects
to `http://127.0.0.1:9527`; LAN clients may connect through the Windows machine's
LAN address.

## Runtime lifecycle

The client:

1. creates or reads the local server configuration;
2. starts the embedded server without requiring a second user action;
3. waits for `/api/v1/health` before opening the library;
4. captures stdout and stderr for diagnostics;
5. polls health every five seconds;
6. restarts an unexpectedly terminated server with 2, 5 and 15 second backoff;
7. stops automatic recovery after three consecutive failures.

The Server page exposes start, stop and restart controls, the process ID,
startup time, recovery count and the last runtime error. These controls are only
shown when the client is connected to `127.0.0.1` or `localhost`.

## Distribution layout

```text
LocalLens-Windows-x64\
├── LocalLens.exe
├── flutter_windows.dll
├── data\
├── plugins\
└── runtime\
    ├── LocalLensServer.exe
    ├── config.example.json
    └── media-tools\
        ├── ffmpeg.exe       # optional, supplied separately
        └── ffprobe.exe      # optional, supplied separately
```

The unified CI workflow builds the Go server and Flutter client on the same
Windows runner and publishes `LocalLens-Windows-x64.zip` as one artifact.

## Compatibility

Remote-server mode remains supported. Existing users with a saved remote server
address continue to connect to that server and do not automatically start the
embedded server.

This first phase does not yet install a Windows Service. System tray behavior,
startup registration, visual editing of every server setting, firewall rule
management and atomic configuration rollback are planned for the next phase.

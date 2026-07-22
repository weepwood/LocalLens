package com.weepwood.locallens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem as PlayerMediaItem
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun MediaViewerDialog(
    settings: ServerSettings,
    item: MediaItem,
    onClose: () -> Unit,
    onUpdated: (MediaItem) -> Unit,
) {
    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(item.fileName, modifier = Modifier.weight(1f), maxLines = 1)
                    RatingActions(settings, item, onUpdated)
                    IconButton(onClick = onClose) {
                        Icon(Icons.Default.Close, contentDescription = "关闭")
                    }
                }
                if (item.kind == "video") {
                    VideoViewer(settings, item, Modifier.fillMaxSize())
                } else {
                    AsyncImage(
                        model = ImageRequest.Builder(LocalContext.current)
                            .data(item.resolved(settings.baseUrl, item.originalUrl))
                            .addHeader("Authorization", "Bearer ${settings.token}")
                            .crossfade(true)
                            .build(),
                        contentDescription = item.fileName,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize().background(Color.Black),
                    )
                }
            }
        }
    }
}

@Composable
private fun RatingActions(
    settings: ServerSettings,
    item: MediaItem,
    onUpdated: (MediaItem) -> Unit,
) {
    val scope = rememberCoroutineScope()
    Row {
        (1..5).forEach { rating ->
            IconButton(
                modifier = Modifier.size(34.dp),
                onClick = {
                    scope.launch {
                        runCatching {
                            LocalLensApi.setRating(
                                settings,
                                item,
                                if (item.rating == rating) 0 else rating,
                            )
                        }.onSuccess(onUpdated)
                    }
                },
            ) {
                Icon(
                    imageVector = if (rating <= item.rating) Icons.Filled.Star else Icons.Outlined.Star,
                    contentDescription = "$rating 星",
                    tint = if (rating <= item.rating) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun VideoViewer(settings: ServerSettings, item: MediaItem, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var playbackUrl by remember(item.id) { mutableStateOf<String?>(null) }
    var mimeType by remember(item.id) { mutableStateOf<String?>(null) }
    var initialPosition by remember(item.id) { mutableLongStateOf(0L) }
    var error by remember(item.id) { mutableStateOf<String?>(null) }

    LaunchedEffect(item.id) {
        runCatching { LocalLensApi.playbackProgress(settings, item) }
            .onSuccess { initialPosition = if (it.completed) 0 else it.positionMs }
        repeat(90) {
            val manifest = runCatching { LocalLensApi.playbackManifest(settings, item) }
                .getOrElse {
                    error = it.message ?: "无法获取播放地址"
                    return@LaunchedEffect
                }
            when (manifest.status) {
                "ready" -> {
                    playbackUrl = item.resolved(settings.baseUrl, manifest.url)
                    mimeType = manifest.mimeType.ifBlank { null }
                    return@LaunchedEffect
                }
                "failed" -> {
                    error = manifest.error.ifBlank { "视频无法播放" }
                    return@LaunchedEffect
                }
                else -> delay(manifest.retryAfter.coerceAtLeast(1) * 1_000)
            }
        }
        error = "视频准备超时"
    }

    val player = remember(playbackUrl, mimeType) {
        playbackUrl?.let { url ->
            val dataSource = DefaultHttpDataSource.Factory()
                .setDefaultRequestProperties(
                    mapOf("Authorization" to "Bearer ${settings.token}"),
                )
            ExoPlayer.Builder(context)
                .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
                .build()
                .apply {
                    setMediaItem(
                        PlayerMediaItem.Builder()
                            .setUri(url)
                            .setMimeType(mimeType)
                            .build(),
                    )
                    if (initialPosition > 0) seekTo(initialPosition)
                    prepare()
                    playWhenReady = true
                }
        }
    }

    DisposableEffect(player, item.id) {
        onDispose {
            player?.let { active ->
                val position = active.currentPosition
                val duration = active.duration.coerceAtLeast(item.durationMs)
                scope.launch {
                    runCatching {
                        LocalLensApi.savePlaybackProgress(
                            settings,
                            item,
                            position,
                            duration,
                        )
                    }
                }
                active.release()
            }
        }
    }

    Box(modifier = modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        when {
            error != null -> Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
            player == null -> CircularProgressIndicator()
            else -> AndroidView(
                factory = { PlayerView(it).apply { this.player = player } },
                update = { it.player = player },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

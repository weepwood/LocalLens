package com.weepwood.locallens

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

data class ServerSettings(val baseUrl: String, val token: String)

data class MediaItem(
    val id: String,
    val fileName: String,
    val kind: String,
    val durationMs: Long,
    val favorite: Boolean,
    val rating: Int,
    val thumbnailUrl: String,
    val originalUrl: String,
    val streamUrl: String,
) {
    fun resolved(baseUrl: String, path: String): String =
        if (path.startsWith("http://") || path.startsWith("https://")) path
        else baseUrl.trimEnd('/') + path
}

data class PlaybackManifest(
    val status: String,
    val url: String,
    val mimeType: String,
    val retryAfter: Long,
    val error: String,
)

data class PlaybackProgress(
    val positionMs: Long,
    val durationMs: Long,
    val completed: Boolean,
)

object LocalLensApi {
    suspend fun verify(settings: ServerSettings) {
        request(settings.baseUrl, "/api/v1/server", token = null)
        request(settings.baseUrl, "/api/v1/media?limit=1", settings.token)
    }

    suspend fun claimPairing(rawPayload: String, deviceName: String): ServerSettings {
        val payload = JSONObject(rawPayload)
        require(payload.optInt("version", 0) == 1) { "不支持的配对二维码版本" }
        val baseUrl = normalizeBaseUrl(payload.getString("baseUrl"))
        val claim = JSONObject()
            .put("pairingId", payload.getString("pairingId"))
            .put("secret", payload.getString("secret"))
            .put("deviceName", deviceName)
            .put("platform", "android")
        val response = JSONObject(
            request(
                baseUrl = baseUrl,
                path = "/api/v1/pairing/claim",
                token = null,
                method = "POST",
                jsonBody = claim,
            ),
        )
        val settings = ServerSettings(baseUrl, response.getString("token"))
        verify(settings)
        return settings
    }

    suspend fun listMedia(settings: ServerSettings, filter: String, search: String): List<MediaItem> {
        val result = mutableListOf<MediaItem>()
        var cursor: String? = null
        repeat(5) {
            val query = buildList {
                add("limit=200")
                when (filter) {
                    "image" -> add("type=image")
                    "video" -> add("type=video")
                    "favorite" -> add("favorite=true")
                }
                if (search.isNotBlank()) {
                    add("q=" + URLEncoder.encode(search.trim(), StandardCharsets.UTF_8))
                }
                cursor?.let { add("cursor=" + URLEncoder.encode(it, StandardCharsets.UTF_8)) }
            }.joinToString("&")
            val root = JSONObject(request(settings.baseUrl, "/api/v1/media?$query", settings.token))
            val array = root.optJSONArray("items") ?: return result
            for (index in 0 until array.length()) {
                result += mediaFromJson(array.getJSONObject(index))
            }
            if (!root.optBoolean("hasMore", false)) return result
            cursor = root.optString("nextCursor").takeIf { it.isNotBlank() } ?: return result
        }
        return result
    }

    suspend fun setFavorite(settings: ServerSettings, item: MediaItem): MediaItem {
        val method = if (item.favorite) "DELETE" else "PUT"
        return mediaFromJson(
            JSONObject(
                request(
                    settings.baseUrl,
                    "/api/v1/media/${item.id}/favorite",
                    settings.token,
                    method,
                ),
            ),
        )
    }

    suspend fun setRating(settings: ServerSettings, item: MediaItem, rating: Int): MediaItem =
        mediaFromJson(
            JSONObject(
                request(
                    settings.baseUrl,
                    "/api/v1/media/${item.id}/rating",
                    settings.token,
                    if (rating == 0) "DELETE" else "PUT",
                    if (rating == 0) null else JSONObject().put("rating", rating.coerceIn(1, 5)),
                ),
            ),
        )

    suspend fun playbackManifest(settings: ServerSettings, item: MediaItem): PlaybackManifest {
        val body = JSONObject()
            .put("platform", "android")
            .put("videoCodecs", org.json.JSONArray(listOf("h264", "hevc", "vp9", "av1")))
            .put("containers", org.json.JSONArray(listOf("mp4", "mkv", "webm")))
            .put("supportsHls", true)
            .put("maxWidth", 3840)
            .put("maxHeight", 2160)
        val root = JSONObject(
            request(
                settings.baseUrl,
                "/api/v1/media/${item.id}/playback-manifest",
                settings.token,
                "POST",
                body,
            ),
        )
        return PlaybackManifest(
            status = root.optString("status"),
            url = root.optString("url"),
            mimeType = root.optString("mimeType"),
            retryAfter = root.optLong("retryAfter", 2),
            error = root.optString("error"),
        )
    }

    suspend fun playbackProgress(settings: ServerSettings, item: MediaItem): PlaybackProgress {
        val root = JSONObject(
            request(
                settings.baseUrl,
                "/api/v1/media/${item.id}/progress",
                settings.token,
            ),
        )
        return PlaybackProgress(
            positionMs = root.optLong("positionMs", 0),
            durationMs = root.optLong("durationMs", item.durationMs),
            completed = root.optBoolean("completed", false),
        )
    }

    suspend fun savePlaybackProgress(
        settings: ServerSettings,
        item: MediaItem,
        positionMs: Long,
        durationMs: Long,
    ) {
        val completed = durationMs > 0 && positionMs >= durationMs - 2_000
        request(
            settings.baseUrl,
            "/api/v1/media/${item.id}/progress",
            settings.token,
            "PUT",
            JSONObject()
                .put("positionMs", positionMs.coerceAtLeast(0))
                .put("durationMs", durationMs.coerceAtLeast(0))
                .put("completed", completed),
        )
    }

    private fun mediaFromJson(item: JSONObject) = MediaItem(
        id = item.getString("id"),
        fileName = item.optString("fileName", "未命名媒体"),
        kind = item.optString("type", "image"),
        durationMs = item.optLong("durationMs", 0),
        favorite = item.optBoolean("favorite", false),
        rating = item.optInt("rating", 0),
        thumbnailUrl = item.optString("thumbnailUrl"),
        originalUrl = item.optString("originalUrl"),
        streamUrl = item.optString("streamUrl"),
    )

    private suspend fun request(
        baseUrl: String,
        path: String,
        token: String?,
        method: String = "GET",
        jsonBody: JSONObject? = null,
    ): String = withContext(Dispatchers.IO) {
        val connection = URI(normalizeBaseUrl(baseUrl) + path).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 8_000
            connection.readTimeout = 40_000
            connection.setRequestProperty("Accept", "application/json")
            token?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
            if (jsonBody != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { it.write(jsonBody.toString().toByteArray(StandardCharsets.UTF_8)) }
            }
            val status = connection.responseCode
            val body = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (status !in 200..299) error("HTTP $status：${body.ifBlank { "请求失败" }}")
            body
        } finally {
            connection.disconnect()
        }
    }

    fun normalizeBaseUrl(value: String): String {
        val trimmed = value.trim().trimEnd('/')
        require(trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
            "请输入有效的 HTTP 或 HTTPS 地址"
        }
        return trimmed
    }
}

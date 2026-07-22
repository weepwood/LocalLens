package com.weepwood.locallens

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { LocalLensTheme { LocalLensApp() } }
    }
}

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
) {
    fun resolved(baseUrl: String, path: String): String =
        if (path.startsWith("http://") || path.startsWith("https://")) path else baseUrl.trimEnd('/') + path
}

private object LocalLensApi {
    suspend fun verify(settings: ServerSettings) {
        request(settings.baseUrl, "/api/v1/server", token = null)
        request(settings.baseUrl, "/api/v1/media?limit=1", settings.token)
    }

    suspend fun listMedia(settings: ServerSettings, filter: String, search: String): List<MediaItem> {
        val query = buildList {
            add("limit=100")
            when (filter) {
                "image" -> add("type=image")
                "video" -> add("type=video")
                "favorite" -> add("favorite=true")
            }
            if (search.isNotBlank()) add("q=" + URLEncoder.encode(search.trim(), StandardCharsets.UTF_8))
        }.joinToString("&")
        val root = JSONObject(request(settings.baseUrl, "/api/v1/media?$query", settings.token))
        val array = root.optJSONArray("items") ?: return emptyList()
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                add(
                    MediaItem(
                        id = item.getString("id"),
                        fileName = item.optString("fileName", "未命名媒体"),
                        kind = item.optString("type", "image"),
                        durationMs = item.optLong("durationMs", 0),
                        favorite = item.optBoolean("favorite", false),
                        rating = item.optInt("rating", 0),
                        thumbnailUrl = item.optString("thumbnailUrl"),
                        originalUrl = item.optString("originalUrl"),
                    ),
                )
            }
        }
    }

    suspend fun setFavorite(settings: ServerSettings, item: MediaItem): MediaItem {
        val method = if (item.favorite) "DELETE" else "PUT"
        val root = JSONObject(request(settings.baseUrl, "/api/v1/media/${item.id}/favorite", settings.token, method))
        return item.copy(favorite = root.optBoolean("favorite", !item.favorite))
    }

    private suspend fun request(baseUrl: String, path: String, token: String?, method: String = "GET"): String =
        withContext(Dispatchers.IO) {
            val normalized = normalizeBaseUrl(baseUrl)
            val connection = URI(normalized + path).toURL().openConnection() as HttpURLConnection
            try {
                connection.requestMethod = method
                connection.connectTimeout = 8_000
                connection.readTimeout = 25_000
                connection.setRequestProperty("Accept", "application/json")
                token?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
                connection.connect()
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
        require(trimmed.startsWith("http://") || trimmed.startsWith("https://")) { "请输入有效的 HTTP 或 HTTPS 地址" }
        return trimmed
    }
}

@Composable
private fun LocalLensApp() {
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("local_lens", Context.MODE_PRIVATE) }
    var settings by remember {
        mutableStateOf(
            preferences.getString("base_url", null)?.let { url ->
                ServerSettings(url, preferences.getString("token", "").orEmpty())
            },
        )
    }

    if (settings == null) {
        SetupScreen { next ->
            preferences.edit().putString("base_url", next.baseUrl).putString("token", next.token).apply()
            settings = next
        }
    } else {
        GalleryScreen(
            settings = settings!!,
            onDisconnect = {
                preferences.edit().clear().apply()
                settings = null
            },
        )
    }
}

@Composable
private fun SetupScreen(onConnected: (ServerSettings) -> Unit) {
    var baseUrl by remember { mutableStateOf("http://192.168.1.2:9527") }
    var token by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Surface(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Icon(Icons.Default.Image, contentDescription = null, modifier = Modifier.size(52.dp), tint = MaterialTheme.colorScheme.primary)
                Text("连接到 LocalLens", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                Text("连接 Windows 上运行的 Tauri 2 / Rust 媒体服务。连接信息只保存在当前 Android 设备中。", color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(
                    value = baseUrl,
                    onValueChange = { baseUrl = it },
                    label = { Text("服务地址") },
                    placeholder = { Text("http://192.168.1.2:9527") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it },
                    label = { Text("设备或管理员 Token") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = {}),
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Button(
                    enabled = !busy && token.length >= 16,
                    modifier = Modifier.fillMaxWidth(),
                    onClick = {
                        scope.launch {
                            busy = true
                            error = null
                            val next = ServerSettings(baseUrl.trimEnd('/'), token.trim())
                            runCatching { LocalLensApi.verify(next) }
                                .onSuccess { onConnected(next) }
                                .onFailure { error = it.message ?: "连接失败" }
                            busy = false
                        }
                    },
                ) {
                    if (busy) CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    else Text("测试并保存连接")
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GalleryScreen(settings: ServerSettings, onDisconnect: () -> Unit) {
    var items by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var filter by remember { mutableStateOf("all") }
    var searchDraft by remember { mutableStateOf("") }
    var search by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var selected by remember { mutableStateOf<MediaItem?>(null) }
    val scope = rememberCoroutineScope()

    fun load() {
        scope.launch {
            loading = true
            error = null
            runCatching { LocalLensApi.listMedia(settings, filter, search) }
                .onSuccess { items = it }
                .onFailure { error = it.message ?: "加载媒体失败" }
            loading = false
        }
    }

    LaunchedEffect(filter, search) { load() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Column { Text("LocalLens", fontWeight = FontWeight.Bold); Text("原生 Android 客户端", style = MaterialTheme.typography.labelSmall) } },
                actions = {
                    IconButton(onClick = { load() }) { Icon(Icons.Default.Refresh, contentDescription = "刷新") }
                    IconButton(onClick = onDisconnect) { Icon(Icons.Default.Logout, contentDescription = "断开连接") }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = searchDraft,
                    onValueChange = { searchDraft = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("搜索文件名或相对路径") },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { search = searchDraft.trim() }),
                )
                IconButton(onClick = { search = searchDraft.trim() }) { Icon(Icons.Default.Search, contentDescription = "搜索") }
            }
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("all" to "全部", "image" to "图片", "video" to "视频", "favorite" to "收藏").forEach { (value, label) ->
                    FilterChip(selected = filter == value, onClick = { filter = value }, label = { Text(label) })
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp)) }
            if (loading && items.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(145.dp),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(items, key = { it.id }) { item ->
                        MediaCell(
                            settings = settings,
                            item = item,
                            onOpen = { if (item.kind == "image") selected = item },
                            onFavorite = {
                                scope.launch {
                                    runCatching { LocalLensApi.setFavorite(settings, item) }
                                        .onSuccess { updated -> items = items.map { if (it.id == updated.id) updated else it } }
                                        .onFailure { error = it.message }
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    selected?.let { item ->
        AlertDialog(
            onDismissRequest = { selected = null },
            confirmButton = { OutlinedButton(onClick = { selected = null }) { Icon(Icons.Default.Close, null); Text("关闭") } },
            title = { Text(item.fileName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            text = {
                AsyncImage(
                    model = authenticatedRequest(settings, item.resolved(settings.baseUrl, item.originalUrl)),
                    contentDescription = item.fileName,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxWidth().height(480.dp),
                )
            },
        )
    }
}

@Composable
private fun MediaCell(settings: ServerSettings, item: MediaItem, onOpen: () -> Unit, onFavorite: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxWidth().height(160.dp).background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(14.dp)).clickable(onClick = onOpen),
    ) {
        AsyncImage(
            model = authenticatedRequest(settings, item.resolved(settings.baseUrl, item.thumbnailUrl)),
            contentDescription = item.fileName,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )
        if (item.kind == "video") {
            Row(modifier = Modifier.align(Alignment.BottomStart).padding(8.dp).background(Color.Black.copy(alpha = .66f), RoundedCornerShape(8.dp)).padding(horizontal = 7.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Videocam, null, tint = Color.White, modifier = Modifier.size(16.dp))
                Text(formatDuration(item.durationMs), color = Color.White, style = MaterialTheme.typography.labelSmall)
            }
        }
        IconButton(onClick = onFavorite, modifier = Modifier.align(Alignment.TopEnd).background(Color.Black.copy(alpha = .45f), RoundedCornerShape(50))) {
            Icon(if (item.favorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder, contentDescription = "收藏", tint = if (item.favorite) Color(0xFFFF6B7A) else Color.White)
        }
        Text(
            item.fileName,
            color = Color.White,
            style = MaterialTheme.typography.labelMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Color.Black.copy(alpha = .5f)).padding(7.dp),
        )
    }
}

@Composable
private fun authenticatedRequest(settings: ServerSettings, url: String): ImageRequest =
    ImageRequest.Builder(LocalContext.current)
        .data(url)
        .addHeader("Authorization", "Bearer ${settings.token}")
        .crossfade(true)
        .build()

private fun formatDuration(durationMs: Long): String {
    val totalSeconds = durationMs / 1000
    return "%d:%02d".format(totalSeconds / 60, totalSeconds % 60)
}

@Composable
private fun LocalLensTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(), content = content)
}

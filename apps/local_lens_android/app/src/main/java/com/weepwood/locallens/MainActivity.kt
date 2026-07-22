package com.weepwood.locallens

import android.content.Context
import android.os.Build
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
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.weight
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Videocam
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
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { LocalLensTheme { LocalLensApp() } }
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

    fun save(next: ServerSettings) {
        preferences.edit()
            .putString("base_url", next.baseUrl)
            .putString("token", next.token)
            .apply()
        settings = next
    }

    if (settings == null) {
        SetupScreen(onConnected = ::save)
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
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val scanner = remember {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(context, options)
    }
    var baseUrl by remember { mutableStateOf("http://192.168.1.2:9527") }
    var token by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    Surface(modifier = Modifier.fillMaxSize()) {
        Box(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Icon(
                    Icons.Default.Image,
                    contentDescription = null,
                    modifier = Modifier.size(52.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
                Text(
                    "连接到 LocalLens",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "扫描 Windows 管理端的一次性二维码，或手动填写 Rust 服务地址与 Token。",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Button(
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !busy,
                    onClick = {
                        busy = true
                        error = null
                        scanner.startScan()
                            .addOnSuccessListener { barcode ->
                                val raw = barcode.rawValue
                                if (raw.isNullOrBlank()) {
                                    error = "二维码没有有效内容"
                                    busy = false
                                } else {
                                    scope.launch {
                                        runCatching {
                                            LocalLensApi.claimPairing(
                                                raw,
                                                "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
                                            )
                                        }.onSuccess(onConnected)
                                            .onFailure { error = it.message ?: "配对失败" }
                                        busy = false
                                    }
                                }
                            }
                            .addOnCanceledListener { busy = false }
                            .addOnFailureListener {
                                error = it.message ?: "无法打开二维码扫描器"
                                busy = false
                            }
                    },
                ) {
                    Icon(Icons.Default.QrCodeScanner, contentDescription = null)
                    Text("扫描配对二维码", modifier = Modifier.padding(start = 8.dp))
                }
                Text("或者手动连接", style = MaterialTheme.typography.labelLarge)
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
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                OutlinedButton(
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
                    if (busy) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Text("测试并保存连接")
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GalleryScreen(settings: ServerSettings, onDisconnect: () -> Unit) {
    var media by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var filter by remember { mutableStateOf("all") }
    var searchDraft by remember { mutableStateOf("") }
    var search by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var selected by remember { mutableStateOf<MediaItem?>(null) }
    val scope = rememberCoroutineScope()

    fun updateItem(updated: MediaItem) {
        media = media.map { if (it.id == updated.id) updated else it }
        if (selected?.id == updated.id) selected = updated
    }

    fun load() {
        scope.launch {
            loading = true
            error = null
            runCatching { LocalLensApi.listMedia(settings, filter, search) }
                .onSuccess { media = it }
                .onFailure { error = it.message ?: "加载媒体失败" }
            loading = false
        }
    }

    LaunchedEffect(filter, search) { load() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("LocalLens", fontWeight = FontWeight.Bold)
                        Text("Kotlin 原生 Android", style = MaterialTheme.typography.labelSmall)
                    }
                },
                actions = {
                    IconButton(onClick = ::load) {
                        Icon(Icons.Default.Refresh, contentDescription = "刷新")
                    }
                    IconButton(onClick = onDisconnect) {
                        Icon(Icons.Default.Logout, contentDescription = "断开连接")
                    }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
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
                IconButton(onClick = { search = searchDraft.trim() }) {
                    Icon(Icons.Default.Search, contentDescription = "搜索")
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                listOf(
                    "all" to "全部",
                    "image" to "图片",
                    "video" to "视频",
                    "favorite" to "收藏",
                ).forEach { (value, label) ->
                    FilterChip(
                        selected = filter == value,
                        onClick = { filter = value },
                        label = { Text(label) },
                    )
                }
            }
            error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp))
            }
            if (loading && media.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(145.dp),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(media, key = { it.id }) { item ->
                        MediaCell(
                            settings = settings,
                            item = item,
                            onOpen = { selected = item },
                            onFavorite = {
                                scope.launch {
                                    runCatching { LocalLensApi.setFavorite(settings, item) }
                                        .onSuccess(::updateItem)
                                        .onFailure { error = it.message ?: "收藏操作失败" }
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    selected?.let { item ->
        MediaViewerDialog(
            settings = settings,
            item = item,
            onClose = { selected = null },
            onUpdated = ::updateItem,
        )
    }
}

@Composable
private fun MediaCell(
    settings: ServerSettings,
    item: MediaItem,
    onOpen: () -> Unit,
    onFavorite: () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen),
        shape = RoundedCornerShape(14.dp),
        tonalElevation = 2.dp,
    ) {
        Column {
            Box(
                modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant),
            ) {
                AsyncImage(
                    model = ImageRequest.Builder(LocalContext.current)
                        .data(item.resolved(settings.baseUrl, item.thumbnailUrl))
                        .addHeader("Authorization", "Bearer ${settings.token}")
                        .crossfade(true)
                        .build(),
                    contentDescription = item.fileName,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxWidth().size(160.dp),
                )
                IconButton(
                    onClick = onFavorite,
                    modifier = Modifier.align(Alignment.TopEnd),
                ) {
                    Icon(
                        if (item.favorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                        contentDescription = "收藏",
                        tint = if (item.favorite) Color.Red else Color.White,
                    )
                }
                if (item.kind == "video") {
                    Row(
                        modifier = Modifier.align(Alignment.BottomStart).padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.Videocam, contentDescription = null, tint = Color.White)
                        Text(formatDuration(item.durationMs), color = Color.White)
                    }
                }
            }
            Text(
                item.fileName,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
            )
            if (item.rating > 0) {
                Text(
                    "★".repeat(item.rating),
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 10.dp, bottom = 8.dp),
                )
            }
        }
    }
}

private fun formatDuration(value: Long): String {
    val seconds = (value / 1_000).coerceAtLeast(0)
    return "%d:%02d".format(seconds / 60, seconds % 60)
}

@Composable
private fun LocalLensTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(),
        content = content,
    )
}

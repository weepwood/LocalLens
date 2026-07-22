import { CameraView, useCameraPermissions } from 'expo-camera';
import { Image } from 'expo-image';
import { StatusBar } from 'expo-status-bar';
import { useVideoPlayer, VideoView } from 'expo-video';
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  FlatList,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  RefreshControl,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  useColorScheme,
  useWindowDimensions,
  View,
} from 'react-native';

import { ApiError, claimPairing, LocalLensApi, parsePairingPayload } from './src/api';
import { clearSettings, loadSettings, normalizeBaseUrl, saveSettings } from './src/storage';
import type { MediaItem, MediaKind, ServerSettings } from './src/types';

const palette = {
  light: {
    background: '#F6F7FB',
    surface: '#FFFFFF',
    surfaceAlt: '#ECEFFA',
    text: '#171923',
    muted: '#687086',
    border: '#DDE1EC',
    primary: '#5664D8',
    primarySoft: '#E7E9FF',
    danger: '#C83B52',
    overlay: 'rgba(12, 15, 24, 0.88)',
  },
  dark: {
    background: '#0E1118',
    surface: '#171B25',
    surfaceAlt: '#232938',
    text: '#F4F6FC',
    muted: '#A5ADBF',
    border: '#303749',
    primary: '#8995FF',
    primarySoft: '#292F55',
    danger: '#FF7890',
    overlay: 'rgba(4, 6, 10, 0.94)',
  },
} as const;

type Theme = (typeof palette)[keyof typeof palette];
type Filter = 'all' | MediaKind | 'favorite';

export default function App() {
  const scheme = useColorScheme();
  const theme = scheme === 'dark' ? palette.dark : palette.light;
  const [booting, setBooting] = useState(true);
  const [settings, setSettings] = useState<ServerSettings | null>(null);

  useEffect(() => {
    void loadSettings()
      .then(setSettings)
      .finally(() => setBooting(false));
  }, []);

  const handleConnected = useCallback(async (next: ServerSettings) => {
    await saveSettings(next);
    setSettings(next);
  }, []);

  const handleDisconnect = useCallback(async () => {
    await clearSettings();
    setSettings(null);
  }, []);

  return (
    <View style={[styles.app, { backgroundColor: theme.background }]}>
      <StatusBar style={scheme === 'dark' ? 'light' : 'dark'} />
      {booting ? (
        <BootScreen theme={theme} />
      ) : settings ? (
        <LibraryScreen settings={settings} theme={theme} onDisconnect={handleDisconnect} />
      ) : (
        <SetupScreen theme={theme} onConnected={handleConnected} />
      )}
    </View>
  );
}

function BootScreen({ theme }: { theme: Theme }) {
  return (
    <SafeAreaView style={styles.centered}>
      <BrandMark theme={theme} />
      <ActivityIndicator color={theme.primary} size="large" />
      <Text style={[styles.mutedText, { color: theme.muted }]}>正在读取安全连接配置…</Text>
    </SafeAreaView>
  );
}

function SetupScreen({
  theme,
  onConnected,
}: {
  theme: Theme;
  onConnected: (settings: ServerSettings) => Promise<void>;
}) {
  const [baseUrl, setBaseUrl] = useState('http://192.168.1.2:9527');
  const [token, setToken] = useState('');
  const [connecting, setConnecting] = useState(false);
  const [scannerVisible, setScannerVisible] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const connect = useCallback(async () => {
    const normalized = normalizeBaseUrl(baseUrl);
    if (!/^https?:\/\/[^\s]+$/i.test(normalized)) {
      setError('请输入有效的 HTTP 或 HTTPS 服务地址');
      return;
    }
    if (token.trim().length < 16) {
      setError('Token 至少需要 16 个字符');
      return;
    }

    setConnecting(true);
    setError(null);
    try {
      const settings = { baseUrl: normalized, token: token.trim() };
      await new LocalLensApi(settings).verify();
      await onConnected(settings);
    } catch (reason) {
      setError(readError(reason));
    } finally {
      setConnecting(false);
    }
  }, [baseUrl, onConnected, token]);

  const acceptPairing = useCallback(
    async (settings: ServerSettings) => {
      setScannerVisible(false);
      setConnecting(true);
      setError(null);
      try {
        await new LocalLensApi(settings).verify();
        await onConnected(settings);
      } catch (reason) {
        setError(readError(reason));
      } finally {
        setConnecting(false);
      }
    },
    [onConnected],
  );

  return (
    <SafeAreaView style={styles.flex}>
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView
          contentContainerStyle={styles.setupScroll}
          keyboardShouldPersistTaps="handled"
        >
          <View style={[styles.setupCard, { backgroundColor: theme.surface, borderColor: theme.border }]}>
            <BrandMark theme={theme} />
            <Text style={[styles.setupTitle, { color: theme.text }]}>连接到 LocalLens</Text>
            <Text style={[styles.setupDescription, { color: theme.muted }]}>
              扫描 Windows 管理端生成的一次性二维码，或手动填写局域网地址与设备 Token。
            </Text>

            <PrimaryButton
              label="扫描二维码配对"
              disabled={connecting}
              theme={theme}
              onPress={() => setScannerVisible(true)}
            />

            <View style={styles.dividerRow}>
              <View style={[styles.divider, { backgroundColor: theme.border }]} />
              <Text style={[styles.dividerLabel, { color: theme.muted }]}>或手动连接</Text>
              <View style={[styles.divider, { backgroundColor: theme.border }]} />
            </View>

            <FieldLabel label="服务地址" theme={theme} />
            <TextInput
              value={baseUrl}
              onChangeText={setBaseUrl}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              placeholder="http://192.168.1.2:9527"
              placeholderTextColor={theme.muted}
              style={[styles.input, { color: theme.text, borderColor: theme.border, backgroundColor: theme.background }]}
            />

            <FieldLabel label="管理员或设备 Token" theme={theme} />
            <TextInput
              value={token}
              onChangeText={setToken}
              autoCapitalize="none"
              autoCorrect={false}
              secureTextEntry
              placeholder="输入 Token"
              placeholderTextColor={theme.muted}
              style={[styles.input, { color: theme.text, borderColor: theme.border, backgroundColor: theme.background }]}
            />

            {error ? (
              <Text style={[styles.errorBox, { color: theme.danger, borderColor: theme.danger }]}>{error}</Text>
            ) : null}

            <PrimaryButton
              label={connecting ? '正在验证连接…' : '测试并保存连接'}
              disabled={connecting}
              loading={connecting}
              theme={theme}
              onPress={() => void connect()}
            />
            <Text style={[styles.securityHint, { color: theme.muted }]}>
              Token 将写入系统安全存储；移动端不会读取 Windows 上的绝对文件路径。
            </Text>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>

      <PairingScanner
        visible={scannerVisible}
        theme={theme}
        onClose={() => setScannerVisible(false)}
        onPaired={acceptPairing}
      />
    </SafeAreaView>
  );
}

function PairingScanner({
  visible,
  theme,
  onClose,
  onPaired,
}: {
  visible: boolean;
  theme: Theme;
  onClose: () => void;
  onPaired: (settings: ServerSettings) => Promise<void>;
}) {
  const [permission, requestPermission] = useCameraPermissions();
  const [processing, setProcessing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!visible) {
      setProcessing(false);
      setError(null);
    }
  }, [visible]);

  const scan = useCallback(
    async (raw: string) => {
      if (processing) return;
      setProcessing(true);
      setError(null);
      try {
        const payload = parsePairingPayload(raw);
        const settings = await claimPairing(
          payload,
          Platform.OS === 'ios' ? 'LocalLens iPhone' : 'LocalLens Android',
          Platform.OS,
        );
        await onPaired(settings);
      } catch (reason) {
        setError(readError(reason));
        setProcessing(false);
      }
    },
    [onPaired, processing],
  );

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <View style={styles.scannerRoot}>
        {permission?.granted ? (
          <CameraView
            style={StyleSheet.absoluteFill}
            facing="back"
            barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
            onBarcodeScanned={processing ? undefined : ({ data }) => void scan(data)}
          />
        ) : (
          <View style={styles.scannerPermission}>
            <Text style={styles.scannerTitle}>需要摄像头权限</Text>
            <Text style={styles.scannerDescription}>摄像头仅用于读取一次性 LocalLens 配对二维码。</Text>
            <PrimaryButton
              label="允许使用摄像头"
              theme={theme}
              onPress={() => void requestPermission()}
            />
          </View>
        )}

        {permission?.granted ? <View style={styles.scanFrame} /> : null}
        <SafeAreaView style={styles.scannerOverlay}>
          <View style={styles.scannerHeader}>
            <Text style={styles.scannerTitle}>扫描 LocalLens 配对码</Text>
            <Pressable accessibilityRole="button" onPress={onClose} style={styles.closeButton}>
              <Text style={styles.closeButtonText}>关闭</Text>
            </Pressable>
          </View>
          <View style={styles.scannerFooter}>
            {processing ? <ActivityIndicator color="#FFFFFF" /> : null}
            <Text style={styles.scannerDescription}>
              {processing ? '正在领取设备 Token…' : '将 Windows 管理端生成的二维码放入取景框'}
            </Text>
            {error ? <Text style={styles.scannerError}>{error}</Text> : null}
          </View>
        </SafeAreaView>
      </View>
    </Modal>
  );
}

function LibraryScreen({
  settings,
  theme,
  onDisconnect,
}: {
  settings: ServerSettings;
  theme: Theme;
  onDisconnect: () => Promise<void>;
}) {
  const api = useMemo(() => new LocalLensApi(settings), [settings]);
  const { width } = useWindowDimensions();
  const columns = width >= 900 ? 5 : width >= 620 ? 4 : 3;
  const gap = 8;
  const itemWidth = Math.floor((width - 24 - gap * (columns - 1)) / columns);
  const [items, setItems] = useState<MediaItem[]>([]);
  const [filter, setFilter] = useState<Filter>('all');
  const [searchDraft, setSearchDraft] = useState('');
  const [search, setSearch] = useState('');
  const [cursor, setCursor] = useState<string | undefined>();
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<MediaItem | null>(null);

  const load = useCallback(
    async (reset: boolean) => {
      if (loading && !reset) return;
      if (reset) setRefreshing(true);
      else setLoading(true);
      setError(null);
      try {
        const page = await api.listMedia({
          type: filter === 'image' || filter === 'video' ? filter : undefined,
          favorite: filter === 'favorite',
          search,
          cursor: reset ? undefined : cursor,
          limit: 60,
        });
        setItems((current) => (reset ? page.items : deduplicate([...current, ...page.items])));
        setCursor(page.nextCursor);
        setHasMore(page.hasMore);
      } catch (reason) {
        setError(readError(reason));
      } finally {
        setLoading(false);
        setRefreshing(false);
      }
    },
    [api, cursor, filter, loading, search],
  );

  useEffect(() => {
    setCursor(undefined);
    void load(true);
    // load intentionally re-runs only when visible query changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api, filter, search]);

  const toggleFavorite = useCallback(
    async (item: MediaItem) => {
      try {
        const updated = await api.setFavorite(item.id, !item.favorite);
        setItems((current) =>
          current
            .map((candidate) => (candidate.id === updated.id ? updated : candidate))
            .filter((candidate) => filter !== 'favorite' || candidate.favorite),
        );
        setSelected((current) => (current?.id === updated.id ? updated : current));
      } catch (reason) {
        Alert.alert('收藏操作失败', readError(reason));
      }
    },
    [api, filter],
  );

  const confirmDisconnect = useCallback(() => {
    Alert.alert('断开服务器', '将清除本机保存的服务地址和 Token，需要重新扫码或手动连接。', [
      { text: '取消', style: 'cancel' },
      { text: '断开', style: 'destructive', onPress: () => void onDisconnect() },
    ]);
  }, [onDisconnect]);

  return (
    <SafeAreaView style={styles.flex}>
      <View style={styles.libraryHeader}>
        <View>
          <Text style={[styles.libraryTitle, { color: theme.text }]}>LocalLens</Text>
          <Text style={[styles.librarySubtitle, { color: theme.muted }]} numberOfLines={1}>
            {normalizeBaseUrl(settings.baseUrl)}
          </Text>
        </View>
        <Pressable
          accessibilityRole="button"
          onPress={confirmDisconnect}
          style={[styles.secondaryButton, { borderColor: theme.border, backgroundColor: theme.surface }]}
        >
          <Text style={[styles.secondaryButtonText, { color: theme.text }]}>连接设置</Text>
        </Pressable>
      </View>

      <View style={styles.searchRow}>
        <TextInput
          value={searchDraft}
          onChangeText={setSearchDraft}
          onSubmitEditing={() => setSearch(searchDraft.trim())}
          returnKeyType="search"
          placeholder="搜索文件名或相对路径"
          placeholderTextColor={theme.muted}
          style={[styles.searchInput, { color: theme.text, borderColor: theme.border, backgroundColor: theme.surface }]}
        />
        <Pressable
          accessibilityRole="button"
          onPress={() => setSearch(searchDraft.trim())}
          style={[styles.searchButton, { backgroundColor: theme.primary }]}
        >
          <Text style={styles.searchButtonText}>搜索</Text>
        </Pressable>
      </View>

      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.filters}>
        <FilterChip label="全部" active={filter === 'all'} theme={theme} onPress={() => setFilter('all')} />
        <FilterChip label="图片" active={filter === 'image'} theme={theme} onPress={() => setFilter('image')} />
        <FilterChip label="视频" active={filter === 'video'} theme={theme} onPress={() => setFilter('video')} />
        <FilterChip label="收藏" active={filter === 'favorite'} theme={theme} onPress={() => setFilter('favorite')} />
      </ScrollView>

      {error ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => void load(true)}
          style={[styles.inlineError, { borderColor: theme.danger }]}
        >
          <Text style={{ color: theme.danger }}>{error}　点击重试</Text>
        </Pressable>
      ) : null}

      <FlatList
        key={columns}
        data={items}
        numColumns={columns}
        keyExtractor={(item) => item.id}
        columnWrapperStyle={{ gap }}
        contentContainerStyle={styles.gridContent}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={() => void load(true)} tintColor={theme.primary} />
        }
        renderItem={({ item }) => (
          <MediaCell
            api={api}
            item={item}
            width={itemWidth}
            theme={theme}
            onOpen={() => setSelected(item)}
            onFavorite={() => void toggleFavorite(item)}
          />
        )}
        onEndReached={() => {
          if (hasMore && !loading) void load(false);
        }}
        onEndReachedThreshold={0.45}
        ListEmptyComponent={
          refreshing ? null : (
            <View style={styles.emptyState}>
              <Text style={[styles.emptyTitle, { color: theme.text }]}>没有找到媒体</Text>
              <Text style={[styles.mutedText, { color: theme.muted }]}>尝试清空搜索条件或切换筛选。</Text>
            </View>
          )
        }
        ListFooterComponent={
          loading ? <ActivityIndicator style={styles.footerLoader} color={theme.primary} /> : null
        }
      />

      <MediaViewer
        api={api}
        item={selected}
        theme={theme}
        onClose={() => setSelected(null)}
        onFavorite={(item) => void toggleFavorite(item)}
      />
    </SafeAreaView>
  );
}

function MediaCell({
  api,
  item,
  width,
  theme,
  onOpen,
  onFavorite,
}: {
  api: LocalLensApi;
  item: MediaItem;
  width: number;
  theme: Theme;
  onOpen: () => void;
  onFavorite: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`打开 ${item.fileName}`}
      onPress={onOpen}
      style={[styles.mediaCell, { width, height: width, backgroundColor: theme.surfaceAlt }]}
    >
      <Image
        source={api.mediaSource(item.thumbnailUrl)}
        style={StyleSheet.absoluteFill}
        contentFit="cover"
        recyclingKey={item.id}
        transition={120}
      />
      {item.isVideo || item.type === 'video' ? (
        <View style={styles.videoBadge}>
          <Text style={styles.videoBadgeText}>▶ {formatDuration(item.durationMs)}</Text>
        </View>
      ) : null}
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={item.favorite ? '取消收藏' : '收藏'}
        hitSlop={8}
        onPress={(event) => {
          event.stopPropagation();
          onFavorite();
        }}
        style={styles.favoriteButton}
      >
        <Text style={[styles.favoriteIcon, item.favorite && styles.favoriteIconActive]}>
          {item.favorite ? '★' : '☆'}
        </Text>
      </Pressable>
    </Pressable>
  );
}

function MediaViewer({
  api,
  item,
  theme,
  onClose,
  onFavorite,
}: {
  api: LocalLensApi;
  item: MediaItem | null;
  theme: Theme;
  onClose: () => void;
  onFavorite: (item: MediaItem) => void;
}) {
  return (
    <Modal visible={item !== null} transparent animationType="fade" onRequestClose={onClose}>
      {item ? (
        <SafeAreaView style={[styles.viewerRoot, { backgroundColor: theme.overlay }]}>
          <View style={styles.viewerHeader}>
            <Pressable onPress={onClose} style={styles.viewerButton}>
              <Text style={styles.viewerButtonText}>关闭</Text>
            </Pressable>
            <Text style={styles.viewerFileName} numberOfLines={1}>
              {item.fileName}
            </Text>
            <Pressable onPress={() => onFavorite(item)} style={styles.viewerButton}>
              <Text style={styles.viewerButtonText}>{item.favorite ? '★' : '☆'}</Text>
            </Pressable>
          </View>

          <View style={styles.viewerMedia}>
            {item.type === 'video' ? (
              <VideoPlayer api={api} item={item} />
            ) : (
              <Image
                source={api.mediaSource(item.originalUrl)}
                style={styles.viewerImage}
                contentFit="contain"
                transition={120}
              />
            )}
          </View>

          <View style={styles.viewerInfo}>
            <Text style={styles.viewerMeta}>{formatDate(item.capturedAt)}</Text>
            <Text style={styles.viewerMeta}>
              {item.width > 0 && item.height > 0 ? `${item.width} × ${item.height} · ` : ''}
              {formatBytes(item.sizeBytes)}
            </Text>
            <Text style={styles.viewerPath} numberOfLines={2}>
              {item.relativePath}
            </Text>
          </View>
        </SafeAreaView>
      ) : null}
    </Modal>
  );
}

function VideoPlayer({ api, item }: { api: LocalLensApi; item: MediaItem }) {
  const source = api.mediaSource(item.streamUrl);
  const player = useVideoPlayer(
    {
      uri: source.uri,
      headers: source.headers,
      useCaching: true,
    },
    (instance) => {
      instance.play();
    },
  );

  return <VideoView player={player} style={styles.videoPlayer} nativeControls contentFit="contain" />;
}

function BrandMark({ theme }: { theme: Theme }) {
  return (
    <View style={styles.brandRow}>
      <View style={[styles.brandIcon, { backgroundColor: theme.primary }]}>
        <Text style={styles.brandIconText}>◎</Text>
      </View>
      <Text style={[styles.brandName, { color: theme.text }]}>LocalLens</Text>
    </View>
  );
}

function FieldLabel({ label, theme }: { label: string; theme: Theme }) {
  return <Text style={[styles.fieldLabel, { color: theme.text }]}>{label}</Text>;
}

function PrimaryButton({
  label,
  theme,
  disabled = false,
  loading = false,
  onPress,
}: {
  label: string;
  theme: Theme;
  disabled?: boolean;
  loading?: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.primaryButton,
        { backgroundColor: theme.primary },
        (disabled || pressed) && styles.buttonDimmed,
      ]}
    >
      {loading ? <ActivityIndicator color="#FFFFFF" size="small" /> : null}
      <Text style={styles.primaryButtonText}>{label}</Text>
    </Pressable>
  );
}

function FilterChip({
  label,
  active,
  theme,
  onPress,
}: {
  label: string;
  active: boolean;
  theme: Theme;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={[
        styles.filterChip,
        {
          backgroundColor: active ? theme.primary : theme.surface,
          borderColor: active ? theme.primary : theme.border,
        },
      ]}
    >
      <Text style={{ color: active ? '#FFFFFF' : theme.text, fontWeight: '600' }}>{label}</Text>
    </Pressable>
  );
}

function deduplicate(items: MediaItem[]): MediaItem[] {
  return [...new Map(items.map((item) => [item.id, item])).values()];
}

function readError(reason: unknown): string {
  if (reason instanceof ApiError || reason instanceof Error) return reason.message;
  return String(reason);
}

function formatDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date);
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
}

function formatDuration(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  const minutes = Math.floor(seconds / 60);
  const remaining = seconds % 60;
  return `${minutes}:${String(remaining).padStart(2, '0')}`;
}

const styles = StyleSheet.create({
  app: { flex: 1 },
  flex: { flex: 1 },
  centered: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 18, padding: 24 },
  mutedText: { fontSize: 14, textAlign: 'center' },
  setupScroll: { flexGrow: 1, justifyContent: 'center', padding: 20 },
  setupCard: { width: '100%', maxWidth: 560, alignSelf: 'center', borderWidth: 1, borderRadius: 24, padding: 24 },
  setupTitle: { fontSize: 28, fontWeight: '800', marginTop: 26 },
  setupDescription: { fontSize: 15, lineHeight: 23, marginTop: 10, marginBottom: 24 },
  brandRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  brandIcon: { width: 42, height: 42, borderRadius: 14, alignItems: 'center', justifyContent: 'center' },
  brandIconText: { color: '#FFFFFF', fontSize: 25, fontWeight: '800' },
  brandName: { fontSize: 22, fontWeight: '800' },
  dividerRow: { flexDirection: 'row', alignItems: 'center', gap: 12, marginVertical: 20 },
  divider: { flex: 1, height: StyleSheet.hairlineWidth },
  dividerLabel: { fontSize: 13 },
  fieldLabel: { fontSize: 14, fontWeight: '700', marginBottom: 8, marginTop: 14 },
  input: { minHeight: 50, borderWidth: 1, borderRadius: 13, paddingHorizontal: 14, fontSize: 15 },
  primaryButton: { minHeight: 50, borderRadius: 14, alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 10, paddingHorizontal: 18, marginTop: 14 },
  primaryButtonText: { color: '#FFFFFF', fontSize: 15, fontWeight: '800' },
  buttonDimmed: { opacity: 0.68 },
  errorBox: { borderWidth: 1, borderRadius: 12, padding: 12, marginTop: 16, lineHeight: 20 },
  securityHint: { fontSize: 12, lineHeight: 18, textAlign: 'center', marginTop: 16 },
  scannerRoot: { flex: 1, backgroundColor: '#05070B' },
  scannerPermission: { flex: 1, justifyContent: 'center', padding: 28, gap: 14 },
  scannerOverlay: { flex: 1, justifyContent: 'space-between' },
  scannerHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', padding: 18 },
  scannerTitle: { color: '#FFFFFF', fontSize: 19, fontWeight: '800' },
  scannerDescription: { color: '#FFFFFF', fontSize: 14, lineHeight: 21, textAlign: 'center' },
  scannerFooter: { margin: 20, borderRadius: 16, backgroundColor: 'rgba(0,0,0,0.72)', padding: 16, gap: 10 },
  scannerError: { color: '#FF879B', textAlign: 'center', lineHeight: 20 },
  closeButton: { paddingHorizontal: 14, paddingVertical: 9, borderRadius: 12, backgroundColor: 'rgba(255,255,255,0.18)' },
  closeButtonText: { color: '#FFFFFF', fontWeight: '700' },
  scanFrame: { position: 'absolute', width: 270, height: 270, borderRadius: 24, borderWidth: 3, borderColor: '#FFFFFF', alignSelf: 'center', top: '31%' },
  libraryHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 12, paddingTop: 10, paddingBottom: 8, gap: 12 },
  libraryTitle: { fontSize: 25, fontWeight: '900' },
  librarySubtitle: { fontSize: 12, marginTop: 3, maxWidth: 230 },
  secondaryButton: { borderWidth: 1, borderRadius: 12, paddingHorizontal: 13, paddingVertical: 10 },
  secondaryButtonText: { fontSize: 13, fontWeight: '700' },
  searchRow: { flexDirection: 'row', paddingHorizontal: 12, gap: 8 },
  searchInput: { flex: 1, height: 46, borderWidth: 1, borderRadius: 13, paddingHorizontal: 13 },
  searchButton: { width: 66, borderRadius: 13, alignItems: 'center', justifyContent: 'center' },
  searchButtonText: { color: '#FFFFFF', fontWeight: '800' },
  filters: { paddingHorizontal: 12, paddingVertical: 10, gap: 8 },
  filterChip: { borderWidth: 1, borderRadius: 999, paddingHorizontal: 16, paddingVertical: 9 },
  inlineError: { marginHorizontal: 12, marginBottom: 8, borderWidth: 1, borderRadius: 12, padding: 11 },
  gridContent: { paddingHorizontal: 12, paddingBottom: 32, gap: 8, flexGrow: 1 },
  mediaCell: { borderRadius: 12, overflow: 'hidden' },
  videoBadge: { position: 'absolute', left: 6, bottom: 6, borderRadius: 8, backgroundColor: 'rgba(0,0,0,0.72)', paddingHorizontal: 7, paddingVertical: 4 },
  videoBadgeText: { color: '#FFFFFF', fontSize: 11, fontWeight: '700' },
  favoriteButton: { position: 'absolute', right: 4, top: 4, width: 34, height: 34, borderRadius: 17, alignItems: 'center', justifyContent: 'center', backgroundColor: 'rgba(0,0,0,0.48)' },
  favoriteIcon: { color: '#FFFFFF', fontSize: 21 },
  favoriteIconActive: { color: '#FFD76A' },
  emptyState: { flex: 1, minHeight: 320, alignItems: 'center', justifyContent: 'center', gap: 8 },
  emptyTitle: { fontSize: 18, fontWeight: '800' },
  footerLoader: { paddingVertical: 24 },
  viewerRoot: { flex: 1 },
  viewerHeader: { height: 58, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 12, gap: 12 },
  viewerButton: { minWidth: 58, alignItems: 'center', paddingVertical: 10, paddingHorizontal: 10, borderRadius: 12, backgroundColor: 'rgba(255,255,255,0.14)' },
  viewerButtonText: { color: '#FFFFFF', fontWeight: '800' },
  viewerFileName: { flex: 1, color: '#FFFFFF', textAlign: 'center', fontWeight: '700' },
  viewerMedia: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  viewerImage: { width: '100%', height: '100%' },
  videoPlayer: { width: '100%', height: '100%' },
  viewerInfo: { padding: 16, gap: 5 },
  viewerMeta: { color: '#FFFFFF', fontSize: 13 },
  viewerPath: { color: '#BFC6D8', fontSize: 12, lineHeight: 18 },
});

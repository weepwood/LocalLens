import 'package:flutter/foundation.dart';

import 'media_item.dart';

class MediaViewerSession extends ChangeNotifier {
  MediaViewerSession({
    required List<MediaItem> items,
    required int initialIndex,
  })  : assert(items.isNotEmpty),
        _items = List<MediaItem>.of(items),
        _index = initialIndex.clamp(0, items.length - 1);

  final List<MediaItem> _items;
  int _index;

  List<MediaItem> get items => List<MediaItem>.unmodifiable(_items);
  int get index => _index;
  int get length => _items.length;
  MediaItem get current => _items[_index];
  bool get canMovePrevious => _index > 0;
  bool get canMoveNext => _index < _items.length - 1;

  bool movePrevious() {
    if (!canMovePrevious) return false;
    _index--;
    notifyListeners();
    return true;
  }

  bool moveNext() {
    if (!canMoveNext) return false;
    _index++;
    notifyListeners();
    return true;
  }

  bool moveTo(int index) {
    if (index < 0 || index >= _items.length || index == _index) return false;
    _index = index;
    notifyListeners();
    return true;
  }

  void replace(MediaItem item) {
    final index = _items.indexWhere((value) => value.id == item.id);
    if (index < 0) return;
    _items[index] = item;
    notifyListeners();
  }
}
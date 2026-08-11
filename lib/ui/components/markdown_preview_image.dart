import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

import '../../acp/acp_input_budget.dart';
import '../../platform/file_manager.dart';
import '../../platform/secure_file_reader.dart';
import '../image_decode_budget.dart';
import '../file_preview/file_preview_document.dart';
import '../theme/app_design_tokens.dart';
import 'bounded_image_preview.dart';

const int _maxInlineMarkdownImageBytes = 16 * 1024 * 1024;
const int _maxLocalMarkdownRasterBytes = filePreviewImageByteLimit;
const int _maxLocalMarkdownSvgBytes = 2 * 1024 * 1024;

typedef MarkdownExternalUriOpener = Future<void> Function(Uri uri);
typedef MarkdownLocalImageResolver =
    Future<FilePreviewTarget> Function({
      required String source,
      required String workspacePath,
      required String baseDirectory,
      required List<String> additionalDirectories,
    });
typedef MarkdownLocalImageSizer = Future<int> Function(String path);
typedef MarkdownBeforeLocalImageRead = FutureOr<void> Function();
typedef MarkdownLocalImageReader =
    Future<Uint8List> Function(
      File file, {
      required int maximumBytes,
      required AcpImageDecodeCancellation cancellation,
    });

Future<Uint8List> _readMarkdownLocalImage(
  FilePreviewTarget target, {
  required int maximumBytes,
  required AcpImageDecodeCancellation cancellation,
}) async {
  if (cancellation.isCancelled) throw const AcpImageDecodeCancelled();
  final root = target.authorizedRoot;
  final relativePath = target.authorizedRelativePath;
  final capability = target.authorizedCapability;
  if (root == null || relativePath == null || capability == null) {
    throw FileSystemException('无法安全打开已授权图片', target.path);
  }
  final snapshot = await readWorkspaceFileSnapshotSecurely(
    resolvedWorkspacePath: root,
    relativePath: relativePath,
    maximumBytes: maximumBytes,
    expectedCapability: capability,
  );
  if (cancellation.isCancelled) throw const AcpImageDecodeCancelled();
  if (snapshot == null) {
    throw FileSystemException('无法安全打开已授权图片', target.path);
  }
  if (snapshot.exceededLimit) {
    throw FilePreviewByteLimitExceededException(maximumBytes);
  }
  return snapshot.bytes;
}

final class MarkdownImageLoadBudgetExceeded implements Exception {
  const MarkdownImageLoadBudgetExceeded(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Bounds encoded image snapshots retained by one rendered Markdown document.
///
/// Each image reference claims its own slot, including duplicate URIs. Snapshot
/// reads are serialized and pessimistically reserve all remaining document
/// bytes before data URI decoding or file IO, so concurrent widgets cannot
/// transiently exceed the document budget.
final class MarkdownImageLoadBudgetLedger {
  MarkdownImageLoadBudgetLedger({
    this.maxImages = 16,
    required this.maxEncodedBytes,
  }) {
    if (maxImages <= 0) {
      throw ArgumentError.value(maxImages, 'maxImages', 'must be positive');
    }
    if (maxEncodedBytes <= 0) {
      throw ArgumentError.value(
        maxEncodedBytes,
        'maxEncodedBytes',
        'must be positive',
      );
    }
  }

  final int maxImages;
  final int maxEncodedBytes;
  final Queue<_MarkdownImageLoadWaiter> _waiters =
      Queue<_MarkdownImageLoadWaiter>();

  int _claimedImages = 0;
  int _reservedBytes = 0;
  bool _loadActive = false;

  int get claimedImages => _claimedImages;
  int get reservedBytes => _reservedBytes;
  int get waitingLoads => _waiters.length;
  bool get loadActive => _loadActive;

  Future<MarkdownImageLoadReservation> acquire({
    required AcpImageDecodeCancellation cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<MarkdownImageLoadReservation>.error(
        const AcpImageDecodeCancelled(),
      );
    }
    if (_claimedImages >= maxImages) {
      return Future<MarkdownImageLoadReservation>.error(
        const MarkdownImageLoadBudgetExceeded('此文档包含过多图片，已停止继续加载'),
      );
    }
    _claimedImages += 1;
    final waiter = _MarkdownImageLoadWaiter(cancellation);
    _waiters.add(waiter);
    void cancel() => _cancelWaiter(waiter);
    waiter.cancelListener = cancel;
    cancellation.addListener(cancel);
    _grantNext();
    return waiter.completer.future;
  }

  void _cancelWaiter(_MarkdownImageLoadWaiter waiter) {
    if (!waiter.waiting) return;
    waiter.waiting = false;
    _waiters.remove(waiter);
    waiter.cancellation.removeListener(waiter.cancelListener!);
    _claimedImages -= 1;
    waiter.completer.completeError(const AcpImageDecodeCancelled());
    _grantNext();
  }

  void _grantNext() {
    if (_loadActive) return;
    if (_reservedBytes >= maxEncodedBytes) {
      while (_waiters.isNotEmpty) {
        final waiter = _waiters.removeFirst();
        if (!waiter.waiting) continue;
        waiter.waiting = false;
        waiter.cancellation.removeListener(waiter.cancelListener!);
        _claimedImages -= 1;
        waiter.completer.completeError(
          const MarkdownImageLoadBudgetExceeded('此文档的图片总大小超过安全预览限制'),
        );
      }
      return;
    }
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.waiting) continue;
      waiter.waiting = false;
      waiter.cancellation.removeListener(waiter.cancelListener!);
      if (waiter.cancellation.isCancelled) {
        _claimedImages -= 1;
        waiter.completer.completeError(const AcpImageDecodeCancelled());
        continue;
      }
      final available = maxEncodedBytes - _reservedBytes;
      _reservedBytes += available;
      _loadActive = true;
      waiter.completer.complete(
        MarkdownImageLoadReservation._(this, available),
      );
      return;
    }
  }

  void _shrink(MarkdownImageLoadReservation reservation, int bytes) {
    if (bytes < 0 || bytes > reservation._reservedBytes) {
      throw RangeError.range(bytes, 0, reservation._reservedBytes, 'bytes');
    }
    _reservedBytes -= reservation._reservedBytes - bytes;
    reservation._reservedBytes = bytes;
  }

  void _finishLoad(MarkdownImageLoadReservation reservation) {
    if (!reservation._loading) return;
    reservation._loading = false;
    _loadActive = false;
    _grantNext();
  }

  void _release(MarkdownImageLoadReservation reservation) {
    if (reservation._released) return;
    _finishLoad(reservation);
    reservation._released = true;
    _reservedBytes -= reservation._reservedBytes;
    reservation._reservedBytes = 0;
    _claimedImages -= 1;
    _grantNext();
  }
}

final class MarkdownImageLoadReservation {
  MarkdownImageLoadReservation._(this._ledger, this._reservedBytes);

  final MarkdownImageLoadBudgetLedger _ledger;
  int _reservedBytes;
  bool _loading = true;
  bool _released = false;

  int get maximumBytes => _reservedBytes;

  void shrinkTo(int bytes) => _ledger._shrink(this, bytes);

  void finishLoad() => _ledger._finishLoad(this);

  void release() => _ledger._release(this);
}

final class _MarkdownImageLoadWaiter {
  _MarkdownImageLoadWaiter(this.cancellation);

  final AcpImageDecodeCancellation cancellation;
  final Completer<MarkdownImageLoadReservation> completer =
      Completer<MarkdownImageLoadReservation>();
  bool waiting = true;
  void Function()? cancelListener;
}

class MarkdownPreviewImage extends StatefulWidget {
  const MarkdownPreviewImage({
    super.key,
    required this.uri,
    required this.workspacePath,
    required this.baseDirectory,
    required this.additionalDirectories,
    this.alt,
    this.openExternalUri,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.boundedImageDecoder = const DartUiBoundedImageDecoder(),
    this.loadBudgetLedger,
    this.resolveLocalImage = resolveMarkdownImageTarget,
    this.readLocalImageSize,
    this.readLocalImage,
    this.beforeLocalImageRead,
    this.inspectImageDimensions = inspectFilePreviewImageDimensions,
  });

  final Uri uri;
  final String workspacePath;
  final String baseDirectory;
  final List<String> additionalDirectories;
  final String? alt;
  final MarkdownExternalUriOpener? openExternalUri;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder boundedImageDecoder;
  final MarkdownImageLoadBudgetLedger? loadBudgetLedger;
  final MarkdownLocalImageResolver resolveLocalImage;
  final MarkdownLocalImageSizer? readLocalImageSize;
  final MarkdownLocalImageReader? readLocalImage;
  final MarkdownBeforeLocalImageRead? beforeLocalImageRead;
  final FilePreviewImageDimensionInspector inspectImageDimensions;

  @override
  State<MarkdownPreviewImage> createState() => _MarkdownPreviewImageState();
}

class _MarkdownPreviewImageState extends State<MarkdownPreviewImage> {
  var _generation = 0;
  AcpImageDecodeCancellationSource? _cancellation;
  MarkdownImageLoadReservation? _pendingLoadReservation;
  MarkdownImageLoadReservation? _installedLoadReservation;
  MarkdownImageLoadBudgetLedger? _ownedLoadBudgetLedger;
  AcpImageDecodeBudgetLedger? _ownedImageDecodeLedger;
  Future<({Uint8List bytes, bool svg})>? _image;

  MarkdownImageLoadBudgetLedger get _loadBudgetLedger =>
      widget.loadBudgetLedger ??
      (_ownedLoadBudgetLedger ??= MarkdownImageLoadBudgetLedger(
        maxImages: 1,
        maxEncodedBytes: widget.inputBudget.maxEmbeddedMediaBytes,
      ));

  AcpImageDecodeBudgetLedger get _imageDecodeLedger =>
      widget.imageDecodeLedger ??
      (_ownedImageDecodeLedger ??= AcpImageDecodeBudgetLedger(
        budget: widget.inputBudget,
      ));

  @override
  void initState() {
    super.initState();
    widget.inputBudget.validate();
    _restartLoad();
  }

  @override
  void didUpdateWidget(covariant MarkdownPreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
    if (oldWidget.uri != widget.uri ||
        oldWidget.workspacePath != widget.workspacePath ||
        oldWidget.baseDirectory != widget.baseDirectory ||
        !identical(oldWidget.inputBudget, widget.inputBudget) ||
        !identical(oldWidget.imageDecodeLedger, widget.imageDecodeLedger) ||
        !identical(oldWidget.boundedImageDecoder, widget.boundedImageDecoder) ||
        !identical(oldWidget.loadBudgetLedger, widget.loadBudgetLedger) ||
        !identical(oldWidget.resolveLocalImage, widget.resolveLocalImage) ||
        !identical(oldWidget.readLocalImageSize, widget.readLocalImageSize) ||
        !identical(oldWidget.readLocalImage, widget.readLocalImage) ||
        !identical(
          oldWidget.beforeLocalImageRead,
          widget.beforeLocalImageRead,
        ) ||
        !identical(
          oldWidget.inspectImageDimensions,
          widget.inspectImageDimensions,
        ) ||
        !_sameStrings(
          oldWidget.additionalDirectories,
          widget.additionalDirectories,
        )) {
      _ownedLoadBudgetLedger = null;
      _ownedImageDecodeLedger = null;
      _restartLoad();
    }
  }

  @override
  void dispose() {
    _cancelLoad();
    super.dispose();
  }

  void _restartLoad() {
    _cancelLoad();
    final scheme = widget.uri.scheme.toLowerCase();
    if (scheme == 'data' && _dataUriPreflightError() != null) {
      _image = null;
      return;
    }
    if (scheme == 'data' || scheme.isEmpty || scheme == 'file') {
      final generation = ++_generation;
      final cancellation = AcpImageDecodeCancellationSource();
      _cancellation = cancellation;
      _image = _loadImage(generation, cancellation);
    } else {
      _image = null;
    }
  }

  String? _dataUriPreflightError() {
    try {
      final data = widget.uri.data;
      final mimeType = data?.mimeType.toLowerCase() ?? '';
      if (data == null || !mimeType.startsWith('image/')) {
        return 'data URI 不是图片';
      }
      final svg = mimeType == 'image/svg+xml';
      final maximumBytes = svg
          ? _maxLocalMarkdownSvgBytes
          : _maxInlineMarkdownImageBytes;
      if (_dataUriPayloadExceeds(widget.uri.toString(), data, maximumBytes)) {
        return svg ? '内嵌 SVG 超过 2 MB 限制' : '内嵌图片超过 16 MB 限制';
      }
      return null;
    } on FormatException {
      return 'data URI 格式无效';
    }
  }

  void _cancelLoad() {
    _generation += 1;
    _cancellation?.cancel();
    _cancellation = null;
    _pendingLoadReservation?.release();
    _pendingLoadReservation = null;
    _installedLoadReservation?.release();
    _installedLoadReservation = null;
  }

  bool _isCurrent(
    int generation,
    AcpImageDecodeCancellationSource cancellation,
  ) =>
      mounted &&
      generation == _generation &&
      identical(_cancellation, cancellation) &&
      !cancellation.isCancelled;

  Future<({Uint8List bytes, bool svg})> _loadImage(
    int generation,
    AcpImageDecodeCancellationSource cancellation,
  ) async {
    MarkdownImageLoadReservation? reservation;
    var installed = false;
    try {
      reservation = await _loadBudgetLedger.acquire(cancellation: cancellation);
      _pendingLoadReservation = reservation;
      if (!_isCurrent(generation, cancellation)) {
        throw const AcpImageDecodeCancelled();
      }
      final result = widget.uri.scheme.toLowerCase() == 'data'
          ? await _loadDataImage(reservation)
          : await _loadLocalImage(reservation, cancellation);
      if (!_isCurrent(generation, cancellation)) {
        throw const AcpImageDecodeCancelled();
      }
      reservation.shrinkTo(result.bytes.length);
      _pendingLoadReservation = null;
      _installedLoadReservation = reservation;
      installed = true;
      return result;
    } finally {
      if (identical(_pendingLoadReservation, reservation)) {
        _pendingLoadReservation = null;
      }
      reservation?.finishLoad();
      if (!installed) reservation?.release();
    }
  }

  Future<({Uint8List bytes, bool svg})> _loadLocalImage(
    MarkdownImageLoadReservation reservation,
    AcpImageDecodeCancellation cancellation,
  ) async {
    final target = await widget.resolveLocalImage(
      source: widget.uri.toString(),
      workspacePath: widget.workspacePath,
      baseDirectory: widget.baseDirectory,
      additionalDirectories: widget.additionalDirectories,
    );
    final svg = _isSvgPath(target.path);
    await widget.beforeLocalImageRead?.call();
    final perImageLimit = svg
        ? _maxLocalMarkdownSvgBytes
        : _maxLocalMarkdownRasterBytes;
    final maximumBytes = _effectiveMaximumBytes(
      perImageLimit,
      reservation.maximumBytes,
    );
    final sizer = widget.readLocalImageSize;
    if (sizer != null) {
      final size = await sizer(target.path);
      if (size > maximumBytes) throw _imageLimitError(svg, maximumBytes);
    }
    try {
      final bytes = widget.readLocalImage == null
          ? await _readMarkdownLocalImage(
              target,
              maximumBytes: maximumBytes,
              cancellation: cancellation,
            )
          : await widget.readLocalImage!(
              File(target.path),
              maximumBytes: maximumBytes,
              cancellation: cancellation,
            );
      if (!svg) await _validateRasterDimensions(bytes);
      return (bytes: bytes, svg: svg);
    } on FilePreviewByteLimitExceededException {
      throw _imageLimitError(svg, maximumBytes);
    }
  }

  Future<({Uint8List bytes, bool svg})> _loadDataImage(
    MarkdownImageLoadReservation reservation,
  ) async {
    final source = widget.uri.toString();
    final data = widget.uri.data;
    final mimeType = data?.mimeType.toLowerCase() ?? '';
    if (data == null || !mimeType.startsWith('image/')) {
      throw const FormatException('data URI 不是图片');
    }
    final svg = mimeType == 'image/svg+xml';
    final perImageLimit = svg
        ? _maxLocalMarkdownSvgBytes
        : _maxInlineMarkdownImageBytes;
    final maximumBytes = _effectiveMaximumBytes(
      perImageLimit,
      reservation.maximumBytes,
    );
    if (_dataUriPayloadExceeds(source, data, maximumBytes)) {
      throw _imageLimitError(svg, maximumBytes, inline: true);
    }
    final bytes = Uint8List.fromList(data.contentAsBytes());
    if (bytes.length > maximumBytes) {
      throw _imageLimitError(svg, maximumBytes, inline: true);
    }
    if (!svg) await _validateRasterDimensions(bytes);
    return (bytes: bytes, svg: svg);
  }

  Future<void> _validateRasterDimensions(Uint8List bytes) async {
    final dimensions = await widget.inspectImageDimensions(bytes);
    if (!filePreviewImageDimensionsAreSafe(dimensions)) {
      throw const FormatException('图片尺寸超过安全预览限制');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      if (widget.uri.host.trim().isEmpty) {
        return _MarkdownImageFailure(alt: widget.alt, message: '图片 URL 缺少主机地址');
      }
      return _RemoteMarkdownImageConsent(
        uri: widget.uri,
        alt: widget.alt,
        onOpenExternally: _openRemoteImageExternally,
      );
    }
    if (scheme == 'data') {
      final error = _dataUriPreflightError();
      if (error != null) {
        return _MarkdownImageFailure(alt: widget.alt, message: error);
      }
    }
    if (scheme.isNotEmpty && scheme != 'file' && scheme != 'data') {
      return _MarkdownImageFailure(
        alt: widget.alt,
        message: '不支持 $scheme 图片路径',
      );
    }

    return FutureBuilder<({Uint8List bytes, bool svg})>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _MarkdownImageFailure(
            alt: widget.alt,
            message: _safeLocalError(snapshot.error!),
          );
        }
        final image = snapshot.data;
        if (image == null) return const _MarkdownImageLoading();
        return _frame(
          context,
          image.svg
              ? SvgPicture.memory(
                  image.bytes,
                  fit: BoxFit.contain,
                  placeholderBuilder: (_) => const _MarkdownImageLoading(),
                  errorBuilder: (_, error, stackTrace) =>
                      _MarkdownImageFailure(alt: widget.alt),
                )
              : BoundedImagePreview.bytes(
                  bytes: image.bytes,
                  inputBudget: widget.inputBudget,
                  imageDecodeLedger: _imageDecodeLedger,
                  decoder: widget.boundedImageDecoder,
                  height: null,
                ),
        );
      },
    );
  }

  Widget _frame(BuildContext context, Widget child) {
    return Semantics(
      label: widget.alt?.trim(),
      image: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 560),
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: child,
        ),
      ),
    );
  }

  Future<void> _openRemoteImageExternally() async {
    try {
      await (widget.openExternalUri ?? openUriExternally)(widget.uri);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开远程图片：$error')));
    }
  }
}

class _RemoteMarkdownImageConsent extends StatelessWidget {
  const _RemoteMarkdownImageConsent({
    required this.uri,
    required this.alt,
    required this.onOpenExternally,
  });

  final Uri uri;
  final String? alt;
  final VoidCallback onOpenExternally;

  @override
  Widget build(BuildContext context) {
    final description = alt?.trim();
    return Semantics(
      container: true,
      label: '已阻止远程图片 ${description ?? ''}'.trim(),
      child: Container(
        key: const Key('markdown-remote-image-blocked'),
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.shield_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      '图片未自动加载',
                      if (description != null && description.isNotEmpty)
                        description,
                    ].join(' · '),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    uri.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('markdown-remote-image-open-external'),
              onPressed: onOpenExternally,
              child: const Text('在浏览器中打开'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkdownImageLoading extends StatelessWidget {
  const _MarkdownImageLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 96,
      child: Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _MarkdownImageFailure extends StatelessWidget {
  const _MarkdownImageFailure({this.alt, this.message = '图片加载失败'});

  final String? alt;
  final String message;

  @override
  Widget build(BuildContext context) {
    final description = alt?.trim();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          const Icon(Icons.broken_image_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                message,
                if (description != null && description.isNotEmpty) description,
              ].join(' · '),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _isSvgPath(String path) => p.extension(path).toLowerCase() == '.svg';

bool _sameStrings(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _safeLocalError(Object error) {
  if (error is FileSystemException) {
    if (error.message.contains('不在当前工作区')) {
      return '图片不在当前工作区或已授权目录中';
    }
    if (error.message.contains('不存在')) return '图片文件不存在';
  }
  if (error is FormatException) return error.message;
  if (error is MarkdownImageLoadBudgetExceeded) return error.message;
  return '图片加载失败';
}

int _effectiveMaximumBytes(int perImageLimit, int documentBytesRemaining) =>
    perImageLimit < documentBytesRemaining
    ? perImageLimit
    : documentBytesRemaining;

FormatException _imageLimitError(
  bool svg,
  int effectiveLimit, {
  bool inline = false,
}) {
  final normalLimit = svg
      ? _maxLocalMarkdownSvgBytes
      : _maxInlineMarkdownImageBytes;
  if (effectiveLimit < normalLimit) {
    return const FormatException('此文档的图片总大小超过安全预览限制');
  }
  if (svg) {
    return FormatException(inline ? '内嵌 SVG 超过 2 MB 限制' : 'SVG 图片超过 2 MB 限制');
  }
  return FormatException(inline ? '内嵌图片超过 16 MB 限制' : '图片文件超过 16 MB 限制');
}

bool _dataUriPayloadExceeds(String source, UriData data, int maximumBytes) {
  final comma = source.indexOf(',');
  if (comma < 0) return false;
  final payloadStart = comma + 1;
  final payloadLength = source.length - payloadStart;
  if (data.isBase64) {
    if (payloadLength % 4 != 0) return false;
    var padding = 0;
    if (payloadLength > 0 && source.codeUnitAt(source.length - 1) == 0x3d) {
      padding = 1;
      if (payloadLength > 1 && source.codeUnitAt(source.length - 2) == 0x3d) {
        padding = 2;
      }
    }
    final decodedBytes = payloadLength ~/ 4 * 3 - padding;
    return decodedBytes > maximumBytes;
  }

  var decodedBytes = 0;
  var index = payloadStart;
  while (index < source.length) {
    decodedBytes += 1;
    if (decodedBytes > maximumBytes) return true;
    if (source.codeUnitAt(index) == 0x25 && index + 2 < source.length) {
      index += 3;
    } else {
      index += 1;
    }
  }
  return false;
}

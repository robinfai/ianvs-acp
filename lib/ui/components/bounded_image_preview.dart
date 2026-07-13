import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter/material.dart';

import '../image_decode_budget.dart';

abstract interface class BoundedImageDecoder {
  Future<BoundedImageBuffer> createBuffer(Uint8List bytes);

  Future<BoundedImageDescriptor> createDescriptor(BoundedImageBuffer buffer);

  Future<BoundedImageCodec> createCodec(
    BoundedImageDescriptor descriptor, {
    required int targetWidth,
    required int targetHeight,
  });

  Future<BoundedImageFrame> getFirstFrame(BoundedImageCodec codec);
}

abstract interface class BoundedImageBuffer {
  void dispose();
}

abstract interface class BoundedImageDescriptor {
  int get width;

  int get height;

  void dispose();
}

abstract interface class BoundedImageCodec {
  void dispose();
}

abstract interface class BoundedImageFrame {
  ui.Image takeImage();

  void dispose();
}

typedef BoundedImageReservationAcquirer =
    Future<AcpImageDecodeReservation> Function({
      required int decodedBytes,
      required AcpImageDecodeCancellation cancellation,
    });

final class DartUiBoundedImageDecoder implements BoundedImageDecoder {
  const DartUiBoundedImageDecoder();

  @override
  Future<BoundedImageBuffer> createBuffer(Uint8List bytes) async {
    return _DartUiBoundedImageBuffer(
      await ui.ImmutableBuffer.fromUint8List(bytes),
    );
  }

  @override
  Future<BoundedImageDescriptor> createDescriptor(
    BoundedImageBuffer buffer,
  ) async {
    final uiBuffer = _requireHandle<_DartUiBoundedImageBuffer>(buffer);
    return _DartUiBoundedImageDescriptor(
      await ui.ImageDescriptor.encoded(uiBuffer.value),
    );
  }

  @override
  Future<BoundedImageCodec> createCodec(
    BoundedImageDescriptor descriptor, {
    required int targetWidth,
    required int targetHeight,
  }) async {
    final uiDescriptor = _requireHandle<_DartUiBoundedImageDescriptor>(
      descriptor,
    );
    return _DartUiBoundedImageCodec(
      await uiDescriptor.value.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      ),
    );
  }

  @override
  Future<BoundedImageFrame> getFirstFrame(BoundedImageCodec codec) async {
    final uiCodec = _requireHandle<_DartUiBoundedImageCodec>(codec);
    final frame = await uiCodec.value.getNextFrame();
    return _DartUiBoundedImageFrame(frame.image);
  }
}

T _requireHandle<T>(Object value) {
  if (value is T) return value as T;
  throw ArgumentError.value(value, 'handle', 'was not created by this decoder');
}

final class _DartUiBoundedImageBuffer implements BoundedImageBuffer {
  _DartUiBoundedImageBuffer(this.value);

  final ui.ImmutableBuffer value;
  var _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    value.dispose();
  }
}

final class _DartUiBoundedImageDescriptor implements BoundedImageDescriptor {
  _DartUiBoundedImageDescriptor(this.value);

  final ui.ImageDescriptor value;
  var _disposed = false;

  @override
  int get width => value.width;

  @override
  int get height => value.height;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    value.dispose();
  }
}

final class _DartUiBoundedImageCodec implements BoundedImageCodec {
  _DartUiBoundedImageCodec(this.value);

  final ui.Codec value;
  var _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    value.dispose();
  }
}

final class _DartUiBoundedImageFrame implements BoundedImageFrame {
  _DartUiBoundedImageFrame(ui.Image image) : _image = image;

  ui.Image? _image;
  var _disposed = false;

  @override
  ui.Image takeImage() {
    if (_disposed) throw StateError('Image frame was disposed.');
    final image = _image;
    if (image == null) throw StateError('Image frame was already consumed.');
    _image = null;
    return image;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _image?.dispose();
    _image = null;
  }
}

class BoundedImagePreview extends StatefulWidget {
  const BoundedImagePreview({
    super.key,
    required this.data,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.decoder = const DartUiBoundedImageDecoder(),
    this.reservationAcquirer,
    this.height = 132,
  }) : assert(
         imageDecodeLedger != null || reservationAcquirer != null,
         'A shared image decode ledger or test reservation acquirer is required.',
       );

  final String data;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder decoder;
  final BoundedImageReservationAcquirer? reservationAcquirer;
  final double height;

  @override
  State<BoundedImagePreview> createState() => _BoundedImagePreviewState();
}

class _BoundedImagePreviewState extends State<BoundedImagePreview> {
  var _generation = 0;
  AcpImageDecodeCancellationSource? _cancellation;
  ui.Image? _installedImage;
  AcpImageDecodeReservation? _installedReservation;

  @override
  void initState() {
    super.initState();
    widget.inputBudget.validate();
    _startDecode();
  }

  @override
  void didUpdateWidget(covariant BoundedImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
    if (widget.data == oldWidget.data &&
        identical(widget.inputBudget, oldWidget.inputBudget) &&
        identical(widget.imageDecodeLedger, oldWidget.imageDecodeLedger) &&
        identical(widget.decoder, oldWidget.decoder) &&
        identical(widget.reservationAcquirer, oldWidget.reservationAcquirer)) {
      return;
    }
    _cancelCurrentGeneration();
    _releaseInstalledImage();
    _startDecode();
  }

  @override
  void dispose() {
    _cancelCurrentGeneration();
    _releaseInstalledImage();
    super.dispose();
  }

  void _startDecode() {
    final generation = ++_generation;
    final cancellation = AcpImageDecodeCancellationSource();
    _cancellation = cancellation;
    unawaited(_decode(generation, cancellation));
  }

  void _cancelCurrentGeneration() {
    _generation += 1;
    _cancellation?.cancel();
    _cancellation = null;
  }

  bool _isCurrent(
    int generation,
    AcpImageDecodeCancellationSource cancellation,
  ) =>
      mounted &&
      generation == _generation &&
      identical(_cancellation, cancellation) &&
      !cancellation.isCancelled;

  Future<void> _decode(
    int generation,
    AcpImageDecodeCancellationSource cancellation,
  ) async {
    final AcpBase64ScanResult scan;
    try {
      scan = scanAcpBase64(
        widget.data,
        maxDecodedBytes: widget.inputBudget.maxEmbeddedMediaBytes,
        resource: 'image_data',
      );
    } catch (_) {
      _showFailure(generation, cancellation);
      return;
    }

    AcpImageDecodeReservation? reservation;
    BoundedImageBuffer? buffer;
    BoundedImageDescriptor? descriptor;
    BoundedImageCodec? codec;
    BoundedImageFrame? frame;
    ui.Image? image;
    var reservationInstalled = false;
    try {
      final acquire =
          widget.reservationAcquirer ??
          ({
            required int decodedBytes,
            required AcpImageDecodeCancellation cancellation,
          }) => widget.imageDecodeLedger!.acquire(
            decodedBytes: decodedBytes,
            cancellation: cancellation,
          );
      reservation = await acquire(
        decodedBytes: scan.decodedBytes,
        cancellation: cancellation,
      );
      if (!_isCurrent(generation, cancellation)) return;

      final bytes = base64Decode(widget.data);
      buffer = await widget.decoder.createBuffer(bytes);
      if (!_isCurrent(generation, cancellation)) return;

      descriptor = await widget.decoder.createDescriptor(buffer);
      if (!_isCurrent(generation, cancellation)) return;

      final width = descriptor.width;
      final height = descriptor.height;
      if (!_validSourceDimensions(width, height, widget.inputBudget)) {
        throw const FormatException('Invalid image dimensions.');
      }
      final target = _previewTarget(
        width,
        height,
        widget.inputBudget.maxImagePreviewPixels,
      );
      final previewPixels = target.width * target.height;
      reservation.shrinkInstalledReservation(
        previewPixels: previewPixels,
        reservedBytes: scan.decodedBytes + previewPixels * 4,
      );

      codec = await widget.decoder.createCodec(
        descriptor,
        targetWidth: target.width,
        targetHeight: target.height,
      );
      if (!_isCurrent(generation, cancellation)) return;

      final completedDescriptor = descriptor;
      descriptor = null;
      _runBoundedImageCleanup(completedDescriptor.dispose);
      final completedBuffer = buffer;
      buffer = null;
      _runBoundedImageCleanup(completedBuffer.dispose);

      frame = await widget.decoder.getFirstFrame(codec);
      if (!_isCurrent(generation, cancellation)) {
        final staleFrame = frame;
        frame = null;
        try {
          image = staleFrame.takeImage();
        } finally {
          _runBoundedImageCleanup(staleFrame.dispose);
        }
        return;
      }
      final completedFrame = frame;
      frame = null;
      try {
        image = completedFrame.takeImage();
      } finally {
        _runBoundedImageCleanup(completedFrame.dispose);
      }
      final completedCodec = codec;
      codec = null;
      _runBoundedImageCleanup(completedCodec.dispose);

      if (!_isCurrent(generation, cancellation)) return;
      _releaseInstalledImage();
      _installedImage = image;
      image = null;
      _installedReservation = reservation;
      reservationInstalled = true;
      if (mounted) setState(() {});
    } catch (_) {
      _showFailure(generation, cancellation);
    } finally {
      final remainingFrame = frame;
      frame = null;
      if (remainingFrame != null) {
        _runBoundedImageCleanup(remainingFrame.dispose);
      }
      final remainingCodec = codec;
      codec = null;
      if (remainingCodec != null) {
        _runBoundedImageCleanup(remainingCodec.dispose);
      }
      final remainingDescriptor = descriptor;
      descriptor = null;
      if (remainingDescriptor != null) {
        _runBoundedImageCleanup(remainingDescriptor.dispose);
      }
      final remainingBuffer = buffer;
      buffer = null;
      if (remainingBuffer != null) {
        _runBoundedImageCleanup(remainingBuffer.dispose);
      }
      final remainingImage = image;
      image = null;
      if (remainingImage != null) {
        _runBoundedImageCleanup(remainingImage.dispose);
      }
      if (reservation != null) {
        _runBoundedImageCleanup(reservation.finishDecode);
        if (!reservationInstalled) {
          _runBoundedImageCleanup(reservation.releaseInstalledMemory);
        }
      }
    }
  }

  void _showFailure(
    int generation,
    AcpImageDecodeCancellationSource cancellation,
  ) {
    if (!_isCurrent(generation, cancellation)) return;
    if (mounted) setState(() {});
  }

  void _releaseInstalledImage() {
    final image = _installedImage;
    _installedImage = null;
    if (image != null) _runBoundedImageCleanup(image.dispose);
    final reservation = _installedReservation;
    _installedReservation = null;
    if (reservation != null) {
      _runBoundedImageCleanup(reservation.releaseInstalledMemory);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _installedImage;
    if (image == null) {
      return const Text(
        'Image preview unavailable.',
        key: ValueKey('bounded-image-placeholder'),
      );
    }
    return RawImage(
      key: const ValueKey('bounded-image-preview'),
      image: image,
      height: widget.height,
      fit: BoxFit.contain,
    );
  }
}

void _runBoundedImageCleanup(void Function() cleanup) {
  try {
    cleanup();
  } catch (error, stackTrace) {
    try {
      Zone.current.handleUncaughtError(error, stackTrace);
    } catch (_) {
      // External Zone error handlers must not interrupt remaining cleanup.
    }
  }
}

bool _validSourceDimensions(int width, int height, AcpInputBudget budget) {
  if (width <= 0 || height <= 0) return false;
  if (width > budget.maxImageDimension || height > budget.maxImageDimension) {
    return false;
  }
  return width <= budget.maxImagePixels ~/ height;
}

({int width, int height}) _previewTarget(int width, int height, int maxPixels) {
  if (width <= maxPixels ~/ height) return (width: width, height: height);
  late int targetWidth;
  late int targetHeight;
  if (width >= height) {
    targetWidth = math.max(
      1,
      math.sqrt(maxPixels.toDouble() * (width / height)).floor(),
    );
    targetHeight = math.max(1, (targetWidth * (height / width)).floor());
  } else {
    targetHeight = math.max(
      1,
      math.sqrt(maxPixels.toDouble() * (height / width)).floor(),
    );
    targetWidth = math.max(1, (targetHeight * (width / height)).floor());
  }
  if (targetWidth > maxPixels ~/ targetHeight) {
    if (targetWidth >= targetHeight) {
      targetWidth = math.max(1, maxPixels ~/ targetHeight);
    } else {
      targetHeight = math.max(1, maxPixels ~/ targetWidth);
    }
  }
  return (width: targetWidth, height: targetHeight);
}

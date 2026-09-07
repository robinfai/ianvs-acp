import 'package:flutter/material.dart';

/// A vertically bounded scroll area whose edge fades communicate overflow.
class ScrollFadeRegion extends StatefulWidget {
  const ScrollFadeRegion({
    super.key,
    required this.maxHeight,
    required this.backgroundColor,
    required this.child,
    this.controller,
    this.fadeExtent = 22,
    this.showScrollbar = false,
  });

  final double maxHeight;
  final Color backgroundColor;
  final Widget child;
  final ScrollController? controller;
  final double fadeExtent;
  final bool showScrollbar;

  @override
  State<ScrollFadeRegion> createState() => _ScrollFadeRegionState();
}

class _ScrollFadeRegionState extends State<ScrollFadeRegion> {
  late ScrollController _controller;
  var _canScrollUp = false;
  var _canScrollDown = false;

  bool get _ownsController => widget.controller == null;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? ScrollController();
    _controller.addListener(_updateEdges);
    _scheduleEdgeUpdate();
  }

  @override
  void didUpdateWidget(covariant ScrollFadeRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _controller.removeListener(_updateEdges);
      if (oldWidget.controller == null) _controller.dispose();
      _controller = widget.controller ?? ScrollController();
      _controller.addListener(_updateEdges);
    }
    _scheduleEdgeUpdate();
  }

  @override
  void dispose() {
    _controller.removeListener(_updateEdges);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _scheduleEdgeUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateEdges();
    });
  }

  void _updateEdges() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final canScrollUp = position.pixels > position.minScrollExtent + 0.5;
    final canScrollDown = position.pixels < position.maxScrollExtent - 0.5;
    if (_canScrollUp == canScrollUp && _canScrollDown == canScrollDown) return;
    setState(() {
      _canScrollUp = canScrollUp;
      _canScrollDown = canScrollDown;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget scrollView = SingleChildScrollView(
      key: const ValueKey('scroll-fade-scroll-view'),
      controller: _controller,
      primary: false,
      child: widget.child,
    );
    if (widget.showScrollbar) {
      scrollView = Scrollbar(
        controller: _controller,
        thumbVisibility: false,
        child: scrollView,
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: Stack(
        children: [
          scrollView,
          _EdgeFade(
            key: const ValueKey('scroll-fade-top'),
            visible: _canScrollUp,
            top: true,
            extent: widget.fadeExtent,
            color: widget.backgroundColor,
          ),
          _EdgeFade(
            key: const ValueKey('scroll-fade-bottom'),
            visible: _canScrollDown,
            top: false,
            extent: widget.fadeExtent,
            color: widget.backgroundColor,
          ),
        ],
      ),
    );
  }
}

class _EdgeFade extends StatelessWidget {
  const _EdgeFade({
    super.key,
    required this.visible,
    required this.top,
    required this.extent,
    required this.color,
  });

  final bool visible;
  final bool top;
  final double extent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final transparent = color.withValues(alpha: 0);
    return Positioned(
      top: top ? 0 : null,
      bottom: top ? null : 0,
      left: 0,
      right: 0,
      height: extent,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: visible ? 1 : 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: top
                    ? <Color>[color, transparent]
                    : <Color>[transparent, color],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

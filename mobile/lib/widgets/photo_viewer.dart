import 'package:flutter/material.dart';

/// Full-screen viewer for a render: pinch to zoom, double-tap to toggle, drag
/// down to dismiss.
///
/// This deliberately uses a route rather than `showDialog`. A dialog hands its
/// child loose constraints, so an `InteractiveViewer` wrapping a `Center` gets
/// an unbounded height and fails layout — the tap appears to do nothing.
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.image,
    this.heroTag,
    this.caption,
  });

  final ImageProvider image;
  final Object? heroTag;
  final String? caption;

  static Route<void> route({
    required ImageProvider image,
    Object? heroTag,
    String? caption,
  }) {
    return PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) =>
          PhotoViewerPage(image: image, heroTag: heroTag, caption: caption),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  final _controller = TransformationController();
  double _dragOffset = 0;

  bool get _isZoomed => _controller.value.getMaxScaleOnAxis() > 1.05;

  void _toggleZoom(TapDownDetails details) {
    if (_isZoomed) {
      _controller.value = Matrix4.identity();
      return;
    }
    // Zoom towards wherever the user tapped rather than the centre.
    final position = details.localPosition;
    _controller.value = Matrix4.identity()
      ..translateByDouble(-position.dx, -position.dy, 0, 1)
      ..scaleByDouble(2.0, 2.0, 2.0, 1);
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = Image(image: widget.image, fit: BoxFit.contain);

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: (1 - _dragOffset.abs() / 320).clamp(0.0, 1.0)),
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onDoubleTapDown: _toggleZoom,
              onDoubleTap: () {},
              // Drag down to dismiss, but only when not zoomed in — otherwise
              // panning a zoomed image would close the viewer.
              onVerticalDragUpdate: _isZoomed
                  ? null
                  : (details) => setState(() => _dragOffset += details.delta.dy),
              onVerticalDragEnd: _isZoomed
                  ? null
                  : (_) {
                      if (_dragOffset.abs() > 110) {
                        Navigator.of(context).pop();
                      } else {
                        setState(() => _dragOffset = 0);
                      }
                    },
              child: Transform.translate(
                offset: Offset(0, _dragOffset),
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: widget.heroTag == null
                        ? image
                        : Hero(tag: widget.heroTag!, child: image),
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close),
              color: Colors.white,
              style: IconButton.styleFrom(backgroundColor: Colors.black45),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          if (widget.caption != null && widget.caption!.isNotEmpty)
            Positioned(
              left: 20,
              right: 20,
              bottom: MediaQuery.of(context).padding.bottom + 24,
              child: Text(
                widget.caption!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

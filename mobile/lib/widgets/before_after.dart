import 'package:flutter/material.dart';

/// Drag-to-compare between the original photo and the render.
///
/// A toggle button makes you hold two frames in your head; a slider lets you
/// park the divider mid-garment and see the seam directly. It is also the
/// single most convincing thing to point a camera at when demoing.
class BeforeAfterSlider extends StatefulWidget {
  const BeforeAfterSlider({
    super.key,
    required this.before,
    required this.after,
    this.beforeLabel = 'You',
    this.afterLabel = 'Try-on',
    this.zoom = 1.0,
    this.zoomAlignment = Alignment.center,
  });

  final ImageProvider before;
  final ImageProvider after;
  final String beforeLabel;
  final String afterLabel;

  /// Applied to both images identically so the comparison stays honest.
  final double zoom;
  final Alignment zoomAlignment;

  @override
  State<BeforeAfterSlider> createState() => _BeforeAfterSliderState();
}

class _BeforeAfterSliderState extends State<BeforeAfterSlider> {
  double _fraction = 0.5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        void updateFrom(double dx) {
          setState(() => _fraction = (dx / width).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => updateFrom(details.localPosition.dx),
          onHorizontalDragUpdate: (details) => updateFrom(details.localPosition.dx),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _zoomed(Image(image: widget.after, fit: BoxFit.cover)),

              // The original is clipped to the left of the divider. Clipping
              // happens in the outer box, zooming inside it, so the divider
              // stays put while the imagery scales.
              ClipRect(
                clipper: _LeftClipper(_fraction),
                child: _zoomed(Image(image: widget.before, fit: BoxFit.cover)),
              ),

              _label(context, widget.beforeLabel, Alignment.topLeft, visible: _fraction > 0.14),
              _label(context, widget.afterLabel, Alignment.topRight, visible: _fraction < 0.86),

              Positioned(
                left: width * _fraction - 1,
                top: 0,
                bottom: 0,
                child: const _Divider(),
              ),
              Positioned(
                left: width * _fraction - 22,
                top: 0,
                bottom: 0,
                child: const Center(child: _Handle()),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _zoomed(Widget child) {
    // Always an AnimatedScale, even at 1.0 — swapping widget types on the way
    // back to full body would skip the animation.
    return AnimatedScale(
      scale: widget.zoom,
      alignment: widget.zoomAlignment,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: child,
    );
  }

  Widget _label(BuildContext context, String text, Alignment alignment, {required bool visible}) {
    return Align(
      alignment: alignment,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  const _LeftClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftClipper oldClipper) => oldClipper.fraction != fraction;
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 2,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6)],
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10)],
      ),
      child: const Icon(Icons.compare_arrows, size: 22, color: Colors.black87),
    );
  }
}

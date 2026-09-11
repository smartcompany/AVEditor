import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:flutter/material.dart';

/// Shared with the on-canvas [TextField] TapRegion so toolbar taps do not
/// count as "outside" and dismiss the keyboard.
const Object kBasicTextEditTapGroup = 'basic_text_edit';

/// Brief window after a toolbar pointer so style/color taps cannot dismiss
/// inline editing via [TapRegion.onTapOutside].
class BasicTextEditDismissGuard {
  BasicTextEditDismissGuard._();

  static DateTime? _armedUntil;

  static void arm([Duration ttl = const Duration(milliseconds: 600)]) {
    _armedUntil = DateTime.now().add(ttl);
  }

  static bool get isArmed {
    final until = _armedUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _armedUntil = null;
      return false;
    }
    return true;
  }
}

enum _TrayMode { fonts, colors }

/// Matches [minOverlayFontSize] / [maxOverlayFontSize] in video_preview.
const _toolbarMinFontSize = 24.0;
const _toolbarMaxFontSize = 240.0;

/// YouTube Shorts–style strip above the keyboard for basic text editing.
class BasicTextEditToolbar extends StatefulWidget {
  const BasicTextEditToolbar({
    super.key,
    required this.overlay,
    required this.onChanged,
  });

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onChanged;

  static const colors = <Color>[
    Colors.white,
    Colors.black,
    Color(0xFFFF4D4D),
    Color(0xFFFF8A3D),
    Color(0xFFFFD166),
    Color(0xFF06D6A0),
    Color(0xFF4CC9F0),
    Color(0xFF7B61FF),
    Color(0xFFFF5DA2),
    Color(0xFFB0B0B0),
  ];

  static const barBackground = _barBg;
  static const barHeight = 52.0;
  static const _barBg = Color(0xFF12141A);
  static const _controlsBg = Color(0xFF1A1C22);
  static const _trayBg = Color(0xFF2A2F3A);

  @override
  State<BasicTextEditToolbar> createState() => _BasicTextEditToolbarState();
}

class _BasicTextEditToolbarState extends State<BasicTextEditToolbar> {
  _TrayMode _tray = _TrayMode.colors;

  TextOverlay get _overlay => widget.overlay;

  void _emit(TextOverlay next) {
    BasicTextEditDismissGuard.arm();
    widget.onChanged(next);
  }

  void _cycleAlign() {
    final next = switch (_overlay.textAlign) {
      TextAlign.left || TextAlign.start => TextAlign.center,
      TextAlign.center => TextAlign.right,
      _ => TextAlign.left,
    };
    _emit(_overlay.copyWith(textAlign: next));
  }

  void _cycleStyle() {
    _emit(
      _overlay.copyWith(
        style: _overlay.style.next,
        templateId: null,
        packItemId: null,
      ),
    );
  }

  Future<void> _pickFont(String id) async {
    await OverlayFonts.ensureLoaded(id);
    if (!mounted) return;
    // Stay on the font tray so the user can preview other faces.
    _emit(_overlay.copyWith(fontFamily: id));
  }

  IconData get _alignIcon {
    return switch (_overlay.textAlign) {
      TextAlign.left || TextAlign.start => Icons.format_align_left,
      TextAlign.right || TextAlign.end => Icons.format_align_right,
      _ => Icons.format_align_center,
    };
  }

  /// Shorts A button: fill → stroke → box → dim box.
  Widget _buildStyleGlyph() {
    final style = _overlay.style;
    final color = _overlay.color;
    final fill = switch (style) {
      TextOverlayStyle.plain => color,
      TextOverlayStyle.outline =>
        color.computeLuminance() > 0.6 ? Colors.black : Colors.white,
      TextOverlayStyle.box =>
        color.computeLuminance() > 0.55 ? Colors.black : Colors.white,
      TextOverlayStyle.boxDim => Colors.white,
    };
    final bg = switch (style) {
      TextOverlayStyle.plain || TextOverlayStyle.outline => Colors.transparent,
      TextOverlayStyle.box => color,
      TextOverlayStyle.boxDim => color.withValues(alpha: 0.55),
    };
    final border = style == TextOverlayStyle.outline
        ? Border.all(color: color, width: 2)
        : null;

    // Match the font-select "Aa" chip footprint (18px type + chip padding).
    return Container(
      width: 36,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: border,
      ),
      child: Text(
        'A',
        style: TextStyle(
          color: fill,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          height: 1,
          shadows: style == TextOverlayStyle.plain
              ? const [Shadow(blurRadius: 4, color: Color(0x88000000))]
              : null,
        ),
      ),
    );
  }

  Widget _buildAaSample({
    required OverlayFontOption font,
    required Color color,
    double size = 18,
  }) {
    return Text(
      'Aa',
      style: font
          .apply(
            TextStyle(
              color: color,
              fontSize: size,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          )
          .copyWith(fontSize: size, height: 1),
    );
  }

  Widget _buildColorSwatch({
    required Color color,
    required bool selected,
    required VoidCallback onTap,
    double size = 28,
  }) {
    final isLight = color.computeLuminance() > 0.85;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? const Color(0xFF4CC9F0)
                : (isLight ? Colors.white38 : Colors.white24),
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  /// IconButton can steal focus / drop IME — use a plain tap target instead.
  Widget _buildToolButton({
    required Widget child,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final font = OverlayFonts.byId(_overlay.fontFamily);
    final fontsOpen = _tray == _TrayMode.fonts;
    final colorsOpen = _tray == _TrayMode.colors;

    // Size scrubber sits above the opaque color bar so it never covers it.
    // Stack empty space is transparent — preview shows through.
    return SizedBox(
      height: BasicTextEditToolbar.barHeight +
          _FontSizeVerticalScrubber.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: BasicTextEditToolbar.barHeight,
            child: TapRegion(
              groupId: kBasicTextEditTapGroup,
              child: ExcludeFocus(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => BasicTextEditDismissGuard.arm(),
                  child: Material(
                    color: BasicTextEditToolbar._barBg,
                    child: Row(
                      children: [
                        ColoredBox(
                          color: BasicTextEditToolbar._controlsBg,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: 4),
                              _ToolbarChip(
                                onTap: _cycleStyle,
                                child: _buildStyleGlyph(),
                              ),
                              _buildToolButton(
                                onTap: _cycleAlign,
                                child: Icon(
                                  _alignIcon,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                              _ToolbarChip(
                                selected: fontsOpen,
                                onTap: () =>
                                    setState(() => _tray = _TrayMode.fonts),
                                child: _buildAaSample(
                                  font: font,
                                  color: fontsOpen
                                      ? const Color(0xFF4CC9F0)
                                      : Colors.white,
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 2, right: 10),
                                child: _buildColorSwatch(
                                  color: _overlay.color,
                                  selected: colorsOpen,
                                  onTap: () => setState(
                                    () => _tray = _TrayMode.colors,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(width: 1, color: Colors.white12),
                        Expanded(
                          child: ColoredBox(
                            color: BasicTextEditToolbar._trayBg,
                            child: fontsOpen
                                ? _buildFontScroller()
                                : _buildColorScroller(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 4,
            bottom: BasicTextEditToolbar.barHeight + 4,
            child: TapRegion(
              groupId: kBasicTextEditTapGroup,
              child: ExcludeFocus(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => BasicTextEditDismissGuard.arm(),
                  child: Material(
                    color: Colors.transparent,
                    child: _FontSizeVerticalScrubber(
                      value: _overlay.fontSize,
                      onChanged: (size) =>
                          _emit(_overlay.copyWith(fontSize: size)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorScroller() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: BasicTextEditToolbar.colors.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final color = BasicTextEditToolbar.colors[index];
        final selected = color.toARGB32() == _overlay.color.toARGB32();
        return Center(
          child: _buildColorSwatch(
            color: color,
            selected: selected,
            onTap: () => _emit(_overlay.copyWith(color: color)),
          ),
        );
      },
    );
  }

  Widget _buildFontScroller() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      itemCount: OverlayFonts.all.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final option = OverlayFonts.all[index];
        final selected =
            option.id == OverlayFonts.byId(_overlay.fontFamily).id;
        return Center(
          child: _ToolbarChip(
            selected: selected,
            onTap: () => _pickFont(option.id),
            child: Text(
              option.label,
              style: option
                  .apply(
                    TextStyle(
                      color: selected
                          ? const Color(0xFF4CC9F0)
                          : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                  .copyWith(fontSize: 13),
            ),
          ),
        );
      },
    );
  }
}

class _ToolbarChip extends StatelessWidget {
  const _ToolbarChip({
    required this.child,
    required this.onTap,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFF2A2E38) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: child,
        ),
      ),
    );
  }
}

/// Volume-style vertical scrubber — top = larger type, bottom = smaller.
class _FontSizeVerticalScrubber extends StatefulWidget {
  const _FontSizeVerticalScrubber({
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  static const height = 148.0;
  static const width = 44.0;

  @override
  State<_FontSizeVerticalScrubber> createState() =>
      _FontSizeVerticalScrubberState();
}

class _FontSizeVerticalScrubberState extends State<_FontSizeVerticalScrubber> {
  static const _trackW = 4.0;
  static const _thumb = 18.0;

  double get _t {
    final span = _toolbarMaxFontSize - _toolbarMinFontSize;
    if (span <= 0) return 0;
    return ((widget.value - _toolbarMinFontSize) / span).clamp(0.0, 1.0);
  }

  void _setFromLocalDy(double dy, double height) {
    BasicTextEditDismissGuard.arm();
    final usable = (height - _thumb).clamp(1.0, double.infinity);
    final t = (1.0 - ((dy - _thumb / 2) / usable)).clamp(0.0, 1.0);
    final next = _toolbarMinFontSize +
        t * (_toolbarMaxFontSize - _toolbarMinFontSize);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final label = '${widget.value.round()}';
    return SizedBox(
      width: _FontSizeVerticalScrubber.width,
      height: _FontSizeVerticalScrubber.height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 3
                      ..color = Colors.black,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final h = constraints.maxHeight;
                  final thumbCenterY =
                      (1.0 - _t) * (h - _thumb) + _thumb / 2;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragDown: (d) =>
                        _setFromLocalDy(d.localPosition.dy, h),
                    onVerticalDragUpdate: (d) =>
                        _setFromLocalDy(d.localPosition.dy, h),
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, h),
                      painter: _FontSizeTrackPainter(
                        thumbCenterY: thumbCenterY,
                        trackWidth: _trackW,
                        thumbSize: _thumb,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  'A',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 2.5
                      ..color = Colors.black,
                  ),
                ),
                const Text(
                  'A',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FontSizeTrackPainter extends CustomPainter {
  _FontSizeTrackPainter({
    required this.thumbCenterY,
    required this.trackWidth,
    required this.thumbSize,
  });

  final double thumbCenterY;
  final double trackWidth;
  final double thumbSize;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final track = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, size.height / 2),
        width: trackWidth,
        height: size.height,
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(track, Paint()..color = const Color(0xFF3A3F4A));

    final fillTop = thumbCenterY;
    final fill = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        cx - trackWidth / 2,
        fillTop,
        cx + trackWidth / 2,
        size.height,
      ),
      const Radius.circular(2),
    );
    // Active segment from thumb down reads as "volume fill".
    canvas.drawRRect(fill, Paint()..color = const Color(0xFF4CC9F0));

    canvas.drawCircle(
      Offset(cx, thumbCenterY),
      thumbSize / 2,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _FontSizeTrackPainter oldDelegate) {
    return oldDelegate.thumbCenterY != thumbCenterY;
  }
}

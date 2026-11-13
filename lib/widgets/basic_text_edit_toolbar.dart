import 'package:aveditor/l10n/l10n_extensions.dart';
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

/// Pins [BasicTextEditToolbar] to the top of the keyboard.
///
/// The parent scaffold must keep `resizeToAvoidBottomInset` false so the
/// timeline or thumbnail strip stays put and this tray paints over the inset.
class BasicTextEditKeyboardTray extends StatelessWidget {
  const BasicTextEditKeyboardTray({
    super.key,
    required this.overlay,
    required this.onChanged,
  });

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onChanged;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQueryData.fromView(
      View.of(context),
    ).viewInsets.bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BasicTextEditToolbar(overlay: overlay, onChanged: onChanged),
        ColoredBox(
          color: BasicTextEditToolbar.barBackground,
          child: SizedBox(height: keyboard, width: double.infinity),
        ),
      ],
    );
  }
}

enum _TrayMode { size, fonts, colors }

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
  /// Size / Font / Color are tabs: exactly one is selected and it decides
  /// what the right side shows. Style and align are one-tap actions that
  /// leave the selected tab alone.
  _TrayMode _tray = _TrayMode.size;
  bool _customColorOpen = false;

  void _selectTray(_TrayMode mode) {
    BasicTextEditDismissGuard.arm();
    if (_tray == mode) return;
    setState(() {
      _tray = mode;
      _customColorOpen = false;
    });
  }

  bool get _isPaletteColor => BasicTextEditToolbar.colors.any(
    (c) => c.toARGB32() == _overlay.color.toARGB32(),
  );

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
  /// A small cycle badge on the corner says "tap to switch style".
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
    final glyph = Container(
      width: 32,
      height: 26,
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
          fontSize: 17,
          fontWeight: FontWeight.w800,
          height: 1,
          shadows: style == TextOverlayStyle.plain
              ? const [Shadow(blurRadius: 4, color: Color(0x88000000))]
              : null,
        ),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        glyph,
        Positioned(
          right: -6,
          bottom: -6,
          child: Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: BasicTextEditToolbar._controlsBg,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white54, width: 1),
            ),
            child: const Icon(Icons.sync, size: 11, color: Colors.white),
          ),
        ),
      ],
    );
  }

  /// Big T + small T: the universal "text size" mark.
  Widget _buildSizeGlyph(Color color) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'T',
            style: TextStyle(fontSize: 19, color: color),
          ),
          TextSpan(
            text: 'T',
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
      style: const TextStyle(fontWeight: FontWeight.w800, height: 1),
    );
  }

  /// Fixed serif "Aa" (the common typeface mark). It does not follow the
  /// picked font, so the tab keeps the same narrow width on small phones.
  Widget _buildFontLabel({required Color color}) {
    return Text(
      'Aa',
      maxLines: 1,
      style: TextStyle(
        fontFamily: 'serif',
        color: color,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        height: 1,
      ),
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sizeOpen = _tray == _TrayMode.size;
    final fontsOpen = _tray == _TrayMode.fonts;
    final colorsOpen = _tray == _TrayMode.colors;

    // Space above the bar is reserved for the custom color panel. Empty
    // Stack space is transparent — the preview shows through.
    return SizedBox(
      height: BasicTextEditToolbar.barHeight + _customPanelSpace,
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
                              const SizedBox(width: 2),
                              _ToolbarChip(
                                onTap: _cycleStyle,
                                child: _buildStyleGlyph(),
                              ),
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: _cycleAlign,
                                  customBorder: const CircleBorder(),
                                  child: SizedBox(
                                    width: 38,
                                    height: 44,
                                    child: Icon(
                                      _alignIcon,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                              // Actions | tabs: the divider and the pill
                              // show that only the three tabs pick what
                              // the right side shows.
                              Container(
                                width: 1,
                                height: 26,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                color: Colors.white24,
                              ),
                              Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0E1015),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _TabSegment(
                                      key: const ValueKey(
                                        'basic-text-size-tab',
                                      ),
                                      selected: sizeOpen,
                                      onTap: () => _selectTray(_TrayMode.size),
                                      child: _buildSizeGlyph(
                                        sizeOpen ? _accent : Colors.white,
                                      ),
                                    ),
                                    _TabSegment(
                                      selected: fontsOpen,
                                      onTap: () => _selectTray(_TrayMode.fonts),
                                      child: _buildFontLabel(
                                        color: fontsOpen
                                            ? _accent
                                            : Colors.white,
                                      ),
                                    ),
                                    _TabSegment(
                                      selected: colorsOpen,
                                      onTap: () =>
                                          _selectTray(_TrayMode.colors),
                                      child: IgnorePointer(
                                        child: _buildColorSwatch(
                                          color: _overlay.color,
                                          selected: colorsOpen,
                                          size: 22,
                                          onTap: () {},
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                          ),
                        ),
                        Container(width: 1, color: Colors.white12),
                        Expanded(
                          child: ColoredBox(
                            color: BasicTextEditToolbar._trayBg,
                            child: switch (_tray) {
                              _TrayMode.size => _FontSizeSlider(
                                value: _overlay.fontSize,
                                onChanged: (size) =>
                                    _emit(_overlay.copyWith(fontSize: size)),
                              ),
                              _TrayMode.fonts => _buildFontScroller(),
                              _TrayMode.colors => _buildColorScroller(),
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (colorsOpen && _customColorOpen)
            Positioned(
              left: 8,
              right: 8,
              bottom: BasicTextEditToolbar.barHeight + 6,
              child: TapRegion(
                groupId: kBasicTextEditTapGroup,
                child: ExcludeFocus(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) => BasicTextEditDismissGuard.arm(),
                    child: _CustomColorPanel(
                      color: _overlay.color,
                      doneLabel: l10n.textColorDone,
                      onChanged: (color) =>
                          _emit(_overlay.copyWith(color: color)),
                      onDone: () => setState(() => _customColorOpen = false),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static const _accent = Color(0xFF4CC9F0);
  static const _customPanelSpace = 148.0;

  Widget _buildColorScroller() {
    final palette = BasicTextEditToolbar.colors;
    // A custom pick that is not in the palette stays visible (and selected)
    // just before the picker button, so the user can see what is applied.
    final showCurrentCustom = !_isPaletteColor;
    final count = palette.length + (showCurrentCustom ? 1 : 0) + 1;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        if (index == count - 1) {
          return Center(
            child: _CustomColorButton(
              tooltip: context.l10n.textColorCustom,
              selected: _customColorOpen,
              onTap: () {
                BasicTextEditDismissGuard.arm();
                setState(() => _customColorOpen = !_customColorOpen);
              },
            ),
          );
        }
        final color = index < palette.length ? palette[index] : _overlay.color;
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
        final selected = option.id == OverlayFonts.byId(_overlay.fontFamily).id;
        return Center(
          child: _ToolbarChip(
            selected: selected,
            onTap: () => _pickFont(option.id),
            child: Text(
              option.label,
              style: option
                  .apply(
                    TextStyle(
                      color: selected ? const Color(0xFF4CC9F0) : Colors.white,
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
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          child: child,
        ),
      ),
    );
  }
}

/// One option inside the size / font / color pill. The selected option gets
/// a raised fill, like a segmented control.
class _TabSegment extends StatelessWidget {
  const _TabSegment({
    super.key,
    required this.child,
    required this.onTap,
    required this.selected,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFF2C313D) : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Center(widthFactor: 1, child: child),
          ),
        ),
      ),
    );
  }
}

/// Rainbow swatch at the end of the palette that opens the custom picker.
class _CustomColorButton extends StatelessWidget {
  const _CustomColorButton({
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const SweepGradient(
              colors: [
                Color(0xFFFF4D4D),
                Color(0xFFFFD166),
                Color(0xFF06D6A0),
                Color(0xFF4CC9F0),
                Color(0xFF7B61FF),
                Color(0xFFFF5DA2),
                Color(0xFFFF4D4D),
              ],
            ),
            border: Border.all(
              color: selected ? const Color(0xFF4CC9F0) : Colors.white24,
              width: selected ? 3 : 1,
            ),
          ),
          child: Center(
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Color(0xCC12141A),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.add, size: 13, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline HSV picker shown above the toolbar. It stays inside the toolbar's
/// tap group, so dragging it never dismisses the keyboard or inline editing.
class _CustomColorPanel extends StatefulWidget {
  const _CustomColorPanel({
    required this.color,
    required this.doneLabel,
    required this.onChanged,
    required this.onDone,
  });

  final Color color;
  final String doneLabel;
  final ValueChanged<Color> onChanged;
  final VoidCallback onDone;

  static const height = 136.0;

  @override
  State<_CustomColorPanel> createState() => _CustomColorPanelState();
}

class _CustomColorPanelState extends State<_CustomColorPanel> {
  late HSVColor _hsv = HSVColor.fromColor(widget.color);

  @override
  void didUpdateWidget(covariant _CustomColorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Palette taps while the panel is open should move the picker too, but
    // our own emits must not snap hue back (grey/black lose their hue).
    if (widget.color.toARGB32() != _hsv.toColor().toARGB32()) {
      _hsv = HSVColor.fromColor(widget.color);
    }
  }

  void _update(HSVColor next) {
    BasicTextEditDismissGuard.arm();
    setState(() => _hsv = next);
    widget.onChanged(next.toColor());
  }

  void _pickSv(Offset local, Size size) {
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = (1 - local.dy / size.height).clamp(0.0, 1.0);
    _update(_hsv.withSaturation(s).withValue(v));
  }

  void _pickHue(double dx, double width) {
    final h = (dx / width).clamp(0.0, 1.0) * 360;
    var next = _hsv.withHue(h == 360 ? 0 : h);
    // From white/black/grey a hue change alone is invisible — jump to a
    // vivid tone so the bar always does something.
    if (next.saturation < 0.05) {
      next = next
          .withSaturation(1)
          .withValue(next.value < 0.8 ? 0.9 : next.value);
    }
    _update(next);
  }

  String get _hex {
    final argb = _hsv.toColor().toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final hueColor = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    return Material(
      color: const Color(0xF21A1C22),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: _CustomColorPanel.height,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, c) {
                          final size = Size(c.maxWidth, c.maxHeight);
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanDown: (d) => _pickSv(d.localPosition, size),
                            onPanUpdate: (d) => _pickSv(d.localPosition, size),
                            child: CustomPaint(
                              size: size,
                              painter: _SvPainter(
                                hueColor: hueColor,
                                hsv: _hsv,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 18,
                      child: LayoutBuilder(
                        builder: (context, c) {
                          final w = c.maxWidth;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragDown: (d) =>
                                _pickHue(d.localPosition.dx, w),
                            onHorizontalDragUpdate: (d) =>
                                _pickHue(d.localPosition.dx, w),
                            child: CustomPaint(
                              size: Size(w, 18),
                              painter: _HuePainter(hue: _hsv.hue),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 60,
                child: Column(
                  children: [
                    Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: _hsv.toColor(),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _hex,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      height: 30,
                      child: Material(
                        color: const Color(0xFF4CC9F0),
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: widget.onDone,
                          child: Center(
                            child: Text(
                              widget.doneLabel,
                              style: const TextStyle(
                                color: Color(0xFF0B0D12),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SvPainter extends CustomPainter {
  _SvPainter({required this.hueColor, required this.hsv});

  final Color hueColor;
  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    canvas.restore();
    final p = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      p,
      8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    canvas.drawCircle(
      p,
      9.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black45,
    );
  }

  @override
  bool shouldRepaint(covariant _SvPainter old) =>
      old.hueColor != hueColor || old.hsv != hsv;
}

class _HuePainter extends CustomPainter {
  _HuePainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(size.height / 2)),
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var i = 0; i <= 6; i++)
              HSVColor.fromAHSV(1, (i * 60) % 360, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    final x = (hue / 360) * size.width;
    final c = Offset(
      x.clamp(size.height / 2, size.width - size.height / 2),
      size.height / 2,
    );
    canvas.drawCircle(c, size.height / 2 + 1, Paint()..color = Colors.white);
    canvas.drawCircle(
      c,
      size.height / 2 - 2,
      Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
    );
  }

  @override
  bool shouldRepaint(covariant _HuePainter old) => old.hue != hue;
}

/// Horizontal size bar for the Size tab. Left = smaller, right = larger.
/// The number only appears in a bubble above the thumb while dragging, so
/// the track can use the full width.
class _FontSizeSlider extends StatefulWidget {
  const _FontSizeSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_FontSizeSlider> createState() => _FontSizeSliderState();
}

class _FontSizeSliderState extends State<_FontSizeSlider> {
  static const _thumb = 18.0;
  static const _bubbleW = 44.0;
  bool _dragging = false;

  double get _t {
    const span = _toolbarMaxFontSize - _toolbarMinFontSize;
    return ((widget.value - _toolbarMinFontSize) / span).clamp(0.0, 1.0);
  }

  void _setFromDx(double dx, double width) {
    BasicTextEditDismissGuard.arm();
    final usable = (width - _thumb).clamp(1.0, double.infinity);
    final t = ((dx - _thumb / 2) / usable).clamp(0.0, 1.0);
    widget.onChanged(
      _toolbarMinFontSize + t * (_toolbarMaxFontSize - _toolbarMinFontSize),
    );
  }

  void _setDragging(bool value) {
    if (_dragging != value) setState(() => _dragging = value);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                final thumbX = _thumb / 2 + _t * (w - _thumb);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragDown: (d) {
                    _setDragging(true);
                    _setFromDx(d.localPosition.dx, w);
                  },
                  onHorizontalDragUpdate: (d) =>
                      _setFromDx(d.localPosition.dx, w),
                  onHorizontalDragEnd: (_) => _setDragging(false),
                  onHorizontalDragCancel: () => _setDragging(false),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CustomPaint(
                        size: Size(w, BasicTextEditToolbar.barHeight),
                        painter: _FontSizeTrackPainter(
                          thumbCenterX: thumbX,
                          thumbSize: _thumb,
                        ),
                      ),
                      if (_dragging)
                        Positioned(
                          left: thumbX - _bubbleW / 2,
                          bottom: BasicTextEditToolbar.barHeight / 2 + 16,
                          child: IgnorePointer(
                            child: _SizeBubble(
                              width: _bubbleW,
                              label: '${widget.value.round()}',
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SizeBubble extends StatelessWidget {
  const _SizeBubble({required this.width, required this.label});

  final double width;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Color(0x66000000))],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF12141A),
          fontSize: 13,
          fontWeight: FontWeight.w800,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _FontSizeTrackPainter extends CustomPainter {
  _FontSizeTrackPainter({required this.thumbCenterX, required this.thumbSize});

  final double thumbCenterX;
  final double thumbSize;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const trackH = 4.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - trackH / 2, size.width, trackH),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFF3A3F4A),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - trackH / 2, thumbCenterX, trackH),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFF4CC9F0),
    );
    canvas.drawCircle(
      Offset(thumbCenterX, cy),
      thumbSize / 2,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _FontSizeTrackPainter old) =>
      old.thumbCenterX != thumbCenterX;
}

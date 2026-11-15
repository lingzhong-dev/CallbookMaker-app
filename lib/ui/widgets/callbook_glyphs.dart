import 'package:prism_ui/icons/icons.dart' as prism;

/// FlClash / Prism UI geometric vector glyphs (24x24 grid) for Live Call Studio.
abstract final class CallbookGlyphs {
  static const dashboard = prism.Glyph([
    prism.GlyphBox(3.5, 3.5, 10.5, 11.5, 2),
    prism.GlyphBox(13.5, 3.5, 20.5, 9.5, 2),
    prism.GlyphBox(3.5, 14.5, 10.5, 20.5, 2),
    prism.GlyphBox(13.5, 12.5, 20.5, 20.5, 2),
  ]);

  static const studio = prism.Glyph([
    prism.GlyphBox(3.5, 4.0, 20.5, 20.0, 3.0),
    prism.GlyphPolyline([
      prism.GlyphVertex(7.5, 9.0),
      prism.GlyphVertex(16.5, 9.0),
    ], role: prism.GlyphRole.detail),
    prism.GlyphPolyline([
      prism.GlyphVertex(7.5, 12.5),
      prism.GlyphVertex(14.5, 12.5),
    ], role: prism.GlyphRole.detail),
    prism.GlyphCircle(15.5, 16.0, 1.5, role: prism.GlyphRole.detail, solid: true),
  ]);

  static const exportCard = prism.Glyph([
    prism.GlyphPolyline([
      prism.GlyphVertex(5, 3, 2.5),
      prism.GlyphVertex(13.5, 3, 1),
      prism.GlyphVertex(19, 8.5, 1),
      prism.GlyphVertex(19, 21, 2.5),
      prism.GlyphVertex(5, 21, 2.5),
    ], closed: true),
    prism.GlyphPolyline([
      prism.GlyphVertex(13.5, 3.2),
      prism.GlyphVertex(13.5, 8.5, 1.5),
      prism.GlyphVertex(18.8, 8.5),
    ], role: prism.GlyphRole.detail),
    prism.GlyphPolyline([
      prism.GlyphVertex(8.5, 14.5),
      prism.GlyphVertex(15.5, 14.5),
    ], role: prism.GlyphRole.detail),
  ]);

  static const theme = prism.Glyph([
    prism.GlyphCircle(12, 12, 8.8),
    prism.GlyphCircle(9.0, 9.5, 1.3, role: prism.GlyphRole.detail, solid: true),
    prism.GlyphCircle(14.8, 9.5, 1.3, role: prism.GlyphRole.detail, solid: true),
    prism.GlyphCircle(8.5, 14.2, 1.3, role: prism.GlyphRole.detail, solid: true),
    prism.GlyphCircle(14.8, 14.5, 1.8, role: prism.GlyphRole.detail, solid: true),
  ]);

  static const play = prism.Glyph([
    prism.GlyphPath(
      'M8.2 6.2C8.2 5.4 9.1 4.9 9.8 5.3L18.4 11.1C19.0 11.5 19.0 12.5 18.4 12.9'
      'L9.8 18.7C9.1 19.1 8.2 18.6 8.2 17.8Z',
    ),
  ]);

  static const stop = prism.Glyph([
    prism.GlyphBox(6.8, 6.8, 17.2, 17.2, 2.6),
  ]);

  static const musicNote = prism.Glyph([
    prism.GlyphCircle(8.2, 17.5, 2.6),
    prism.GlyphCircle(16.6, 15.8, 2.6),
    prism.GlyphPolyline([
      prism.GlyphVertex(10.8, 17.5),
      prism.GlyphVertex(10.8, 6.2, 1.2),
      prism.GlyphVertex(19.2, 4.6, 1.2),
      prism.GlyphVertex(19.2, 15.8),
    ], role: prism.GlyphRole.line),
  ]);

  static const fullscreen = prism.Glyph([
    prism.GlyphPolyline([
      prism.GlyphVertex(4, 9),
      prism.GlyphVertex(4, 4, 1.5),
      prism.GlyphVertex(9, 4),
    ], role: prism.GlyphRole.line),
    prism.GlyphPolyline([
      prism.GlyphVertex(15, 4),
      prism.GlyphVertex(20, 4, 1.5),
      prism.GlyphVertex(20, 9),
    ], role: prism.GlyphRole.line),
    prism.GlyphPolyline([
      prism.GlyphVertex(20, 15),
      prism.GlyphVertex(20, 20, 1.5),
      prism.GlyphVertex(15, 20),
    ], role: prism.GlyphRole.line),
    prism.GlyphPolyline([
      prism.GlyphVertex(9, 20),
      prism.GlyphVertex(4, 20, 1.5),
      prism.GlyphVertex(4, 15),
    ], role: prism.GlyphRole.line),
  ]);

  static const trash = prism.Glyph([
    prism.GlyphPolyline([
      prism.GlyphVertex(5, 7),
      prism.GlyphVertex(19, 7),
    ], role: prism.GlyphRole.line),
    prism.GlyphPolyline([
      prism.GlyphVertex(9.5, 4.5),
      prism.GlyphVertex(14.5, 4.5),
    ], role: prism.GlyphRole.line),
    prism.GlyphBox(6.8, 7.2, 17.2, 19.8, 2.0),
    prism.GlyphPolyline([
      prism.GlyphVertex(10, 10.5),
      prism.GlyphVertex(10, 16.5),
    ], role: prism.GlyphRole.detail),
    prism.GlyphPolyline([
      prism.GlyphVertex(14, 10.5),
      prism.GlyphVertex(14, 16.5),
    ], role: prism.GlyphRole.detail),
  ]);

  static const archive = prism.Glyph([
    prism.GlyphBox(3.5, 4.5, 20.5, 8.8, 2.0),
    prism.GlyphBox(4.8, 8.8, 19.2, 19.8, 2.2),
    prism.GlyphPolyline([
      prism.GlyphVertex(9.5, 13.0),
      prism.GlyphVertex(14.5, 13.0),
    ], role: prism.GlyphRole.detail),
  ]);
}

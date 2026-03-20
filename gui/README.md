# Zicro GUI (Mach Engine)

GPU-accelerated GUI frontend for Zicro using Mach Engine.

## Architecture

Based on research of modern editors (Zed, Lapce):
- **GPU Acceleration**: wgpu via Mach (same as Lapce)
- **Font Atlas Caching**: Rasterized glyphs in GPU texture (like Zed)
- **Viewport Culling**: Only render visible lines
- **Batch Rendering**: All glyphs in one draw call
- **Incremental Highlighting**: Update only changed regions

## Structure

```
gui/
├── main.zig              # Entry point
├── text_renderer/        # GPU-accelerated text rendering
│   ├── font.zig          # Font loading (FreeType/HarfBuzz)
│   ├── font_atlas.zig    # GPU texture atlas for glyphs
│   ├── glyph_cache.zig   # Glyph rasterization cache
│   ├── text_layout.zig   # Line layout, viewport culling
│   ├── batch_renderer.zig # Batch rendering
│   └── cursor.zig        # Cursor & selection rendering
├── editor_widget.zig     # Main editor widget
├── input.zig             # Keyboard/mouse handling
├── ui/                   # Sidebar, statusbar, palette
└── platform/             # Clipboard, file dialogs
```

## Development Status

**Current Phase**: Setup (Week 1-2)
- [ ] Integrate Mach Engine
- [ ] Create basic window
- [ ] Test on macOS/Linux/Windows

**Next Phase**: Text Rendering (Week 3-6)
- [ ] Font loading
- [ ] Font atlas caching
- [ ] Viewport culling
- [ ] Performance validation (60 FPS with 10k lines)

See `/Users/rafkat/.claude/plans/snug-frolicking-crescent.md` for full plan.

# Text Renderer

GPU-accelerated text rendering engine inspired by Zed and Lapce.

## Key Techniques

### Font Atlas Caching (like Zed)
- Rasterize glyphs once, store in GPU texture
- Reuse cached glyphs across frames
- Reduces CPU→GPU transfers

### Batch Rendering
- Collect all visible glyphs
- Submit in single draw call
- Minimize GPU state changes

### Viewport Culling
- Only render visible lines
- Calculate visible range from scroll position
- Skip offscreen content entirely

## Performance Targets

- 60 FPS with 10k+ line files
- <100MB memory usage
- Sub-16ms frame time

## Implementation Plan

1. **font.zig**: Load TTF fonts via FreeType/HarfBuzz
2. **font_atlas.zig**: Pack glyphs into GPU texture atlas
3. **glyph_cache.zig**: Cache rasterized glyphs
4. **text_layout.zig**: Calculate line positions, handle tabs/UTF-8
5. **batch_renderer.zig**: Batch glyph quads for GPU
6. **cursor.zig**: Render cursor and selection highlights

module matn.editor.minimap;

import std.algorithm : min, max, clamp;
import std.conv : to;

import matn.platform.sdl;
import matn.platform.font : FontEngine;
import matn.ui.grid.cell : Color, CellStyle, CellAttr;
import matn.ui.grid.grid : GlyphGrid;
import matn.ui.grid.renderer : drawRealBox, drawRealLine, drawRealRect;
import matn.extension.base;
import matn.editor.syntax : SyntaxHighlightingExtension, SyntaxTheme, DSyntaxExtension;

/// A single rendered code band in the minimap overview
struct MinimapBand
{
    float dx;
    float w;
    int dyRow;
    Color color;
}

/// Context passed to minimap during cell-grid rendering pass
struct MinimapContext
{
    int startCol;
    int width;
    int startRow;
    int endRow;
    Color bg;
    Color border;
    Color text;
    Color accent;
}

/// Minimap Extension: High-resolution bird's-eye code overview map with interactive viewport navigation
class MinimapExtension : Extension, VisualExtension
{
    bool visible = true;
    override @property bool isVisible() const { return isActive && visible; }
    int width = 14;              // Width in character columns
    float pixelsPerLine = 2.0f;  // Height per line in vector space
    float miniCharWidth = 1.1f;  // Logical width per character in band space (matches GUI Matn)

    private bool _isHovered = false;
    private bool _isDragging = false;

    private float _lastPanelX = 0.0f;
    private float _lastPanelY = 0.0f;
    private float _lastPanelW = 0.0f;
    private float _lastPanelH = 0.0f;

    private int _cachedWindowStart = 0;
    private int _cachedWindowSize = 1;
    private int _cachedTotalLines = 1;
    private string _cachedFilePath = "";
    private size_t _cachedLineCount = 0;
    private int _cachedScrollRow = -1;
    private float _cachedHeight = -1.0f;
    private bool _cachedIsLight = false;
    private MinimapBand[] _cachedBands;

    this()
    {
        super(ExtensionManifest(
            "matn.minimap",
            "Minimap",
            "1.0.0",
            "Matn Core",
            "High-resolution bird's-eye code overview map with viewport navigation and dragging",
            true
        ));
        this._enabled = true;
    }

    override protected void onActivate()
    {
        if (_context)
        {
            _context.registerSetting("EDITOR", "Minimap", "High-resolution bird's-eye code overview map on the right", {
                toggle();
            });
            _context.registerSetting("EDITOR", "Minimap Width", "Width of the minimap overview panel", {
                width = (width >= 20) ? 10 : width + 2;
            });

            _context.registerCommand(ExtensionCommand(
                "minimap.toggle", "Toggle Minimap", "View", "Ctrl+M",
                { toggle(); }
            ));
        }
    }

    void toggle()
    {
        visible = !visible;
    }

    void invalidateCache()
    {
        _cachedLineCount = 0;
        _cachedFilePath = "";
        _cachedHeight = -1.0f;
        _cachedScrollRow = -1;
    }

    @property bool isHovered() const { return _isHovered; }
    @property bool isDragging() const { return _isDragging; }
    @property float lastPanelX() const { return _lastPanelX; }
    @property float lastPanelY() const { return _lastPanelY; }
    @property float lastPanelW() const { return _lastPanelW; }
    @property float lastPanelH() const { return _lastPanelH; }
    @property int cachedWindowStart() const { return _cachedWindowStart; }
    @property int cachedWindowSize() const { return _cachedWindowSize; }
    @property const(MinimapBand)[] cachedBands() const { return _cachedBands; }

    /// Rebuilds cached bands with real syntax highlighting (just like GUI Matn)
    void rebuildBands(
        const(dchar[][]) lines,
        float panelH,
        int centerLine,
        string filePath,
        SyntaxHighlightingExtension syntaxExt,
        SyntaxTheme synTheme,
        Color defaultTextColor,
        bool isLight = false,
        int tabWidth = 4
    )
    {
        _cachedBands = [];
        _cachedTotalLines = max(1, cast(int) lines.length);

        if (panelH <= 0 || pixelsPerLine <= 0)
        {
            _cachedWindowSize = 1;
            _cachedWindowStart = 0;
            return;
        }

        int tw = max(1, tabWidth);
        _cachedWindowSize = clamp(cast(int)(panelH / pixelsPerLine), 1, _cachedTotalLines);
        _cachedWindowStart = clamp(centerLine - _cachedWindowSize / 2, 0, max(0, _cachedTotalLines - _cachedWindowSize));

        bool hasSyntax = (syntaxExt !is null && syntaxExt.isEnabled && syntaxExt.detectLanguage(filePath) !is null);
        Color plainBandColor = isLight ? Color(60, 65, 80, 160) : Color(synTheme.defaultColor.r, synTheme.defaultColor.g, synTheme.defaultColor.b, 75);

        Color[] lineColors;

        foreach (r; 0 .. _cachedWindowSize)
        {
            int li = _cachedWindowStart + r;
            if (li >= lines.length)
                break;

            auto line = lines[li];
            if (line.length == 0)
                continue; // Blank line: leaves natural visual gap between code blocks

            // Calculate indentation and non-whitespace extent with accurate tab stops
            int indentChars = 0;
            int totalChars = 0;
            bool inIndent = true;
            foreach (dchar ch; line)
            {
                int adv = (ch == '\t') ? (tw - (totalChars % tw)) : 1;
                if (inIndent && (ch == ' ' || ch == '\t'))
                    indentChars += adv;
                else
                    inIndent = false;
                totalChars += adv;
            }

            if (totalChars <= indentChars && inIndent)
                continue; // Whitespace-only line: leaves visible gap

            if (!hasSyntax)
            {
                // Plain-text file (or language without AST parser): single clean silhouette band
                float bx = indentChars * miniCharWidth;
                float bw = max(miniCharWidth, (totalChars - indentChars) * miniCharWidth);
                _cachedBands ~= MinimapBand(bx, bw, r, plainBandColor);
                continue;
            }

            // Real syntax-highlighted code minimap!
            syntaxExt.highlightLine(filePath, li, line, synTheme, lineColors);

            size_t charIdx = 0;
            int vCol = 0;

            while (charIdx < line.length)
            {
                dchar ch = line[charIdx];
                int adv = (ch == '\t') ? (tw - (vCol % tw)) : 1;
                Color curCol = (charIdx < lineColors.length) ? lineColors[charIdx] : synTheme.defaultColor;

                // Skip plain whitespace between code tokens
                if ((ch == ' ' || ch == '\t') && curCol == synTheme.defaultColor)
                {
                    vCol += adv;
                    charIdx++;
                    continue;
                }

                int spanStartVCol = vCol;
                bool isStringOrComment = (curCol == synTheme.stringColor || curCol == synTheme.commentColor);

                while (charIdx < line.length)
                {
                    dchar cCh = line[charIdx];
                    Color cCol = (charIdx < lineColors.length) ? lineColors[charIdx] : synTheme.defaultColor;

                    if (cCol != curCol)
                        break;

                    if (!isStringOrComment && (cCh == ' ' || cCh == '\t'))
                        break;

                    int cAdv = (cCh == '\t') ? (tw - (vCol % tw)) : 1;
                    vCol += cAdv;
                    charIdx++;
                }

                int spanEndVCol = vCol;
                if (spanEndVCol <= spanStartVCol)
                {
                    vCol += adv;
                    charIdx++;
                    continue;
                }

                // In light mode keep opacity crisp so dark text doesn't bleach into white
                Color col = curCol;
                if (col == synTheme.defaultColor)
                {
                    col = plainBandColor;
                }
                else
                {
                    ubyte targetAlpha = isLight ? cast(ubyte)(col.a * 190 / 255) : cast(ubyte)(col.a * 130 / 255);
                    col.a = targetAlpha;
                }

                float bx = spanStartVCol * miniCharWidth;
                float bw = max(miniCharWidth, (spanEndVCol - spanStartVCol) * miniCharWidth);
                _cachedBands ~= MinimapBand(bx, bw, r, col);
            }
        }
    }

    /// Overload for backwards compatibility and tests
    void rebuildBands(const(dchar[][]) lines, float panelH, int centerLine,
                      Color defaultTextColor, bool isLight = false)
    {
        auto synTheme = SyntaxTheme.fromTheme(defaultTextColor, defaultTextColor, defaultTextColor, isLight);
        rebuildBands(lines, panelH, centerLine, "", null, synTheme, defaultTextColor, isLight);
    }

    /// Render cell-grid background and vertical border (Pass 1 & 2)
    void render(GlyphGrid grid, MinimapContext ctx)
    {
        if (!_enabled || !visible || ctx.width <= 0 || grid is null)
            return;

        int startCol = ctx.startCol;
        int maxCol = min(grid.cols, startCol + ctx.width);

        foreach (r; ctx.startRow .. ctx.endRow)
        {
            if (r < 0 || r >= grid.rows) continue;

            // Subtle background fill
            grid.fillRect(startCol, r, maxCol - startCol, 1, ' ', CellStyle(ctx.text, ctx.bg));

            // Left vertical divider (clean cell color bar, no ASCII box characters)
            grid.putCell(startCol, r, ' ', CellStyle(ctx.border, ctx.border));
        }
    }

    /// Render real SDL vector bands and viewport rectangle (Pass 3)
    void renderReal(
        SDL_Renderer* renderer,
        FontEngine font,
        float padX,
        float padY,
        int minimapCol,
        int minimapW,
        int startRow,
        int endRow,
        const(dchar[][]) lines,
        int scrollRow,
        int scrollCol,
        int editCols,
        int tabWidth,
        string filePath,
        SyntaxHighlightingExtension syntaxExt,
        SyntaxTheme synTheme,
        Color accentColor,
        Color textColor,
        Color panelBg,
        Color selectionColor,
        bool isLight,
        bool isHandleActive = false
    )
    {
        if (!_enabled || !visible || renderer is null || font is null || minimapW <= 0 || endRow <= startRow)
            return;

        _lastPanelX = padX + minimapCol * font.charWidth;
        _lastPanelY = padY + startRow * font.lineHeight;
        _lastPanelW = minimapW * font.charWidth;
        _lastPanelH = max(1.0f, (endRow - startRow) * font.lineHeight);

        int totalDocLines = max(1, cast(int) lines.length);
        int visibleRows = max(1, endRow - startRow);
        int centerLine = scrollRow + visibleRows / 2;

        bool scrolled = (scrollRow != _cachedScrollRow);
        bool needsRebuild = (filePath != _cachedFilePath) || (lines.length != _cachedLineCount) ||
            (_lastPanelH != _cachedHeight) || (_cachedIsLight != isLight) ||
            (scrolled && _cachedWindowSize < _cachedTotalLines);

        if (needsRebuild)
        {
            rebuildBands(lines, _lastPanelH, centerLine, filePath, syntaxExt, synTheme, textColor, isLight, tabWidth);
            _cachedLineCount = lines.length;
            _cachedHeight = _lastPanelH;
            _cachedScrollRow = scrollRow;
            _cachedFilePath = filePath;
            _cachedIsLight = isLight;
        }

        // 1. Draw smooth panel background
        if (panelBg.a > 0)
        {
            drawRealBox(renderer, _lastPanelX, _lastPanelY, _lastPanelW, _lastPanelH, Color(0, 0, 0, 0), panelBg);
        }

        // 2. Draw vertical separator (highlighted accent bar when resizing or hovered)
        if (isHandleActive)
        {
            SDL_SetRenderDrawColor(renderer, accentColor.r, accentColor.g, accentColor.b, 220);
            SDL_FRect handleRect = SDL_FRect(_lastPanelX - 1.0f, _lastPanelY, 2.0f, _lastPanelH);
            SDL_RenderFillRect(renderer, &handleRect);
        }
        else
        {
            Color sepCol = isLight ? Color(0, 0, 0, 30) : Color(255, 255, 255, 22);
            drawRealLine(renderer, _lastPanelX, _lastPanelY, _lastPanelX, _lastPanelY + _lastPanelH, sepCol);
        }

        // 3. Draw syntax-highlighted code silhouette bands (dimmed softly like GUI Matn)
        foreach (ref band; _cachedBands)
        {
            float bx = _lastPanelX + 3.0f + band.dx;
            if (bx >= _lastPanelX + _lastPanelW - 2.0f) continue;
            float bw = min(band.w, (_lastPanelX + _lastPanelW - 2.0f) - bx);
            float by = _lastPanelY + band.dyRow * pixelsPerLine;
            if (by + pixelsPerLine > _lastPanelY + _lastPanelH) continue;
            drawRealBox(renderer, bx, by, bw, max(1.0f, pixelsPerLine - 0.3f), Color(0, 0, 0, 0), band.color);
        }

        // 4. Draw soft, translucent Viewport Slider ("You are here" indicator)
        float vy = _lastPanelY + clamp((scrollRow - _cachedWindowStart) * pixelsPerLine, 0.0f, _lastPanelH);
        float vh = clamp(visibleRows * pixelsPerLine, 6.0f, _lastPanelH - (vy - _lastPanelY));

        // Precise horizontal viewport highlight matching the editor's visible columns
        float contentStartX = _lastPanelX + 3.0f;
        float maxContentX = _lastPanelX + _lastPanelW - 2.0f;
        float vx = contentStartX + scrollCol * miniCharWidth;
        float vw = editCols * miniCharWidth;

        // If at leftmost column (scrollCol == 0), anchor to panel left edge
        if (scrollCol <= 0)
        {
            vx = _lastPanelX;
            vw = min(_lastPanelW, max(24.0f, 3.0f + editCols * miniCharWidth));
        }
        else
        {
            // Scrolled horizontally: accurately frame the visible window
            if (vx > maxContentX - 8.0f)
            {
                vx = maxContentX - 8.0f;
                vw = 8.0f;
            }
            else
            {
                if (vx + vw > maxContentX)
                    vw = maxContentX - vx;
                if (vw < 12.0f)
                    vw = 12.0f;
            }
        }

        ubyte sliderAlpha = _isDragging ? 120 : (_isHovered ? 95 : 75);
        Color sliderBg = Color(selectionColor.r, selectionColor.g, selectionColor.b, sliderAlpha);

        drawRealBox(renderer, vx, vy, vw, vh, Color(0, 0, 0, 0), sliderBg);
    }

    /// Overload for backwards compatibility and callers without horizontal coordinates
    void renderReal(
        SDL_Renderer* renderer,
        FontEngine font,
        float padX,
        float padY,
        int minimapCol,
        int minimapW,
        int startRow,
        int endRow,
        const(dchar[][]) lines,
        int scrollRow,
        string filePath,
        SyntaxHighlightingExtension syntaxExt,
        SyntaxTheme synTheme,
        Color accentColor,
        Color textColor,
        Color panelBg,
        Color selectionColor,
        bool isLight,
        bool isHandleActive = false
    )
    {
        renderReal(renderer, font, padX, padY, minimapCol, minimapW, startRow, endRow,
                   lines, scrollRow, 0, 80, 4, filePath, syntaxExt, synTheme,
                   accentColor, textColor, panelBg, selectionColor, isLight, isHandleActive);
    }

    /// Check if mouse coordinates fall inside minimap bounds
    bool isOverMinimap(float mouseX, float mouseY) const
    {
        if (!_enabled || !visible || _lastPanelH <= 0) return false;
        return (mouseX >= _lastPanelX && mouseX <= _lastPanelX + _lastPanelW &&
                mouseY >= _lastPanelY && mouseY <= _lastPanelY + _lastPanelH);
    }

    /// Handle mouse button down event on minimap. Centers viewport at clicked line and column.
    bool handleMouseDown(float mouseX, float mouseY, int totalDocLines, int visibleRows, out int newScrollRow)
    {
        int dummyCol;
        return handleMouseDown(mouseX, mouseY, totalDocLines, visibleRows, newScrollRow, 80, dummyCol);
    }

    /// Handle mouse button down event on minimap with horizontal centering.
    bool handleMouseDown(float mouseX, float mouseY, int totalDocLines, int visibleRows, out int newScrollRow, int editCols, out int newScrollCol)
    {
        newScrollCol = -1;
        if (!isOverMinimap(mouseX, mouseY))
        {
            newScrollRow = -1;
            return false;
        }

        _isDragging = true;
        int windowSize = max(1, _cachedWindowSize);
        float clampedY = clamp(mouseY, _lastPanelY, _lastPanelY + _lastPanelH);
        int clickedLine = _cachedWindowStart + clamp(cast(int)((clampedY - _lastPanelY) / pixelsPerLine), 0, windowSize - 1);
        newScrollRow = clamp(clickedLine - visibleRows / 2, 0, max(0, totalDocLines - visibleRows));

        float relX = mouseX - (_lastPanelX + 3.0f);
        if (relX > 0 && miniCharWidth > 0)
        {
            int clickedCol = cast(int)(relX / miniCharWidth);
            newScrollCol = max(0, clickedCol - editCols / 2);
        }
        return true;
    }

    /// Handle mouse motion event on minimap. Updates drag scroll position or hover state.
    bool handleMouseMotion(float mouseX, float mouseY, int totalDocLines, int visibleRows, out int newScrollRow)
    {
        int dummyCol;
        return handleMouseMotion(mouseX, mouseY, totalDocLines, visibleRows, newScrollRow, 80, dummyCol);
    }

    /// Handle mouse motion event on minimap with horizontal centering.
    bool handleMouseMotion(float mouseX, float mouseY, int totalDocLines, int visibleRows, out int newScrollRow, int editCols, out int newScrollCol)
    {
        _isHovered = isOverMinimap(mouseX, mouseY);
        newScrollCol = -1;

        if (_isDragging)
        {
            int windowSize = max(1, _cachedWindowSize);
            float clampedY = clamp(mouseY, _lastPanelY, _lastPanelY + _lastPanelH);
            int clickedLine = _cachedWindowStart + clamp(cast(int)((clampedY - _lastPanelY) / pixelsPerLine), 0, windowSize - 1);
            newScrollRow = clamp(clickedLine - visibleRows / 2, 0, max(0, totalDocLines - visibleRows));

            float relX = mouseX - (_lastPanelX + 3.0f);
            if (relX > 0 && miniCharWidth > 0)
            {
                int clickedCol = cast(int)(relX / miniCharWidth);
                newScrollCol = max(0, clickedCol - editCols / 2);
            }
            return true;
        }

        newScrollRow = -1;
        return false;
    }

    /// Handle mouse button release
    bool handleMouseUp()
    {
        bool wasDragging = _isDragging;
        _isDragging = false;
        return wasDragging;
    }

    /// Handle mouse wheel scroll over minimap
    bool handleMouseWheel(int wheelY, int totalDocLines, int visibleRows, int currentScrollRow, out int newScrollRow)
    {
        newScrollRow = clamp(currentScrollRow - wheelY * 3, 0, max(0, totalDocLines - visibleRows));
        return true;
    }
}

unittest
{
    auto minimap = new MinimapExtension();
    assert(minimap.id == "matn.minimap");
    assert(minimap.visible);
    assert(minimap.isEnabled);

    // Test band rebuilding without syntax (plain fallback)
    dchar[][] sampleLines = [
        "void main()"d.dup,
        "{"d.dup,
        "    int a = 1;"d.dup,
        ""d.dup,
        "    return 0;"d.dup,
        "}"d.dup
    ];

    minimap.rebuildBands(sampleLines, 200.0f, 0, Color(200, 200, 200, 255));
    assert(minimap.cachedBands.length == 5); // 6 lines with 1 blank line skipped = 5 bands!

    // Verify first band (void main())
    assert(minimap.cachedBands[0].dyRow == 0);
    assert(minimap.cachedBands[0].w > 0);

    // Verify blank line (line 3) is skipped
    foreach (ref b; minimap.cachedBands)
    {
        assert(b.dyRow != 3); // blank line was omitted
    }

    // Test real syntax-highlighted minimap
    auto synMgr = new SyntaxHighlightingExtension();
    synMgr.registerLanguage(new DSyntaxExtension());
    auto synTheme = SyntaxTheme.fromTheme(Color.white, Color(80, 140, 240), Color(128, 128, 128));
    synMgr.analyzeBuffer("sample.d", sampleLines, synTheme);

    minimap.rebuildBands(sampleLines, 200.0f, 0, "sample.d", synMgr, synTheme, Color.white);
    // Real syntax highlighting yields individual token bands per line (e.g. 'int', 'a', '=', '1', ';')
    assert(minimap.cachedBands.length > 5);

    // Verify that token colors are properly dimmed to ~51% (alpha 130)
    bool hasDimmedToken = false;
    foreach (ref b; minimap.cachedBands)
    {
        if (b.color.a == cast(ubyte)(255 * 130 / 255))
            hasDimmedToken = true;
    }
    assert(hasDimmedToken, "Minimap bands should contain syntax token colors dimmed to 130 alpha");

    minimap.invalidateCache();
    assert(minimap.cachedWindowStart == 0);

    // Hit testing and dragging simulation
    minimap._lastPanelX = 600.0f;
    minimap._lastPanelY = 20.0f;
    minimap._lastPanelW = 100.0f;
    minimap._lastPanelH = 300.0f;

    assert(minimap.isOverMinimap(650.0f, 150.0f));
    assert(!minimap.isOverMinimap(100.0f, 150.0f));

    int targetScroll = -1;
    int targetScrollCol = -1;
    bool downHandled = minimap.handleMouseDown(650.0f, 80.0f, 100, 20, targetScroll, 40, targetScrollCol);
    assert(downHandled);
    assert(minimap.isDragging);
    assert(targetScroll >= 0);
    assert(targetScrollCol >= 0);

    bool motionHandled = minimap.handleMouseMotion(660.0f, 120.0f, 100, 20, targetScroll, 40, targetScrollCol);
    assert(motionHandled);
    assert(targetScroll >= 0);
    assert(targetScrollCol >= 0);

    // Test light theme band rebuilding
    auto lightSynTheme = SyntaxTheme.fromTheme(Color(30, 30, 30, 255), Color(0, 100, 200, 255), Color(120, 120, 120, 255), true);
    minimap.rebuildBands(sampleLines, 200.0f, 0, "sample.d", synMgr, lightSynTheme, Color(30, 30, 30, 255), true, 4);
    assert(minimap.cachedBands.length > 5);
    bool hasLightToken = false;
    foreach (ref b; minimap.cachedBands)
    {
        if (b.color.a == cast(ubyte)(255 * 190 / 255))
            hasLightToken = true;
    }
    assert(hasLightToken, "Light theme minimap bands should have crisp contrast (alpha 190)");

    bool upHandled = minimap.handleMouseUp();
    assert(upHandled);
    assert(!minimap.isDragging);
}

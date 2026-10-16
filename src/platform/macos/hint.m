#include "macos.h"

static float border_radius;

/* nil means "auto": follow the system appearance. */
static NSColor *bgColor;
static NSColor *fgColor;
const char *font;

struct hint_style {
	NSColor *bg;
	NSColor *fg;
	NSColor *typed;
	NSColor *edge;
	NSColor *shadow;
};

static void get_style(NSView *view, struct hint_style *style)
{
	const int dark = macos_is_dark(view);

	if (dark) {
		style->bg = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.12 alpha:0.88];
		style->fg = [NSColor colorWithWhite:1 alpha:0.95];
		style->edge = [NSColor colorWithWhite:1 alpha:0.14];
		style->shadow = [NSColor colorWithWhite:0 alpha:0.35];
	} else {
		style->bg = [NSColor colorWithSRGBRed:0.99 green:0.99 blue:1 alpha:0.92];
		style->fg = [NSColor colorWithWhite:0 alpha:0.85];
		style->edge = [NSColor colorWithWhite:0 alpha:0.12];
		style->shadow = [NSColor colorWithWhite:0 alpha:0.10];
	}

	/* Explicitly configured colors win, but keep the shadow for legibility. */
	if (bgColor) {
		style->bg = bgColor;
		style->edge = nil;
	}

	if (fgColor)
		style->fg = fgColor;

	style->typed = [style->fg colorWithAlphaComponent:style->fg.alphaComponent * 0.35];
}

/*
 * Drawing ~2000 hints piece by piece is slow (~50ms), so each distinct hint
 * box and (for fixed pitch fonts) each glyph is rendered once per redraw into
 * a CGLayer matched to the destination (and thus its backing scale) and then
 * stamped.
 */
struct stamps {
	CGContextRef ctx;
	struct hint_style *style;

	NSFont *font; /* Fixed pitch font the glyphs are rendered with (if any). */
	CGFloat advance;
	CGLayerRef glyphs[2][128]; /* [typed][char] */

	struct {
		int w;
		int h;
		CGLayerRef layer;
	} boxes[4];
};

/* Run AppKit drawing code against a layer. */
static CGLayerRef render_layer(CGContextRef ctx, CGFloat w, CGFloat h, void (^draw)(void))
{
	CGLayerRef layer = CGLayerCreateWithContext(ctx, CGSizeMake(w, h), NULL);

	[NSGraphicsContext saveGraphicsState];
	NSGraphicsContext.currentContext =
	    [NSGraphicsContext graphicsContextWithCGContext:CGLayerGetContext(layer) flipped:NO];
	draw();
	[NSGraphicsContext restoreGraphicsState];

	return layer;
}

/* The hint box (shadow, background and edge), with a 1pt margin for the shadow. */
static CGLayerRef get_box(struct stamps *st, int w, int h)
{
	size_t i;
	const size_t n = sizeof st->boxes / sizeof st->boxes[0];
	const float r = MIN(border_radius, h / 2.0);
	struct hint_style *style = st->style;

	for (i = 0; i < n && st->boxes[i].layer; i++)
		if (st->boxes[i].w == w && st->boxes[i].h == h)
			return st->boxes[i].layer;

	if (i == n)
		return NULL;

	st->boxes[i].w = w;
	st->boxes[i].h = h;
	st->boxes[i].layer = render_layer(st->ctx, w + 2, h + 2, ^{
		/* A cheap offset shadow, NSShadow blurring is too slow. */
		[style->shadow setFill];
		[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0.5, 0, w + 1, h + 0.5)
						 xRadius:r + 0.5
						 yRadius:r + 0.5] fill];

		[style->bg setFill];
		[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1, w, h) xRadius:r yRadius:r] fill];

		if (style->edge) {
			NSBezierPath *path = [NSBezierPath
			    bezierPathWithRoundedRect:NSMakeRect(1.25, 1.25, w - 0.5, h - 0.5)
					      xRadius:r
					      yRadius:r];
			[style->edge setStroke];
			path.lineWidth = 0.5;
			[path stroke];
		}
	});

	return st->boxes[i].layer;
}

/* A single glyph in a box of height h, baseline placed as in macos_draw_text(). */
static CGLayerRef get_glyph(struct stamps *st, char c, int typed, int h)
{
	CGLayerRef *layer = &st->glyphs[typed][(int)c];
	NSFont *font = st->font;
	NSDictionary *attrs;
	NSString *str;

	if (*layer)
		return *layer;

	attrs = @{
		NSFontAttributeName : font,
		NSForegroundColorAttributeName : typed ? st->style->typed : st->style->fg,
	};
	str = [NSString stringWithFormat:@"%c", c];

	*layer = render_layer(st->ctx, st->advance, h, ^{
		CGFloat baseline = h / 2.0 - font.capHeight / 2;
		[str drawAtPoint:NSMakePoint(0, baseline + font.descender) withAttributes:attrs];
	});

	return *layer;
}

/* Returns 0 if the label can't be drawn from glyph stamps. */
static int stamp_label(struct stamps *st, struct screen *scr, struct hint *h)
{
	size_t i;
	const size_t len = strlen(h->label);
	NSFont *f = macos_get_font(font, h->w, h->h, h->label);
	CGFloat x;

	if (!f.isFixedPitch)
		return 0;

	if (!st->font) {
		st->font = f;
		st->advance = [@"m" sizeWithAttributes:@{NSFontAttributeName : f}].width;
	} else if (![f isEqual:st->font]) {
		return 0; /* e.g shrunk to fit */
	}

	for (i = 0; i < len; i++)
		if ((unsigned char)h->label[i] >= 128)
			return 0;

	x = h->x + (h->w - len * st->advance) / 2;

	for (i = 0; i < len; i++)
		CGContextDrawLayerAtPoint(st->ctx,
					  CGPointMake(x + i * st->advance, scr->h - h->y - h->h),
					  get_glyph(st, h->label[i], i < h->typed, h->h));

	return 1;
}

static void draw_hook(void *arg, NSView *view)
{
	size_t i, j;
	struct screen *scr = arg;
	struct hint_style style;
	struct stamps st = {0};

	get_style(view, &style);
	st.ctx = NSGraphicsContext.currentContext.CGContext;
	st.style = &style;

	for (i = 0; i < scr->nr_hints; i++) {
		struct hint *h = &scr->hints[i];
		CGLayerRef box = get_box(&st, h->w, h->h);

		if (box)
			CGContextDrawLayerAtPoint(st.ctx, CGPointMake(h->x - 1, scr->h - h->y - h->h - 1), box);
		else
			macos_draw_box(scr, style.bg, h->x, h->y, h->w, h->h, MIN(border_radius, h->h / 2.0));

		if (!stamp_label(&st, scr, h))
			macos_draw_text(scr, style.fg, style.typed, font,
					h->x, h->y, h->w, h->h, h->label, h->typed);
	}

	for (i = 0; i < 128; i++)
		for (j = 0; j < 2; j++)
			if (st.glyphs[j][i])
				CGLayerRelease(st.glyphs[j][i]);

	for (i = 0; i < sizeof st.boxes / sizeof st.boxes[0]; i++)
		if (st.boxes[i].layer)
			CGLayerRelease(st.boxes[i].layer);
}

void osx_hint_draw(struct screen *scr, struct hint *hints, size_t n)
{
	scr->nr_hints = n;
	memcpy(scr->hints, hints, sizeof(struct hint)*n);

	window_register_draw_hook(scr->overlay, draw_hook, scr);
}

void osx_init_hint(const char *bg, const char *fg, int _border_radius,
	       const char *font_family)
{
	/* Called from the warpd thread, which never drains its own pool. */
	@autoreleasepool {
		bgColor = macos_color(bg);
		fgColor = macos_color(fg);

		border_radius = (float)_border_radius;
		font = font_family;
	}
}

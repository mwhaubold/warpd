#include "macos.h"

/*
 * Hints are shown as Core Animation layers (composited on the GPU), so they
 * can be animated even when there are ~2000 of them:
 *
 * - Each hint is a layer showing a shared pre-rendered box image, with one
 *   sublayer per character showing a shared pre-rendered glyph image (for
 *   fixed pitch fonts, otherwise a rendered label image).
 * - A new set of hints sweeps in from the pointer: hints are grouped into
 *   rings by their distance from the pointer and each ring fades/scales in
 *   slightly after the previous one.
 * - When the set changes (e.g while typing), the matching hints get a fresh
 *   root layer and the previous root collapses towards them as a single
 *   layer. Selecting the last hint makes it pulse.
 *
 * Animating whole groups keeps the number of animations small, adding one
 * per hint takes ~40ms with 2000 hints.
 */

#define NR_RINGS 8

static float border_radius;

/* nil means "auto": follow the system appearance. */
static NSColor *bgColor;
static NSColor *fgColor;
const char *font;

/* Set when colors/font change, rendered images are dropped on the main thread. */
static int images_stale = 1;

/* Rendered box/glyph/label images keyed by their parameters. Main thread only. */
static NSMutableDictionary<NSString *, id> *images;

struct hint_style {
	NSColor *bg;
	NSColor *fg;
	NSColor *typed;
	NSColor *edge;
	NSColor *shadow;
};

static void get_style(int dark, struct hint_style *style)
{
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

/* Returns a (cached) image of the given size in points, drawn with AppKit at the given scale. */
static CGImageRef get_image(NSString *key, CGFloat scale, CGFloat w, CGFloat h, void (^draw)(void))
{
	id img = images[key];

	if (!img) {
		CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		CGContextRef ctx = CGBitmapContextCreate(NULL, ceil(w * scale), ceil(h * scale), 8, 0, cs,
							 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);

		CGContextScaleCTM(ctx, scale, scale);

		[NSGraphicsContext saveGraphicsState];
		NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
		draw();
		[NSGraphicsContext restoreGraphicsState];

		img = (__bridge_transfer id)CGBitmapContextCreateImage(ctx);
		images[key] = img;

		CGContextRelease(ctx);
		CGColorSpaceRelease(cs);
	}

	return (__bridge CGImageRef)img;
}

/* The hint box (shadow, background and edge), with a 1pt margin for the shadow. */
static CGImageRef get_box(struct hint_style *style, int w, int h, CGFloat scale, int dark)
{
	NSString *key = [NSString stringWithFormat:@"box %d %d %g %d", w, h, scale, dark];

	return get_image(key, scale, w + 2, h + 2, ^{
		const float r = MIN(border_radius, h / 2.0);

		/* A cheap offset shadow (blurring isn't worth it at this size). */
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
}

/* Draw str (its first typed characters in typed_col) with the cap height centered in a box of height h. */
static void draw_label(NSString *str, NSFont *f, NSColor *fg, NSColor *typed_col, size_t typed, CGFloat x, CGFloat h)
{
	NSMutableAttributedString *astr = [[NSMutableAttributedString alloc]
	    initWithString:str
		attributes:@{
			NSFontAttributeName : f,
			NSForegroundColorAttributeName : fg,
			/* Labels are arbitrary letter combinations, never merge them (e.g "fi"). */
			NSLigatureAttributeName : @0,
		}];

	typed = MIN(typed, str.length);
	if (typed)
		[astr addAttribute:NSForegroundColorAttributeName value:typed_col range:NSMakeRange(0, typed)];

	[astr drawAtPoint:NSMakePoint(x, h / 2.0 - f.capHeight / 2 + f.descender)];
}

/*
 * Images resolved during a single update, all hints of a set share their
 * font/height so this avoids building a lookup key per glyph (~25ms with
 * 2000 hints).
 */
struct update_cache {
	NSFont *font;
	int h;
	CGFloat advance;

	/* Images of one or two characters for font/h, keyed by chunk_key(). */
	NSMutableDictionary<NSNumber *, id> *chunks;

	struct {
		int w;
		int h;
		CGImageRef img;
	} boxes[4];
};

static CGImageRef cached_box(struct update_cache *uc, struct hint_style *style, int w, int h,
			     CGFloat scale, int dark)
{
	size_t i;
	const size_t n = sizeof uc->boxes / sizeof uc->boxes[0];

	for (i = 0; i < n && uc->boxes[i].img; i++)
		if (uc->boxes[i].w == w && uc->boxes[i].h == h)
			return uc->boxes[i].img;

	if (i == n)
		return get_box(style, w, h, scale, dark);

	uc->boxes[i].w = w;
	uc->boxes[i].h = h;
	return uc->boxes[i].img = get_box(style, w, h, scale, dark);
}

static CALayer *create_hint_layer(struct screen *scr, struct hint *h, struct hint_style *style,
				  CGFloat scale, int dark, struct update_cache *uc)
{
	size_t i;
	const size_t len = strlen(h->label);
	NSFont *f = macos_get_font(font, h->w, h->h, h->label);
	CALayer *layer = [CALayer layer];

	layer.frame = CGRectMake(h->x - 1, scr->h - h->y - h->h - 1, h->w + 2, h->h + 2);
	layer.contentsScale = scale;
	layer.contents = (__bridge id)cached_box(uc, style, h->w, h->h, scale, dark);

	if (f.isFixedPitch) {
		/*
		 * Sublayers showing shared images of two characters at a time,
		 * which halves the number of layers compared to one per glyph.
		 */
		if (f != uc->font || h->h != uc->h) {
			NSString *key = [NSString stringWithFormat:@"chunks %@ %g %d %g %d",
						   f.fontName, f.pointSize, h->h, scale, dark];

			if (!images[key])
				images[key] = [NSMutableDictionary dictionary];

			uc->chunks = images[key];
			uc->font = f;
			uc->h = h->h;
			uc->advance = [@"m" sizeWithAttributes:@{NSFontAttributeName : f}].width;
		}

		for (i = 0; i < len; i += 2) {
			const size_t n = MIN(len - i, 2);
			const unsigned char c1 = h->label[i];
			const unsigned char c2 = n == 2 ? h->label[i + 1] : 0;
			const int typed = (i < h->typed) | (i + 1 < h->typed) << 1;
			NSNumber *key = @(c1 << 16 | c2 << 8 | typed);
			CALayer *chunk = [CALayer layer];
			id img = uc->chunks[key];

			if (!img) {
				NSString *str = [[NSString alloc] initWithBytes:h->label + i
									 length:n
								       encoding:NSUTF8StringEncoding];
				const CGFloat height = h->h;
				const CGFloat w = n * uc->advance;
				CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
				CGContextRef ctx = CGBitmapContextCreate(NULL, ceil(w * scale), ceil(height * scale), 8, 0, cs,
									 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);

				CGContextScaleCTM(ctx, scale, scale);
				[NSGraphicsContext saveGraphicsState];
				NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
				draw_label(str, f, (typed & 2) ? style->typed : style->fg, style->typed,
					   typed & 1, 0, height);
				[NSGraphicsContext restoreGraphicsState];

				img = (__bridge_transfer id)CGBitmapContextCreateImage(ctx);
				uc->chunks[key] = img;

				CGContextRelease(ctx);
				CGColorSpaceRelease(cs);
			}

			chunk.frame = CGRectMake(1 + (h->w - len * uc->advance) / 2 + i * uc->advance, 1,
						 n * uc->advance, h->h);
			chunk.contentsScale = scale;
			chunk.contents = img;

			[layer addSublayer:chunk];
		}
	} else {
		/* Proportional fonts: one image per label. */
		NSString *str = [NSString stringWithUTF8String:h->label];
		NSString *key = [NSString stringWithFormat:@"label %@ %d %d %d %@ %g %g %d",
					   str, h->typed, h->w, h->h, f.fontName, f.pointSize, scale, dark];
		CALayer *label = [CALayer layer];
		const CGFloat w = h->w;
		const CGFloat height = h->h;
		const size_t typed = h->typed;

		label.frame = CGRectMake(1, 1, w, height);
		label.contentsScale = scale;
		label.contents = (__bridge id)get_image(key, scale, w, height, ^{
			const CGFloat textw = [str sizeWithAttributes:@{NSFontAttributeName : f}].width;
			draw_label(str, f, style->fg, style->typed, typed, (w - textw) / 2, height);
		});

		[layer addSublayer:label];
	}

	return layer;
}

static void ensure_hint_view(struct screen *scr)
{
	NSView *content = scr->overlay->win.contentView;
	NSView *view;

	if (scr->hint_view)
		return;

	view = [[NSView alloc] initWithFrame:content.bounds];
	view.layer = [CALayer layer]; /* layer hosting */
	view.wantsLayer = YES;
	view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	/* Below the mode indicator. */
	[content addSubview:view positioned:NSWindowBelow relativeTo:nil];
	scr->hint_view = view;
}

/* Hide the overlay once the last animation is done (unless something else is shown by now). */
static void animation_done(struct screen *scr)
{
	scr->hint_animations--;

	if (!macos_screen_needs_overlay(scr))
		window_hide(scr->overlay);
}

/*
 * Animate a root layer which is no longer needed out and remove it: it
 * collapses towards anchor, or grows (pulses) if pulse is set.
 */
static void retire(struct screen *scr, CALayer *root, CGPoint anchor, int pulse)
{
	CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
	CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
	CAAnimationGroup *group = [CAAnimationGroup animation];
	const CGSize size = root.bounds.size;

	/* Scale around the anchor without moving the layer. */
	root.anchorPoint = CGPointMake(anchor.x / size.width, anchor.y / size.height);
	root.position = anchor;

	scale.fromValue = @1;
	scale.toValue = pulse ? @1.6 : @0.85;
	opacity.fromValue = @1;
	opacity.toValue = @0;

	group.animations = @[ scale, opacity ];
	group.duration = pulse ? 0.18 : 0.12;
	group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

	root.opacity = 0;
	scr->hint_animations++;

	[CATransaction begin];
	[CATransaction setCompletionBlock:^{
		[root removeFromSuperlayer];
		animation_done(scr);
	}];
	[root addAnimation:group forKey:@"retire"];
	[CATransaction commit];
}

/* The pointer position relative to scr (LLO), or its center if the pointer is elsewhere. */
static CGPoint wave_origin(struct screen *scr)
{
	NSPoint loc = [NSEvent mouseLocation];
	CGFloat x = loc.x - scr->x;
	CGFloat y = loc.y - scr->y;

	if (x < 0 || y < 0 || x > scr->w || y > scr->h)
		return CGPointMake(scr->w / 2.0, scr->h / 2.0);

	return CGPointMake(x, y);
}

/* Ring containers which fade and grow in one after the other, starting at origin. */
static void add_wave(CALayer *root, CALayer *__strong rings[NR_RINGS], CGPoint origin)
{
	size_t i;
	const CGSize size = root.bounds.size;
	const CFTimeInterval now = [root convertTime:CACurrentMediaTime() fromLayer:nil];

	for (i = 0; i < NR_RINGS; i++) {
		CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
		CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
		CAAnimationGroup *group = [CAAnimationGroup animation];
		CALayer *ring = [CALayer layer];

		/* Full size so sublayers share the root's coordinates, scaled around the origin. */
		ring.bounds = root.bounds;
		ring.anchorPoint = CGPointMake(origin.x / size.width, origin.y / size.height);
		ring.position = origin;

		scale.fromValue = @0.9;
		scale.toValue = @1;
		opacity.fromValue = @0;
		opacity.toValue = @1;

		group.animations = @[ scale, opacity ];
		group.duration = 0.14;
		group.beginTime = now + i * 0.01;
		group.fillMode = kCAFillModeBackwards;
		group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

		[ring addAnimation:group forKey:@"wave"];
		[root addSublayer:ring];
		rings[i] = ring;
	}
}

/*
 * Apply the hints passed to osx_hint_draw()/osx_screen_clear() since the last
 * commit to the hint layers. Main thread only.
 */
void macos_update_hints(struct screen *scr)
{
	size_t i;
	struct hint_style style;
	CALayer *old = scr->hint_root;
	CALayer *root = nil;
	CALayer *rings[NR_RINGS];
	const size_t prev = scr->hints_shown;
	const size_t n = scr->nr_hints;
	const int animate = macos_animations();
	const CGPoint prev_center = scr->hints_center;
	CGFloat scale;
	int dark;
	struct update_cache uc = {0};

	if (!scr->hints_dirty)
		return;

	scr->hints_dirty = 0;

	if (!prev && !n)
		return;

	ensure_hint_view(scr);

	if (!images)
		images = [NSMutableDictionary dictionary];

	if (images_stale) {
		[images removeAllObjects];
		images_stale = 0;
	}

	scale = scr->overlay->win.backingScaleFactor;
	dark = macos_is_dark(scr->hint_view);
	get_style(dark, &style);

	[CATransaction begin];
	[CATransaction setDisableActions:YES];

	if (n) {
		const CGPoint origin = wave_origin(scr);
		const CGFloat maxdist = hypot(MAX(origin.x, scr->w - origin.x), MAX(origin.y, scr->h - origin.y));
		const int wave = animate && !prev;
		CGFloat cx = 0, cy = 0;

		root = [CALayer layer];
		root.frame = scr->hint_view.layer.bounds;

		if (wave)
			add_wave(root, rings, origin);

		for (i = 0; i < n; i++) {
			struct hint *h = &scr->hints[i];
			CALayer *layer = create_hint_layer(scr, h, &style, scale, dark, &uc);
			const CGFloat x = h->x + h->w / 2.0;
			const CGFloat y = scr->h - h->y - h->h / 2.0;

			cx += x;
			cy += y;

			if (wave) {
				size_t ring = hypot(x - origin.x, y - origin.y) / maxdist * NR_RINGS;
				[rings[MIN(ring, NR_RINGS - 1)] addSublayer:layer];
			} else {
				[root addSublayer:layer];
			}
		}

		scr->hints_center = CGPointMake(cx / n, cy / n);
		[scr->hint_view.layer addSublayer:root];
	}

	scr->hint_root = root;
	scr->hints_shown = n;

	if (old) {
		if (animate)
			/* Collapse towards the remaining hints, or pulse the selected one. */
			retire(scr, old, n ? scr->hints_center : prev_center, !n && prev == 1);
		else
			[old removeFromSuperlayer];
	}

	[CATransaction commit];
}

/*
 * Briefly outline rect (upper left origin, relative to scr), e.g the element
 * the pointer snapped to. Main thread only.
 */
void macos_flash_rect(struct screen *scr, CGRect rect)
{
	CAShapeLayer *outline;
	CGPathRef path;
	CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
	CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
	CAAnimationGroup *group = [CAAnimationGroup animation];
	const CGRect frame = CGRectMake(rect.origin.x, scr->h - rect.origin.y - rect.size.height,
					rect.size.width, rect.size.height);
	const CGFloat r = MIN(6, MIN(frame.size.width, frame.size.height) / 2);

	if (!macos_animations())
		return;

	ensure_hint_view(scr);

	outline = [CAShapeLayer layer];
	outline.frame = CGRectInset(frame, -3, -3);
	path = CGPathCreateWithRoundedRect(CGRectInset(outline.bounds, 1, 1), r + 2, r + 2, NULL);
	outline.path = path;
	CGPathRelease(path);
	outline.fillColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.12].CGColor;
	outline.strokeColor = NSColor.controlAccentColor.CGColor;
	outline.lineWidth = 2;
	outline.opacity = 0;

	scale.fromValue = @0.96;
	scale.toValue = @1.04;
	opacity.fromValue = @1;
	opacity.toValue = @0;

	group.animations = @[ scale, opacity ];
	group.duration = 0.45;
	group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

	scr->hint_animations++;
	window_show(scr->overlay);

	[CATransaction begin];
	[CATransaction setCompletionBlock:^{
		[outline removeFromSuperlayer];
		animation_done(scr);
	}];
	[scr->hint_view.layer addSublayer:outline];
	[outline addAnimation:group forKey:@"flash"];
	[CATransaction commit];
}

/* Drop all hint layers immediately (e.g the screen was reconfigured). Main thread only. */
void macos_reset_hints(struct screen *scr)
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for (CALayer *layer in [scr->hint_view.layer.sublayers copy])
		[layer removeFromSuperlayer];
	[CATransaction commit];

	scr->hint_root = nil;
	scr->hints_shown = 0;
	scr->hints_dirty = 0;
}

void osx_hint_draw(struct screen *scr, struct hint *hints, size_t n)
{
	scr->nr_hints = n;
	memcpy(scr->hints, hints, sizeof(struct hint) * n);
	scr->hints_dirty = 1;
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

		/* Colors/font may have changed, render new images on the next update. */
		images_stale = 1;
	}
}

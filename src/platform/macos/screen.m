/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

#include "macos.h"

struct screen screens[MAX_SCREENS];
size_t nr_screens;

static NSColor *color_or_accent(const char *color)
{
	NSColor *c = macos_color(color);
	return c ? c : NSColor.controlAccentColor;
}

/* A soft shadow keeps thin lines legible on any background. */
static void with_shadow(CGFloat blur, CGFloat alpha, void (^draw)(void))
{
	NSShadow *shadow = [[NSShadow alloc] init];

	shadow.shadowBlurRadius = blur;
	shadow.shadowOffset = NSMakeSize(0, -0.5);
	shadow.shadowColor = [NSColor colorWithWhite:0 alpha:alpha];

	[NSGraphicsContext saveGraphicsState];
	[shadow set];
	draw();
	[NSGraphicsContext restoreGraphicsState];
}

static void draw_hook(void *arg, NSView *view)
{
	struct box *b = arg;

	with_shadow(3, 0.35, ^{
		macos_draw_box(b->scr, b->color, b->x, b->y, b->w, b->h, MIN(b->w, b->h) / 2.0);
	});
}

/* A ring around the pointer position, leaving the target itself visible. */
static void cursor_draw_hook(void *arg, NSView *view)
{
	struct screen *scr = arg;
	const CGFloat r = scr->cursor.size;
	const NSPoint c = NSMakePoint(scr->cursor.x, scr->h - scr->cursor.y);
	NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r)];
	NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 1.5, c.y - 1.5, 3, 3)];

	with_shadow(3, 0.4, ^{
		/* Halo for contrast against backgrounds similar to the cursor color. */
		[[NSColor colorWithWhite:1 alpha:0.9] setStroke];
		ring.lineWidth = 4.5;
		[ring stroke];
	});

	[scr->cursor.color setStroke];
	ring.lineWidth = 2.5;
	[ring stroke];

	[scr->cursor.color setFill];
	[dot fill];
}

void osx_screen_draw_cursor(struct screen *scr, int x, int y, int size, const char *color)
{
	scr->cursor.x = x;
	scr->cursor.y = y;
	scr->cursor.size = size;
	scr->cursor.color = color_or_accent(color);

	window_register_draw_hook(scr->overlay, cursor_draw_hook, scr);
}

void osx_screen_draw_indicator(struct screen *scr, const char *mode, const char *position, int size, const char *color)
{
	scr->hud.visible = 1;
	scr->hud.size = size;
	scr->hud.color = color_or_accent(color);
	snprintf(scr->hud.text, sizeof scr->hud.text, "%s", mode);
	snprintf(scr->hud.position, sizeof scr->hud.position, "%s", position);
}

@interface HUDLabelView : NSView
@property struct screen *scr;
@end

@implementation HUDLabelView
- (void)drawRect:(NSRect)dirtyRect
{
	struct screen *scr = self.scr;
	const CGFloat size = scr->hud.size;
	const CGFloat pad = size * 0.9;
	const CGFloat dot = size * 0.55;
	NSFont *font = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
	NSDictionary *attrs = @{
		NSFontAttributeName : font,
		NSForegroundColorAttributeName : NSColor.labelColor,
		NSKernAttributeName : @(size * 0.06),
	};
	const CGFloat mid = self.bounds.size.height / 2;

	[scr->hud.color setFill];
	[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pad, mid - dot / 2, dot, dot)] fill];

	[[NSString stringWithUTF8String:scr->hud.text]
	    drawAtPoint:NSMakePoint(pad + dot + size * 0.5, mid - font.capHeight / 2 + font.descender)
	 withAttributes:attrs];
}
@end

/* Apply the indicator state to its (blurred) view. Main thread only. */
void macos_update_hud(struct screen *scr)
{
	NSVisualEffectView *view = scr->hud_view;
	HUDLabelView *label;
	CGFloat w, h, x, y;
	const CGFloat margin = 12;
	const CGFloat size = scr->hud.size;
	NSRect vf = scr->visible_frame;

	if (!scr->hud.visible) {
		view.hidden = YES;
		return;
	}

	if (!view) {
		view = [[NSVisualEffectView alloc] init];
		view.material = NSVisualEffectMaterialHUDWindow;
		view.blendingMode = NSVisualEffectBlendingModeBehindWindow;
		view.state = NSVisualEffectStateActive;
		view.wantsLayer = YES;
		view.layer.masksToBounds = YES;
		view.layer.borderWidth = 0.5;

		label = [[HUDLabelView alloc] init];
		label.scr = scr;
		label.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[view addSubview:label];

		[scr->overlay->win.contentView addSubview:view];
		scr->hud_view = view;
	}

	label = view.subviews.firstObject;

	w = [[NSString stringWithUTF8String:scr->hud.text] sizeWithAttributes:@{
		NSFontAttributeName : [NSFont systemFontOfSize:size weight:NSFontWeightSemibold],
		NSKernAttributeName : @(size * 0.06),
	}].width + size * (0.9 * 2 + 0.55 + 0.5);
	h = size * 2.2;

	x = strstr(scr->hud.position, "left") ? vf.origin.x + margin
					      : vf.origin.x + vf.size.width - w - margin;
	y = strstr(scr->hud.position, "bottom") ? vf.origin.y + margin
						: vf.origin.y + vf.size.height - h - margin;

	view.frame = NSMakeRect(x, y, w, h);
	view.layer.cornerRadius = h / 2;
	view.layer.borderColor = [NSColor colorWithWhite:macos_is_dark(view) ? 1 : 0 alpha:0.12].CGColor;
	label.frame = view.bounds;
	label.needsDisplay = YES;
	view.hidden = NO;
}

void osx_screen_draw_box(struct screen *scr, int x, int y, int w, int h, const char *color)
{
	assert(scr->nr_boxes < MAX_BOXES);
	struct box *b = &scr->boxes[scr->nr_boxes++];

	b->x = x;
	b->y = y;
	b->w = w;
	b->h = h;
	b->scr = scr;
	b->color = color_or_accent(color);

	window_register_draw_hook(scr->overlay, draw_hook, b);
}

void osx_screen_list(struct screen *rscreens[MAX_SCREENS], size_t *n)
{
	size_t i;

	for (i = 0; i < nr_screens; i++)
		rscreens[i] = &screens[i];

	*n = nr_screens;
}

void osx_screen_clear(struct screen *scr)
{
	scr->hud.visible = 0;
	scr->nr_boxes = 0;
	scr->overlay->nr_hooks = 0;
}

void osx_screen_get_dimensions(struct screen *scr, int *w, int *h)
{
	*w = scr->w;
	*h = scr->h;
}

/* Only accessed on the main thread. */
static int screens_dirty = 0;

/*
 * (Re)build the screen list from NSScreen.screens. Must run on the main
 * thread while no mode is active.
 *
 * Entries are updated in place and overlay windows are reused rather than
 * freed, so screen_t pointers held by the core (e.g grid.c, mouse.c) always
 * point to valid memory. The core re-fetches them at the start of every mode.
 */
static void update_screens()
{
	size_t i;
	size_t n = 0;

	for (NSScreen *screen in NSScreen.screens) {
		struct screen *scr;
		NSRect frame = screen.frame;

		if (n == MAX_SCREENS) {
			fprintf(stderr, "WARNING: more than %d screens, ignoring the rest\n", MAX_SCREENS);
			break;
		}

		scr = &screens[n++];

		scr->x = frame.origin.x;
		scr->y = frame.origin.y;
		scr->w = frame.size.width;
		scr->h = frame.size.height;

		scr->visible_frame = NSOffsetRect(screen.visibleFrame, -frame.origin.x, -frame.origin.y);
		scr->hud.visible = 0;

		scr->nr_hints = 0;
		scr->nr_boxes = 0;

		if (scr->overlay)
			[scr->overlay->win setFrame:frame display:NO];
		else
			scr->overlay = create_overlay_window(scr->x, scr->y, scr->w, scr->h);

		scr->overlay->nr_hooks = 0;
		window_hide(scr->overlay);
	}

	/* Hide overlays belonging to screens which have gone away. */
	for (i = n; i < nr_screens; i++) {
		screens[i].overlay->nr_hooks = 0;
		window_hide(screens[i].overlay);
	}

	nr_screens = n;
	screens_dirty = 0;
}

/*
 * Apply pending display configuration changes (hotplug, rearrangement,
 * resolution changes). Called from the warpd thread while idle.
 */
void macos_sync_screens()
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		if (screens_dirty)
			update_screens();
	});
}

void macos_init_screen()
{
	update_screens();

	[[NSNotificationCenter defaultCenter]
	    addObserverForName:NSApplicationDidChangeScreenParametersNotification
			object:nil
			 queue:[NSOperationQueue mainQueue]
		    usingBlock:^(NSNotification *note) {
			    screens_dirty = 1;
			    osx_input_interrupt_screen_change();
		    }];
}

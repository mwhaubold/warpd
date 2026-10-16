/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

/*
 * Snap the pointer onto nearby clickable UI elements using the
 * accessibility API (which warpd needs to be trusted for anyway).
 */

#include "macos.h"

/* How many ancestors of the element under the point to consider (e.g a button's label). */
#define MAX_DEPTH 4

static int is_clickable(AXUIElementRef el)
{
	static NSSet *roles;
	CFTypeRef role = NULL;
	CFArrayRef actions = NULL;
	int ret = 0;

	if (!roles)
		roles = [NSSet setWithArray:@[
			@"AXButton", @"AXLink", @"AXCheckBox", @"AXRadioButton", @"AXPopUpButton",
			@"AXMenuButton", @"AXMenuItem", @"AXMenuBarItem", @"AXTextField", @"AXComboBox",
			@"AXDisclosureTriangle", @"AXIncrementor", @"AXDockItem", @"AXTab",
		]];

	if (AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role) == kAXErrorSuccess) {
		ret = [roles containsObject:(__bridge NSString *)role];
		CFRelease(role);
	}

	if (!ret && AXUIElementCopyActionNames(el, &actions) == kAXErrorSuccess) {
		ret = [(__bridge NSArray *)actions containsObject:(__bridge NSString *)kAXPressAction];
		CFRelease(actions);
	}

	return ret;
}

/* The element's frame in global (upper left origin) coordinates. */
static int get_frame(AXUIElementRef el, CGRect *frame)
{
	CFTypeRef pos = NULL, size = NULL;
	int ret = 0;

	if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &pos) == kAXErrorSuccess &&
	    AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &size) == kAXErrorSuccess)
		ret = AXValueGetValue(pos, kAXValueTypeCGPoint, &frame->origin) &&
		      AXValueGetValue(size, kAXValueTypeCGSize, &frame->size);

	if (pos)
		CFRelease(pos);
	if (size)
		CFRelease(size);

	return ret;
}

int osx_snap_to_element(struct screen *scr, int *x, int *y, int radius)
{
	/* Called from the warpd thread, which never drains its own pool. */
	@autoreleasepool {
		static AXUIElementRef systemwide;
		AXUIElementRef el = NULL;
		CGRect frame;
		int depth;
		int snapped = 0;

		/* Global (upper left origin) coordinates are relative to the primary screen's top. */
		const CGFloat top = screens[0].h - (scr->y + scr->h);
		const CGFloat gx = scr->x + *x;
		const CGFloat gy = top + *y;

		if (!systemwide) {
			systemwide = AXUIElementCreateSystemWide();
			/* Don't let an unresponsive app stall warpd (applies to all elements). */
			AXUIElementSetMessagingTimeout(systemwide, 0.1);
		}

		if (AXUIElementCopyElementAtPosition(systemwide, gx, gy, &el) != kAXErrorSuccess)
			return 0;

		for (depth = 0; el && depth < MAX_DEPTH; depth++) {
			AXUIElementRef parent = NULL;
			pid_t pid;

			/* Never snap to our own overlays. */
			if (AXUIElementGetPid(el, &pid) == kAXErrorSuccess && pid == getpid())
				break;

			if (is_clickable(el) && get_frame(el, &frame)) {
				const CGFloat cx = CGRectGetMidX(frame);
				const CGFloat cy = CGRectGetMidY(frame);

				/*
				 * Only small elements whose center is close by, so a
				 * snap is a small correction rather than a jump (and
				 * never to the middle of a large text area).
				 */
				if (frame.size.width <= 4 * radius && frame.size.height <= 2 * radius &&
				    hypot(cx - gx, cy - gy) <= radius &&
				    cx >= scr->x && cx < scr->x + scr->w && cy >= top && cy < top + scr->h) {
					const CGRect local = CGRectMake(frame.origin.x - scr->x,
									frame.origin.y - top,
									frame.size.width, frame.size.height);

					*x = cx - scr->x;
					*y = cy - top;
					snapped = 1;

					dispatch_async(dispatch_get_main_queue(), ^{
						macos_flash_rect(scr, local);
					});
				}

				break;
			}

			if (AXUIElementCopyAttributeValue(el, kAXParentAttribute, (CFTypeRef *)&parent) != kAXErrorSuccess)
				parent = NULL;

			CFRelease(el);
			el = parent;
		}

		if (el)
			CFRelease(el);

		return snapped;
	}
}

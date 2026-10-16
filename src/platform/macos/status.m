/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

/* Menu bar (status) icon. Everything in here runs on the main thread. */

#include "macos.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSStatusItem *item;
static NSMenuItem *pause_item;
static int paused;

static void update_status()
{
	NSString *symbol = paused ? @"cursorarrow.slash" : @"cursorarrow.rays";
	NSImage *img = [NSImage imageWithSystemSymbolName:symbol
				 accessibilityDescription:paused ? @"warpd (paused)" : @"warpd"];

	img.template = YES;
	item.button.image = img;
	item.button.toolTip = paused ? @"warpd (paused)" : @"warpd";
	pause_item.title = paused ? @"Resume warpd" : @"Pause warpd";
}

/* Create an empty config with a pointer to the docs if none exists yet. */
static void ensure_config_exists(NSString *path)
{
	NSFileManager *fm = NSFileManager.defaultManager;

	if ([fm fileExistsAtPath:path])
		return;

	[fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
	    withIntermediateDirectories:YES
			     attributes:nil
				  error:nil];
	[@"# warpd config, see `man warpd` or `warpd --list-options` for all options.\n"
	    "# Changes are applied as soon as the file is saved.\n"
	 writeToFile:path
	  atomically:YES
	    encoding:NSUTF8StringEncoding
	       error:nil];
}

@interface StatusTarget : NSObject
@end

@implementation StatusTarget
- (void)togglePause:(id)sender
{
	paused = !paused;
	osx_input_set_paused(paused);
	update_status();
}

- (void)reloadConfig:(id)sender
{
	osx_input_interrupt();
}

- (void)openConfig:(id)sender
{
	NSString *path;
	NSURL *editor;

	if (!macos_config_path)
		return;

	path = [NSString stringWithUTF8String:macos_config_path];
	ensure_config_exists(path);

	/* The config has no extension, so explicitly use the default text editor. */
	editor = [NSWorkspace.sharedWorkspace URLForApplicationToOpenContentType:UTTypePlainText];
	if (editor)
		[NSWorkspace.sharedWorkspace openURLs:@[ [NSURL fileURLWithPath:path] ]
				 withApplicationAtURL:editor
				        configuration:[NSWorkspaceOpenConfiguration configuration]
				    completionHandler:nil];
	else
		[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
}

- (void)quit:(id)sender
{
	exit(0);
}
@end

static StatusTarget *target;

static NSMenuItem *add_item(NSMenu *menu, NSString *title, SEL action, NSString *key)
{
	NSMenuItem *mi = [menu addItemWithTitle:title action:action keyEquivalent:key];
	mi.target = target;
	return mi;
}

void osx_init_status_icon(int enabled)
{
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSMenu *menu;

		if (!enabled) {
			if (item) {
				[NSStatusBar.systemStatusBar removeStatusItem:item];
				[item release];
			}
			item = nil;
			return;
		}

		if (item)
			return;

		if (!target)
			target = [[StatusTarget alloc] init];
		menu = [[NSMenu alloc] init];

		[menu addItemWithTitle:@"warpd " VERSION action:nil keyEquivalent:@""].enabled = NO;
		[menu addItem:NSMenuItem.separatorItem];
		pause_item = add_item(menu, @"Pause warpd", @selector(togglePause:), @"");
		add_item(menu, @"Reload Config", @selector(reloadConfig:), @"");
		add_item(menu, @"Open Config…", @selector(openConfig:), @"");
		[menu addItem:NSMenuItem.separatorItem];
		add_item(menu, @"Quit warpd", @selector(quit:), @"");

		/* Not compiled with ARC: retain past the current autorelease pool. */
		item = [[NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength] retain];
		item.menu = menu;
		[menu release];

		update_status();
	});
}

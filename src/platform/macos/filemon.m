#import "macos.h"

static void fsEventCallbackFunction(ConstFSEventStreamRef streamRef,
                             void *clientCallBackInfo, size_t numEvents,
                             void *eventPaths,
                             const FSEventStreamEventFlags *eventFlags,
                             const FSEventStreamEventId *eventIds)
{
	osx_input_interrupt();
}

const char *macos_config_path;

void osx_monitor_file(const char *_path)
{
	macos_config_path = strdup(_path);

	dispatch_sync(dispatch_get_main_queue(), ^{
		NSString *path = [NSString stringWithCString:_path
						    encoding:NSUTF8StringEncoding];


		CFArrayRef paths = CFArrayCreate(NULL, (void**)&path, 1, NULL);
		FSEventStreamContext context;

		context.version = 0;
		context.info = NULL;
		context.retain = NULL;
		context.release = NULL;
		context.copyDescription = NULL;

		FSEventStreamRef stream = FSEventStreamCreate(
		    kCFAllocatorDefault, &fsEventCallbackFunction, &context, paths,
		    kFSEventStreamEventIdSinceNow, 3.0,
		    kFSEventStreamCreateFlagFileEvents |
			kFSEventStreamCreateFlagWatchRoot);

		FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		FSEventStreamStart(stream);
	});
}

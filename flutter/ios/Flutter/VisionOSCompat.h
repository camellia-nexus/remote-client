#import <Foundation/Foundation.h>

#if TARGET_OS_IOS
@interface NSProcessInfo (VisionOSCompat)
@property (readonly) BOOL isiOSAppOnVision;
@end
#endif

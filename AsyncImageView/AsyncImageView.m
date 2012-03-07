//
//  AsyncImageView.m
//
//  Version 1.3 beta 2
//
//  Created by Nick Lockwood on 03/04/2011.
//  Copyright (c) 2011 Charcoal Design
//
//  Distributed under the permissive zlib License
//  Get the latest version from either of these locations:
//
//  http://charcoaldesign.co.uk/source/cocoa#asyncimageview
//  https://github.com/nicklockwood/AsyncImageView
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//  claim that you wrote the original software. If you use this software
//  in a product, an acknowledgment in the product documentation would be
//  appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//  misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AsyncImageView.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>


NSString *const AsyncImageLoadDidFinish = @"AsyncImageLoadDidFinish";
NSString *const AsyncImageLoadDidFail = @"AsyncImageLoadDidFail";
NSString *const AsyncImageTargetReleased = @"AsyncImageTargetReleased";

NSString *const AsyncImageImageKey = @"image";
NSString *const AsyncImageURLKey = @"URL";
NSString *const AsyncImageCacheKey = @"cache";
NSString *const AsyncImageErrorKey = @"error";


@interface AsyncImageCache ()

@property (nonatomic, strong) NSCache *cache;

@end


@implementation AsyncImageCache

@synthesize cache;
@synthesize useImageNamed;
@synthesize storeToDisk;
@synthesize pathOnDisk;

+ (AsyncImageCache *)sharedCache
{
    static AsyncImageCache *sharedInstance = nil;
    if (sharedInstance == nil)
    {
        sharedInstance = [[self alloc] init];
    }
    return sharedInstance;
}

- (id)init
{
    if ((self = [super init]))
    {
		useImageNamed = YES;
        cache = [[NSCache alloc] init];
    }
    return self;
}

- (void)setCountLimit:(NSUInteger)countLimit
{
    cache.countLimit = countLimit;
}

- (NSUInteger)countLimit
{
    return cache.countLimit;
}

- (void)setPathOnDisk:(NSString *)path
{
    NSFileManager *fileManager= [NSFileManager defaultManager]; 
    if(![fileManager fileExistsAtPath:path]) {
        if(![fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL]) 
        {
            NSLog(@"Error: Could not create storage directory!");
        }
    }
    
    pathOnDisk = [path copy];
}

- (UIImage *)imageForURL:(NSURL *)URL
{
	if (useImageNamed && [URL isFileURL])
	{
		NSString *path = [URL path];
		NSString *imageName = [path lastPathComponent];
		NSString *directory = [path stringByDeletingLastPathComponent];
		if ([[[NSBundle mainBundle] resourcePath] isEqualToString:directory])
		{
			return [UIImage imageNamed:imageName];
		}
	}
    
    UIImage *img = [cache objectForKey:URL];
    if (!img && storeToDisk && pathOnDisk)
    {
        NSString *path = [pathOnDisk stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", URL.hash]];
        if([[NSFileManager defaultManager] fileExistsAtPath:path]) 
        {
            img = [UIImage imageWithContentsOfFile:path];
            [cache setObject:img forKey:URL];
        }
    }
    
    return img;
}

- (void)setImage:(UIImage *)image forURL:(NSURL *)URL
{
    if (useImageNamed && [URL isFileURL])
    {
        NSString *path = [URL path];
        NSString *directory = [path stringByDeletingLastPathComponent];
        if ([[[NSBundle mainBundle] resourcePath] isEqualToString:directory])
        {
            //do not store in cache
            return;
        }
    }
    [cache setObject:image forKey:URL];
}

- (void)removeImageForURL:(NSURL *)URL
{
    [cache removeObjectForKey:URL];
    
    if (storeToDisk && pathOnDisk)
    {
        // remove the item from the disk cache as well
        NSString *path = [pathOnDisk stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", URL.hash]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path])
        {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    }
}

- (void)clearCache
{
    //remove objects that aren't in use
    [cache removeAllObjects];
}

- (void)clearDiskCache
{
    if (storeToDisk && pathOnDisk)
    {
        // delete the entire disk cache
        if ([[NSFileManager defaultManager] fileExistsAtPath:pathOnDisk])
        {
            [[NSFileManager defaultManager] removeItemAtPath:pathOnDisk error:nil];
        }
    }
}

- (void)dealloc
{
    AH_RELEASE(cache);
    AH_SUPER_DEALLOC;
}

@end


@interface AsyncImageConnection : NSObject

@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, strong) NSURL *URL;
@property (nonatomic, strong) AsyncImageCache *cache;
@property (nonatomic, strong) id target;
@property (nonatomic, assign) SEL success;
@property (nonatomic, assign) SEL failure;
@property (nonatomic, assign) BOOL decompressImage;
@property (nonatomic, readonly, getter = isLoading) BOOL loading;
@property (nonatomic, readonly) BOOL cancelled;

+ (AsyncImageConnection *)connectionWithURL:(NSURL *)URL
                                      cache:(AsyncImageCache *)cache
									 target:(id)target
									success:(SEL)success
									failure:(SEL)failure
							decompressImage:(BOOL)decompressImage;

- (AsyncImageConnection *)initWithURL:(NSURL *)URL
                                cache:(AsyncImageCache *)cache
							   target:(id)target
							  success:(SEL)success
							  failure:(SEL)failure
					  decompressImage:(BOOL)decompressImage;

- (void)start;
- (void)cancel;
- (BOOL)isInCache;

@end


@implementation AsyncImageConnection

@synthesize connection;
@synthesize data;
@synthesize URL;
@synthesize cache;
@synthesize target;
@synthesize success;
@synthesize failure;
@synthesize decompressImage;
@synthesize loading;
@synthesize cancelled;


+ (AsyncImageConnection *)connectionWithURL:(NSURL *)URL
                                      cache:(AsyncImageCache *)_cache
									 target:(id)target
									success:(SEL)_success
									failure:(SEL)_failure
							decompressImage:(BOOL)_decompressImage
{
    return AH_AUTORELEASE([[self alloc] initWithURL:URL
                                              cache:_cache
                                             target:target
                                            success:_success
                                            failure:_failure
                                    decompressImage:_decompressImage]);
}

- (AsyncImageConnection *)initWithURL:(NSURL *)_URL
                                cache:(AsyncImageCache *)_cache
							   target:(id)_target
							  success:(SEL)_success
							  failure:(SEL)_failure
					  decompressImage:(BOOL)_decompressImage
{
    if ((self = [self init]))
    {
        self.URL = _URL;
        self.cache = _cache;
        self.target = _target;
        self.success = _success;
        self.failure = _failure;
		self.decompressImage = _decompressImage;
    }
    return self;
}

- (BOOL)isInCache
{
    return [cache imageForURL:URL] != nil;
}

- (void)loadFailedWithError:(NSError *)error
{
	loading = NO;
	cancelled = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:AsyncImageLoadDidFail
                                                        object:target
                                                      userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                URL, AsyncImageURLKey,
                                                                error, AsyncImageErrorKey,
                                                                nil]];
}

- (void)cacheImage:(UIImage *)image
{
	if (!cancelled)
	{
        if (image)
        {
            [cache setImage:image forURL:URL];
        }
        
		NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
										 image, AsyncImageImageKey,
										 URL, AsyncImageURLKey,
										 nil];
		if (cache)
		{
			[userInfo setObject:cache forKey:AsyncImageCacheKey];
		}
		
		loading = NO;
		[[NSNotificationCenter defaultCenter] postNotificationName:AsyncImageLoadDidFinish
															object:target
														  userInfo:AH_AUTORELEASE([userInfo copy])];
	}
	else
	{
		loading = NO;
		cancelled = NO;
	}
}

- (void)decompressImageInBackground:(UIImage *)image
{
	@synchronized ([self class])
	{
		if (!cancelled && decompressImage)
		{
			//force image decompression
			UIGraphicsBeginImageContext(CGSizeMake(1, 1));
			[image drawAtPoint:CGPointZero];
			UIGraphicsEndImageContext();
		}

		//add to cache (may be cached already but it doesn't matter)
		[self performSelectorOnMainThread:@selector(cacheImage:)
							   withObject:image
							waitUntilDone:YES];
	}
}

- (void)processDataInBackground:(NSData *)_data
{
	@synchronized ([self class])
	{	
		if (!cancelled)
		{
			UIImage *image = [[UIImage alloc] initWithData:_data];
			if (image)
			{
                @autoreleasepool {
                    if([cache storeToDisk] && [cache pathOnDisk])
                    {
                        [_data writeToFile:[[cache pathOnDisk] stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", URL.hash]] atomically:YES];
                    }
                }
                
				[self decompressImageInBackground:image];
                AH_RELEASE(image);
			}
			else
			{
                @autoreleasepool
                {
                    NSError *error = [NSError errorWithDomain:@"AsyncImageLoader" code:0 userInfo:[NSDictionary dictionaryWithObject:@"Invalid image data" forKey:NSLocalizedDescriptionKey]];
                    [self performSelectorOnMainThread:@selector(loadFailedWithError:) withObject:error waitUntilDone:YES];
				}
			}
		}
		else
		{
			//clean up
			[self performSelectorOnMainThread:@selector(cacheImage:)
								   withObject:nil
								waitUntilDone:YES];
		}
	}
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    self.data = [NSMutableData data];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)_data
{
    //check for released target
    if ([target retainCount] == 1)
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:AsyncImageTargetReleased object:target];
        return;
    }
    
    //check for cached image
	UIImage *image = [cache imageForURL:URL];
    if (image)
    {
        [self cancel];
        [self performSelectorInBackground:@selector(decompressImageInBackground:) withObject:image];
        return;
    }
    
    //add data
    [data appendData:_data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    [self performSelectorInBackground:@selector(processDataInBackground:) withObject:data];
    self.connection = nil;
    self.data = nil;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    self.connection = nil;
    self.data = nil;
    [self loadFailedWithError:error];
}

- (void)start
{
    if (loading && !cancelled)
    {
        return;
    }
	
	//begin loading
	loading = YES;
	cancelled = NO;
    
    //check for released target
    if ([target retainCount] == 1)
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:AsyncImageTargetReleased object:target];
        return;
    }
    
    //check for nil URL
    if (URL == nil)
    {
        [self cacheImage:nil];
        return;
    }
    
    //check for cached image
	UIImage *image = [cache imageForURL:URL];
    if (image)
    {
        [self performSelectorInBackground:@selector(decompressImageInBackground:) withObject:image];
        return;
    }
    
    //begin load
    NSURLRequest *request = [NSURLRequest requestWithURL:URL
                                             cachePolicy:NSURLCacheStorageNotAllowed
                                         timeoutInterval:[AsyncImageLoader sharedLoader].loadingTimeout];
    
    connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    [connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [connection start];
}

- (void)cancel
{
	cancelled = YES;
    [connection cancel];
    self.connection = nil;
    self.data = nil;
}

- (void)dealloc
{
    AH_RELEASE(connection);
    AH_RELEASE(data);
    AH_RELEASE(URL);
    AH_RELEASE(target);
    AH_SUPER_DEALLOC;
}

@end


@interface AsyncImageLoader ()

@property (nonatomic, strong) NSMutableArray *connections;

@end


@implementation AsyncImageLoader

@synthesize cache;
@synthesize connections;
@synthesize concurrentLoads;
@synthesize loadingTimeout;
@synthesize decompressImages;

+ (AsyncImageLoader *)sharedLoader
{
	static AsyncImageLoader *sharedInstance = nil;
	if (sharedInstance == nil)
	{
		sharedInstance = [[self alloc] init];
	}
	return sharedInstance;
}

- (AsyncImageLoader *)init
{
	if ((self = [super init]))
	{
        cache = AH_RETAIN([AsyncImageCache sharedCache]);
        concurrentLoads = 2;
        loadingTimeout = 60;
		decompressImages = NO;
		connections = [[NSMutableArray alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(imageLoaded:)
													 name:AsyncImageLoadDidFinish
												   object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(imageFailed:)
													 name:AsyncImageLoadDidFail
												   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(targetReleased:)
													 name:AsyncImageTargetReleased
												   object:nil];
	}
	return self;
}

- (void)updateQueue
{
    //start connections
    NSInteger count = 0;
    for (int i = 0; i < [connections count]; i++)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if (![connection isLoading])
        {
            if ([connection isInCache])
            {
                [connection start];
            } else {
                
                // Do not fetch a URL twice. Instead, we let the connection sit here
                // and wait for the first connection to finish.
                BOOL foundEarlier = NO;
                for (int j = 0; j < i; j++) {
                    AsyncImageConnection *otherConnection = [connections objectAtIndex:j];
                    if ([otherConnection.URL isEqual:connection.URL]) {
                        foundEarlier = YES;
                        break;
                    }
                }
                
                if (!foundEarlier && (count < concurrentLoads)) {
                    count ++;
                    [connection start];
                }
            }
        }
    }
}

- (void)imageLoaded:(NSNotification *)notification
{  
    //complete connections for URL
    NSURL *URL = [notification.userInfo objectForKey:AsyncImageURLKey];
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if (connection.URL == URL || [connection.URL isEqual:URL])
        {
            //cancel connection (in case it's a duplicate)
            [connection cancel];
            
            //perform action
			UIImage *image = [notification.userInfo objectForKey:AsyncImageImageKey];
            objc_msgSend(connection.target, connection.success, image, connection.URL);

            //remove from queue
            [connections removeObjectAtIndex:i];
        }
    }
    
    //update the queue
    [self updateQueue];
}

- (void)imageFailed:(NSNotification *)notification
{
    //remove connections for URL
    NSURL *URL = [notification.userInfo objectForKey:AsyncImageURLKey];
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if ([connection.URL isEqual:URL])
        {
            //cancel connection (in case it's a duplicate)
            [connection cancel];
            
            //perform failure action
            if (connection.failure)
            {
                NSError *error = [notification.userInfo objectForKey:AsyncImageErrorKey];
                objc_msgSend(connection.target, connection.failure, error, URL);
            }
            
            //remove from queue
            [connections removeObjectAtIndex:i];
        }
    }
    
    //update the queue
    [self updateQueue];
}

- (void)targetReleased:(NSNotification *)notification
{
    //remove connections for URL
    id target = [notification object];
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if (connection.target == target)
        {
            //cancel connection
            [connection cancel];
            [connections removeObjectAtIndex:i];
        }
    }
    
    //update the queue
    [self updateQueue];
}

- (void)loadImageWithURL:(NSURL *)URL target:(id)target success:(SEL)success failure:(SEL)failure
{
    //create new connection
    [connections addObject:[AsyncImageConnection connectionWithURL:URL
                                                             cache:cache
															target:target
														   success:success
														   failure:failure
												   decompressImage:decompressImages]];
    [self updateQueue];
}

- (void)loadImageWithURL:(NSURL *)URL target:(id)target action:(SEL)action
{
    [self loadImageWithURL:URL target:target success:action failure:NULL];
}

- (void)loadImageWithURL:(NSURL *)URL
{
    [self loadImageWithURL:URL target:nil success:NULL failure:NULL];
}

- (void)cancelLoadingURL:(NSURL *)URL target:(id)target action:(SEL)action
{
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if ([connection.URL isEqual:URL] && connection.target == target && connection.success == action)
        {
            [connection cancel];
            [connections removeObjectAtIndex:i];
        }
    }
}

- (void)cancelLoadingURL:(NSURL *)URL target:(id)target
{
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if ([connection.URL isEqual:URL] && connection.target == target)
        {
            [connection cancel];
            [connections removeObjectAtIndex:i];
        }
    }
}

- (void)cancelLoadingURL:(NSURL *)URL
{
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if ([connection.URL isEqual:URL])
        {
            [connection cancel];
            [connections removeObjectAtIndex:i];
        }
    }
}

- (void)cancelLoadingForTarget:(id)target
{
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if (connection.target == target)
        {
            [connection cancel];
            [connections removeObjectAtIndex:i];
        }
    }
}

- (NSURL *)URLForTarget:(id)target action:(SEL)action
{
    //return the most recent image URL assigned to the target
    //this is not neccesarily the next image that will be assigned
    for (int i = [connections count] - 1; i >= 0; i--)
    {
        AsyncImageConnection *connection = [connections objectAtIndex:i];
        if (connection.target == target && connection.success == action)
        {
            return AH_AUTORELEASE(AH_RETAIN(connection.URL));
        }
    }
    return nil;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
    AH_RELEASE(cache);
    AH_RELEASE(connections);
    AH_SUPER_DEALLOC;
}

@end


@implementation UIImageView(AsyncImageView)

- (void)setImageURL:(NSURL *)imageURL
{
    [[AsyncImageLoader sharedLoader] loadImageWithURL:imageURL target:self action:@selector(setImageAsync:)];
}

- (NSURL *)imageURL
{
	return [[AsyncImageLoader sharedLoader] URLForTarget:self action:@selector(setImageAsync:)];
}

@end


@interface AsyncImageView ()

@property (nonatomic, strong) UIActivityIndicatorView *activityView;

@end

BOOL defaultCrossFadeAll = YES;
BOOL defaultCrossFadeAsync = YES;
BOOL defaultActivityIndicator = YES;
BOOL loadCachedImagesSynchronously = NO;
BOOL defaultLoadOnlyMostRecentURL = NO;

@implementation AsyncImageView

@synthesize showActivityIndicator;
@synthesize activityIndicatorStyle;
@synthesize crossfadeAllImages;
@synthesize crossfadeAsyncImages;
@synthesize crossfadeDuration;
@synthesize activityView;
@synthesize loadOnlyMostRecentURL;

- (void)setUp
{
	showActivityIndicator = defaultActivityIndicator ? (self.image == nil) : NO;
	activityIndicatorStyle = UIActivityIndicatorViewStyleGray;
    crossfadeAllImages = defaultCrossFadeAll;
    crossfadeAsyncImages = defaultCrossFadeAsync;
	crossfadeDuration = 0.4;
    loadOnlyMostRecentURL = defaultLoadOnlyMostRecentURL;
}

- (id)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        [self setUp];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    if ((self = [super initWithCoder:aDecoder]))
    {
        [self setUp];
    }
    return self;
}

- (void)setImageURL:(NSURL *)imageURL
{
    if(loadOnlyMostRecentURL) [[AsyncImageLoader sharedLoader] cancelLoadingForTarget:self];
    
    if(loadCachedImagesSynchronously) {
        UIImage *img = [[AsyncImageCache sharedCache] imageForURL:imageURL];
        if(img) {
            self.image = img;
            return;
        }
    }
    
    super.imageURL = imageURL;
    if (showActivityIndicator && !self.image)
    {
        if (activityView == nil)
        {
            activityView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:activityIndicatorStyle];
            activityView.hidesWhenStopped = YES;
            activityView.center = CGPointMake(self.bounds.size.width / 2.0f, self.bounds.size.width / 2.0f);
            activityView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
            [self addSubview:activityView];
        }
        [activityView startAnimating];
    }
}

- (void)setActivityIndicatorStyle:(UIActivityIndicatorViewStyle)style
{
	activityIndicatorStyle = style;
	[activityView removeFromSuperview];
	self.activityView = nil;
}

- (void)setImage:(UIImage *)image
{
    if (crossfadeAllImages)
    {
        CATransition *animation = [CATransition animation];
        animation.type = kCATransitionFade;
        animation.duration = crossfadeDuration;
        [self.layer addAnimation:animation forKey:nil];
    }
    super.image = image;
    [activityView stopAnimating];
}

- (void)setImageAsync:(UIImage *)image
{
    if (crossfadeAsyncImages && !crossfadeAllImages) {
        CATransition *animation = [CATransition animation];
        animation.type = kCATransitionFade;
        animation.duration = crossfadeDuration;
        [self.layer addAnimation:animation forKey:nil];
    }
    self.image = image;
}

+ (void)setDefaultCrossFadeAll:(BOOL)val {
    defaultCrossFadeAll = val;
}

+ (void)setDefaultCrossFadeAsync:(BOOL)val {
    defaultCrossFadeAsync = val;
}

+ (void)setDefaultActivityIndicator:(BOOL)val {
    defaultActivityIndicator = val;
}

+ (void)setDefaultLoadOnlyMostRecentURL:(BOOL)val {
    defaultLoadOnlyMostRecentURL = val;
}

+ (void)loadCachedImagesSynchronously:(BOOL)val {
    loadCachedImagesSynchronously = val;
}

- (void)dealloc
{
    [[AsyncImageLoader sharedLoader] cancelLoadingForTarget:self];
	AH_RELEASE(activityView);
    AH_SUPER_DEALLOC;
}

@end

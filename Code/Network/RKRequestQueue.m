//
//  RKRequestQueue.m
//  RestKit
//
//  Created by Blake Watters on 12/1/10.
//  Copyright 2010 Two Toasters. All rights reserved.
//

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#import "RKRequestQueue.h"
#import "RKResponse.h"
#import "RKNotifications.h"
#import "RKClient.h"
#import "../Support/RKLog.h"

static RKRequestQueue* gSharedQueue = nil;

static const NSTimeInterval kFlushDelay = 0.3;

// Set Logging Component
#undef RKLogComponent
#define RKLogComponent lcl_cRestKitNetworkQueue

@interface RKRequestQueue (Private)

// Declare the loading count read-write
@property (nonatomic, readwrite) NSUInteger loadingCount;
@end

@implementation RKRequestQueue

@synthesize delegate = _delegate;
@synthesize concurrentRequestsLimit = _concurrentRequestsLimit;
@synthesize requestTimeout = _requestTimeout;
@synthesize suspended = _suspended;
@synthesize loadingCount = _loadingCount;

#if TARGET_OS_IPHONE
@synthesize showsNetworkActivityIndicatorWhenBusy = _showsNetworkActivityIndicatorWhenBusy;
#endif

+ (RKRequestQueue*)sharedQueue {
	if (!gSharedQueue) {
		gSharedQueue = [[RKRequestQueue alloc] init];
		gSharedQueue.suspended = NO;
        RKLogDebug(@"Shared queue initialized: %@", gSharedQueue);
	}
	return gSharedQueue;
}

+ (void)setSharedQueue:(RKRequestQueue*)requestQueue {
	if (gSharedQueue != requestQueue) {
        RKLogDebug(@"Shared queue instance changed from %@ to %@", gSharedQueue, requestQueue);
		[gSharedQueue release];
		gSharedQueue = [requestQueue retain];        
	}
}

- (id)init {
	if ((self = [super init])) {
		_requests = [[NSMutableArray alloc] init];
		_suspended = YES;
		_loadingCount = 0;
		_concurrentRequestsLimit = 5;
		_requestTimeout = 300;
        _showsNetworkActivityIndicatorWhenBusy = NO;

		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(responseDidLoad:)
													 name:RKResponseReceivedNotification
												   object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(responseDidLoad:)
													 name:RKRequestFailedWithErrorNotification
												   object:nil];
#if TARGET_OS_IPHONE
        BOOL backgroundOK = &UIApplicationDidEnterBackgroundNotification != NULL;
        if (backgroundOK) {
            [[NSNotificationCenter defaultCenter] addObserver:self 
                                                     selector:@selector(willTransitionToBackground) 
                                                         name:UIApplicationDidEnterBackgroundNotification 
                                                       object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(willTransitionToForeground)
                                                         name:UIApplicationWillEnterForegroundNotification
                                                       object:nil];
        }
#endif
	}
	return self;
}

- (void)dealloc {
    RKLogDebug(@"Queue instance is being deallocated: %@", self);
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_queueTimer invalidate];
    [_requests release];
    _requests = nil;

    [super dealloc];
}

- (NSUInteger)count {
    return [_requests count];
}

- (void)setLoadingCount:(NSUInteger)count {
    if (_loadingCount == 0 && count > 0) {
        RKLogTrace(@"Loading count increasing from 0 to %d. Firing requestQueueDidBeginLoading", count);
        
        // Transitioning from empty to processing
        if ([_delegate respondsToSelector:@selector(requestQueueDidBeginLoading:)]) {
            [_delegate requestQueueDidBeginLoading:self];
        }

#if TARGET_OS_IPHONE        
        if (self.showsNetworkActivityIndicatorWhenBusy) {
            [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
        }
#endif
    } else if (_loadingCount > 0 && count == 0) {
        RKLogTrace(@"Loading count decreasing from %d to 0. Firing requestQueueDidFinishLoading", _loadingCount);
        
        // Transition from processing to empty
        if ([_delegate respondsToSelector:@selector(requestQueueDidFinishLoading:)]) {
            [_delegate requestQueueDidFinishLoading:self];
        }
        
#if TARGET_OS_IPHONE
        if (self.showsNetworkActivityIndicatorWhenBusy) {
            [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        }
#endif
    }
    
    RKLogTrace(@"Loading count set to %d for queue %@", count, self);
    _loadingCount = count;
}

- (void)loadNextInQueueDelayed {
	if (!_queueTimer) {
		_queueTimer = [NSTimer scheduledTimerWithTimeInterval:kFlushDelay
													   target:self
													 selector:@selector(loadNextInQueue)
													 userInfo:nil
													  repeats:NO];
        RKLogDebug(@"Timer initialized with delay %f for queue %@", kFlushDelay, self);
	}
}

- (void)loadNextInQueue {
	// This makes sure that the Request Queue does not fire off any requests until the Reachability state has been determined.
	if ([[[RKClient sharedClient] baseURLReachabilityObserver] networkStatus] == RKReachabilityIndeterminate ||
        self.suspended) {
		_queueTimer = nil;
		[self loadNextInQueueDelayed];
        
        RKLogTrace(@"Deferring queue loading because of %@", self.suspended ? @"queue suspension" : @"indeterminate network condition");
		return;
	}

	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

	_queueTimer = nil;

    NSUInteger count = [_requests count];
    for (NSUInteger index = 0; index < count; index++) {
        RKRequest* request = [_requests objectAtIndex:index];
        RKLogTrace(@"Processing request %@ in queue %@", request, self);
        
		if ([request isLoading]) {
            RKLogTrace(@"Skipping request %@: currently loading.", request);
        } else if ([request isLoaded]) {
            RKLogTrace(@"Skipping request %@: already loaded.", request);
        } else if (self.loadingCount > _concurrentRequestsLimit) {
            RKLogTrace(@"Skipping request %@: Maximum concurrent request limit of %d is reached", request, self.loadingCount);
        } else {
            if ([_delegate respondsToSelector:@selector(requestQueue:willSendRequest:)]) {
                [_delegate requestQueue:self willSendRequest:request];
            }
            
            self.loadingCount = self.loadingCount + 1;
            [request sendAsynchronously];
            RKLogDebug(@"Sent request %@ from top of queue %@. Loading count = %d", request, self, self.loadingCount);

            if ([_delegate respondsToSelector:@selector(requestQueue:didSendRequest:)]) {
                [_delegate requestQueue:self didSendRequest:request];
            }
		}
	}
	
	if (_requests.count && !_suspended) {
		[self loadNextInQueueDelayed];
	}

	[pool drain];
}

- (void)setSuspended:(BOOL)isSuspended {    
    if (_suspended != isSuspended) {
        if (isSuspended) {
            RKLogDebug(@"Queue %@ has been suspended", self);
            
            // Becoming suspended
            if ([_delegate respondsToSelector:@selector(requestQueueWasSuspended:)]) {
                [_delegate requestQueueWasSuspended:self];
            }
        } else {
            RKLogDebug(@"Queue %@ has been unsuspended", self);
            
            // Becoming unsupended
            if ([_delegate respondsToSelector:@selector(requestQueueWasUnsuspended:)]) {
                [_delegate requestQueueWasUnsuspended:self];
            }
        }
    }

	_suspended = isSuspended;

	if (!_suspended) {
		[self loadNextInQueue];
	} else if (_queueTimer) {
		[_queueTimer invalidate];
		_queueTimer = nil;
	}
}

- (void)addRequest:(RKRequest*)request {
    RKLogTrace(@"Request %@ added to queue %@", request, self);
    
	[_requests addObject:request];
	[self loadNextInQueue];
}

- (BOOL)containsRequest:(RKRequest*)request {
    return [_requests containsObject:request];
}

- (void)cancelRequest:(RKRequest*)request loadNext:(BOOL)loadNext {
    if (![request isLoading]) {
        RKLogDebug(@"Canceled undispatched request %@ and removed from queue %@", request, self);
        
        [_requests removeObject:request];
        request.delegate = nil;
        
        if ([_delegate respondsToSelector:@selector(requestQueue:didCancelRequest:)]) {
            [_delegate requestQueue:self didCancelRequest:request];
        }
    } else if ([_requests containsObject:request] && ![request isLoaded]) {
        RKLogDebug(@"Canceled loading request %@ and removed from queue %@", request, self);
        
		[request cancel];
		request.delegate = nil;
        
        if ([_delegate respondsToSelector:@selector(requestQueue:didCancelRequest:)]) {
            [_delegate requestQueue:self didCancelRequest:request];
        }

		[_requests removeObject:request];
		self.loadingCount = self.loadingCount - 1;
		
		if (loadNext) {
			[self loadNextInQueue];
		}
	}
}

- (void)cancelRequest:(RKRequest*)request {
	[self cancelRequest:request loadNext:YES];
}

- (void)cancelRequestsWithDelegate:(NSObject<RKRequestDelegate>*)delegate {
    RKLogDebug(@"Cancelling all request in queue %@ with delegate %@", self, delegate);
    
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	NSArray* requestsCopy = [NSArray arrayWithArray:_requests];
	for (RKRequest* request in requestsCopy) {
		if (request.delegate && request.delegate == delegate) {
			[self cancelRequest:request];
		}
	}
	[pool drain];
}

- (void)cancelAllRequests {
    RKLogDebug(@"Cancelling all request in queue %@", self);
    
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	NSArray* requestsCopy = [NSArray arrayWithArray:_requests];
	for (RKRequest* request in requestsCopy) {
		[self cancelRequest:request loadNext:NO];
	}
	[pool drain];
}

- (void)start {
    RKLogDebug(@"Started queue %@", self);
    [self setSuspended:NO];
}

/**
 * Invoked via observation when a request has loaded a response. Remove
 * the completed request from the queue and continue processing
 */
- (void)responseDidLoad:(NSNotification*)notification {
	  if (notification.object) {
        
        // Get the RKRequest, so we can check if it is from this RKRequestQueue
        RKRequest *request = nil;
        if ([notification.object isKindOfClass:[RKResponse class]]) {
			      request = [(RKResponse*)notification.object request];
        } else if ([notification.object isKindOfClass:[RKRequest class]]) {
            request = (RKRequest*)notification.object;
        }
        
		// Our RKRequest completed and we're notified with an RKResponse object
        if (request != nil && [self containsRequest:request]) { 
            if ([notification.object isKindOfClass:[RKResponse class]]) {
                RKLogTrace(@"Received response for request %@, removing from queue.", request);
                
                [_requests removeObject:request];
                self.loadingCount = self.loadingCount - 1;
                
                if ([_delegate respondsToSelector:@selector(requestQueue:didLoadResponse:)]) {
                    [_delegate requestQueue:self didLoadResponse:(RKResponse*)notification.object];
                }
				
				// Our RKRequest failed and we're notified with the original RKRequest object
            } else if ([notification.object isKindOfClass:[RKRequest class]]) {
                RKLogTrace(@"Received failure notification for request %@, removing from queue.", request);
                
                [_requests removeObject:request];
                self.loadingCount = self.loadingCount - 1;
                
                NSDictionary* userInfo = [notification userInfo];
                NSError* error = nil;
                if (userInfo) {
                    error = [userInfo objectForKey:@"error"];
                    RKLogDebug(@"Request %@ failed loading in queue %@ with error: %@", request, self, [error localizedDescription]);
                }
                
                if ([_delegate respondsToSelector:@selector(requestQueue:didFailRequest:withError:)]) {
                    [_delegate requestQueue:self didFailRequest:request withError:error];
                }
            }
			
            [self loadNextInQueue];
        } else {
            RKLogWarning(@"Request queue %@ received unexpected lifecycle notification for request %@: Request not found in queue.", self, request);
        }
	}
}

#pragma mark - Background Request Support

- (void)willTransitionToBackground {
    RKLogDebug(@"App is transitioning into background, suspending queue");
    
    // Suspend the queue so background requests do not trigger additional requests on state changes
    self.suspended = YES;
}

- (void)willTransitionToForeground {
    RKLogDebug(@"App returned from background, unsuspending queue");
    
    self.suspended = NO;
}

@end

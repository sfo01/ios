//
//  DDGStoriesViewController.m
//  DuckDuckGo
//
//  Created by Johnnie Walker on 06/03/2013.
//
//

#import "DDGStoriesViewController.h"
#import "DDGUnderViewController.h"
#import "DDGSettingsViewController.h"
#import "DDGPanGestureRecognizer.h"
#import "DDGStory.h"
#import "DDGStoryFeed.h"
#import "DDGStoryCell.h"
#import "NSArray+ConcurrentIteration.h"
#import "DDGHistoryProvider.h"
#import "DDGBookmarksProvider.h"
#import "SVProgressHUD.h"
#import "AFNetworking.h"
#import "DDGActivityViewController.h"
#import "DDGStoryFetcher.h"
#import "DDGSafariActivity.h"
#import "DDGActivityItemProvider.h"
#import <CoreImage/CoreImage.h>
#import "DDGTableView.h"

NSString *const DDGLastViewedStoryKey = @"last_story";
CGFloat const DDGStoriesInterRowSpacing = 10;
CGFloat const DDGStoriesBetweenItemsSpacing = 10;
CGFloat const DDGStoriesMulticolumnWidthThreshold = 500;
CGFloat const DDGStoryImageRatio = 2.08f;  //1.597f = measured from iPhone screenshot; 1.36f = measured from iPad screenshot
CGFloat const DDGStoryImageRatioMosaic = 1.356f;

NSTimeInterval const DDGMinimumRefreshInterval = 30;

NSInteger const DDGLargeImageViewTag = 1;

@interface DDGStoriesViewController () {
    BOOL isRefreshing;
    EGORefreshTableHeaderView *refreshHeaderView;
    CIContext *_blurContext;
}
@property (nonatomic, readwrite, strong) NSManagedObjectContext *managedObjectContext;
@property (strong, nonatomic) NSFetchedResultsController *fetchedResultsController;
@property (nonatomic, strong) NSOperationQueue *imageDownloadQueue;
@property (nonatomic, strong) NSOperationQueue *imageDecompressionQueue;
@property (nonatomic, strong) NSMutableSet *enqueuedDownloadOperations;
@property (nonatomic, strong) NSIndexPath *swipeViewIndexPath;
@property (nonatomic, strong) DDGPanGestureRecognizer *panLeftGestureRecognizer;
@property (nonatomic, strong) IBOutlet UICollectionView *storyView;
@property (strong, nonatomic) IBOutlet UIView *swipeView;
@property (nonatomic, weak) IBOutlet UIButton *swipeViewSaveButton;
@property (nonatomic, weak) IBOutlet UIButton *swipeViewSafariButton;
@property (nonatomic, weak) IBOutlet UIButton *swipeViewShareButton;
@property (nonatomic, readwrite, weak) id <DDGSearchHandler> searchHandler;
@property (nonatomic, strong) DDGStoryFeed *sourceFilter;
@property (nonatomic, strong) NSMutableDictionary *decompressedImages;
@property (nonatomic, strong) NSMutableSet *enqueuedDecompressionOperations;
@property (nonatomic, strong) DDGStoryFetcher *storyFetcher;
@property (nonatomic, strong) DDGHistoryProvider *historyProvider;
@end



#pragma mark DDGStoriesLayout

static NSString * const DDGStoriesLayoutKind = @"PhotoCell";


@interface DDGStoriesLayout : UICollectionViewLayout
@property (nonatomic, weak) DDGStoriesViewController* storiesController;
@property BOOL mosaicMode;
@property (nonatomic, strong) NSDictionary *layoutInfo;

@end


@implementation DDGStoriesLayout

- (id)init
{
    self = [super init];
    if (self) {
        [self setup];
    }
    
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super init];
    if (self) {
        [self setup];
    }
    
    return self;
}

- (void)setup
{
    self.mosaicMode = TRUE;
}

- (void)prepareLayout
{
    NSMutableDictionary *newLayoutInfo = [NSMutableDictionary dictionary];
    NSMutableDictionary *cellLayoutInfo = [NSMutableDictionary dictionary];
    
    NSInteger sectionCount = [self.collectionView numberOfSections];
    
    for (NSInteger section = 0; section < sectionCount; section++) {
        NSInteger itemCount = [self.collectionView numberOfItemsInSection:section];
        
        for (NSInteger item = 0; item < itemCount; item++) {
            NSIndexPath* indexPath = [NSIndexPath indexPathForItem:item inSection:0];
            UICollectionViewLayoutAttributes* itemAttributes =
            [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:indexPath];
            itemAttributes.frame = [self frameForStoryAtIndexPath:indexPath];
            
            cellLayoutInfo[indexPath] = itemAttributes;
        }
    }
    
    newLayoutInfo[DDGStoriesLayoutKind] = cellLayoutInfo;
    
    self.layoutInfo = newLayoutInfo;
}


CGFloat DDG_rowHeightWithContainerSize(CGSize size) {
    BOOL mosaicMode = size.width >= DDGStoriesMulticolumnWidthThreshold;
    CGFloat rowHeight;
    if(mosaicMode) { // set to the height of the larger story
        rowHeight = ((size.width - DDGStoriesBetweenItemsSpacing)*2/3) / DDGStoryImageRatioMosaic;
    } else { // set to the height
        rowHeight = size.width / DDGStoryImageRatio;
    }
    return MAX(10.0f, rowHeight); // a little safety
}

- (CGSize)collectionViewContentSize
{
    NSUInteger numStories = [self.collectionView numberOfItemsInSection:0];
    CGSize size = self.collectionView.frame.size;
    self.mosaicMode = size.width >= DDGStoriesMulticolumnWidthThreshold;
    NSUInteger cellsPerRow = self.mosaicMode ? 3 : 1;
    CGFloat rowHeight = DDG_rowHeightWithContainerSize(size);
    NSUInteger numRows = numStories/3;
    if(numStories%cellsPerRow!=0) numRows++;
    size.height = rowHeight * numRows;
    return size;
}



- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect
{
    NSMutableArray* elementAttributes = [NSMutableArray new];
    CGSize size = self.collectionView.frame.size;
    BOOL mosaicMode = size.width >= DDGStoriesMulticolumnWidthThreshold;
    CGFloat rowHeight = DDG_rowHeightWithContainerSize(size);
    
    NSUInteger cellsPerRow = mosaicMode ? 3 : 1;
    NSUInteger rowsBeforeRect = floor(rect.origin.y / rowHeight);
    NSUInteger rowsWithinRect = ceil((rect.origin.y+rect.size.height) / rowHeight) - rowsBeforeRect + 1;
    
    for(NSUInteger row = rowsBeforeRect; row < rowsBeforeRect + rowsWithinRect; row++) {
        for(NSUInteger column = 0 ; column < cellsPerRow; column++) {
            NSUInteger storyIndex = row * cellsPerRow + column;
            if(storyIndex >= [self.collectionView numberOfItemsInSection:0]) break;
            UICollectionViewLayoutAttributes* attributes = [self layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:storyIndex inSection:0]];
            [elementAttributes addObject:attributes];
        }
    }
    return elementAttributes;
}


- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewLayoutAttributes *itemAttributes = [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:indexPath];
    itemAttributes.frame = [self frameForStoryAtIndexPath:indexPath];
    return itemAttributes;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds
{
    return TRUE; // re-layout for all bounds changes
}

- (CGRect)frameForStoryAtIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger row = indexPath.item;
    if(row==NSNotFound) return CGRectZero;
    row = row / (self.mosaicMode ? 3 : 1);
    NSInteger column = indexPath.item % (self.mosaicMode ? 3 : 1);
    CGSize frameSize = self.collectionView.frame.size;
    CGFloat rowHeight = DDG_rowHeightWithContainerSize(frameSize);
    CGFloat rowWidth = frameSize.width;
    BOOL oddRow = (row % 2) == 1;
    
    CGRect storyRect = CGRectMake(0, row * rowHeight + DDGStoriesInterRowSpacing,
                                  rowWidth, rowHeight - DDGStoriesInterRowSpacing);
    if(self.mosaicMode) {
        if(oddRow) {
            if(column==0) { // top left of three
                storyRect.size.width = (rowWidth - DDGStoriesBetweenItemsSpacing)/3;
                storyRect.size.height = (rowHeight - DDGStoriesBetweenItemsSpacing*2)/2;
            } else if(column==1) { // bottom left of three
                storyRect.size.width = (rowWidth - DDGStoriesBetweenItemsSpacing)/3;
                storyRect.size.height = (rowHeight - DDGStoriesBetweenItemsSpacing*2)/2;
                storyRect.origin.y += rowHeight - storyRect.size.height - DDGStoriesBetweenItemsSpacing;
            } else { // if(column==2) // the large right-side story
                storyRect.size.width = (rowWidth - DDGStoriesBetweenItemsSpacing)*2/3;
                storyRect.origin.x += rowWidth - storyRect.size.width;
            }
        } else { // even row
            if(column==1) { // top right of three
                storyRect.size.width = (rowWidth - DDGStoriesBetweenItemsSpacing)/3;
                storyRect.size.height = (rowHeight - DDGStoriesBetweenItemsSpacing*2)/2;
                storyRect.origin.x += rowWidth - storyRect.size.width;
            } else if(column==2) { // bottom right of three
                storyRect.size.width = (rowWidth - DDGStoriesBetweenItemsSpacing)/3;
                storyRect.size.height = (rowHeight - DDGStoriesBetweenItemsSpacing*2)/2;
                storyRect.origin.y += rowHeight - storyRect.size.height - DDGStoriesBetweenItemsSpacing;
                storyRect.origin.x += rowWidth - storyRect.size.width;
            } else { // if(column==0) // the large left-side story
                storyRect.size.width = (rowWidth - DDGStoriesBetweenItemsSpacing)*2/3;
            }
        }
    } else { // not a mosaic
        // the defaults are good enough
    }
    //NSLog(@"item %lu:  frame: %@", indexPath.item, NSStringFromCGRect(storyRect));

    return storyRect;
}


@end




#pragma mark DDGStoriesViewController


@implementation DDGStoriesViewController

#pragma mark - Memory Management

- (id)initWithSearchHandler:(id <DDGSearchHandler>)searchHandler managedObjectContext:(NSManagedObjectContext *)managedObjectContext;
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.title = NSLocalizedString(@"Stories", @"View controller title: Stories");
        self.searchHandler = searchHandler;
        self.managedObjectContext = managedObjectContext;
        
        //Create the context where the blur is going on.
        EAGLContext *eaglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        [options setObject: [NSNull null] forKey: kCIContextWorkingColorSpace];
        _blurContext = [CIContext contextWithEAGLContext:eaglContext options:options];
    }
    return self;
}

- (void)dealloc
{
    [self.imageDownloadQueue cancelAllOperations];
    self.imageDownloadQueue = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DDGSlideOverMenuWillAppearNotification
                                                  object:nil];
}

- (DDGHistoryProvider *)historyProvider {
    if (nil == _historyProvider) {
        _historyProvider = [[DDGHistoryProvider alloc] initWithManagedObjectContext:self.managedObjectContext];
    }
    
    return _historyProvider;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    NSMutableDictionary *cachedImages = [NSMutableDictionary new];
    NSArray *indexPaths = [self.storyView indexPathsForVisibleItems];
    for (NSIndexPath *indexPath in indexPaths) {
        DDGStory *story = [self.fetchedResultsController objectAtIndexPath:indexPath];
        if (story) {
            UIImage *image = [self.decompressedImages objectForKey:story.cacheKey];
            if (image) {
                [cachedImages setObject:image forKey:story.cacheKey];
            }
        }
    }
    [self.decompressedImages removeAllObjects];
    [self.decompressedImages addEntriesFromDictionary:cachedImages];
    
    if (nil == self.view) {
        [self.imageDownloadQueue cancelAllOperations];
        [self.enqueuedDownloadOperations removeAllObjects];
        [self.imageDecompressionQueue cancelAllOperations];
        [self.enqueuedDecompressionOperations removeAllObjects];
    }
}

- (void)reenableScrollsToTop {
    self.storyView.scrollsToTop = YES;
}

#pragma mark - No Stories

- (void)showNoStoriesView {
    if (nil == self.noStoriesView) {
        [[NSBundle mainBundle] loadNibNamed:@"NoStoriesView" owner:self options:nil];
        UIImageView *largeImageView = (UIImageView *)[self.noStoriesView viewWithTag:DDGLargeImageViewTag];
        largeImageView.image = [UIImage imageNamed:@"NoFavorites"];
    }
    
    [UIView animateWithDuration:0 animations:^{
        [self.storyView removeFromSuperview];
        self.noStoriesView.frame = self.view.bounds;
        [self.view addSubview:self.noStoriesView];
    }];
}

- (void)hideNoStoriesView {
    if (nil == self.storyView.superview) {
        [UIView animateWithDuration:0 animations:^{
            [self.noStoriesView removeFromSuperview];
            self.noStoriesView = nil;
            self.storyView.frame = self.view.bounds;
            [self.view addSubview:self.storyView];
        }];        
    }
}

#pragma mark - UIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    DDGStoriesLayout* storyLayout = [[DDGStoriesLayout alloc] init];
    storyLayout.storiesController = self;
    UICollectionView* storyView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:storyLayout];
    storyView.backgroundColor = [UIColor duckNoContentColor];
    storyView.dataSource = self;
    storyView.delegate = self;
    storyView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [storyView registerClass:DDGStoryCell.class forCellWithReuseIdentifier:DDGStoryCellIdentifier];
    
    [self.view addSubview:storyView];
    self.storyView = storyView;
    
    self.fetchedResultsController = [self fetchedResultsController:[[NSUserDefaults standardUserDefaults] objectForKey:DDGStoryFetcherStoriesLastUpdatedKey]];
    
    [self prepareUpcomingCellContent];
    
    if (!self.savedStoriesOnly && refreshHeaderView == nil) {
		refreshHeaderView = [[EGORefreshTableHeaderView alloc] initWithFrame:CGRectMake(0.0f, 0.0f - self.storyView.bounds.size.height, self.view.frame.size.width, self.storyView.bounds.size.height)];
		refreshHeaderView.backgroundColor = [UIColor duckSearchBarBackground];
        refreshHeaderView.delegate = self;
		[self.storyView addSubview:refreshHeaderView];
        [refreshHeaderView refreshLastUpdatedDate];
	}
	
    [refreshHeaderView refreshLastUpdatedDate];
        
    //    // force-decompress the first 10 images
    //    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
    //        NSArray *stories = self.stories;
    //        for(int i=0;i<MIN(stories.count, 10);i++)
    //            [[stories objectAtIndex:i] prefetchAndDecompressImage];
    //    });
        
    DDGPanGestureRecognizer* panLeftGestureRecognizer = [[DDGPanGestureRecognizer alloc] initWithTarget:self action:@selector(panLeft:)];
    panLeftGestureRecognizer.maximumNumberOfTouches = 1;
    
    self.panLeftGestureRecognizer = panLeftGestureRecognizer;
    [[self.slideOverMenuController panGesture] requireGestureRecognizerToFail:panLeftGestureRecognizer];
    
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 2;
    queue.name = @"DDG Watercooler Image Download Queue";
    self.imageDownloadQueue = queue;
    
    NSOperationQueue *decompressionQueue = [NSOperationQueue new];
    decompressionQueue.name = @"DDG Watercooler Image Decompression Queue";
    self.imageDecompressionQueue = decompressionQueue;
    
    self.decompressedImages = [NSMutableDictionary new];
    
    self.enqueuedDownloadOperations = [NSMutableSet new];
    self.enqueuedDecompressionOperations = [NSMutableSet set];    
}

- (void)viewDidUnload {
    [self setSwipeView:nil];
    [super viewDidUnload];
    
    self.decompressedImages = nil;
    
    [self.imageDownloadQueue cancelAllOperations];
    self.imageDownloadQueue = nil;
    [self.imageDecompressionQueue cancelAllOperations];
    self.imageDecompressionQueue = nil;
    self.enqueuedDownloadOperations = nil;
    self.enqueuedDecompressionOperations = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DDGSlideOverMenuWillAppearNotification
                                                  object:nil];
    // Release any retained subviews of the main view.
    // e.g. self.myOutlet = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    NSNumber *lastStoryID = [[NSUserDefaults standardUserDefaults] objectForKey:DDGLastViewedStoryKey];
    if (nil != lastStoryID) {
        NSArray *stories = self.fetchedResultsController.fetchedObjects;
        NSArray *storyIDs = [stories valueForKey:@"id"];
        NSInteger index = [storyIDs indexOfObject:lastStoryID];
        if (index != NSNotFound) {
            [self focusOnStory:[stories objectAtIndex:index] animated:NO];
        }
    }
    
    if (!self.savedStoriesOnly) {
        if ([self shouldRefresh]) {
            [self refreshStoriesTriggeredManually:NO includeSources:YES];
        }
    } else if ([self.fetchedResultsController.fetchedObjects count] == 0) {
        [self showNoStoriesView];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    // if we animated out, animate back in
    if(_storyView.alpha == 0) {
        _storyView.transform = CGAffineTransformMakeScale(2, 2);
        [UIView animateWithDuration:0.3 animations:^{
            _storyView.alpha = 1;
            _storyView.transform = CGAffineTransformIdentity;
        }];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(slidingViewUnderLeftWillAppear:)
                                                 name:DDGSlideOverMenuWillAppearNotification
                                               object:nil];
    
    [self.storyView addGestureRecognizer:self.panLeftGestureRecognizer];
}

- (void)viewWillDisappear:(BOOL)animated
{
    if (nil != self.swipeViewIndexPath)
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DDGSlideOverMenuWillAppearNotification
                                                  object:nil];
    
    [self.storyView removeGestureRecognizer:self.panLeftGestureRecognizer];
	[super viewWillDisappear:animated];
    
    [self.imageDownloadQueue cancelAllOperations];
    [self.enqueuedDownloadOperations removeAllObjects];
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
	if (IPHONE)
	    return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
	else
        return YES;
}

#pragma mark - Filtering

#ifndef __clang_analyzer__
- (IBAction)filter:(id)sender {
    
    void (^completion)() = ^() {
        DDGStory *story = nil;
        
        if ([sender isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)sender;
            CGPoint point = [button convertPoint:button.bounds.origin toView:self.storyView];
            NSIndexPath *indexPath = [self.storyView indexPathForItemAtPoint:point];
            story = [self.fetchedResultsController objectAtIndexPath:indexPath];
        }
        
        if (nil != self.sourceFilter) {
            self.sourceFilter = nil;
        } else if ([sender isKindOfClass:[UIButton class]]) {
            self.sourceFilter = story.feed;
        }

        NSPredicate *predicate = nil;
        if (nil != self.sourceFilter)
            predicate = [NSPredicate predicateWithFormat:@"feed == %@", self.sourceFilter];

        NSArray *oldStories = [self.fetchedResultsController fetchedObjects];
        
        [NSFetchedResultsController deleteCacheWithName:self.fetchedResultsController.cacheName];
        self.fetchedResultsController.delegate = nil;
        self.fetchedResultsController = nil;
        
        NSDate *feedDate = [[NSUserDefaults standardUserDefaults] objectForKey:DDGStoryFetcherStoriesLastUpdatedKey];
        self.fetchedResultsController = [self fetchedResultsController:feedDate];
        
        NSArray *newStories = [self.fetchedResultsController fetchedObjects];
        
        [self replaceStories:oldStories withStories:newStories focusOnStory:story];
    };
    
    if (nil != self.swipeViewIndexPath)
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:completion];
    else
        completion();
}
#endif

-(NSArray *)indexPathsofStoriesInArray:(NSArray *)newStories andNotArray:(NSArray *)oldStories {
    NSMutableArray *indexPaths = [NSMutableArray arrayWithCapacity:[newStories count]];
    
    for(int i=0; i<newStories.count; i++) {
        DDGStory *story = [newStories objectAtIndex:i];
        NSString *storyID = story.id;
        
        BOOL matchFound = NO;
        for(DDGStory *oldStory in oldStories) {
            if([storyID isEqualToString:[oldStory id]]) {
                matchFound = YES;
                break;
            }
        }
        
        if(!matchFound) {
            [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
        }
    }
    return [indexPaths copy];
}

- (NSInteger)replaceStories:(NSArray *)oldStories withStories:(NSArray *)newStories focusOnStory:(DDGStory *)story {
    
    NSArray *addedStories = [self indexPathsofStoriesInArray:newStories andNotArray:oldStories];
    NSArray *removedStories = [self indexPathsofStoriesInArray:oldStories andNotArray:newStories];
    NSInteger changes = [addedStories count] + [removedStories count];
    
    // update the table view with added and removed stories
    //[self.storyView beginUpdates];
    
//    if(removedStories.count > 0) {
//        [self.storyView deleteItemsAtIndexPaths:removedStories];
//    }
//    if(addedStories.count > 0) {
//        [self.storyView insertItemsAtIndexPaths:addedStories];
//    }
    NSLog(@"updating with %lu deleted items and %lu new items", removedStories.count, addedStories.count);
    [self.storyView reloadSections:[NSIndexSet indexSetWithIndex:0]];

    if (self.savedStoriesOnly && [self.fetchedResultsController.fetchedObjects count] == 0) {
        [self showNoStoriesView];
    } else {
        [self hideNoStoriesView];
    }
    
    [self focusOnStory:story animated:YES];
    
    return changes;
}


#pragma mark - Search handler

-(void)searchControllerLeftButtonPressed
{
    [self.slideOverMenuController showMenu];
}

-(void)loadQueryOrURL:(NSString *)queryOrURL
{
    [(DDGUnderViewController *)[self.slideOverMenuController menuViewController] loadQueryOrURL:queryOrURL];
}

#pragma mark - Swipe View

- (IBAction)openInSafari:(id)sender {
    if (nil == self.swipeViewIndexPath)
        return;
    
    NSArray *stories = self.fetchedResultsController.fetchedObjects;
    DDGStory *story = [stories objectAtIndex:self.swipeViewIndexPath.item];
    
    
    double delayInSeconds = 0.2;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
        
        NSURL *storyURL = story.URL;
        
        if (nil == storyURL)
            return;
        
        [[UIApplication sharedApplication] openURL:storyURL];
    });
}

- (void)save:(id)sender {
    if (nil == self.swipeViewIndexPath)
        return;
    
    DDGStory *story = [self.fetchedResultsController objectAtIndexPath:self.swipeViewIndexPath];
    
    double delayInSeconds = 0.2;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:^{
            story.savedValue = !story.savedValue;
            NSManagedObjectContext *context = story.managedObjectContext;
            [context performBlock:^{
                NSError *error = nil;
                if (![context save:&error])
                    NSLog(@"error: %@", error);
            }];
            NSString *status = story.savedValue ? NSLocalizedString(@"Added", @"Bookmark Activity Confirmation: Saved") : NSLocalizedString(@"Removed", @"Bookmark Activity Confirmation: Unsaved");
            UIImage *image = story.savedValue ? [[UIImage imageNamed:@"FavoriteSolid"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : [[UIImage imageNamed:@"UnfavoriteSolid"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            [SVProgressHUD showImage:image status:status];
        }];
    });    
}

- (void)share:(id)sender {
    if (nil == self.swipeViewIndexPath)
        return;
    
    DDGStory *story = [self.fetchedResultsController objectAtIndexPath:self.swipeViewIndexPath];
    
    double delayInSeconds = 0.2;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:^{
            NSString *shareTitle = story.title;
            NSURL *shareURL = story.URL;
            
            DDGActivityItemProvider *titleProvider = [[DDGActivityItemProvider alloc] initWithPlaceholderItem:[shareURL absoluteString]];
            [titleProvider setItem:[NSString stringWithFormat:@"%@: %@\n\nvia DuckDuckGo for iOS\n", shareTitle, shareURL] forActivityType:UIActivityTypeMail];
            
            DDGSafariActivityItem *urlItem = [DDGSafariActivityItem safariActivityItemWithURL:shareURL];            
            NSArray *items = @[titleProvider, urlItem];
            
            DDGActivityViewController *avc = [[DDGActivityViewController alloc] initWithActivityItems:items applicationActivities:@[]];
            [self presentViewController:avc animated:YES completion:NULL];
        }];
    });
}

- (void)slidingViewUnderLeftWillAppear:(NSNotification *)notification {
    if (nil != self.swipeViewIndexPath)
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:DDGLastViewedStoryKey];
}

- (void)hideSwipeViewForIndexPath:(NSIndexPath *)indexPath completion:(void (^)())completion {
    UICollectionViewCell* cell = [self.storyView cellForItemAtIndexPath:indexPath];
    self.swipeViewIndexPath = nil;
    
    UIView *swipeView = self.swipeView;
    self.swipeView = nil;
    
    [UIView animateWithDuration:0.1
                     animations:^{
                         cell.contentView.frame = swipeView.frame;
                     } completion:^(BOOL finished) {
                         [swipeView removeFromSuperview];
                         if (NULL != completion)
                             completion();
                     }];
    
    [[self.slideOverMenuController panGesture] setEnabled:YES];
}

- (void)insertSwipeViewForIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell* cell = [self.storyView cellForItemAtIndexPath:indexPath];
    if (cell) {
        UIView *behindView = cell.contentView;
        CGRect swipeFrame = behindView.frame;
        if (!self.swipeView) {
            [[NSBundle mainBundle] loadNibNamed:@"HomeSwipeView" owner:self options:nil];
        }
        [self.swipeView setTintColor:[UIColor whiteColor]];
        DDGStory *story = [self.fetchedResultsController objectAtIndexPath:indexPath];
        BOOL saved = story.savedValue;
        NSString *imageName = (saved) ? @"Unfavorite" : @"Favorite";
        [self.swipeViewSafariButton setImage:[[UIImage imageNamed:@"Safari"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                                    forState:UIControlStateNormal];
        [self.swipeViewSaveButton setImage:[[UIImage imageNamed:imageName] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                                  forState:UIControlStateNormal];
        [self.swipeViewShareButton setImage:[[UIImage imageNamed:@"ShareSwipe"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                                   forState:UIControlStateNormal];
        self.swipeView.frame = swipeFrame;
        [behindView.superview insertSubview:self.swipeView belowSubview:behindView];
        self.swipeViewIndexPath = indexPath;
    }
}

- (void)showSwipeViewForIndexPath:(NSIndexPath *)indexPath {
    
    UICollectionViewCell* cell = [self.storyView cellForItemAtIndexPath:indexPath];
    
    void(^completion)() = ^() {
        if (nil != cell) {
            UIView *behindView = cell.contentView;
            CGRect swipeFrame = behindView.frame;
            [self insertSwipeViewForIndexPath:indexPath];
            [UIView animateWithDuration:0.2
                             animations:^{
                                 behindView.frame = CGRectMake(swipeFrame.origin.x - swipeFrame.size.width,
                                                               swipeFrame.origin.y,
                                                               swipeFrame.size.width,
                                                               swipeFrame.size.height);
                             }];
        }
    };
    
    if (nil != self.swipeViewIndexPath) {
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:completion];
    } else {
        completion();
    }
}

// Called when a left swipe occurred

- (void)panLeft:(DDGPanGestureRecognizer *)recognizer {
    
    if (recognizer.state == UIGestureRecognizerStateFailed) {
        
    } else if (recognizer.state == UIGestureRecognizerStateEnded
               || recognizer.state == UIGestureRecognizerStateCancelled) {
        
        if (nil != self.swipeViewIndexPath) {
            UICollectionViewCell* cell = [self.storyView cellForItemAtIndexPath:self.swipeViewIndexPath];
            CGPoint origin = self.swipeView.frame.origin;
            CGRect contentFrame = cell.contentView.frame;
            CGFloat offset = origin.x - contentFrame.origin.x;
            CGFloat percent = offset / contentFrame.size.width;
            
            CGPoint velocity = [recognizer velocityInView:recognizer.view];
            
            [[self.slideOverMenuController panGesture] setEnabled:NO];
            
            if (velocity.x < 0 && percent > 0.25) {
                CGFloat distanceRemaining = contentFrame.size.width - offset;
                CGFloat duration = MIN(distanceRemaining / fabs(velocity.x), 0.4);
                [UIView animateWithDuration:duration
                                 animations:^{
                                     cell.contentView.frame = CGRectMake(origin.x - contentFrame.size.width,
                                                                         contentFrame.origin.y,
                                                                         contentFrame.size.width,
                                                                         contentFrame.size.height);
                                 }];
                
            } else {
                [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
            }
        }
        
    } else if (recognizer.state == UIGestureRecognizerStateChanged) {
        CGPoint location = [recognizer locationInView:self.storyView];
        NSIndexPath *indexPath = [self.storyView indexPathForItemAtPoint:location];
        
        if (nil != self.swipeViewIndexPath
            && ![self.swipeViewIndexPath isEqual:indexPath]) {
            [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
        }
        
        if (nil == self.swipeViewIndexPath) {
            [self insertSwipeViewForIndexPath:indexPath];
        }
        
        DDGStoryCell *cell = (DDGStoryCell *)[self.storyView cellForItemAtIndexPath:self.swipeViewIndexPath];
        CGPoint translation = [recognizer translationInView:recognizer.view];
        
        CGPoint center = cell.contentView.center;
        cell.contentView.center = CGPointMake(center.x + translation.x, center.y);
        
        [recognizer setTranslation:CGPointZero inView:recognizer.view];
    }
    
}

#pragma mark - Scroll view delegate

- (void)prepareUpcomingCellContent {
    NSArray *stories = [self.fetchedResultsController fetchedObjects];
    NSInteger count = [stories count];
    
    NSInteger lowestIndex = count;
    NSInteger highestIndex = 0;
    
    for (NSIndexPath *indexPath in [self.storyView indexPathsForVisibleItems]) {
        lowestIndex = MIN(lowestIndex, indexPath.item);
        highestIndex = MAX(highestIndex, indexPath.item);
    }
    
    lowestIndex = MAX(0, lowestIndex-2);
    highestIndex = MIN(count, highestIndex+3);
    
    for (NSInteger i = lowestIndex; i<highestIndex; i++) {
        DDGStory *story = [stories objectAtIndex:i];
        UIImage *decompressedImage = [self.decompressedImages objectForKey:story.cacheKey];
        
        if (nil == decompressedImage) {
            if (story.isImageDownloaded) {
                [self decompressAndDisplayImageForStory:story];
            } else  {
                [self.storyFetcher downloadImageForStory:story];
            }
        }
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    
    if (nil != self.swipeViewIndexPath)
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
    
    if(scrollView.contentOffset.y <= 0) {
        [refreshHeaderView egoRefreshScrollViewDidScroll:scrollView];
    }
    
    [self prepareUpcomingCellContent];
}

-(void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    [refreshHeaderView egoRefreshScrollViewDidEndDragging:scrollView];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (nil != self.swipeViewIndexPath)
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
}

#pragma mark - EGORefreshTableHeaderDelegate Methods

- (void)egoRefreshTableHeaderDidTriggerRefresh:(EGORefreshTableHeaderView*)view {
    [self refreshStoriesTriggeredManually:YES includeSources:NO];
}

- (BOOL)egoRefreshTableHeaderDataSourceIsLoading:(EGORefreshTableHeaderView*)view {
    return isRefreshing;
}

- (NSDate*)egoRefreshTableHeaderDataSourceLastUpdated:(EGORefreshTableHeaderView*)view {
    return [[NSUserDefaults standardUserDefaults] objectForKey:DDGStoryFetcherStoriesLastUpdatedKey];;
}

#pragma mark - collection view data source

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)collectionView
{
    return 1; //[[self.fetchedResultsController sections] count];
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section
{
    id <NSFetchedResultsSectionInfo> sectionInfo = [self.fetchedResultsController sections][section];
    return [sectionInfo numberOfObjects];
}

- (UICollectionViewCell*)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    DDGStoryCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:DDGStoryCellIdentifier forIndexPath:indexPath];
    if (!cell) {
        cell = [DDGStoryCell new];
    }
    [self configureCell:cell atIndexPath:indexPath];
	return cell;
}

#pragma  mark - collection view delegate

-(BOOL)collectionView:(UICollectionView *)collectionView shouldSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    if (nil != self.swipeViewIndexPath) {
        [self hideSwipeViewForIndexPath:self.swipeViewIndexPath completion:NULL];
        return FALSE;
    }
    
    return TRUE;
}

-(void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    DDGStory *story = [self.fetchedResultsController objectAtIndexPath:indexPath];

    story.readValue = YES;
    
    [[NSUserDefaults standardUserDefaults] setObject:story.id forKey:DDGLastViewedStoryKey];
    
    NSInteger readabilityMode = [[NSUserDefaults standardUserDefaults] integerForKey:DDGSettingStoriesReadabilityMode];
    [self.searchHandler loadStory:story readabilityMode:(readabilityMode == DDGReadabilityModeOnExclusive || readabilityMode == DDGReadabilityModeOnIfAvailable)];
    
    [self.historyProvider logStory:story];
    
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
}

#pragma mark - Loading popular stories

- (BOOL)shouldRefresh
{
    NSDate *lastAttempt = (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:DDGLastRefreshAttemptKey];
    if (lastAttempt) {
        NSTimeInterval timeInterval = [[NSDate date] timeIntervalSinceDate:lastAttempt];
        return (timeInterval > DDGMinimumRefreshInterval);
    }
    return YES;
}

- (void)decompressAndDisplayImageForStory:(DDGStory *)story;
{
    if (nil == story.image || nil == story.cacheKey)
        return;
    
    NSString *cacheKey = story.cacheKey;
    
    if ([self.enqueuedDecompressionOperations containsObject:cacheKey])
        return;
    
    __weak DDGStoriesViewController *weakSelf = self;
    
    void (^completionBlock)() = ^() {
        NSIndexPath *indexPath = [weakSelf.fetchedResultsController indexPathForObject:story];
        if (nil != indexPath) {
            [weakSelf.storyView reloadItemsAtIndexPaths:@[indexPath]];
        }
    };
    
    UIImage *image = story.image;
    
    if (nil == image)
        completionBlock();
    else {
        [self.enqueuedDecompressionOperations addObject:cacheKey];
        [self.imageDecompressionQueue addOperationWithBlock:^{
            //Draw the received image in a graphics context.
            UIGraphicsBeginImageContextWithOptions(image.size, YES, image.scale);
            [image drawAtPoint:CGPointZero blendMode:kCGBlendModeCopy alpha:1.0];
            UIImage *decompressed = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            
            //We're drawing the blurred image here too, but this is a shared OpenGLES graphics context.
            /*
            if (!story.blurredImage) {
                CIImage *imageToBlur = [CIImage imageWithCGImage:decompressed.CGImage];
                
                CGAffineTransform transform = CGAffineTransformIdentity;
                CIFilter *clampFilter = [CIFilter filterWithName:@"CIAffineClamp"];
                [clampFilter setValue:imageToBlur forKey:@"inputImage"];
                [clampFilter setValue:[NSValue valueWithBytes:&transform objCType:@encode(CGAffineTransform)] forKey:@"inputTransform"];
                
                CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
                [blurFilter setValue:clampFilter.outputImage forKey:@"inputImage"];
                [blurFilter setValue:@10 forKey:@"inputRadius"];
                
                CGImageRef filteredImage = [_blurContext createCGImage:blurFilter.outputImage fromRect:[imageToBlur extent]];
                story.blurredImage = [UIImage imageWithCGImage:filteredImage];
                CGImageRelease(filteredImage);
            }
             */
            
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                [weakSelf.decompressedImages setObject:decompressed forKey:cacheKey];
            }];
            
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                [weakSelf.enqueuedDecompressionOperations removeObject:cacheKey];
                completionBlock();
            }];
        }];
    }
}

- (void)focusOnStory:(DDGStory *)story animated:(BOOL)animated {
    if (nil != story) {
        NSIndexPath *indexPath = [self.fetchedResultsController indexPathForObject:story];
        if (nil != indexPath)
            [self.storyView scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionNone animated:animated];
    }
}

- (DDGStoryFetcher *)storyFetcher {
    if (nil == _storyFetcher)
        _storyFetcher = [[DDGStoryFetcher alloc] initWithParentManagedObjectContext:self.managedObjectContext];
    
    return _storyFetcher;
}

- (void)refreshStoriesTriggeredManually:(BOOL)manual includeSources:(BOOL)includeSources
{
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:DDGLastRefreshAttemptKey];
    if (includeSources) {
        [self refreshSources:manual];
    } else {
        [self refreshStories:manual];
    }
}

- (void)refreshSources:(BOOL)manual {
    if (!self.storyFetcher.isRefreshing) {
        __weak DDGStoriesViewController *weakSelf = self;
        [self.storyFetcher refreshSources:^(NSDate *feedDate){
            NSLog(@"refreshing sources");
            NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:[DDGStoryFeed entityName]];
            NSPredicate *iconPredicate = [NSPredicate predicateWithFormat:@"imageDownloaded == %@", @(NO)];
            [request setPredicate:iconPredicate];
            NSError *error = nil;
            NSArray *feeds = [weakSelf.managedObjectContext executeFetchRequest:request error:&error];
            if (nil == feeds) {
                NSLog(@"failed to fetch story feeds. Error: %@", error);
            }
            
            [weakSelf refreshStories:manual];
        }];
    }
}

- (void)refreshStories:(BOOL)manual {
    if (!self.storyFetcher.isRefreshing) {
        
        __block NSArray *oldStories = nil;        
        DDGStoriesViewController *weakSelf = self;
        
        void (^willSave)() = ^() {
            oldStories = [self.fetchedResultsController fetchedObjects];
            
            [NSFetchedResultsController deleteCacheWithName:weakSelf.fetchedResultsController.cacheName];
            weakSelf.fetchedResultsController.delegate = nil;
        };
        
        void (^completion)(NSDate *lastFetchDate) = ^(NSDate *feedDate) {
            NSArray *oldStories = [weakSelf.fetchedResultsController fetchedObjects];

            weakSelf.fetchedResultsController = nil;
            weakSelf.fetchedResultsController = [self fetchedResultsController:feedDate];
            
            NSArray *newStories = [self.fetchedResultsController fetchedObjects];
            NSInteger changes = [weakSelf replaceStories:oldStories withStories:newStories focusOnStory:nil];
            [weakSelf prepareUpcomingCellContent];
            
            isRefreshing = NO;
            /* Should only call this method if the refresh was triggered by a PTR */
            if (manual) {
                [refreshHeaderView egoRefreshScrollViewDataSourceDidFinishedLoading:weakSelf.storyView];
            }
            
            if(changes > 0 && [[NSUserDefaults standardUserDefaults] boolForKey:DDGSettingQuackOnRefresh]) {
                SystemSoundID quack;
                NSURL *url = [[NSBundle mainBundle] URLForResource:@"quack" withExtension:@"wav"];
                AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &quack);
                AudioServicesPlaySystemSound(quack);
            }
        };
        
        [self.storyFetcher refreshStories:willSave completion:completion];
    }
}

#pragma mark - NSFetchedResultsController

- (NSFetchedResultsController *)fetchedResultsController:(NSDate *)feedDate
{
    if (_fetchedResultsController != nil) {
        return _fetchedResultsController;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    // Edit the entity name as appropriate.
    NSEntityDescription *entity = [DDGStory entityInManagedObjectContext:self.managedObjectContext];
    [fetchRequest setEntity:entity];
    
    // Set the batch size to a suitable number.
    [fetchRequest setFetchBatchSize:20];
    
    // Edit the sort key as appropriate.
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"timeStamp" ascending:NO];
    NSArray *sortDescriptors = @[sortDescriptor];
    
    [fetchRequest setSortDescriptors:sortDescriptors];
    
    NSMutableArray *predicates = [NSMutableArray array];
    
    NSInteger readabilityMode = [[NSUserDefaults standardUserDefaults] integerForKey:DDGSettingStoriesReadabilityMode];
    if (readabilityMode == DDGReadabilityModeOnExclusive && !self.savedStoriesOnly)
        [predicates addObject:[NSPredicate predicateWithFormat:@"articleURLString.length > 0"]];
    
    if (nil != self.sourceFilter)
        [predicates addObject:[NSPredicate predicateWithFormat:@"feed == %@", self.sourceFilter]];
    if (self.savedStoriesOnly)
        [predicates addObject:[NSPredicate predicateWithFormat:@"saved == %@", @(YES)]];
    if (nil != feedDate && !self.savedStoriesOnly)
        [predicates addObject:[NSPredicate predicateWithFormat:@"feedDate == %@", feedDate]];    
    if ([predicates count] > 0)
        [fetchRequest setPredicate:[NSCompoundPredicate andPredicateWithSubpredicates:predicates]];
    
    // Edit the section name key path and cache name if appropriate.
    // nil for section name key path means "no sections".
    NSFetchedResultsController *aFetchedResultsController = [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:self.managedObjectContext sectionNameKeyPath:nil cacheName:nil];
    aFetchedResultsController.delegate = self;
    self.fetchedResultsController = aFetchedResultsController;
    
	NSError *error = nil;
	if (![self.fetchedResultsController performFetch:&error]) {
        // Replace this implementation with code to handle the error appropriately.
        // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
	    NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
	}
    
//    NSLog(@"feedDate: %@", feedDate);
//    for (DDGStory *story in [_fetchedResultsController fetchedObjects]) {
//        NSLog(@"story.feedDate: %@ (isEqual: %i)", story.feedDate, [feedDate isEqual:story.feedDate]);
//    }
    
    return _fetchedResultsController;
}

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller
{
//    [self.storyView beginUpdates];
}

- (void)controller:(NSFetchedResultsController *)controller didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex forChangeType:(NSFetchedResultsChangeType)type
{
    switch(type) {
        case NSFetchedResultsChangeInsert:
            [self.storyView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex]];
            break;
            
        case NSFetchedResultsChangeDelete:
            [self.storyView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex]];
            break;
      
        case NSFetchedResultsChangeMove:
        case NSFetchedResultsChangeUpdate:
            break;
    }
}

- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath
{
    [self.storyView reloadSections:[NSIndexSet indexSetWithIndex:0]];
//    UICollectionView *storyView = self.storyView;
//
//    switch(type) {
//        case NSFetchedResultsChangeInsert:
//            [storyView insertItemsAtIndexPaths:@[newIndexPath]];
//            break;
//            
//        case NSFetchedResultsChangeDelete:
//        {
//            [storyView deleteItemsAtIndexPaths:@[indexPath]];
//            if (self.savedStoriesOnly && [self.fetchedResultsController.fetchedObjects count] == 0)
//                [self performSelector:@selector(showNoStoriesView) withObject:nil afterDelay:0.2];
//            
//        }
//            break;
//            
//        case NSFetchedResultsChangeUpdate:
//            [self configureCell:(DDGStoryCell *)[storyView cellForItemAtIndexPath:indexPath] atIndexPath:indexPath];
//            break;
//            
//        case NSFetchedResultsChangeMove:
//            [storyView deleteItemsAtIndexPaths:@[indexPath]];
//            [storyView insertItemsAtIndexPaths:@[newIndexPath]];
//            break;
//    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    //[self.storyView endUpdates];
}

- (void)configureCell:(DDGStoryCell *)cell atIndexPath:(NSIndexPath *)indexPath
{
    DDGStory *story = [self.fetchedResultsController objectAtIndexPath:indexPath];
    cell.displaysDropShadow = (indexPath.item == ([self.storyView numberOfItemsInSection:0] - 1));
    cell.displaysInnerShadow = (indexPath.item != 0);
    cell.title = story.title;
    cell.read = story.readValue;
    if (story.feed) {
        cell.favicon = [story.feed image];
    }
    UIImage *image = [self.decompressedImages objectForKey:story.cacheKey];
    if (image) {
        cell.image = image;
    } else {
        if (story.isImageDownloaded) {
            [self decompressAndDisplayImageForStory:story];
        } else {
            __weak typeof(self) weakSelf = self;
            [self.storyFetcher downloadImageForStory:story completion:^(BOOL success) {
                [weakSelf configureCell:cell atIndexPath:indexPath];
            }];
        }
    }
}


@end

// DO NOT EDIT. This file is machine-generated and constantly overwritten.
// Make changes to DDGHistoryItem.m instead.

#import "_DDGHistoryItem.h"

const struct DDGHistoryItemAttributes DDGHistoryItemAttributes = {
	.timeStamp = @"timeStamp",
	.title = @"title",
	.urlString = @"urlString",
};

const struct DDGHistoryItemRelationships DDGHistoryItemRelationships = {
	.story = @"story",
};

const struct DDGHistoryItemFetchedProperties DDGHistoryItemFetchedProperties = {
	.fetchedProperty = @"fetchedProperty",
};

@implementation DDGHistoryItemID
@end

@implementation _DDGHistoryItem

+ (id)insertInManagedObjectContext:(NSManagedObjectContext*)moc_ {
	NSParameterAssert(moc_);
	return [NSEntityDescription insertNewObjectForEntityForName:@"HistoryItem" inManagedObjectContext:moc_];
}

+ (NSString*)entityName {
	return @"HistoryItem";
}

+ (NSEntityDescription*)entityInManagedObjectContext:(NSManagedObjectContext*)moc_ {
	NSParameterAssert(moc_);
	return [NSEntityDescription entityForName:@"HistoryItem" inManagedObjectContext:moc_];
}

- (DDGHistoryItemID*)objectID {
	return (DDGHistoryItemID*)[super objectID];
}

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
	NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey:key];
	

	return keyPaths;
}




@dynamic timeStamp;






@dynamic title;






@dynamic urlString;






@dynamic story;

	



@dynamic fetchedProperty;




+ (NSArray*)fetchHistoryItemsWithPrefix:(NSManagedObjectContext*)moc_ {
	NSError *error = nil;
	NSArray *result = [self fetchHistoryItemsWithPrefix:moc_ error:&error];
	if (error) {
#if TARGET_OS_IPHONE
		NSLog(@"error: %@", error);
#else
		[NSApp presentError:error];
#endif
	}
	return result;
}
+ (NSArray*)fetchHistoryItemsWithPrefix:(NSManagedObjectContext*)moc_ error:(NSError**)error_ {
	NSParameterAssert(moc_);
	NSError *error = nil;
	
	NSManagedObjectModel *model = [[moc_ persistentStoreCoordinator] managedObjectModel];
	
	NSDictionary *substitutionVariables = [NSDictionary dictionary];
										
	NSFetchRequest *fetchRequest = [model fetchRequestFromTemplateWithName:@"historyItemsWithPrefix"
													 substitutionVariables:substitutionVariables];
	NSAssert(fetchRequest, @"Can't find fetch request named \"historyItemsWithPrefix\".");
	
	NSArray *result = [moc_ executeFetchRequest:fetchRequest error:&error];
	if (error_) *error_ = error;
	return result;
}



@end
